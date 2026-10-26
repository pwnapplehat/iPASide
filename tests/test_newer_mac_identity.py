"""Apple error -23782: "A Mac with macOS version 10.13 or later is required".

GitHub issue #14, and a pile of iloader reports from the same days: every public anisette service
says its Mac runs Mac OS X 10.12.6, and for some Apple Accounts Apple now answers ``init`` with
-23782 instead of a challenge. iPASide now answers that one error by presenting a newer Mac
identity and asking again; accounts that sign in today never see it. These tests pin when the newer
identity is used, that one sign-in uses it throughout, and what is said when Apple still refuses.
"""

from __future__ import annotations

from typing import Any

import pytest

from ipaside_engine import anisette, anisette_remote, gsa

SERVER_INFO = "<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
SERVER_AGENT = "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0"
APPLE_WORDS = "A Mac with macOS version 10.13 or later is required to sign in with this Apple Account."


@pytest.fixture(autouse=True)
def remote_service(monkeypatch: pytest.MonkeyPatch, isolated_data: Any) -> None:
    """A remote service reporting the old identity, and a data folder with nothing remembered."""
    monkeypatch.delenv(anisette.PROVIDER_ENV, raising=False)
    monkeypatch.setattr(anisette, "_newer_mac_active", False)
    fetched = anisette_remote.Fetched(
        headers={"X-Apple-I-MD": "otp", "X-Mme-Device-Id": "id"},
        identity=anisette_remote.ClientIdentity(SERVER_INFO, SERVER_AGENT),
        server="https://mac-ani.jkcoxson.com",
    )
    monkeypatch.setattr(anisette_remote, "fetch", lambda: fetched)


# --------------------------------------------------------------------------- #
# The provider
# --------------------------------------------------------------------------- #
def test_the_services_own_identity_is_used_until_apple_asks_for_more() -> None:
    headers = anisette.get_headers()
    assert headers["X-MMe-Client-Info"] == SERVER_INFO
    assert anisette.gsa_user_agent() == SERVER_AGENT
    assert not anisette.newer_mac_identity_active()
    assert anisette.status()["newer_mac_identity"] is False


def test_asking_for_a_newer_mac_switches_the_identity_once() -> None:
    assert anisette.use_newer_mac_identity() is True
    headers = anisette.get_headers()
    assert headers["X-MMe-Client-Info"] == anisette.NEWER_MAC_CLIENT_INFO
    assert anisette.gsa_user_agent() == anisette.NEWER_MAC_USER_AGENT
    assert anisette.status()["newer_mac_identity"] is True
    # Asking again changes nothing, so the caller knows a second retry cannot help.
    assert anisette.use_newer_mac_identity() is False


def test_the_other_anisette_values_are_left_alone() -> None:
    anisette.use_newer_mac_identity()
    headers = anisette.get_headers()
    assert headers["X-Apple-I-MD"] == "otp"
    assert headers["X-Mme-Device-Id"] == "id"


def test_the_newer_identity_is_a_hardware_and_os_pair_that_exists() -> None:
    """A MacBookPro13,3 runs macOS 13; 13.6.7 is build 22G720; Darwin 22.6.0 belongs to it."""
    assert "MacBookPro13,3" in anisette.NEWER_MAC_CLIENT_INFO
    assert "macOS;13.6.7;22G720" in anisette.NEWER_MAC_CLIENT_INFO
    assert "Darwin/22.6.0" in anisette.NEWER_MAC_USER_AGENT
    assert "com.apple.akd/1.0" in anisette.NEWER_MAC_CLIENT_INFO  # still akd, never Xcode
    assert "com.apple.dt.Xcode" not in anisette.NEWER_MAC_CLIENT_INFO


def test_the_choice_is_remembered_by_the_next_run(monkeypatch: pytest.MonkeyPatch) -> None:
    anisette.use_newer_mac_identity()
    monkeypatch.setattr(anisette, "_newer_mac_active", False)  # a new engine process
    assert anisette.newer_mac_identity_active()
    assert anisette.get_headers()["X-MMe-Client-Info"] == anisette.NEWER_MAC_CLIENT_INFO


def test_a_failed_write_still_applies_for_this_run(monkeypatch: pytest.MonkeyPatch) -> None:
    def refuse(self: Any, *args: Any, **kwargs: Any) -> int:
        raise OSError("read-only")

    monkeypatch.setattr(anisette.Path, "write_text", refuse)
    assert anisette.use_newer_mac_identity() is True
    assert anisette.get_headers()["X-MMe-Client-Info"] == anisette.NEWER_MAC_CLIENT_INFO


