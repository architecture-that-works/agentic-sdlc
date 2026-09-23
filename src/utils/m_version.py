import tomllib
from pathlib import Path


def get_version() -> str:
    path = Path(__file__).parents[2] / "pyproject.toml"
    with path.open("rb") as f:
        data = tomllib.load(f)
    return data["project"]["version"]
