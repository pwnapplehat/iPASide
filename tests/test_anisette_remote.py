"""The remote (v3) anisette provider, tested against a real loopback server.

Apple closed the local anisette route in October 2026 (-80045, then -80046 at the token request), so
iPASide now gets anisette from a Mac service. These tests run the real client code - HTTP, the
provisioning WebSocket, state on disk - against a small server on 127.0.0.1 that speaks the same
protocol (SideStore/omnisette-server "v3"). Only Apple's own two provisioning endpoints are replaced
by a recorder, so nothing here touches the network.
"""

from __future__ import annotations

import base64
import hashlib
import json
import re
import socket
import threading
import uuid
from typing import Any

import pytest
from wsproto import ConnectionType, WSConnection
from wsproto.events import (
    AcceptConnection,
    CloseConnection,
    Ping,
    Pong,
    Request,
    TextMessage,
)

from ipaside_engine import anisette, anisette_remote, paths
from ipaside_engine.anisette import AnisetteError
from ipaside_engine.anisette_remote import RemoteAnisette

CLIENT_INFO = "<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
USER_AGENT = "akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0"
ADI_PB = b"opaque-adi-blob-from-the-service"
START_URL = "https://gsa.apple.com/grandslam/MidService/startMachineProvisioning"
FINISH_URL = "https://gsa.apple.com/grandslam/MidService/finishMachineProvisioning"


class FakeService:
    """A loopback v3 anisette service: /v3/client_info, /v3/get_headers, /v3/provisioning_session."""

    def __init__(self) -> None:
        self.client_info: Any = {"client_info": CLIENT_INFO, "user_agent": USER_AGENT}
        self.mode = "ok"
        self.sessions = 0
        self.client_messages: list[dict[str, Any]] = []
        self.get_headers_bodies: list[dict[str, Any]] = []
        self.get_headers_replies: list[Any] = []  # consumed in order; the last one repeats
        self.pongs = 0
        self._sock = socket.socket()
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        self.url = f"http://127.0.0.1:{self._sock.getsockname()[1]}"
        self._stop = False

    def start(self) -> None:
        threading.Thread(target=self._accept, daemon=True).start()

    def stop(self) -> None:
        self._stop = True
        try:
            self._sock.close()
        except OSError:
            pass

    def _accept(self) -> None:
        while not self._stop:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    # -- plain HTTP -------------------------------------------------------- #
    def _handle(self, conn: socket.socket) -> None:
        with conn:
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(65536)
                if not chunk:
                    return
                data += chunk
            head, _, body = data.partition(b"\r\n\r\n")
            lines = head.split(b"\r\n")
            method, target, _ = lines[0].decode().split(" ")
            if b"upgrade: websocket" in head.lower():
                self._websocket(conn, data)
                return
            length = 0
            for line in lines[1:]:
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":")[1])
            while len(body) < length:
                body += conn.recv(65536)
            if method == "GET" and target == "/v3/client_info":
                self._reply(conn, 200, self.client_info)
            elif method == "POST" and target == "/v3/get_headers":
                parsed = json.loads(body)
                self.get_headers_bodies.append(parsed)
                replies = self.get_headers_replies or [self.headers_ok()]
                reply = replies.pop(0) if len(replies) > 1 else replies[0]
                if isinstance(reply, int):
                    self._reply(conn, reply, {})
                else:
                    self._reply(conn, 200, reply)
            else:
                self._reply(conn, 404, {})

    @staticmethod
    def headers_ok() -> dict[str, str]:
        return {
            "result": "Headers",
            "X-Apple-I-MD": "OTP-ONE-TIME-PASSWORD",
            "X-Apple-I-MD-M": "MACHINE-ID",
            "X-Apple-I-MD-RINFO": "17106176",
        }

    @staticmethod
    def _reply(conn: socket.socket, status: int, payload: Any) -> None:
        raw = json.dumps(payload).encode()
        conn.sendall(
            f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {len(raw)}\r\n"
            "Connection: close\r\n\r\n".encode() + raw
        )

    # -- the provisioning WebSocket ---------------------------------------- #
    def _websocket(self, conn: socket.socket, first: bytes) -> None:
        self.sessions += 1
        ws = WSConnection(ConnectionType.SERVER)
        ws.receive_data(first)
        for event in ws.events():
            if isinstance(event, Request):
                conn.sendall(ws.send(AcceptConnection()))

        def send(obj: dict[str, Any]) -> None:
            text = json.dumps(obj)
            if self.mode == "fragmented":
                half = len(text) // 2
                conn.sendall(ws.send(TextMessage(data=text[:half], message_finished=False)))
                conn.sendall(ws.send(TextMessage(data=text[half:], message_finished=True)))
            else:
                conn.sendall(ws.send(TextMessage(data=text)))

        def receive() -> dict[str, Any] | None:
            while True:
                for event in ws.events():
                    if isinstance(event, TextMessage):
                        message = json.loads(event.data)
                        self.client_messages.append(message)
                        return message
                    if isinstance(event, Pong):
                        self.pongs += 1
                    if isinstance(event, CloseConnection):
                        return None
                data = conn.recv(65536)
                if not data:
                    return None
                ws.receive_data(data)

        try:
            if self.mode == "close_early":
                conn.sendall(ws.send(CloseConnection(code=1000)))
                return
            if self.mode == "garbage":
                conn.sendall(ws.send(TextMessage(data="this is not json")))
                return
            if self.mode == "ping_first":
                conn.sendall(ws.send(Ping()))
            if self.mode == "timeout":
                send({"result": "Timeout"})
                return
            if self.mode == "invalid_identifier":
                send({"result": "InvalidIdentifier"})
                return
            send({"result": "GiveIdentifier"})
            if receive() is None:
                return
            send({"result": "GiveStartProvisioningData"})
            if receive() is None:
                return
            if self.mode == "start_error":
                send({"result": "StartProvisioningError", "message": "start went wrong"})
                return
            send({"result": "GiveEndProvisioningData", "cpim": "CPIM-FROM-SERVICE"})
            if receive() is None:
                return
            if self.mode == "end_error":
                send({"result": "EndProvisioningError", "message": "finish went wrong"})
                return
            send({"result": "ProvisioningSuccess", "adi_pb": base64.b64encode(ADI_PB).decode()})
            receive()  # wait for the client to hang up
        except (OSError, ValueError):
            return


