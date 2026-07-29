"""
Codebase-map generator — PageRank-ranked symbol map for agent context.

Extracts Python symbols (functions, classes) via the stdlib ``ast`` module,
builds import-dependency edges, computes a PageRank-style relevance score
(power iteration, pure Python), and serialises the top-ranked symbols into a
fixed token budget (~1024 tokens).

Relationship to the Module Map
-------------------------------
This tool produces an **auto-generated ranked snapshot** — it is NOT the
authoritative Module Map in ``CONTEXT.md``.  The two are complementary:

  Module Map (CONTEXT.md)  — governance: bounded-context boundaries,
                              issue-type routing, skill index.
                              Updated by humans via the ``ship`` skill.
                              Source of truth for agent navigation.

  Codebase Map (this tool) — efficiency: auto-ranked symbol snapshot for
                              cold-starting agents entering an unfamiliar repo.
                              Never authoritative; safe to regenerate freely.
                              Load in addition to, never instead of, CONTEXT.md.

Kill criterion (issue #121): if generation exceeds ``--timeout`` (default 15s),
the output includes a WARN header so the generator is flagged for optimisation
rather than silently slow-starting a session.

Usage (harness probe)
---------------------
    uv run python -m src.tools.codebase_map [--root <path>]
                                             [--format md|json]
                                             [--budget <tokens>]
                                             [--timeout <secs>]
"""

from __future__ import annotations

import argparse
import ast
import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

_CHARS_PER_TOKEN: int = 4
_DEFAULT_BUDGET_TOKENS: int = 1024
_DEFAULT_TIMEOUT_SECS: float = 15.0
_PAGERANK_DAMPING: float = 0.85
_PAGERANK_ITERATIONS: int = 30
_PAGERANK_CONVERGENCE: float = 1e-6


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Symbol:
    """A symbol extracted from a source file."""

    module: str
    name: str
    kind: str
    signature: str
    lineno: int


@dataclass
class ModuleEntry:
    """A module with its PageRank score and symbols, ready for serialisation."""

    module: str
    score: float
    symbols: list[Symbol] = field(default_factory=list)


# ---------------------------------------------------------------------------
# File discovery
# ---------------------------------------------------------------------------


def discover_files(root: Path) -> list[Path]:
    """Return all .py files under root, sorted for determinism."""
    return sorted(root.rglob("*.py"))


def module_key(filepath: Path, root: Path) -> str:
    """Relative POSIX path from root used as the graph node key."""
    try:
        return filepath.relative_to(root).as_posix()
    except ValueError:
        return filepath.as_posix()


# ---------------------------------------------------------------------------
# Symbol extraction
# ---------------------------------------------------------------------------


def _ast_name(node: ast.expr) -> str:
    """Extract a readable name string from an AST expression node."""
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return f"{_ast_name(node.value)}.{node.attr}"
    if isinstance(node, ast.Subscript):
        return f"{_ast_name(node.value)}[...]"
    if isinstance(node, ast.Constant):
        return repr(node.value)
    return "..."


def _args_signature(args: ast.arguments) -> str:
    """Flatten an ast.arguments node into a compact readable string."""
    parts: list[str] = []

    for arg in getattr(args, "posonlyargs", []):
        ann = f": {_ast_name(arg.annotation)}" if arg.annotation else ""
        parts.append(f"{arg.arg}{ann}")
    if getattr(args, "posonlyargs", []):
        parts.append("/")

    defaults_offset = len(args.args) - len(args.defaults)
    for i, arg in enumerate(args.args):
        ann = f": {_ast_name(arg.annotation)}" if arg.annotation else ""
        name = f"{arg.arg}{ann}"
        if (i - defaults_offset) >= 0:
            name += "=..."
        parts.append(name)

    if args.vararg:
        parts.append(f"*{args.vararg.arg}")
    elif args.kwonlyargs:
        parts.append("*")

    for i, kw in enumerate(args.kwonlyargs):
        ann = f": {_ast_name(kw.annotation)}" if kw.annotation else ""
        name = f"{kw.arg}{ann}"
        if args.kw_defaults[i] is not None:
            name += "=..."
        parts.append(name)

    if args.kwarg:
        parts.append(f"**{args.kwarg.arg}")

    return ", ".join(parts)


