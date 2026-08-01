"""Anisette headers must be safe to put on an HTTP wire.

HTTP libraries (urllib3 via requests) encode header values as latin-1. The
upstream ``anisette`` package fills ``X-Apple-I-TimeZone`` from ``str(tzinfo)``,
which on a non-English Windows install is a localized display name - on Chinese
Windows, ``中国标准时间`` (exactly six characters). Putting that on a request
raises::

    UnicodeEncodeError: 'latin-1' codec can't encode characters in position 0-5

which is what blocked Apple ID sign-in for a reporter on engine 1.1.2 (GitHub
issue #3): GrandSlam SRP succeeded, then the trusted-device 2FA trigger dumped
every anisette field into request headers and died. These tests pin the
sanitiser that rewrites timezone/locale to ASCII, and prove a 2FA-shaped
request with the bad value fails while the sanitised one does not.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock

import pytest
import requests

from ipaside_engine import anisette, gsa


# The exact timezone display name Chinese Windows returns for China Standard Time.
# Six characters: UnicodeEncodeError reports "position 0-5".
_CHINESE_TZ = "中国标准时间"
_CHINESE_LOCALE = "中文_中国"


def test_chinese_timezone_is_not_latin1() -> None:
    """Document the OS value that breaks urllib3, so a regression is obvious."""
    with pytest.raises(UnicodeEncodeError, match="latin-1") as caught:
        _CHINESE_TZ.encode("latin-1")
    assert caught.value.start == 0
    assert caught.value.end == 6


def test_ascii_timezone_prefers_abbreviation_when_ascii() -> None:
    tz = timezone(timedelta(hours=5, minutes=30), name="India Standard Time")
    when = datetime(2026, 7, 31, 12, 0, tzinfo=tz)
    assert anisette.ascii_timezone(when) == "India Standard Time"


def test_ascii_timezone_falls_back_to_gmt_offset_for_cjk_name() -> None:
    tz = timezone(timedelta(hours=8), name=_CHINESE_TZ)
    when = datetime(2026, 7, 31, 12, 0, tzinfo=tz)
    assert anisette.ascii_timezone(when) == "GMT+08:00"
    anisette.ascii_timezone(when).encode("latin-1")  # must not raise


def test_ascii_timezone_negative_offset() -> None:
    tz = timezone(-timedelta(hours=5), name="hora estándar de América del Este")
    when = datetime(2026, 1, 15, 12, 0, tzinfo=tz)
    assert anisette.ascii_timezone(when) == "GMT-05:00"


def test_ascii_locale_maps_windows_display_names_to_apple_tags() -> None:
    # Issue #5: this exact Windows value is ASCII but Apple answers HTTP 500 for it.
    assert anisette.ascii_locale("Chinese (Simplified)_China") == "zh_CN"
    assert anisette.ascii_locale("Chinese (Traditional)_Taiwan") == "zh_TW"
    assert anisette.ascii_locale("English_India") == "en_IN"
    assert anisette.ascii_locale("English_United States") == "en_US"
    assert anisette.ascii_locale("zh_CN") == "zh_CN"
    assert anisette.ascii_locale("zh-Hans-CN") == "zh_Hans_CN"
    cjk_fallback = anisette.ascii_locale(_CHINESE_LOCALE)
    assert cjk_fallback.isascii()
    assert anisette._APPLE_LOCALE.fullmatch(cjk_fallback)
    # Empty / None consult the process locale; must still be an Apple-style tag.
    assert anisette._APPLE_LOCALE.fullmatch(anisette.ascii_locale(""))
    assert anisette._APPLE_LOCALE.fullmatch(anisette.ascii_locale(None))
    assert anisette.ascii_locale("Chinese (Simplified)_China") == "zh_CN"


def test_wire_safe_headers_rewrite_localized_os_fields() -> None:
    raw = {
        "X-Apple-I-MD": "AAAABQ==",
        "X-Apple-I-TimeZone": _CHINESE_TZ,
        "X-Apple-Locale": "Chinese (Simplified)_China",
        "X-MMe-Client-Info": "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1>",
    }
    safe = anisette._wire_safe_headers(raw)
    assert safe["X-Apple-I-TimeZone"] != _CHINESE_TZ
    assert safe["X-Apple-I-TimeZone"].isascii()
    assert safe["X-Apple-Locale"] == "zh_CN"
    assert safe["X-Apple-I-MD"] == "AAAABQ=="
    for value in safe.values():
        if isinstance(value, str):
            value.encode("latin-1")


def test_twofa_request_with_chinese_timezone_raises_without_sanitiser() -> None:
    """Reproduce issue #3: urllib3 dies encoding the localized timezone as a header."""
    bad = {
        "X-Apple-I-Client-Time": "2026-07-31T15:30:32+08:00Z",
        "X-Apple-I-MD": "AAAABQAAABBAkppa4y0mtsmoC3gVqnNCAAAABA==",
        "X-Apple-I-MD-LU": "NTY2Qjg3",
        "X-Apple-I-MD-M": "IoQPIo33",
        "X-Apple-I-MD-RINFO": "17106176",
        "X-Apple-I-SRL-NO": "0",
        "X-Apple-I-TimeZone": _CHINESE_TZ,
        "X-Apple-Locale": "zh_CN",
        "X-MMe-Client-Info": (
            "<MacBookPro13,2> <macOS;13.1;22C65> "
            "<com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
        ),
        "X-Mme-Device-Id": "F718CB6B-8090-4AA6-9D92-1FB9AA417A0E",
    }
    headers = gsa._twofa_headers("adsid", "token", bad)
    with pytest.raises(UnicodeEncodeError, match="latin-1"):
        # httpbin is unused: the encode fails while building the wire request,
        # before any bytes leave the machine.
        requests.get(
            "https://httpbin.org/headers",
            headers=headers,
            timeout=5,
        )