class AppleRecorder:
    """Stands in for Apple's two provisioning endpoints."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []
        self.fail: Exception | None = None

    def post(self, url: str, body: dict[str, Any], identity: Any, state: Any) -> dict[str, Any]:
        if self.fail:
            raise self.fail
        self.calls.append(
            {
                "url": url,
                "body": body,
                "user_agent": identity.user_agent,
                "client_info": identity.client_info,
                "md_lu": state.md_lu,
                "device_id": state.device_id,
                "identifier": state.identifier,
            }
        )
        if url == START_URL:
            return {"spim": "SPIM-FROM-APPLE"}
        return {"ptm": "PTM-FROM-APPLE", "tk": "TK-FROM-APPLE"}


@pytest.fixture
def service():
    fake = FakeService()
    fake.start()
    yield fake
    fake.stop()


@pytest.fixture
def apple(monkeypatch: pytest.MonkeyPatch) -> AppleRecorder:
    recorder = AppleRecorder()
    monkeypatch.setattr(RemoteAnisette, "_apple_post", lambda self, *a, **k: recorder.post(*a, **k))
    monkeypatch.setattr(RemoteAnisette, "_provisioning_urls", lambda self, identity: (START_URL, FINISH_URL))
    return recorder


@pytest.fixture
def provider(service: FakeService, apple: AppleRecorder) -> RemoteAnisette:
    return RemoteAnisette(servers=(service.url,))


def _state_file():
    return paths.anisette_dir() / anisette_remote.STATE_FILE


# --------------------------------------------------------------------------- #
# Provisioning and headers
# --------------------------------------------------------------------------- #


def test_first_fetch_provisions_through_the_service_and_returns_headers(
    provider: RemoteAnisette, service: FakeService, apple: AppleRecorder
) -> None:
    fetched = provider.fetch()

    assert service.sessions == 1
    sent = service.client_messages
    identifier = base64.b64decode(sent[0]["identifier"])
    assert len(identifier) == 16
    assert sent[1] == {"spim": "SPIM-FROM-APPLE"}
    assert sent[2] == {"ptm": "PTM-FROM-APPLE", "tk": "TK-FROM-APPLE"}

    # Apple is called directly, with the service's identity and this install's own device id.
    start, finish = apple.calls
    assert start["url"] == START_URL and finish["url"] == FINISH_URL
    assert finish["body"]["Request"]["cpim"] == "CPIM-FROM-SERVICE"
    for call in apple.calls:
        assert call["user_agent"] == USER_AGENT
        assert call["client_info"] == CLIENT_INFO
        assert call["md_lu"] == hashlib.sha256(identifier).hexdigest()
        assert call["device_id"] == str(uuid.UUID(bytes=identifier))

    headers = fetched.headers
    assert headers["X-Apple-I-MD"] == "OTP-ONE-TIME-PASSWORD"
    assert headers["X-Apple-I-MD-M"] == "MACHINE-ID"
    assert headers["X-Apple-I-MD-RINFO"] == "17106176"
    assert headers["X-Apple-I-MD-LU"] == hashlib.sha256(identifier).hexdigest()
    assert headers["X-Mme-Device-Id"] == str(uuid.UUID(bytes=identifier))
    assert headers["X-Apple-I-SRL-NO"] == "0"
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", headers["X-Apple-I-Client-Time"])
    assert fetched.identity.client_info == CLIENT_INFO
    assert fetched.identity.user_agent == USER_AGENT

    # the service was asked for headers with this install's identifier and the blob it returned
    body = service.get_headers_bodies[0]
    assert base64.b64decode(body["identifier"]) == identifier
    assert base64.b64decode(body["adi_pb"]) == ADI_PB


def test_the_identity_is_saved_and_reused(provider: RemoteAnisette, service: FakeService) -> None:
    first = provider.fetch()
    saved = json.loads(_state_file().read_text(encoding="utf-8"))
    assert base64.b64decode(saved["adi_pb"]) == ADI_PB
    assert saved["server"] == service.url

    second = provider.fetch()
    assert service.sessions == 1  # no second provisioning
    assert second.headers["X-Mme-Device-Id"] == first.headers["X-Mme-Device-Id"]

    # and it survives a restart of the engine
    again = RemoteAnisette(servers=(service.url,)).fetch()
    assert service.sessions == 1
    assert again.headers["X-Mme-Device-Id"] == first.headers["X-Mme-Device-Id"]


def test_every_install_gets_its_own_identifier(service: FakeService, apple: AppleRecorder, monkeypatch) -> None:
    ids = []
    for _ in range(2):
        _state_file().unlink(missing_ok=True)
        ids.append(RemoteAnisette(servers=(service.url,)).fetch().headers["X-Mme-Device-Id"])
    assert ids[0] != ids[1]


def test_a_rejected_identity_is_reprovisioned_once(provider: RemoteAnisette, service: FakeService) -> None:
    service.get_headers_replies = [
        {"result": "GetHeadersError", "message": "ADI error -45061: not provisioned"},
        FakeService.headers_ok(),
    ]
    fetched = provider.fetch()
    assert service.sessions == 2
    first_id = base64.b64decode(service.client_messages[0]["identifier"])
    second_id = base64.b64decode(service.client_messages[3]["identifier"])
    assert first_id != second_id  # a clean new identity, not a retry of the old one
    assert fetched.headers["X-Mme-Device-Id"] == str(uuid.UUID(bytes=second_id))


def test_still_rejected_after_a_fresh_identity_is_an_error(provider: RemoteAnisette, service: FakeService) -> None:
    service.get_headers_replies = [{"result": "GetHeadersError", "message": "ADI error -45061"}]
    with pytest.raises(AnisetteError, match="freshly provisioned"):
        provider.fetch()
    assert service.sessions == 2  # tried exactly once more, not in a loop


def test_other_header_errors_are_reported_with_the_services_words(
    provider: RemoteAnisette, service: FakeService
) -> None:
    service.get_headers_replies = [{"result": "GetHeadersError", "message": "something exploded"}]
    with pytest.raises(AnisetteError, match="something exploded"):
        provider.fetch()


# --------------------------------------------------------------------------- #
# Provisioning failures
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    ("mode", "expected"),
    [("start_error", r"\(start\): start went wrong"), ("end_error", r"\(finish\): finish went wrong")],
)
def test_apple_provisioning_errors_reported_by_the_service_are_shown(
    provider: RemoteAnisette, service: FakeService, mode: str, expected: str
) -> None:
    service.mode = mode
    with pytest.raises(AnisetteError, match=expected):
        provider.fetch()
    assert not _state_file().exists()  # nothing half-provisioned is kept


def test_an_error_from_apple_itself_is_not_hidden_behind_a_server_fallback(
    service: FakeService, apple: AppleRecorder
) -> None:
    apple.fail = AnisetteError("Apple's provisioning service answered error -123: nope")
    other = FakeService()
    other.start()
    try:
        with pytest.raises(AnisetteError, match="-123: nope"):
            RemoteAnisette(servers=(service.url, other.url)).fetch()
        assert other.sessions == 0  # a definitive answer from Apple does not try the next server
    finally:
        other.stop()


@pytest.mark.parametrize("mode", ["timeout", "invalid_identifier", "close_early", "garbage"])
def test_a_service_that_misbehaves_is_skipped_and_the_next_one_used(
    service: FakeService, apple: AppleRecorder, mode: str
) -> None:
    service.mode = mode
    good = FakeService()
    good.start()
    try:
        fetched = RemoteAnisette(servers=(service.url, good.url)).fetch()
        assert fetched.server == good.url
        assert good.sessions == 1
    finally:
        good.stop()


def test_every_server_down_gives_one_clear_message_naming_each(apple: AppleRecorder) -> None:
    with pytest.raises(AnisetteError) as caught:
        RemoteAnisette(servers=("http://127.0.0.1:1", "http://localhost:2")).fetch()
    text = str(caught.value)
    assert "Could not reach any anisette service" in text
    assert "127.0.0.1" in text and "localhost" in text
    assert "Traceback" not in text


def test_a_server_that_is_down_falls_back_without_error(service: FakeService, apple: AppleRecorder) -> None:
    fetched = RemoteAnisette(servers=("http://127.0.0.1:1", service.url)).fetch()
    assert fetched.server == service.url


# --------------------------------------------------------------------------- #
# Validation of what a server sends
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "bad",
    [
        {"client_info": "<a> <b> <c>\r\nX-Injected: yes", "user_agent": USER_AGENT},
        {"client_info": "no angle brackets at all", "user_agent": USER_AGENT},
        {"client_info": "<" + "x" * 500 + "> <b> <c>", "user_agent": USER_AGENT},
        {"client_info": CLIENT_INFO, "user_agent": "agent\r\nX-Injected: yes"},
        {"client_info": CLIENT_INFO},
        {"client_info": 5, "user_agent": USER_AGENT},
        ["not", "an", "object"],
    ],
)
def test_a_malformed_client_identity_is_refused(service: FakeService, apple: AppleRecorder, bad: Any) -> None:
    service.client_info = bad
    with pytest.raises(AnisetteError, match="Could not reach any anisette service"):
        RemoteAnisette(servers=(service.url,)).fetch()
    assert service.sessions == 0  # never got as far as provisioning with a bad identity


@pytest.mark.parametrize(
    "bad",
    [
        {"result": "Headers", "X-Apple-I-MD": "x", "X-Apple-I-MD-M": "y"},  # a field missing
        {"result": "Headers", "X-Apple-I-MD": "bad\r\nvalue", "X-Apple-I-MD-M": "y", "X-Apple-I-MD-RINFO": "z"},
        {"result": "Headers", "X-Apple-I-MD": "", "X-Apple-I-MD-M": "y", "X-Apple-I-MD-RINFO": "z"},
        {"result": "Headers", "X-Apple-I-MD": 7, "X-Apple-I-MD-M": "y", "X-Apple-I-MD-RINFO": "z"},
        {"result": "SomethingNew"},
        ["list"],
        500,
    ],
)
def test_malformed_headers_from_a_server_are_refused(
    service: FakeService, apple: AppleRecorder, bad: Any
) -> None:
    service.get_headers_replies = [bad]
    with pytest.raises(AnisetteError):
        RemoteAnisette(servers=(service.url,)).fetch()


def test_plain_http_is_only_accepted_for_this_machine(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(anisette_remote.SERVER_ENV, "http://anisette.example.com")
    with pytest.raises(AnisetteError, match="https://"):
        RemoteAnisette().fetch()
    monkeypatch.setenv(anisette_remote.SERVER_ENV, "https://anisette.example.com/")
    assert RemoteAnisette().servers() == ("https://anisette.example.com",)  # trailing slash tidied
    monkeypatch.delenv(anisette_remote.SERVER_ENV)
    assert RemoteAnisette().servers() == anisette_remote.SERVERS


def test_the_built_in_servers_are_all_https_mac_services() -> None:
    assert anisette_remote.SERVERS[0] == "https://mac-ani.jkcoxson.com"
    assert len(anisette_remote.SERVERS) >= 2  # one service being down must not stop sign-in
    assert all(url.startswith("https://") for url in anisette_remote.SERVERS)


def test_apple_urls_must_be_apple() -> None:
    real = RemoteAnisette()  # the real _apple_post: this test must not use the recorder fixture
    state = anisette_remote._State.new()
    identity = anisette_remote.ClientIdentity(CLIENT_INFO, USER_AGENT)
    for url in ("https://evil.example.com/x", "http://gsa.apple.com/x", "https://apple.com.evil.test/x"):
        with pytest.raises(AnisetteError, match="not an Apple address"):
            real._apple_post(url, {}, identity, state)


# --------------------------------------------------------------------------- #
# The WebSocket client
# --------------------------------------------------------------------------- #


def test_a_ping_is_answered_and_provisioning_carries_on(
    provider: RemoteAnisette, service: FakeService
) -> None:
    service.mode = "ping_first"
    provider.fetch()
    assert service.pongs >= 1


def test_a_message_split_across_frames_is_put_back_together(
    provider: RemoteAnisette, service: FakeService
) -> None:
    service.mode = "fragmented"
    provider.fetch()
    assert service.sessions == 1


# --------------------------------------------------------------------------- #
# State on disk
# --------------------------------------------------------------------------- #


def test_a_damaged_state_file_is_replaced_not_fatal(provider: RemoteAnisette, service: FakeService) -> None:
    _state_file().write_text("{not json", encoding="utf-8")
    provider.fetch()
    assert service.sessions == 1
    assert json.loads(_state_file().read_text(encoding="utf-8"))["adi_pb"]


def test_reset_state_forgets_the_identity(provider: RemoteAnisette, service: FakeService) -> None:
    provider.fetch()
    anisette_remote.reset_state()
    assert not _state_file().exists()
    provider.fetch()
    assert service.sessions == 2


# --------------------------------------------------------------------------- #
# How anisette.get_headers() uses it
# --------------------------------------------------------------------------- #


def test_remote_is_the_default_and_its_identity_reaches_the_headers(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv(anisette.PROVIDER_ENV, raising=False)
    assert anisette.provider_name() == "remote"
    fetched = anisette_remote.Fetched(
        headers={"X-Apple-I-MD": "otp", "X-Mme-Device-Id": "id"},
        identity=anisette_remote.ClientIdentity(CLIENT_INFO, USER_AGENT),
        server="https://mac-ani.jkcoxson.com",
    )
    monkeypatch.setattr(anisette_remote, "fetch", lambda: fetched)
    headers = anisette.get_headers()
    assert headers["X-MMe-Client-Info"] == CLIENT_INFO  # the service's identity, not the local constant
    assert anisette.gsa_user_agent() == USER_AGENT
    headers["X-Apple-I-TimeZone"].encode("latin-1")  # still wire-safe


def test_local_mode_is_still_available_for_rollback(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(anisette.PROVIDER_ENV, "local")
    monkeypatch.setattr(anisette, "_raw_headers", lambda: {"X-Apple-I-MD": "otp"})
    monkeypatch.setattr(anisette_remote, "fetch", lambda: pytest.fail("remote must not be used in local mode"))
    headers = anisette.get_headers()
    assert headers["X-MMe-Client-Info"] == anisette.CLIENT_INFO
    assert anisette.gsa_user_agent() is None


def test_status_says_which_provider_is_active(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(anisette.PROVIDER_ENV, raising=False)
    remote = anisette.status()
    assert remote["provider"] == "remote"
    assert remote["servers"] == list(anisette_remote.SERVERS)
    assert remote["state_path"].endswith(anisette_remote.STATE_FILE)
    monkeypatch.setenv(anisette.PROVIDER_ENV, "local")
    local = anisette.status()
    assert local["provider"] == "local" and local["servers"] == []
