"""Tests for src/tools/codebase_map.py — PageRank codebase-map generator.

Covers:
1. Symbol extraction (classes, functions, async functions, signatures)
2. Import resolution and graph construction
3. PageRank algorithm correctness (convergence, sum, monotonicity)
4. Token budget enforcement in both md and json formats
5. Determinism (same input → same output)
6. Timeout warning in output
7. Integration: generate_codebase_map on this repo's src/
"""

from __future__ import annotations

import json
import textwrap
from pathlib import Path

import pytest

from src.tools.codebase_map import (
    _CHARS_PER_TOKEN,
    _DEFAULT_BUDGET_TOKENS,
    ModuleEntry,
    Symbol,
    build_import_graph,
    discover_files,
    extract_imports,
    extract_symbols,
    generate_codebase_map,
    module_key,
    pagerank,
    serialise_map,
)

REPO_ROOT = Path(__file__).resolve().parents[2]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _write(path: Path, code: str) -> None:
    path.write_text(textwrap.dedent(code), encoding="utf-8")


# ---------------------------------------------------------------------------
# module_key
# ---------------------------------------------------------------------------


def test_module_key_relative_posix(tmp_path: Path) -> None:
    f = tmp_path / "src" / "config.py"
    assert module_key(f, tmp_path) == "src/config.py"


def test_module_key_top_level(tmp_path: Path) -> None:
    f = tmp_path / "main.py"
    assert module_key(f, tmp_path) == "main.py"


# ---------------------------------------------------------------------------
# discover_files
# ---------------------------------------------------------------------------


def test_discover_files_returns_sorted(tmp_path: Path) -> None:
    (tmp_path / "b.py").write_text("", encoding="utf-8")
    (tmp_path / "a.py").write_text("", encoding="utf-8")
    files = discover_files(tmp_path)
    names = [f.name for f in files]
    assert names == sorted(names)


def test_discover_files_recurses(tmp_path: Path) -> None:
    sub = tmp_path / "sub"
    sub.mkdir()
    (sub / "deep.py").write_text("", encoding="utf-8")
    (tmp_path / "top.py").write_text("", encoding="utf-8")
    files = discover_files(tmp_path)
    keys = {module_key(f, tmp_path) for f in files}
    assert "sub/deep.py" in keys
    assert "top.py" in keys


def test_discover_files_ignores_non_py(tmp_path: Path) -> None:
    (tmp_path / "notes.txt").write_text("", encoding="utf-8")
    (tmp_path / "app.py").write_text("", encoding="utf-8")
    files = discover_files(tmp_path)
    assert all(f.suffix == ".py" for f in files)


# ---------------------------------------------------------------------------
# extract_symbols
# ---------------------------------------------------------------------------


def test_extract_symbols_class(tmp_path: Path) -> None:
    f = tmp_path / "mod.py"
    _write(
        f,
        """\
        class Foo:
            pass
        """,
    )
    syms = extract_symbols(f, tmp_path)
    assert len(syms) == 1
    assert syms[0].name == "Foo"
    assert syms[0].kind == "class"
    assert "class Foo" in syms[0].signature


def test_extract_symbols_class_with_bases(tmp_path: Path) -> None:
    f = tmp_path / "mod.py"
    _write(
        f,
        """\
        class Bar(Base1, Base2):
            pass
        """,
    )
    syms = extract_symbols(f, tmp_path)
    assert len(syms) == 1
    assert "Base1, Base2" in syms[0].signature


def test_extract_symbols_function(tmp_path: Path) -> None:
    f = tmp_path / "mod.py"
    _write(
        f,
        """\
        def greet(name: str) -> str:
            return name
        """,
    )
    syms = extract_symbols(f, tmp_path)
    assert len(syms) == 1
    assert syms[0].name == "greet"
    assert syms[0].kind == "function"
    assert "def greet" in syms[0].signature
    assert "-> str" in syms[0].signature


def test_extract_symbols_async_function(tmp_path: Path) -> None:
    f = tmp_path / "mod.py"
    _write(
        f,
        """\
        async def fetch(url: str) -> bytes:
            ...
        """,
    )
    syms = extract_symbols(f, tmp_path)
    assert len(syms) == 1
    assert syms[0].kind == "async_function"
    assert "async def fetch" in syms[0].signature


def test_extract_symbols_skips_inner_functions(tmp_path: Path) -> None:
    f = tmp_path / "mod.py"
    _write(
        f,
        """\
        def outer():
            def inner():
                pass
        """,
    )
    syms = extract_symbols(f, tmp_path)
    names = [s.name for s in syms]
    assert "outer" in names
    assert "inner" not in names


