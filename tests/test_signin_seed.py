"""Signing the built-in SideStore in, with no Apple ID prompt.

SideStore authenticates by token when its keychain already holds an ``adsid`` and the
``com.apple.gs.xcode.auth`` GrandSlam token - the password-less branch of its
``AuthenticationOperation.signIn``. iPASide holds both for the account that signed
LiveContainer, so it seeds them and the built-in store opens already signed in.

The awkward part is delivery. LiveContainer namespaces each guest's keychain into a
``TEAMID.com.kdt.livecontainer.shared.N`` group where ``N`` is chosen at random per
container, so the tokens are written into every one of the 128 the host is entitled to -
which is exactly the list :func:`build_entitlements` signs, and these tests pin the two
together so they cannot drift.
"""

from __future__ import annotations

import plistlib

import pytest

from ipaside_engine import gsa, livecontainer

BUNDLE = {"bundle_id": "com.kdt.livecontainer.ABCDE12345", "team_id": "ABCDE12345"}
SESSION = {"adsid": "0000123-adsid", "auth_token": "xcode-token", "email": "a@b.c"}


@pytest.fixture
def signed_in(monkeypatch):
    """The active account has the tokens SideStore's token path needs."""
    monkeypatch.setattr(livecontainer.gsa, "load_session", lambda *a, **k: dict(SESSION))


@pytest.fixture
def has_helper(monkeypatch):
    """This build ships the dylib that consumes the request on the device."""
    monkeypatch.setattr(
        livecontainer.signing,
        "resolve_helper_dylib",
        lambda: r"C:\vendor\iPASideCertImport.dylib",
    )


def test_the_request_carries_the_tokens_and_service(signed_in):
    request = plistlib.loads(livecontainer._signin_request(BUNDLE))

    assert request["AppleIDAdsid"] == SESSION["adsid"]
    assert request["AppleIDXcodeToken"] == SESSION["auth_token"]
    assert request["KeychainService"] == livecontainer.SIDESTORE_KEYCHAIN_SERVICE


def test_it_targets_every_keychain_group_the_build_is_signed_for(signed_in):
    """LiveContainer picks one at random, so all of them have to be seeded, and they must
    be the very groups the app is signed to reach - not a hand-written parallel list."""
    request = plistlib.loads(livecontainer._signin_request(BUNDLE))
    expected = livecontainer.build_entitlements(BUNDLE["team_id"], BUNDLE["bundle_id"])[
        "keychain-access-groups"
    ]

    assert request["AccessGroups"] == expected
    assert len(request["AccessGroups"]) == livecontainer.KEYCHAIN_GROUPS
    assert (
        request["AccessGroups"][0] == f"{BUNDLE['team_id']}.com.kdt.livecontainer.shared"
    )
    assert request["AccessGroups"][-1].endswith(".shared.127")


def test_no_helper_dylib_writes_nothing(monkeypatch, signed_in):
    """Without something on the device to consume it, a live account token must not be
    dropped into Documents for nothing."""
    monkeypatch.setattr(livecontainer.signing, "resolve_helper_dylib", lambda: None)
    wrote: dict = {}

    async def fake_seed(*_args, **_kwargs):
        wrote["called"] = True
        return True

    monkeypatch.setattr(livecontainer, "_seed_signin_async", fake_seed)

    result = livecontainer.deliver_signin(BUNDLE, "udid")

    assert result["seeded"] is False
    assert result["automatic"] is False
    assert "called" not in wrote, "no request may leave when nothing can consume it"


def test_it_delivers_the_request_and_reports_first_launch_suppressed(
    monkeypatch, signed_in, has_helper
):
    calls: dict = {}

    async def fake_seed(bundle_id, serial, request):
        calls.update(bundle_id=bundle_id, serial=serial, request=request)
        return True

    monkeypatch.setattr(livecontainer, "_seed_signin_async", fake_seed)

    result = livecontainer.deliver_signin(BUNDLE, "udid")

    assert result == {
        "seeded": True,
        "automatic": True,
        "first_launch_suppressed": True,
    }
    assert calls["bundle_id"] == BUNDLE["bundle_id"]
    payload = plistlib.loads(calls["request"])
    assert payload["AppleIDXcodeToken"] == SESSION["auth_token"]


def test_not_signed_in_is_reported_not_raised(monkeypatch, has_helper):
    """The tokens come from a signed-in account; without one, say so rather than crash the
    install that has already put LiveContainer on the phone."""

    def no_session(*_args, **_kwargs):
        raise gsa.GsaError("not signed in")

    monkeypatch.setattr(livecontainer.gsa, "load_session", no_session)

    result = livecontainer.deliver_signin(BUNDLE, "udid")

    assert result["seeded"] is False
    assert "not signed in" in result["error"]


def test_a_delivery_failure_is_reported_not_raised(monkeypatch, signed_in, has_helper):
    """LiveContainer is already installed by then; only the hand-off failed."""

    async def explode(*_args, **_kwargs):
        raise OSError("device went away")

    monkeypatch.setattr(livecontainer, "_seed_signin_async", explode)

    result = livecontainer.deliver_signin(BUNDLE, "udid")

    assert result["seeded"] is False
    assert "device went away" in result["error"]


# --------------------------------------------------------------------------- #
# Surviving SideStore's first-launch keychain reset
# --------------------------------------------------------------------------- #
class _FakeAFC:
    """Just enough of the house_arrest surface for _suppress_first_launch."""

    def __init__(self, existing: bytes | None):
        self._existing = existing
        self.written: dict = {}
        self.made: list = []

    async def get_file_contents(self, path):
        if self._existing is None:
            raise FileNotFoundError(path)
        return self._existing

    async def makedirs(self, path):
        self.made.append(path)

    async def set_file_contents(self, path, data):
        self.written[path] = data


def _run(coro):
    import asyncio

    return asyncio.run(coro)


def test_first_launch_is_written_when_the_prefs_are_absent():
    """The fresh-install case: no prefs yet, so a value is written to skip the reset."""
    afc = _FakeAFC(existing=None)

    result = _run(livecontainer._suppress_first_launch(afc))

    assert result is True
    written = plistlib.loads(afc.written[livecontainer._SIDESTORE_PREFS])
    assert written[livecontainer._FIRST_LAUNCH_KEY] is not None


def test_an_existing_first_launch_date_is_left_untouched():
    """A store that really has launched keeps its own first-launch date; nothing rewritten."""
    from datetime import datetime

    existing = plistlib.dumps({livecontainer._FIRST_LAUNCH_KEY: datetime(2020, 1, 1)})
    afc = _FakeAFC(existing=existing)

    result = _run(livecontainer._suppress_first_launch(afc))

    assert result is True
    assert afc.written == {}


def test_other_prefs_are_preserved_when_setting_first_launch():
    existing = plistlib.dumps({"someOtherKey": "keepme"})
    afc = _FakeAFC(existing=existing)

    _run(livecontainer._suppress_first_launch(afc))

    written = plistlib.loads(afc.written[livecontainer._SIDESTORE_PREFS])
    assert written["someOtherKey"] == "keepme"
    assert written[livecontainer._FIRST_LAUNCH_KEY] is not None
