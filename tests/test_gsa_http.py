"""GrandSlam HTTP must not reuse a spent gsa.apple.com keep-alive connection.

Apple's GsService2 front-end serves two requests per keep-alive socket. The
third returns HTTP 503 with a text/html body while the second response still
advertises Connection: keep-alive, so the client cannot see that the socket is
spent. Sign-in is three requests on that host (SRP init, SRP complete, then
o=apptokens — or the trusted-device trigger if 2FA is required). A pooled
session therefore fails before 2FA can complete.

That is GitHub issue #7. AltStore measured the same behaviour against
https://gsa.apple.com/grandslam/GsService2 (issue 1782, comment 5558494372):
four dummy o=init requests, no credentials, 3rd and 4th HTML 503; the same
request on a fresh connection is a normal plist. Retrying the spent socket
still 503s. developerservices2.apple.com has no such limit.

These tests pin the Python equivalent of AltStore's fix: every GSA request
gets its own session, sends Connection: close, and invalidates the session
when the body has been read. A mock HTTP/1.1 server implements Apple's
two-request rule so the suite does not need a live Apple ID.
"""

from __future__ import annotations

import contextlib
import json
import plistlib
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from unittest.mock import MagicMock

import pytest
import requests

from ipaside_engine import gsa

_OK_PLIST = plistlib.dumps(
    {"Response": {"Status": {"ec": 0, "em": "OK"}}},
    fmt=plistlib.FMT_XML,
)
_HTML_503 = b"<html><body>503 Service Temporarily Unavailable</body></html>"
_ANISETTES = {
    "X-MMe-Client-Info": (
        "<MacBookPro13,2> <macOS;13.1;22C65> "
        "<com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
    ),
    "X-Apple-Locale": "en_US",
}