def test_extract_symbols_skips_methods(tmp_path: Path) -> None:
    f = tmp_path / "mod.py"
    _write(
        f,
        """\
        class MyClass:
            def method(self) -> None:
                pass
        """,
    )
    syms = extract_symbols(f, tmp_path)
    names = [s.name for s in syms]
    assert "MyClass" in names
    assert "method" not in names


def test_extract_symbols_returns_empty_on_syntax_error(tmp_path: Path) -> None:
    f = tmp_path / "broken.py"
    f.write_text("def (: pass", encoding="utf-8")
    assert extract_symbols(f, tmp_path) == []


def test_extract_symbols_long_signature_truncated(tmp_path: Path) -> None:
    f = tmp_path / "mod.py"
    params = ", ".join(f"param_{i}: int = 0" for i in range(20))
    f.write_text(f"def big({params}) -> None: pass\n", encoding="utf-8")
    syms = extract_symbols(f, tmp_path)
    assert len(syms) == 1
    assert len(syms[0].signature) <= 80


def test_extract_symbols_multiple_top_level(tmp_path: Path) -> None:
    f = tmp_path / "mod.py"
    _write(
        f,
        """\
        class A:
            pass

        def b():
            pass

        class C(A):
            pass
        """,
    )
    syms = extract_symbols(f, tmp_path)
    names = [s.name for s in syms]
    assert names == ["A", "b", "C"]


def test_extract_symbols_module_key_stored(tmp_path: Path) -> None:
    sub = tmp_path / "pkg"
    sub.mkdir()
    f = sub / "mod.py"
    _write(f, "class X: pass\n")
    syms = extract_symbols(f, tmp_path)
    assert syms[0].module == "pkg/mod.py"


# ---------------------------------------------------------------------------
# extract_imports
# ---------------------------------------------------------------------------


def test_extract_imports_absolute(tmp_path: Path) -> None:
    (tmp_path / "config.py").write_text("", encoding="utf-8")
    f = tmp_path / "main.py"
    _write(f, "from config import settings\n")
    known = frozenset(["config.py", "main.py"])
    result = extract_imports(f, tmp_path, known)
    assert "config.py" in result


def test_extract_imports_ignores_stdlib(tmp_path: Path) -> None:
    f = tmp_path / "mod.py"
    _write(f, "import os\nimport sys\n")
    known = frozenset(["mod.py"])
    result = extract_imports(f, tmp_path, known)
    assert result == frozenset()


def test_extract_imports_ignores_self(tmp_path: Path) -> None:
    f = tmp_path / "mod.py"
    _write(f, "from mod import something\n")
    known = frozenset(["mod.py"])
    result = extract_imports(f, tmp_path, known)
    assert "mod.py" not in result


def test_extract_imports_relative(tmp_path: Path) -> None:
    pkg = tmp_path / "pkg"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("", encoding="utf-8")
    (pkg / "utils.py").write_text("", encoding="utf-8")
    f = pkg / "main.py"
    _write(f, "from .utils import helper\n")
    known = frozenset(["pkg/__init__.py", "pkg/utils.py", "pkg/main.py"])
    result = extract_imports(f, tmp_path, known)
    assert "pkg/utils.py" in result


def test_extract_imports_nested_path(tmp_path: Path) -> None:
    src = tmp_path / "src"
    src.mkdir()
    utils = src / "utils"
    utils.mkdir()
    (utils / "m_log.py").write_text("", encoding="utf-8")
    f = src / "main.py"
    _write(f, "from src.utils.m_log import f_log\n")
    known = frozenset(["src/main.py", "src/utils/m_log.py"])
    result = extract_imports(f, tmp_path, known)
    assert "src/utils/m_log.py" in result


def test_extract_imports_returns_frozenset(tmp_path: Path) -> None:
    f = tmp_path / "mod.py"
    f.write_text("", encoding="utf-8")
    result = extract_imports(f, tmp_path, frozenset(["mod.py"]))
    assert isinstance(result, frozenset)


# ---------------------------------------------------------------------------
# build_import_graph
# ---------------------------------------------------------------------------


def test_build_import_graph_all_nodes_present(tmp_path: Path) -> None:
    for name in ("a.py", "b.py", "c.py"):
        (tmp_path / name).write_text("", encoding="utf-8")
    files = discover_files(tmp_path)
    graph = build_import_graph(tmp_path, files)
    keys = {module_key(f, tmp_path) for f in files}
    assert set(graph.keys()) == keys


def test_build_import_graph_edges(tmp_path: Path) -> None:
    (tmp_path / "base.py").write_text("", encoding="utf-8")
    (tmp_path / "app.py").write_text("from base import X\n", encoding="utf-8")
    files = discover_files(tmp_path)
    graph = build_import_graph(tmp_path, files)
    assert "base.py" in graph["app.py"]