def test_the_local_emulator_keeps_its_fixed_identity(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(anisette.PROVIDER_ENV, "local")
    assert anisette.use_newer_mac_identity() is False
    assert anisette.status()["newer_mac_identity"] is False


# --------------------------------------------------------------------------- #
# The sign-in
# --------------------------------------------------------------------------- #
def _init_replies(monkeypatch: pytest.MonkeyPatch, replies: list[dict[str, Any]]) -> list[dict[str, str]]:
    """Make ``init`` answer with ``replies`` in turn; returns the headers each request carried."""
    seen: list[dict[str, str]] = []

    def fake(params: dict[str, Any], headers: dict[str, str]) -> dict[str, Any]:
        assert params["o"] == "init"
        seen.append(dict(headers))
        return replies[len(seen) - 1]

    monkeypatch.setattr(gsa, "_gs_request", fake)
    return seen


def _wants_newer_mac() -> dict[str, Any]:
    return {"Status": {"ec": -23782, "em": APPLE_WORDS, "hsc": 200}}


def _refused_for_another_reason() -> dict[str, Any]:
    return {"Status": {"ec": -20101, "em": "Your account or password is incorrect.", "hsc": 200}}


def test_apples_ask_for_a_newer_mac_is_answered_with_one(monkeypatch: pytest.MonkeyPatch) -> None:
    seen = _init_replies(monkeypatch, [_wants_newer_mac(), _refused_for_another_reason()])
    headers = anisette.get_headers()
    with pytest.raises(gsa.GsaError, match="-20101"):  # the retry got past -23782 to the next answer
        gsa._authenticate_once("me@example.com", "pw", headers)
    assert [h["X-MMe-Client-Info"] for h in seen] == [SERVER_INFO, anisette.NEWER_MAC_CLIENT_INFO]


def test_the_rest_of_that_sign_in_carries_the_newer_identity(monkeypatch: pytest.MonkeyPatch) -> None:
    """The caller keeps using its headers dict (for the token request), so it must change in place."""
    _init_replies(monkeypatch, [_wants_newer_mac(), _refused_for_another_reason()])
    headers = anisette.get_headers()
    assert headers["X-MMe-Client-Info"] == SERVER_INFO
    with pytest.raises(gsa.GsaError):
        gsa._authenticate_once("me@example.com", "pw", headers)
    assert headers["X-MMe-Client-Info"] == anisette.NEWER_MAC_CLIENT_INFO
    assert anisette.gsa_user_agent() == anisette.NEWER_MAC_USER_AGENT


def test_begin_login_finishes_with_the_headers_the_retry_produced(monkeypatch: pytest.MonkeyPatch) -> None:
    finished: list[dict[str, str]] = []

    def authenticate(email: str, password: str, headers: dict[str, str]) -> tuple[dict[str, Any], None]:
        headers["X-MMe-Client-Info"] = anisette.NEWER_MAC_CLIENT_INFO  # what the retry does
        return {"adsid": "A1", "GsIdmsToken": "T1"}, None

    monkeypatch.setattr(gsa, "_authenticate_once", authenticate)
    monkeypatch.setattr(
        gsa, "_finalize_session",
        lambda email, spd, headers: finished.append(dict(headers)) or {"status": "authenticated"},
    )
    assert gsa.begin_login("me@example.com", "pw") == {"status": "authenticated"}
    assert finished[0]["X-MMe-Client-Info"] == anisette.NEWER_MAC_CLIENT_INFO


def test_a_second_refusal_is_explained_and_not_retried_again(monkeypatch: pytest.MonkeyPatch) -> None:
    seen = _init_replies(monkeypatch, [_wants_newer_mac(), _wants_newer_mac()])
    with pytest.raises(gsa.GsaError) as raised:
        gsa._authenticate_once("me@example.com", "pw", anisette.get_headers())
    assert len(seen) == 2
    text = str(raised.value)
    assert "-23782" in text and "macOS 10.13" in text
    assert "still refused" in text and "password" in text


def test_once_the_newer_identity_is_in_use_the_error_is_reported_as_it_is(monkeypatch: pytest.MonkeyPatch) -> None:
    anisette.use_newer_mac_identity()
    seen = _init_replies(monkeypatch, [_wants_newer_mac()])
    with pytest.raises(gsa.GsaError) as raised:
        gsa._authenticate_once("me@example.com", "pw", anisette.get_headers())
    assert len(seen) == 1  # nothing newer left to try
    assert "-23782" in str(raised.value) and APPLE_WORDS in str(raised.value)


def test_the_local_emulator_is_not_retried(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(anisette.PROVIDER_ENV, "local")
    monkeypatch.setattr(anisette, "_raw_headers", lambda: {"X-Apple-I-MD": "otp"})
    seen = _init_replies(monkeypatch, [_wants_newer_mac()])
    with pytest.raises(gsa.GsaError, match="-23782"):
        gsa._authenticate_once("me@example.com", "pw", anisette.get_headers())
    assert len(seen) == 1


def test_other_init_errors_never_switch_the_identity(monkeypatch: pytest.MonkeyPatch) -> None:
    seen = _init_replies(monkeypatch, [_refused_for_another_reason()])
    with pytest.raises(gsa.GsaError, match="-20101"):
        gsa._authenticate_once("me@example.com", "pw", anisette.get_headers())
    assert len(seen) == 1
    assert not anisette.newer_mac_identity_active()
