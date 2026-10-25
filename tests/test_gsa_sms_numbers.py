"""The text-message second factor: which number to text, and what to do when Apple refuses.

GitHub issue #12: on iOS 27 an Apple ID whose sign-in answered

    GsService2/complete  http=200 ec=0 hsc=409 au='secondaryAuth'
    sms/trigger          http=403

could not get past the text-message step at all, and the same 403 is reported by iloader users
(nab138/iloader#932). iPASide always texted phone id 1, a guess that only holds for an account with a
single number that was never replaced. These tests pin the replacement: ask Apple for the account's
numbers and use a real id, accept the replies that mean "a code is already on its way", and when the
text really is refused say so plainly, falling back to the code Apple may already have pushed.
"""

from __future__ import annotations

import json
from typing import Any
from unittest.mock import MagicMock

import pytest

from ipaside_engine import gsa

_HEADERS = {"X-Apple-Locale": "en_US", "X-MMe-Client-Info": "<Windows> <com.apple.AuthKit/1>"}


def _response(status: int, body: Any = b"", url: str = "https://gsa.apple.com/auth") -> MagicMock:
    response = MagicMock()
    response.status_code = status
    response.url = url
    response.content = body if isinstance(body, bytes) else json.dumps(body).encode()
    response.headers = {"Content-Type": "application/json"}
    return response


class _Apple:
    """A stand-in for gsa.apple.com's two text-message endpoints; records what was sent."""

    def __init__(self, numbers: Any, put: MagicMock) -> None:
        self.numbers = numbers
        self.put = put
        self.sent: list[dict[str, Any]] = []

    def __call__(self, method: str, url: str, *, headers: dict[str, str], data: bytes | None = None) -> MagicMock:
        if method == "GET":
            assert url == gsa._AUTH_INFO
            if isinstance(self.numbers, Exception):
                raise self.numbers
            return _response(200, {"trustedPhoneNumbers": self.numbers} if self.numbers is not None else b"<html/>")
        assert method == "PUT" and url == gsa._SMS_ENDPOINT
        self.sent.append(json.loads(data or b"{}"))
        return self.put


def _install(monkeypatch: pytest.MonkeyPatch, numbers: Any, put: MagicMock) -> _Apple:
    apple = _Apple(numbers, put)
    monkeypatch.setattr(gsa, "_gsa_http", apple)
    return apple


# --------------------------------------------------------------------------- #
# Which number
# --------------------------------------------------------------------------- #
def test_the_text_goes_to_the_number_apple_lists_not_to_a_guess(monkeypatch: pytest.MonkeyPatch) -> None:
    numbers = [{"id": 7, "pushMode": "sms", "lastTwoDigits": "42", "numberWithDialCode": "+1 (•••) •••-••42"}]
    apple = _install(monkeypatch, numbers, _response(200))
    assert gsa._trigger_sms("adsid", "token", _HEADERS) == 7
    assert apple.sent == [{"phoneNumber": {"id": 7}, "mode": "sms"}]


def test_a_number_delivered_by_text_is_preferred_over_one_delivered_by_voice() -> None:
    numbers = [{"id": 2, "pushMode": "voice"}, {"id": 5, "pushMode": "sms"}, {"id": 9, "pushMode": "sms"}]
    assert gsa._pick_phone_id(numbers) == 5


def test_without_a_text_number_the_first_listed_one_is_used() -> None:
    assert gsa._pick_phone_id([{"id": 4, "pushMode": "voice"}, {"id": 6}]) == 4


@pytest.mark.parametrize(
    "numbers",
    [None, [], RuntimeError("network down"), [{"id": "x"}, {"id": True}, "junk", {"pushMode": "sms"}]],
    ids=["html page", "empty list", "request failed", "unusable entries"],
)
def test_when_apple_will_not_list_numbers_the_old_default_is_used(
    monkeypatch: pytest.MonkeyPatch, numbers: Any
) -> None:
    apple = _install(monkeypatch, numbers, _response(200))
    assert gsa._trigger_sms("adsid", "token", _HEADERS) == gsa._DEFAULT_PHONE_ID == 1
    assert apple.sent == [{"phoneNumber": {"id": 1}, "mode": "sms"}]


def test_the_code_is_submitted_for_the_same_number_it_was_texted_to(monkeypatch: pytest.MonkeyPatch) -> None:
    sent: list[dict[str, Any]] = []

    def fake_http(method: str, url: str, *, headers: dict[str, str], data: bytes | None = None) -> MagicMock:
        sent.append(json.loads(data))
        return _response(200, b"", url)

    monkeypatch.setattr(gsa, "_gsa_http", fake_http)
    gsa._submit_sms("adsid", "token", "123456", _HEADERS, 7)
    assert sent == [{"phoneNumber": {"id": 7}, "mode": "sms", "securityCode": {"code": "123456"}}]