def extract_symbols(filepath: Path, root: Path) -> list[Symbol]:
    """Extract module-level class and function symbols via stdlib ast.

    Returns an empty list for unparseable files (syntax errors, binary).
    """
    key = module_key(filepath, root)
    try:
        source = filepath.read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(source, filename=str(filepath))
    except (SyntaxError, OSError):
        return []

    symbols: list[Symbol] = []
    for node in ast.iter_child_nodes(tree):
        if isinstance(node, ast.ClassDef):
            bases = ", ".join(_ast_name(b) for b in node.bases) if node.bases else ""
            sig = f"class {node.name}({bases})" if bases else f"class {node.name}"
            symbols.append(
                Symbol(
                    module=key,
                    name=node.name,
                    kind="class",
                    signature=sig,
                    lineno=node.lineno,
                )
            )
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            is_async = isinstance(node, ast.AsyncFunctionDef)
            prefix = "async def" if is_async else "def"
            args_str = _args_signature(node.args)
            ret = f" -> {_ast_name(node.returns)}" if node.returns else ""
            sig = f"{prefix} {node.name}({args_str}){ret}"
            if len(sig) > 80:
                sig = sig[:77] + "..."
            symbols.append(
                Symbol(
                    module=key,
                    name=node.name,
                    kind="async_function" if is_async else "function",
                    signature=sig,
                    lineno=node.lineno,
                )
            )
    return symbols


# ---------------------------------------------------------------------------
# Import graph
# ---------------------------------------------------------------------------


def _resolve_module(
    dotted: str,
    level: int,
    file_pkg: str,
    known_keys: frozenset[str],
) -> str | None:
    """Resolve an import to a known module key, or None if not in-project."""
    if level > 0:
        pkg_parts = file_pkg.split("/") if file_pkg else []
        base_parts = pkg_parts[: max(0, len(pkg_parts) - (level - 1))]
        if dotted:
            base_parts.extend(dotted.split("."))
        full = "/".join(base_parts)
    else:
        full = dotted.replace(".", "/")

    for candidate in (f"{full}.py", f"{full}/__init__.py"):
        if candidate in known_keys:
            return candidate
    return None


def extract_imports(
    filepath: Path,
    root: Path,
    known_keys: frozenset[str],
) -> frozenset[str]:
    """Return the set of known module keys that filepath imports."""
    key = module_key(filepath, root)
    file_pkg = "/".join(key.rsplit("/", 1)[:-1]) if "/" in key else ""

    try:
        source = filepath.read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(source, filename=str(filepath))
    except (SyntaxError, OSError):
        return frozenset()

    found: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                resolved = _resolve_module(alias.name, 0, file_pkg, known_keys)
                if resolved and resolved != key:
                    found.add(resolved)
        elif isinstance(node, ast.ImportFrom):
            lv = node.level or 0
            if node.module:
                resolved = _resolve_module(node.module, lv, file_pkg, known_keys)
                if resolved and resolved != key:
                    found.add(resolved)
            elif lv > 0:
                pkg_parts = file_pkg.split("/") if file_pkg else []
                base_parts = pkg_parts[: max(0, len(pkg_parts) - (lv - 1))]
                full = "/".join(base_parts)
                for candidate in (f"{full}.py", f"{full}/__init__.py"):
                    if candidate in known_keys and candidate != key:
                        found.add(candidate)
                        break
    return frozenset(found)