# ---------------------------------------------------------------------------
# pagerank
# ---------------------------------------------------------------------------


def test_pagerank_empty_graph() -> None:
    assert pagerank({}) == {}


def test_pagerank_single_node() -> None:
    graph: dict[str, frozenset[str]] = {"a.py": frozenset()}
    scores = pagerank(graph)
    assert pytest.approx(scores["a.py"], abs=1e-6) == 1.0


def test_pagerank_sum_approximately_one() -> None:
    graph: dict[str, frozenset[str]] = {
        "a.py": frozenset({"b.py"}),
        "b.py": frozenset({"c.py"}),
        "c.py": frozenset(),
    }
    scores = pagerank(graph)
    total = sum(scores.values())
    assert pytest.approx(total, abs=1e-4) == 1.0


def test_pagerank_chain_sink_highest_rank() -> None:
    """In a chain A→B→C, C (the sink) should receive the most rank."""
    graph: dict[str, frozenset[str]] = {
        "a.py": frozenset({"b.py"}),
        "b.py": frozenset({"c.py"}),
        "c.py": frozenset(),
    }
    scores = pagerank(graph)
    assert scores["c.py"] >= scores["b.py"]
    assert scores["c.py"] >= scores["a.py"]


def test_pagerank_isolated_node_has_some_rank() -> None:
    graph: dict[str, frozenset[str]] = {
        "a.py": frozenset({"b.py"}),
        "b.py": frozenset(),
        "orphan.py": frozenset(),
    }
    scores = pagerank(graph)
    assert scores["orphan.py"] > 0.0


def test_pagerank_all_nodes_positive() -> None:
    graph: dict[str, frozenset[str]] = {
        "a.py": frozenset({"b.py", "c.py"}),
        "b.py": frozenset({"c.py"}),
        "c.py": frozenset(),
    }
    scores = pagerank(graph)
    assert all(v > 0.0 for v in scores.values())


def test_pagerank_deterministic() -> None:
    graph: dict[str, frozenset[str]] = {
        "a.py": frozenset({"b.py"}),
        "b.py": frozenset({"c.py"}),
        "c.py": frozenset({"a.py"}),
    }
    scores_1 = pagerank(graph)
    scores_2 = pagerank(graph)
    assert scores_1 == scores_2


def test_pagerank_hub_has_higher_rank_than_leaf() -> None:
    """Node 'hub' is imported by both 'a' and 'b'; leaf is imported by none."""
    graph: dict[str, frozenset[str]] = {
        "a.py": frozenset({"hub.py"}),
        "b.py": frozenset({"hub.py"}),
        "hub.py": frozenset(),
        "leaf.py": frozenset(),
    }
    scores = pagerank(graph)
    assert scores["hub.py"] > scores["leaf.py"]


# ---------------------------------------------------------------------------
# serialise_map
# ---------------------------------------------------------------------------


def _make_entries(n: int = 5) -> list[ModuleEntry]:
    return [
        ModuleEntry(
            module=f"src/module_{i}.py",
            score=1.0 / (i + 1),
            symbols=[
                Symbol(
                    module=f"src/module_{i}.py",
                    name=f"Class{i}",
                    kind="class",
                    signature=f"class Class{i}",
                    lineno=1,
                )
            ],
        )
        for i in range(n)
    ]


def test_serialise_map_md_within_budget() -> None:
    entries = _make_entries(20)
    result = serialise_map(entries, budget_tokens=256, fmt="md")
    assert len(result) <= 256 * _CHARS_PER_TOKEN + 200  # small slack for header/footer


def test_serialise_map_md_contains_markers() -> None:
    result = serialise_map(_make_entries(3), fmt="md")
    assert "<!-- CODEBASE-MAP:BEGIN -->" in result
    assert "<!-- CODEBASE-MAP:END -->" in result


def test_serialise_map_md_contains_module_map_note() -> None:
    result = serialise_map(_make_entries(1), fmt="md")
    assert "CONTEXT.md" in result
    assert "Module Map" in result


def test_serialise_map_timeout_warn_in_md() -> None:
    result = serialise_map(
        _make_entries(1), elapsed=20.0, timeout_exceeded=True, fmt="md"
    )
    assert "WARNING" in result
    assert "20.0s" in result


def test_serialise_map_no_warn_without_timeout() -> None:
    result = serialise_map(
        _make_entries(1), elapsed=1.0, timeout_exceeded=False, fmt="md"
    )
    assert "WARNING" not in result


