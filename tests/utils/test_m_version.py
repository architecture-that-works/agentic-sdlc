from src.utils.m_version import get_version


def test_get_version_returns_declared_version():
    assert get_version() == "0.1.1"


def test_get_version_returns_nonempty_string():
    assert isinstance(get_version(), str)
    assert len(get_version()) > 0
