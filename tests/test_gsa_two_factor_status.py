"""How a GrandSlam ``complete`` reply announces a second factor.

Live trace, 2026-10-17, real account with trusted-device 2FA (Apple's replies, no secrets):

    GsService2/init      http=200 ec=0 hsc=200
    GsService2/complete  http=200 ec=0 hsc=409          <- no ``au`` field
    GsService2/apptokens http=200 ec=-22411 hsc=401

``complete`` succeeded and Apple had already pushed the code to the phone (hsc 409). iPASide only
looked for ``au``, decided no second factor was needed, asked for the final tokens straight away,
and Apple refused. The phone showed a code popup while iPASide showed "-22411 This action cannot
be completed at this time".
"""

from __future__ import annotations

from typing import Any

import pytest

from ipaside_engine import gsa


@pytest.mark.parametrize(
    ("status", "expected"),
    [
        # the new reply: code already pushed, no au
        ({"ec": 0, "em": "", "hsc": 409}, gsa.SECONDARY_CODE_ALREADY_SENT),
        # the old replies still work
        ({"ec": 0, "au": "trustedDeviceSecondaryAuth", "hsc": 200}, "trustedDeviceSecondaryAuth"),
        ({"ec": 0, "au": "secondaryAuth"}, "secondaryAuth"),
        # a text challenge that also pushed a code: still texted first, with the pushed code as the
        # fallback (the reply shape of issue #12; the same shape texted fine on 2026-10-23)
        ({"ec": 0, "au": "secondaryAuth", "hsc": 409}, gsa.SECONDARY_SMS_CODE_ALREADY_SENT),
        # any other au is the more specific statement, so it wins over hsc
        ({"ec": 0, "au": "trustedDeviceSecondaryAuth", "hsc": 409}, "trustedDeviceSecondaryAuth"),
        # no second factor at all
        ({"ec": 0, "em": "", "hsc": 200}, None),
        ({"ec": 0}, None),
        ({}, None),
        # an account without 2FA set up is not a challenge
        ({"ec": 0, "au": "repair"}, None),
        ({"ec": 0, "au": "repair", "hsc": 409}, None),
        # other hsc values are not a challenge
        ({"ec": 0, "hsc": 401}, None),
        ({"ec": 0, "hsc": 434}, None),
    ],
)
def test_secondary_auth_reads_the_reply(status: dict[str, Any], expected: str | None) -> None:
    assert gsa._secondary_auth(status) == expected


class _Calls:
    def __init__(self) -> None:
        self.events: list[str] = []
        self.pending: tuple[Any, ...] | None = None


@pytest.fixture
def login_flow(monkeypatch: pytest.MonkeyPatch) -> _Calls:
    calls = _Calls()
    monkeypatch.setattr(gsa.anisette, "get_headers", lambda: {"X-Apple-I-MD": "x"})
    monkeypatch.setattr(gsa, "_trigger_trusted", lambda *a, **k: calls.events.append("trigger_trusted"))
    monkeypatch.setattr(gsa, "_trigger_sms", lambda *a, **k: calls.events.append("trigger_sms"))

    def save(*args: Any, **kwargs: Any) -> None:
        calls.pending = args

    monkeypatch.setattr(gsa, "_save_pending", save)
    monkeypatch.setattr(
        gsa, "_finalize_session",
        lambda email, spd, headers: calls.events.append("finalize") or {"status": "authenticated"},
    )
    return calls


def _sign_in_returns(monkeypatch: pytest.MonkeyPatch, secondary: str | None) -> None:
    monkeypatch.setattr(
        gsa, "_authenticate_once",
        lambda email, password, headers: ({"adsid": "A1", "GsIdmsToken": "T1"}, secondary),
    )


def test_a_code_apple_already_sent_asks_for_the_code_without_triggering_another(
    monkeypatch: pytest.MonkeyPatch, login_flow: _Calls
) -> None:
    _sign_in_returns(monkeypatch, gsa.SECONDARY_CODE_ALREADY_SENT)
    result = gsa.begin_login("me@example.com", "pw")
    assert result == {"status": "2fa_required", "method": "trusteddevice"}
    assert login_flow.events == []  # no second trigger, and no premature apptokens request
    assert login_flow.pending is not None
    assert login_flow.pending[-1] == "trusteddevice"


def test_the_old_trusted_device_reply_still_triggers_the_code(
    monkeypatch: pytest.MonkeyPatch, login_flow: _Calls
) -> None:
    _sign_in_returns(monkeypatch, "trustedDeviceSecondaryAuth")
    assert gsa.begin_login("me@example.com", "pw") == {"status": "2fa_required", "method": "trusteddevice"}
    assert login_flow.events == ["trigger_trusted"]


def test_the_sms_reply_still_triggers_a_text(monkeypatch: pytest.MonkeyPatch, login_flow: _Calls) -> None:
    _sign_in_returns(monkeypatch, "secondaryAuth")
    assert gsa.begin_login("me@example.com", "pw") == {"status": "2fa_required", "method": "sms"}
    assert login_flow.events == ["trigger_sms"]


def test_no_second_factor_goes_straight_to_the_tokens(
    monkeypatch: pytest.MonkeyPatch, login_flow: _Calls
) -> None:
    _sign_in_returns(monkeypatch, None)
    assert gsa.begin_login("me@example.com", "pw") == {"status": "authenticated"}
    assert login_flow.events == ["finalize"]
    assert login_flow.pending is None