def test_twofa_request_with_sanitised_headers_encodes(monkeypatch: pytest.MonkeyPatch) -> None:
    """After sanitising, the same 2FA-shaped request is latin-1 clean."""
    raw = {
        "X-Apple-I-Client-Time": "2026-07-31T15:30:32+08:00Z",
        "X-Apple-I-MD": "AAAABQAAABBAkppa4y0mtsmoC3gVqnNCAAAABA==",
        "X-Apple-I-MD-LU": "NTY2Qjg3",
        "X-Apple-I-MD-M": "IoQPIo33",
        "X-Apple-I-MD-RINFO": "17106176",
        "X-Apple-I-SRL-NO": "0",
        "X-Apple-I-TimeZone": _CHINESE_TZ,
        "X-Apple-Locale": "Chinese (Simplified)_China",
        "X-MMe-Client-Info": (
            "<MacBookPro13,2> <macOS;13.1;22C65> "
            "<com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
        ),
        "X-Mme-Device-Id": "F718CB6B-8090-4AA6-9D92-1FB9AA417A0E",
    }
    monkeypatch.setattr(
        anisette,
        "ascii_timezone",
        lambda now=None: anisette._gmt_offset_label(timedelta(hours=8)),
    )
    safe = anisette._wire_safe_headers(raw)
    assert safe["X-Apple-I-TimeZone"] == "GMT+08:00"
    assert safe["X-Apple-Locale"] == "zh_CN"

    headers = gsa._twofa_headers("adsid", "token", safe)
    captured: dict[str, str] = {}

    def fake_get(url: str, headers: dict[str, str] | None = None, **kwargs: object) -> MagicMock:
        assert headers is not None
        for key, value in headers.items():
            value.encode("latin-1")
            captured[key] = value
        response = MagicMock()
        response.status_code = 200
        response.content = b""
        return response

    monkeypatch.setattr(gsa.requests, "get", fake_get)
    gsa._trigger_trusted("adsid", "token", safe)
    assert captured["X-Apple-I-TimeZone"] == "GMT+08:00"
    assert "中国" not in captured["X-Apple-I-TimeZone"]


def test_trigger_trusted_raises_on_http_500(monkeypatch: pytest.MonkeyPatch) -> None:
    """Issue #5: never tell the UI a code was sent when Apple rejected the trigger."""

    def fake_get(url: str, headers: dict[str, str] | None = None, **kwargs: object) -> MagicMock:
        response = MagicMock()
        response.status_code = 500
        response.content = b""
        return response

    monkeypatch.setattr(gsa.requests, "get", fake_get)
    with pytest.raises(gsa.GsaError, match="did not send a verification code"):
        gsa._trigger_trusted("adsid", "token", {"X-Apple-Locale": "zh_CN"})


def test_get_headers_returns_latin1_safe_values(monkeypatch: pytest.MonkeyPatch) -> None:
    """End-to-end through get_headers: provider may emit CJK, caller must not see it."""

    class FakeProvider:
        def get_data(self) -> dict[str, str]:
            return {
                "X-Apple-I-TimeZone": _CHINESE_TZ,
                "X-Apple-Locale": "Chinese (Simplified)_China",
                "X-Apple-I-MD": "AAAABQ==",
            }

    monkeypatch.setattr(anisette, "_load_provider", lambda: FakeProvider())
    monkeypatch.setattr(
        anisette,
        "ascii_timezone",
        lambda now=None: "GMT+08:00",
    )
    headers = anisette.get_headers()
    assert headers["X-Apple-I-TimeZone"] == "GMT+08:00"
    assert headers["X-Apple-Locale"] == "zh_CN"
    for value in headers.values():
        if isinstance(value, str):
            value.encode("latin-1")


def test_chinese_windows_locale_maps_away_from_apple_rejected_value() -> None:
    """Pin the exact 1.1.3 regression: Windows locale kept, Apple returns 500."""
    assert anisette._apple_locale_tag("Chinese (Simplified)_China") == "zh_CN"
    raw = {
        "X-Apple-I-MD": "AAAABQ==",
        "X-Apple-I-TimeZone": "GMT+08:00",
        "X-Apple-Locale": "Chinese (Simplified)_China",
    }
    safe = anisette._wire_safe_headers(raw)
    assert safe["X-Apple-Locale"] == "zh_CN"
    assert safe["X-Apple-Locale"] != "Chinese (Simplified)_China"