# --------------------------------------------------------------------------- #
# What Apple answers to the trigger
# --------------------------------------------------------------------------- #
def test_a_refused_text_says_which_step_and_what_apple_said(monkeypatch: pytest.MonkeyPatch) -> None:
    _install(monkeypatch, None, _response(403, b""))
    with pytest.raises(gsa.GsaError) as raised:
        gsa._trigger_sms("adsid", "token", _HEADERS)
    text = str(raised.value)
    assert "text a verification code" in text and "HTTP 403" in text
    assert "not a wrong password" in text


def test_a_refused_text_quotes_apples_own_explanation_when_it_gives_one(monkeypatch: pytest.MonkeyPatch) -> None:
    body = {"serviceErrors": [{"code": "-28248", "title": "Can't send code", "message": "Choose another way."}]}
    _install(monkeypatch, None, _response(403, body))
    with pytest.raises(gsa.GsaError, match="HTTP 403.*Can't send code.*Choose another way"):
        gsa._trigger_sms("adsid", "token", _HEADERS)


@pytest.mark.parametrize("code", ["-22979", "-22981"])
def test_too_many_codes_sent_means_the_last_one_still_works(monkeypatch: pytest.MonkeyPatch, code: str) -> None:
    body = {"serviceErrors": [{"code": code, "message": "Enter the last code you received."}]}
    _install(monkeypatch, [{"id": 3, "pushMode": "sms"}], _response(403, body))
    assert gsa._trigger_sms("adsid", "token", _HEADERS) == 3


def test_an_open_challenge_is_a_code_already_on_its_way(monkeypatch: pytest.MonkeyPatch) -> None:
    body = {"mode": "sms", "securityCode": {"length": 6, "tooManyCodesSent": False}}
    _install(monkeypatch, None, _response(412, body))
    assert gsa._trigger_sms("adsid", "token", _HEADERS) == 1


@pytest.mark.parametrize("flag", ["securityCodeLocked", "securityCodeCooldown", "tooManyCodesValidated"])
def test_a_locked_challenge_is_not_treated_as_a_code_on_its_way(
    monkeypatch: pytest.MonkeyPatch, flag: str
) -> None:
    _install(monkeypatch, None, _response(412, {"securityCode": {"length": 6, flag: True}}))
    with pytest.raises(gsa.GsaError, match="HTTP 412"):
        gsa._trigger_sms("adsid", "token", _HEADERS)


def test_an_unrelated_server_error_is_not_mistaken_for_success(monkeypatch: pytest.MonkeyPatch) -> None:
    _install(monkeypatch, None, _response(500, b"boom"))
    with pytest.raises(gsa.GsaError, match="HTTP 500"):
        gsa._trigger_sms("adsid", "token", _HEADERS)


# --------------------------------------------------------------------------- #
# begin_login / complete_2fa
# --------------------------------------------------------------------------- #
class _Flow:
    def __init__(self) -> None:
        self.pending: dict[str, Any] = {}
        self.submitted: dict[str, Any] = {}


@pytest.fixture
def flow(monkeypatch: pytest.MonkeyPatch) -> _Flow:
    state = _Flow()
    monkeypatch.setattr(gsa.anisette, "get_headers", lambda: dict(_HEADERS))
    monkeypatch.setattr(gsa, "_trigger_trusted", lambda *a, **k: None)

    def save(email: str, adsid: str, idms: str, method: str, *, phone_id: int = 1) -> None:
        state.pending = {"adsid": adsid, "idms": idms, "method": method, "phone_id": phone_id}

    monkeypatch.setattr(gsa, "_save_pending", save)
    monkeypatch.setattr(gsa, "_load_pending", lambda: state.pending or None)
    monkeypatch.setattr(
        gsa, "_submit_sms",
        lambda adsid, idms, code, headers, phone_id=1: state.submitted.update(sms=phone_id, code=code),
    )
    monkeypatch.setattr(
        gsa, "_submit_trusted",
        lambda adsid, idms, code, headers: state.submitted.update(trusted=True, code=code),
    )
    monkeypatch.setattr(gsa, "_finalize_session", lambda email, spd, headers: {"status": "authenticated"})
    return state


def _signs_in_with(monkeypatch: pytest.MonkeyPatch, secondary: str | None) -> None:
    monkeypatch.setattr(
        gsa, "_authenticate_once",
        lambda email, password, headers: ({"adsid": "A1", "GsIdmsToken": "T1"}, secondary),
    )


def _text_is_refused(monkeypatch: pytest.MonkeyPatch) -> None:
    def refuse(*args: Any, **kwargs: Any) -> int:
        raise gsa.GsaError("Apple would not text a verification code (HTTP 403).")

    monkeypatch.setattr(gsa, "_trigger_sms", refuse)


