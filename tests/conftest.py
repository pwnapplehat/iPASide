"""Pytest configuration: put the engine package on the import path, and make sure
no test can reach the developer's real application data.
"""

import sys
from pathlib import Path

import pytest

ENGINE_DIR = Path(__file__).resolve().parents[1] / "src" / "iPASide.Engine"
if str(ENGINE_DIR) not in sys.path:
    sys.path.insert(0, str(ENGINE_DIR))


@pytest.fixture(autouse=True)
def isolated_app_data(tmp_path_factory, monkeypatch):
    """Point ipaside_engine.paths at a throwaway data directory, for every test.

    Everything in ``paths`` is derived from LOCALAPPDATA and most of it creates
    directories just by being called, so a test that touches the engine without
    asking for isolation writes into the real %LOCALAPPDATA%\\iPASide - a stray
    tweaks/fixture/Fixture.dylib from an older version of this suite is still
    sitting there. Autouse makes isolation the default: reaching real user data
    now takes a deliberate opt-out rather than merely forgetting to opt in.

    A directory of its own, not ``tmp_path``, so app data never mixes in with the
    files a test lays out for itself.
    """
    root = tmp_path_factory.mktemp("appdata")
    monkeypatch.setenv("LOCALAPPDATA", str(root))
    return root


@pytest.fixture(autouse=True)
def local_anisette_by_default(monkeypatch):
    """Tests use the local provider unless they ask for the remote one.

    The remote provider talks to a public service; no test should reach the network by accident.
    The remote tests set up their own loopback server and choose the provider explicitly.
    """
    monkeypatch.setenv("IPASIDE_ANISETTE", "local")


@pytest.fixture
def isolated_data(isolated_app_data):
    """This test's throwaway LOCALAPPDATA root, for asserting on derived paths.

    Isolation itself is automatic; ask for this only when you need the path.
    """
    return isolated_app_data
