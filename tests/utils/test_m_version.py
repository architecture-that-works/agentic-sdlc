import tomllib
from pathlib import Path

from src.utils.m_version import get_version


def test_get_version_returns_declared_version():
    pyproject = Path(__file__).parents[2] / "pyproject.toml"
    with pyproject.open("rb") as f:
        expected = tomllib.load(f)["project"]["version"]
    assert get_version() == expected


def test_get_version_returns_nonempty_string():
    assert isinstance(get_version(), str)
    assert len(get_version()) > 0