def test_the_number_texted_is_remembered_for_the_code_step(monkeypatch: pytest.MonkeyPatch, flow: _Flow) -> None:
    _signs_in_with(monkeypatch, "secondaryAuth")
    monkeypatch.setattr(gsa, "_trigger_sms", lambda *a, **k: 7)
    assert gsa.begin_login("me@example.com", "pw") == {"status": "2fa_required", "method": "sms"}
    assert flow.pending["phone_id"] == 7
    _signs_in_with(monkeypatch, None)  # the sign-in after the code is accepted
    gsa.complete_2fa("me@example.com", "pw", "123456")
    assert flow.submitted == {"sms": 7, "code": "123456"}


def test_a_session_saved_before_the_number_was_recorded_still_completes(
    monkeypatch: pytest.MonkeyPatch, flow: _Flow
) -> None:
    flow.pending = {"adsid": "A1", "idms": "T1", "method": "sms"}  # as an older version wrote it
    _signs_in_with(monkeypatch, None)
    gsa.complete_2fa("me@example.com", "pw", "123456")
    assert flow.submitted["sms"] == 1


def test_a_text_challenge_that_also_pushed_a_code_still_texts_first(
    monkeypatch: pytest.MonkeyPatch, flow: _Flow
) -> None:
    """The account that worked on 2026-10-23 had exactly this reply, and the text arrived."""
    _signs_in_with(monkeypatch, gsa.SECONDARY_SMS_CODE_ALREADY_SENT)
    monkeypatch.setattr(gsa, "_trigger_sms", lambda *a, **k: 2)
    assert gsa.begin_login("me@example.com", "pw") == {"status": "2fa_required", "method": "sms"}
    assert flow.pending["method"] == "sms"


def test_when_the_text_is_refused_the_pushed_code_is_asked_for_instead(
    monkeypatch: pytest.MonkeyPatch, flow: _Flow
) -> None:
    _signs_in_with(monkeypatch, gsa.SECONDARY_SMS_CODE_ALREADY_SENT)
    _text_is_refused(monkeypatch)
    result = gsa.begin_login("me@example.com", "pw")
    assert result["status"] == "2fa_required" and result["method"] == "trusteddevice"
    assert "HTTP 403" in result["notice"]
    assert "Apple devices" in result["notice"]
    assert flow.pending["method"] == "trusteddevice"
    _signs_in_with(monkeypatch, None)
    gsa.complete_2fa("me@example.com", "pw", "654321")
    assert flow.submitted == {"trusted": True, "code": "654321"}


def test_a_refused_text_without_a_pushed_code_is_an_error_not_a_dead_end(
    monkeypatch: pytest.MonkeyPatch, flow: _Flow
) -> None:
    """No hsc 409, so no code was sent anywhere: asking for one would wait for nothing."""
    _signs_in_with(monkeypatch, "secondaryAuth")
    _text_is_refused(monkeypatch)
    with pytest.raises(gsa.GsaError, match="HTTP 403"):
        gsa.begin_login("me@example.com", "pw")
    assert flow.pending == {}


def test_a_code_apple_still_wants_after_a_text_challenge_gets_the_plain_message(
    monkeypatch: pytest.MonkeyPatch, flow: _Flow
) -> None:
    flow.pending = {"adsid": "A1", "idms": "T1", "method": "sms", "phone_id": 1}
    _signs_in_with(monkeypatch, gsa.SECONDARY_SMS_CODE_ALREADY_SENT)
    with pytest.raises(gsa.GsaError, match="Apple still wants a verification code") as raised:
        gsa.complete_2fa("me@example.com", "pw", "123456")
    assert "secondaryAuthCodeAlreadySent" not in str(raised.value)


def test_other_sign_ins_carry_no_notice(monkeypatch: pytest.MonkeyPatch, flow: _Flow) -> None:
    _signs_in_with(monkeypatch, gsa.SECONDARY_CODE_ALREADY_SENT)
    assert gsa.begin_login("me@example.com", "pw") == {"status": "2fa_required", "method": "trusteddevice"}
    _signs_in_with(monkeypatch, "trustedDeviceSecondaryAuth")
    assert gsa.begin_login("me@example.com", "pw") == {"status": "2fa_required", "method": "trusteddevice"}


# --------------------------------------------------------------------------- #
# The trace says what Apple answered, and never a number
# --------------------------------------------------------------------------- #
def test_the_trace_records_apples_error_code_and_how_many_numbers_never_the_numbers(isolated_data) -> None:
    numbers = {"trustedPhoneNumbers": [{"id": 1, "numberWithDialCode": "+1 555 010 0042", "lastTwoDigits": "42"}]}
    gsa._trace("auth/numbers", _response(200, numbers))
    gsa._trace(
        "sms/trigger",
        _response(403, {"serviceErrors": [{"code": "-28248", "title": "T", "message": "secret words"}]}),
    )
    text = (isolated_data / "iPASide" / "gsa-trace.log").read_text(encoding="utf-8")
    assert "auth/numbers http=200 json=trustedPhoneNumbers numbers=1" in text
    assert "sms/trigger http=403 json=serviceErrors svc=-28248" in text
    for private in ("555", "0042", "secret words"):
        assert private not in text