def build_import_graph(root: Path, files: list[Path]) -> dict[str, frozenset[str]]:
    """Build a module-key → frozenset[imported-module-key] adjacency dict."""
    keys: frozenset[str] = frozenset(module_key(f, root) for f in files)
    graph: dict[str, frozenset[str]] = {}
    for f in files:
        k = module_key(f, root)
        graph[k] = extract_imports(f, root, keys)
    for k in keys:
        graph.setdefault(k, frozenset())
    return graph


# ---------------------------------------------------------------------------
# PageRank
# ---------------------------------------------------------------------------


def pagerank(
    graph: dict[str, frozenset[str]],
    *,
    damping: float = _PAGERANK_DAMPING,
    iterations: int = _PAGERANK_ITERATIONS,
    convergence: float = _PAGERANK_CONVERGENCE,
) -> dict[str, float]:
    """Power-iteration PageRank on an import-dependency graph.

    Edges represent imports: A → B means A imports B.
    Nodes that many others import accumulate high rank.
    Convergence is guaranteed: ranks sum to 1.0 at every step.
    """
    nodes = sorted(graph.keys())
    if not nodes:
        return {}
    n = len(nodes)
    rank: dict[str, float] = {node: 1.0 / n for node in nodes}

    for _ in range(iterations):
        new_rank: dict[str, float] = {node: (1.0 - damping) / n for node in nodes}
        for src in nodes:
            dests = graph[src]
            if not dests:
                contrib = rank[src] * damping / n
                for node in nodes:
                    new_rank[node] += contrib
            else:
                contrib = rank[src] * damping / len(dests)
                for dest in dests:
                    if dest in new_rank:
                        new_rank[dest] += contrib
        delta = sum(abs(new_rank[node] - rank[node]) for node in nodes)
        rank = new_rank
        if delta < convergence:
            break

    return rank


# ---------------------------------------------------------------------------
# Serialisation
# ---------------------------------------------------------------------------


def _render_module_md(entry: ModuleEntry) -> str:
    lines = [f"## {entry.module}  (score: {entry.score:.4f})"]
    if entry.symbols:
        lines.append("```python")
        for sym in entry.symbols:
            lines.append(sym.signature)
        lines.append("```")
    return "\n".join(lines)


def serialise_map(
    ranked: list[ModuleEntry],
    *,
    budget_tokens: int = _DEFAULT_BUDGET_TOKENS,
    elapsed: float = 0.0,
    timeout_exceeded: bool = False,
    fmt: Literal["md", "json"] = "md",
) -> str:
    """Serialise ranked modules into a string within the token budget."""
    if fmt == "json":
        return _serialise_json(
            ranked,
            budget_tokens=budget_tokens,
            timeout_exceeded=timeout_exceeded,
        )
    return _serialise_md(
        ranked,
        budget_tokens=budget_tokens,
        elapsed=elapsed,
        timeout_exceeded=timeout_exceeded,
    )


def _serialise_md(
    ranked: list[ModuleEntry],
    *,
    budget_tokens: int,
    elapsed: float,
    timeout_exceeded: bool,
) -> str:
    warn = (
        f"\n> WARNING: generation exceeded timeout ({elapsed:.1f}s). "
        "Flag for optimisation.\n"
        if timeout_exceeded
        else ""
    )
    header = (
        "<!-- CODEBASE-MAP:BEGIN -->\n"
        "# Auto-Generated Codebase Map\n"
        f"{warn}\n"
        # No wall-clock generation time here — the map is a reproducible artifact
        # (see generate_codebase_map's determinism contract). Elapsed is still used
        # above for the timeout WARNING, which is an error path, not steady state.
        f"> Budget: {budget_tokens} tokens\n"
        ">\n"
        "> **Relationship to Module Map:** This map is auto-generated and ranked\n"
        "> by import-graph PageRank. It complements — and must not replace — the\n"
        "> hand-curated Module Map in `CONTEXT.md`, which is the authoritative\n"
        "> governance document for bounded contexts and agent navigation.\n"
        "\n"
    )
    footer = "\n<!-- CODEBASE-MAP:END -->\n"
    budget_chars = budget_tokens * _CHARS_PER_TOKEN
    used_chars = len(header) + len(footer)

    sections: list[str] = []
    for entry in ranked:
        section = _render_module_md(entry)
        if used_chars + len(section) + 1 > budget_chars:
            break
        sections.append(section)
        used_chars += len(section) + 1

    return header + "\n".join(sections) + footer