def test_serialise_map_json_valid() -> None:
    result = serialise_map(_make_entries(3), fmt="json")
    parsed = json.loads(result)
    assert "modules" in parsed
    assert "budget_tokens" in parsed
    assert "note" in parsed


def test_serialise_map_json_within_budget() -> None:
    entries = _make_entries(50)
    result = serialise_map(entries, budget_tokens=256, fmt="json")
    assert len(result) <= 256 * _CHARS_PER_TOKEN + 200


def test_serialise_map_json_timeout_flag() -> None:
    result = serialise_map(
        _make_entries(1), elapsed=30.0, timeout_exceeded=True, fmt="json"
    )
    parsed = json.loads(result)
    assert parsed["timeout_exceeded"] is True


def test_serialise_map_md_modules_listed_by_score() -> None:
    entries = [
        ModuleEntry("high.py", 0.9, []),
        ModuleEntry("low.py", 0.1, []),
    ]
    result = serialise_map(entries, fmt="md")
    assert result.index("high.py") < result.index("low.py")


# ---------------------------------------------------------------------------
# generate_codebase_map
# ---------------------------------------------------------------------------


def test_generate_codebase_map_within_budget(tmp_path: Path) -> None:
    for i in range(10):
        (tmp_path / f"mod_{i}.py").write_text(f"class C{i}: pass\n", encoding="utf-8")
    result = generate_codebase_map(tmp_path, budget_tokens=512)
    assert len(result) <= 512 * _CHARS_PER_TOKEN + 300


def test_generate_codebase_map_deterministic(tmp_path: Path) -> None:
    (tmp_path / "a.py").write_text("class A: pass\n", encoding="utf-8")
    (tmp_path / "b.py").write_text(
        "from a import A\nclass B(A): pass\n", encoding="utf-8"
    )
    r1 = generate_codebase_map(tmp_path)
    r2 = generate_codebase_map(tmp_path)
    assert r1 == r2


def test_generate_codebase_map_timeout_warn(tmp_path: Path) -> None:
    (tmp_path / "x.py").write_text("", encoding="utf-8")
    result = generate_codebase_map(tmp_path, timeout_secs=0.0)
    assert "WARNING" in result


def test_generate_codebase_map_json_output(tmp_path: Path) -> None:
    (tmp_path / "a.py").write_text("class A: pass\n", encoding="utf-8")
    result = generate_codebase_map(tmp_path, fmt="json")
    parsed = json.loads(result)
    assert isinstance(parsed["modules"], list)
    assert parsed["modules"][0]["module"] == "a.py"


def test_generate_codebase_map_empty_root(tmp_path: Path) -> None:
    result = generate_codebase_map(tmp_path)
    assert "<!-- CODEBASE-MAP:BEGIN -->" in result


def test_generate_codebase_map_ranked_by_imports(tmp_path: Path) -> None:
    """The most-imported module should appear first in the output."""
    (tmp_path / "hub.py").write_text("class Hub: pass\n", encoding="utf-8")
    (tmp_path / "user1.py").write_text("from hub import Hub\n", encoding="utf-8")
    (tmp_path / "user2.py").write_text("from hub import Hub\n", encoding="utf-8")
    (tmp_path / "leaf.py").write_text("class Leaf: pass\n", encoding="utf-8")
    result = generate_codebase_map(tmp_path, fmt="md")
    assert result.index("hub.py") < result.index("leaf.py")


# ---------------------------------------------------------------------------
# Integration: run against this repo's src/ directory
# ---------------------------------------------------------------------------


def test_generate_codebase_map_on_repo_src() -> None:
    src_root = REPO_ROOT / "src"
    result = generate_codebase_map(src_root, budget_tokens=_DEFAULT_BUDGET_TOKENS)
    assert "<!-- CODEBASE-MAP:BEGIN -->" in result
    assert "<!-- CODEBASE-MAP:END -->" in result
    # src/config.py and src/main.py must appear (they're always in the repo)
    assert "config.py" in result or "main.py" in result
    # output fits in budget (with a small slack for header/footer)
    assert len(result) <= _DEFAULT_BUDGET_TOKENS * _CHARS_PER_TOKEN + 500


def test_generate_codebase_map_on_repo_src_is_deterministic() -> None:
    src_root = REPO_ROOT / "src"
    r1 = generate_codebase_map(src_root)
    r2 = generate_codebase_map(src_root)
    assert r1 == r2


def test_generate_codebase_map_on_repo_src_within_15s() -> None:
    import time

    src_root = REPO_ROOT / "src"
    t0 = time.monotonic()
    generate_codebase_map(src_root)
    elapsed = time.monotonic() - t0
    assert elapsed < 15.0, (
        f"Generation took {elapsed:.2f}s — exceeds 15s kill criterion"
    )