class _GsaServer(ThreadingHTTPServer):
    """HTTP/1.1 server that records per-connection request counts."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.events: list[dict[str, Any]] = []
        self.counts: dict[object, int] = {}


class _TwoRequestKeepAliveHandler(BaseHTTPRequestHandler):
    """Apple's measured GsService2 rule: 1st/2nd 200 plist, 3rd+ 503 HTML."""

    protocol_version = "HTTP/1.1"
    timeout = 2

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
        return

    def do_GET(self) -> None:  # noqa: N802
        self._handle()

    def do_POST(self) -> None:  # noqa: N802
        self._handle()

    def _client_wants_close(self) -> bool:
        return (self.headers.get("Connection") or "").lower() == "close"

    def _handle(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        peer = self.client_address
        count = self.server.counts.get(peer, 0) + 1
        self.server.counts[peer] = count
        self.server.events.append(
            {
                "n": count,
                "conn": peer,
                "connection": self.headers.get("Connection"),
                "path": self.path,
                "method": self.command,
            }
        )
        keep_alive = not self._client_wants_close()
        if count >= 3:
            self._reply(503, "text/html", _HTML_503, keep_alive=keep_alive)
            return
        self._reply(200, "text/x-xml-plist;charset=UTF-8", _OK_PLIST, keep_alive=keep_alive)

    def _reply(self, status: int, content_type: str, body: bytes, *, keep_alive: bool) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if keep_alive:
            self.send_header("Connection", "keep-alive")
            self.send_header("Keep-Alive", "timeout=2")
            self.close_connection = False
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(body)


class _FirstSpentThenOkHandler(_TwoRequestKeepAliveHandler):
    """First TCP request is HTML 503; every later request is a plist."""

    def _handle(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        type(self).calls = getattr(type(self), "calls", 0) + 1
        self.server.events.append(
            {"call": type(self).calls, "connection": self.headers.get("Connection")}
        )
        keep_alive = not self._client_wants_close()
        if type(self).calls == 1:
            self._reply(503, "text/html", _HTML_503, keep_alive=keep_alive)
            return
        self._reply(200, "text/x-xml-plist;charset=UTF-8", _OK_PLIST, keep_alive=keep_alive)


class _AlwaysHtml503Handler(_TwoRequestKeepAliveHandler):
    def _handle(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        type(self).calls = getattr(type(self), "calls", 0) + 1
        self._reply(503, "text/html", _HTML_503, keep_alive=not self._client_wants_close())


@contextlib.contextmanager
def _serve(handler: type[BaseHTTPRequestHandler]) -> Iterator[_GsaServer]:
    server = _GsaServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def _endpoint(server: _GsaServer, path: str = "/grandslam/GsService2") -> str:
    host, port = server.server_address[:2]
    return f"http://{host}:{port}{path}"


def test_pooled_keep_alive_is_spent_on_the_third_request() -> None:
    """Document Apple's rule on the mock: 3rd request on one socket is HTML 503."""
    with _serve(_TwoRequestKeepAliveHandler) as server:
        url = _endpoint(server)
        session = requests.Session()
        try:
            statuses = []
            types = []
            for _ in range(4):
                response = session.post(url, data=_OK_PLIST, timeout=5)
                statuses.append(response.status_code)
                types.append(response.headers.get("Content-Type"))
        finally:
            session.close()
    assert statuses == [200, 200, 503, 503]
    assert types[0].startswith("text/x-xml-plist")
    assert types[1].startswith("text/x-xml-plist")
    assert "html" in (types[2] or "")
    assert "html" in (types[3] or "")
    assert [event["n"] for event in server.events] == [1, 2, 3, 4]
    assert len({event["conn"] for event in server.events}) == 1


def test_sign_in_shaped_gs_requests_each_use_a_fresh_connection(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """init + complete + apptokens must not share a keep-alive socket."""
    with _serve(_TwoRequestKeepAliveHandler) as server:
        monkeypatch.setattr(gsa, "_GS_ENDPOINT", _endpoint(server))
        for operation in ("init", "complete", "apptokens"):
            body = gsa._gs_request({"o": operation, "u": "probe@example.invalid"}, _ANISETTES)
            assert body["Status"]["ec"] == 0
    assert len(server.events) == 3
    assert all(event["n"] == 1 for event in server.events)
    assert len({event["conn"] for event in server.events}) == 3
    assert {event["connection"] for event in server.events} == {"close"}


def test_html_503_on_a_spent_socket_is_retried_on_a_new_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Retry must be a new session. Retrying the spent socket still 503s."""
    _FirstSpentThenOkHandler.calls = 0
    with _serve(_FirstSpentThenOkHandler) as server:
        monkeypatch.setattr(gsa, "_GS_ENDPOINT", _endpoint(server))
        body = gsa._gs_request({"o": "init", "u": "probe@example.invalid"}, _ANISETTES)
        assert body["Status"]["ec"] == 0
    assert _FirstSpentThenOkHandler.calls == 2
    assert server.events[0]["connection"] == "close"
    assert server.events[1]["connection"] == "close"


def test_html_503_is_a_gsa_error_not_a_plist_parse(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Issue #7: raise_for_status + plistlib.loads turned Apple's HTML into noise."""
    _AlwaysHtml503Handler.calls = 0
    with _serve(_AlwaysHtml503Handler) as server:
        monkeypatch.setattr(gsa, "_GS_ENDPOINT", _endpoint(server))
        with pytest.raises(gsa.GsaError, match="HTTP 503") as caught:
            gsa._gs_request({"o": "init", "u": "probe@example.invalid"}, _ANISETTES)
    assert "plist" not in str(caught.value).lower()
    assert _AlwaysHtml503Handler.calls == 2


def test_gsa_http_once_never_retries_the_same_session(monkeypatch: pytest.MonkeyPatch) -> None:
    """urllib3 retries would replay the spent connection. That must stay off."""
    seen: list[int] = []

    class _Adapter(requests.adapters.HTTPAdapter):
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            seen.append(kwargs.get("max_retries", "missing"))
            super().__init__(*args, **kwargs)

    monkeypatch.setattr(gsa, "HTTPAdapter", _Adapter)
    response = MagicMock()
    response.status_code = 200
    response.content = _OK_PLIST
    response.headers = {"Content-Type": "text/x-xml-plist"}

    class _Session:
        def mount(self, *_a: object, **_k: object) -> None:
            return None

        def request(self, *_a: object, **_k: object) -> MagicMock:
            return response

        def close(self) -> None:
            return None

        def __enter__(self) -> _Session:
            return self

        def __exit__(self, *_a: object) -> None:
            self.close()

    monkeypatch.setattr(gsa.requests, "Session", _Session)
    gsa._gsa_http_once("POST", "http://127.0.0.1/grandslam/GsService2", headers={})
    assert seen == [0]


def test_trusted_device_trigger_is_isolated_from_prior_gs_requests(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Issue #7 path: init + complete + GET trusteddevice must not share a socket."""
    with _serve(_TwoRequestKeepAliveHandler) as server:
        monkeypatch.setattr(gsa, "_GS_ENDPOINT", _endpoint(server))
        monkeypatch.setattr(
            gsa, "_TRUSTED_TRIGGER", _endpoint(server, "/auth/verify/trusteddevice")
        )
        gsa._gs_request({"o": "init", "u": "probe@example.invalid"}, _ANISETTES)
        gsa._gs_request({"o": "complete", "u": "probe@example.invalid"}, _ANISETTES)
        gsa._trigger_trusted("adsid", "token", _ANISETTES)
    assert len(server.events) == 3
    assert all(event["n"] == 1 for event in server.events)
    assert [event["method"] for event in server.events] == ["POST", "POST", "GET"]
    assert {event["connection"] for event in server.events} == {"close"}


def test_submit_trusted_html_503_is_a_gsa_error(monkeypatch: pytest.MonkeyPatch) -> None:
    _AlwaysHtml503Handler.calls = 0
    with _serve(_AlwaysHtml503Handler) as server:
        monkeypatch.setattr(
            gsa, "_VALIDATE", _endpoint(server, "/grandslam/GsService2/validate")
        )
        with pytest.raises(gsa.GsaError, match="HTTP 503"):
            gsa._submit_trusted("adsid", "token", "123456", _ANISETTES)
    assert _AlwaysHtml503Handler.calls == 2


def test_trigger_trusted_uses_isolated_gsa_http(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, Any] = {}

    def fake_http(method: str, url: str, *, headers: dict[str, str], data: bytes | None = None) -> MagicMock:
        captured["method"] = method
        captured["url"] = url
        captured["headers"] = headers
        response = MagicMock()
        response.status_code = 200
        response.content = b"<html>ok</html>"
        response.headers = {"Content-Type": "text/html"}
        return response

    monkeypatch.setattr(gsa, "_gsa_http", fake_http)
    gsa._trigger_trusted("adsid", "token", {"X-Apple-Locale": "zh_CN"})
    assert captured["method"] == "GET"
    assert captured["url"] == gsa._TRUSTED_TRIGGER


def test_spent_connection_predicate_requires_html_503() -> None:
    html = MagicMock()
    html.status_code = 503
    html.headers = {"Content-Type": "text/html"}
    html.content = _HTML_503
    assert gsa._gsa_spent_connection(html)

    plist_503 = MagicMock()
    plist_503.status_code = 503
    plist_503.headers = {"Content-Type": "text/x-xml-plist"}
    plist_503.content = _OK_PLIST
    assert not gsa._gsa_spent_connection(plist_503)

    ok = MagicMock()
    ok.status_code = 200
    ok.headers = {"Content-Type": "text/html"}
    ok.content = b"<html>interstitial</html>"
    assert not gsa._gsa_spent_connection(ok)


def test_gsa_client_info_replaces_blocked_xcode_token() -> None:
    """Issue #7 live 2026-09-18: Apple drops GsService2 on com.apple.dt.Xcode."""
    anisette_default = (
        "<MacBookPro13,2> <macOS;13.1;22C65> "
        "<com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>"
    )
    rewritten = gsa._gsa_client_info(anisette_default)
    assert rewritten == (
        "<MacBookPro13,2> <macOS;13.1;22C65> "
        "<com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    )
    assert "Xcode" not in rewritten
    # The block is the substring, not the version (AltStore #1790).
    bumped = gsa._gsa_client_info(
        "<Mac17,2> <macOS;27.0;26A5421a> "
        "<com.apple.AuthKit/1 (com.apple.dt.Xcode/25183.54.10)>"
    )
    assert "com.apple.dt.Xcode" not in bumped
    assert "com.apple.akd/1.0" in bumped
    already = (
        "<Mac15,7> <macOS;27.0;26A5378j> "
        "<com.apple.AuthKit/1 (com.apple.akd/1.0)>"
    )
    assert gsa._gsa_client_info(already) == already
    assert gsa._gsa_client_info("") == ""


def test_gs_request_sends_akd_not_xcode_client_info(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, str] = {}

    def fake_http(
        method: str,
        url: str,
        *,
        headers: dict[str, str],
        data: bytes | None = None,
    ) -> MagicMock:
        captured.update(headers)
        response = MagicMock()
        response.status_code = 200
        response.url = url
        response.content = _OK_PLIST
        response.headers = {"Content-Type": "text/x-xml-plist"}
        return response

    monkeypatch.setattr(gsa, "_gsa_http", fake_http)
    gsa._gs_request({"o": "init", "u": "probe@example.invalid"}, _ANISETTES)
    assert "com.apple.dt.Xcode" not in captured["X-MMe-Client-Info"]
    assert "com.apple.akd/1.0" in captured["X-MMe-Client-Info"]


def test_twofa_headers_replace_xcode_client_token() -> None:
    headers = gsa._twofa_headers("adsid", "token", _ANISETTES)
    assert "com.apple.dt.Xcode" not in headers["X-MMe-Client-Info"]
    assert "com.apple.akd/1.0" in headers["X-MMe-Client-Info"]
    # Anisette OTP fields must still ride along for trusted-device.
    assert "X-Apple-Locale" in headers


def test_sms_trigger_puts_json_on_isolated_gsa_http(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, Any] = {}

    def fake_http(
        method: str,
        url: str,
        *,
        headers: dict[str, str],
        data: bytes | None = None,
    ) -> MagicMock:
        captured["method"] = method
        captured["url"] = url
        captured["headers"] = headers
        captured["data"] = data
        response = MagicMock()
        response.status_code = 200
        response.url = url
        response.content = b"<html>ok</html>"
        response.headers = {"Content-Type": "text/html"}
        return response

    monkeypatch.setattr(gsa, "_gsa_http", fake_http)
    gsa._trigger_sms("adsid", "token", _ANISETTES)
    assert captured["method"] == "PUT"
    assert captured["url"] == gsa._SMS_ENDPOINT
    assert json.loads(captured["data"]) == {"phoneNumber": {"id": 1}, "mode": "sms"}
    assert "json" in captured["headers"]["Content-Type"]
    assert "com.apple.dt.Xcode" not in captured["headers"]["X-MMe-Client-Info"]
    assert "com.apple.akd/1.0" in captured["headers"]["X-MMe-Client-Info"]
    assert captured["url"].endswith("/auth/verify/phone")
    assert not captured["url"].endswith("/phone/")


def test_sms_trigger_accepts_http_423_too_many_codes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Apple 423 + tooManyCodesSent still means a code is already in flight."""

    def fake_http(
        method: str,
        url: str,
        *,
        headers: dict[str, str],
        data: bytes | None = None,
    ) -> MagicMock:
        response = MagicMock()
        response.status_code = 423
        response.url = url
        response.content = json.dumps(
            {
                "success": 0,
                "securityCode": {"tooManyCodesSent": True},
                "serviceErrors": [
                    {
                        "code": "-22979",
                        "message": "Enter the last code you received or try again later.",
                    }
                ],
            }
        ).encode()
        response.headers = {"Content-Type": "application/json"}
        return response

    monkeypatch.setattr(gsa, "_gsa_http", fake_http)
    gsa._trigger_sms("adsid", "token", _ANISETTES)


def test_sms_submit_posts_code_json(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, Any] = {}

    def fake_http(
        method: str,
        url: str,
        *,
        headers: dict[str, str],
        data: bytes | None = None,
    ) -> MagicMock:
        captured["method"] = method
        captured["url"] = url
        captured["data"] = data
        response = MagicMock()
        response.status_code = 200
        response.url = url
        response.content = b""
        response.headers = {"Content-Type": "application/json"}
        return response

    monkeypatch.setattr(gsa, "_gsa_http", fake_http)
    gsa._submit_sms("adsid", "token", "123456", _ANISETTES)
    assert captured["method"] == "POST"
    assert captured["url"] == gsa._SMS_SUBMIT
    body = json.loads(captured["data"])
    assert body["phoneNumber"] == {"id": 1}
    assert body["mode"] == "sms"
    assert body["securityCode"] == {"code": "123456"}


def test_sms_submit_maps_incorrect_code_json_to_gsa_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Live 2026-09-18: HTTP 400 body is Apple -21669, not a generic HTTP error."""

    def fake_http(
        method: str,
        url: str,
        *,
        headers: dict[str, str],
        data: bytes | None = None,
    ) -> MagicMock:
        response = MagicMock()
        response.status_code = 400
        response.url = url
        response.content = json.dumps(
            {
                "success": 0,
                "serviceErrors": [
                    {
                        "code": "-21669",
                        "title": "Incorrect Verification Code",
                        "message": "Try entering your verification code again.",
                    }
                ],
            }
        ).encode()
        response.headers = {"Content-Type": "application/json"}
        return response

    monkeypatch.setattr(gsa, "_gsa_http", fake_http)
    with pytest.raises(gsa.GsaError, match="Incorrect Verification Code"):
        gsa._submit_sms("adsid", "token", "000000", _ANISETTES)


# --------------------------------------------------------------------------- #
# Sign-in trace (gsa-trace.log)
# --------------------------------------------------------------------------- #


def _plist_response(status: dict[str, object], extra: dict[str, object] | None = None) -> MagicMock:
    import plistlib

    body: dict[str, object] = {"Status": status}
    body.update(extra or {})
    response = MagicMock()
    response.status_code = 200
    response.content = plistlib.dumps({"Response": body})
    response.headers = {"Content-Type": "text/x-xml-plist"}
    return response


def test_trace_records_the_outcome_and_never_a_secret(isolated_data) -> None:
    secret_token = "SECRET-IDMS-TOKEN-VALUE"
    response = _plist_response(
        {"ec": -22411, "em": "This action cannot be completed at this time", "hsc": 409, "au": "trustedDeviceSecondaryAuth"},
        {"spd": b"encrypted-session-data", "GsIdmsToken": secret_token, "M2": b"proof"},
    )
    gsa._trace("GsService2/complete", response)
    text = (isolated_data / "iPASide" / "gsa-trace.log").read_text(encoding="utf-8")
    assert "GsService2/complete" in text
    assert "http=200" in text
    assert "ec=-22411" in text and "hsc=409" in text
    assert "trustedDeviceSecondaryAuth" in text
    assert "keys=" in text  # the names of the fields are kept, so a changed reply shape is visible
    assert secret_token not in text
    assert "encrypted-session-data" not in text
    assert "proof" not in text


def test_trace_marks_an_html_error_page_without_copying_it(isolated_data) -> None:
    response = MagicMock()
    response.status_code = 503
    response.content = b"<html><body>Service Temporarily Unavailable secret-page-text</body></html>"
    response.headers = {"Content-Type": "text/html"}
    gsa._trace("GsService2/init", response)
    text = (isolated_data / "iPASide" / "gsa-trace.log").read_text(encoding="utf-8")
    assert "http=503" in text and " html" in text
    assert "secret-page-text" not in text


def test_trace_never_breaks_sign_in(monkeypatch: pytest.MonkeyPatch) -> None:
    def broken() -> None:
        raise OSError("disk full")

    monkeypatch.setattr(gsa.paths, "data_dir", broken)
    gsa._trace("GsService2/init", _plist_response({"ec": 0}))  # must not raise


def test_trace_file_stays_small(isolated_data) -> None:
    path = isolated_data / "iPASide" / "gsa-trace.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((b"old line of trace output\n") * 20_000)
    assert path.stat().st_size > gsa._TRACE_MAX_BYTES
    gsa._trace("GsService2/init", _plist_response({"ec": 0}))
    assert path.stat().st_size <= gsa._TRACE_MAX_BYTES
    assert path.read_text(encoding="utf-8").rstrip().endswith("keys=Status")


def test_gs_request_writes_a_trace_line(monkeypatch: pytest.MonkeyPatch, isolated_data) -> None:
    monkeypatch.setattr(gsa, "_gsa_http", lambda *a, **k: _plist_response({"ec": 0}))
    gsa._gs_request({"o": "init", "u": "probe@example.invalid"}, _ANISETTES)
    text = (isolated_data / "iPASide" / "gsa-trace.log").read_text(encoding="utf-8")
    assert "GsService2/init" in text and "ec=0" in text