def _serialise_json(
    ranked: list[ModuleEntry],
    *,
    budget_tokens: int,
    timeout_exceeded: bool,
) -> str:
    budget_chars = budget_tokens * _CHARS_PER_TOKEN
    # No wall-clock timing field — keeps the JSON artifact reproducible, matching
    # generate_codebase_map's determinism contract.
    wrapper: dict = {
        "budget_tokens": budget_tokens,
        "timeout_exceeded": timeout_exceeded,
        "note": (
            "Auto-generated ranked map. Complements but does not replace "
            "the Module Map in CONTEXT.md."
        ),
        "modules": [],
    }
    # Use compact JSON throughout so budget accounting matches output size exactly.
    overhead = len(json.dumps(wrapper, separators=(",", ":")))
    remaining = budget_chars - overhead

    modules: list[dict] = []
    for entry in ranked:
        obj: dict = {
            "module": entry.module,
            "score": round(entry.score, 6),
            "symbols": [
                {"name": s.name, "kind": s.kind, "signature": s.signature}
                for s in entry.symbols
            ],
        }
        encoded = json.dumps(obj, separators=(",", ":"))
        if remaining - len(encoded) < 0:
            break
        modules.append(obj)
        remaining -= len(encoded)

    wrapper["modules"] = modules
    return json.dumps(wrapper, separators=(",", ":"))


# ---------------------------------------------------------------------------
# Main generator
# ---------------------------------------------------------------------------


def generate_codebase_map(
    root: Path,
    *,
    budget_tokens: int = _DEFAULT_BUDGET_TOKENS,
    timeout_secs: float = _DEFAULT_TIMEOUT_SECS,
    fmt: Literal["md", "json"] = "md",
) -> str:
    """Generate a PageRank-ranked codebase map within the token budget.

    Deterministic: identical input tree produces identical output.
    Time-bounded: if elapsed > timeout_secs, a WARN header is added.
    """
    t0 = time.monotonic()

    files = discover_files(root)
    file_symbols: dict[str, list[Symbol]] = {
        module_key(f, root): extract_symbols(f, root) for f in files
    }
    graph = build_import_graph(root, files)
    scores = pagerank(graph)

    sorted_modules = sorted(scores.keys(), key=lambda k: (-scores[k], k))
    ranked = [
        ModuleEntry(
            module=mod,
            score=scores[mod],
            symbols=file_symbols.get(mod, []),
        )
        for mod in sorted_modules
    ]

    elapsed = time.monotonic() - t0
    return serialise_map(
        ranked,
        budget_tokens=budget_tokens,
        elapsed=elapsed,
        timeout_exceeded=elapsed > timeout_secs,
        fmt=fmt,
    )


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a PageRank-ranked codebase map for agent context."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("."),
        help="Repository root (default: current directory)",
    )
    parser.add_argument(
        "--format",
        dest="fmt",
        choices=["md", "json"],
        default="md",
        help="Output format: md or json (default: md)",
    )
    parser.add_argument(
        "--budget",
        type=int,
        default=_DEFAULT_BUDGET_TOKENS,
        help=f"Token budget for the output (default: {_DEFAULT_BUDGET_TOKENS})",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=_DEFAULT_TIMEOUT_SECS,
        help=f"Timeout in seconds; exceeded → WARN header (default: {_DEFAULT_TIMEOUT_SECS})",
    )
    args = parser.parse_args()

    result = generate_codebase_map(
        args.root.resolve(),
        budget_tokens=args.budget,
        timeout_secs=args.timeout,
        fmt=args.fmt,
    )
    print(result)


if __name__ == "__main__":
    main()
