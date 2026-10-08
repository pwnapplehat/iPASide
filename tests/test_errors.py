"""Tests for the boundary between a situation and a bug.

An expected failure (phone unplugged, Apple said no) must reach the user as its own
message; anything else must keep its traceback. The app forwards `str(exc)` straight
into an error banner, so the vanished-device path must never be an empty string.
``DeviceNotFoundError`` used to stringify blank; current pymobiledevice3 includes the
UDID. Either way we translate it into a reconnect sentence.
"""

import pytest

from ipaside_engine import apple_support, apps, developer, device, gsa, ipa, lockdown, sideload, signing
from ipaside_engine._asyncutil import run
from ipaside_engine.errors import EngineError
from ipaside_engine.__main__ import main

UDID = "935cbbb9b82d25d15566e5939bcea5677b1c44ae"


@pytest.mark.parametrize(
    "error_type",
    [
        sideload.SideloadError,
        device.DeviceError,
        signing.SigningError,
        developer.DeveloperServicesError,
        gsa.GsaError,
        apple_support.AppleSupportError,
        ipa.IpaError,
        apps.InstallLimitError,
    ],
)
def test_every_expected_failure_shares_the_base(error_type):
    # The CLI and the serve loop both key off this to decide message-vs-stack.
    assert issubclass(error_type, EngineError)


@pytest.fixture
def usbmux(monkeypatch):
    """Replace usbmux's connect with something that fails how we ask it to."""

    def install(error):
        import pymobiledevice3.lockdown as pml

        def connect(serial=None, connection_type=None):
            raise error

        monkeypatch.setattr(pml, "create_using_usbmux", connect)

    monkeypatch.setattr(device, "resolve_serial_async", _immediately(UDID))
    return install


def _immediately(value):
    async def resolved(_serial=None):
        return value

    return resolved


def test_a_vanished_device_is_named_not_blank(usbmux):
    from pymobiledevice3.exceptions import DeviceNotFoundError

    usbmux(DeviceNotFoundError(UDID))
    with pytest.raises(device.DeviceError) as caught:
        run(lockdown.create(UDID))

    message = str(caught.value)
    assert UDID in message
    assert "not connected" in message
    assert message.strip(), "an empty message would render an empty error banner"


def test_another_connection_failure_keeps_its_detail(usbmux):
    usbmux(OSError("the pairing record is missing"))
    with pytest.raises(device.DeviceError, match="pairing record is missing"):
        run(lockdown.create(UDID))


def test_a_failure_with_no_message_still_says_something(usbmux):
    class Nameless(Exception):
        pass

    usbmux(Nameless())
    message = str(_raised(lambda: run(lockdown.create(UDID))))
    assert "Nameless" in message  # the type is all there is to report
    assert UDID in message


class TestPreferredConnection:
    """The transport choice, which reaches lockdown through the environment."""

    def test_unset_means_prefer_usb_and_fall_back(self, monkeypatch):
        monkeypatch.delenv(lockdown.CONNECTION_ENV, raising=False)
        assert lockdown.preferred_connection() is None

    @pytest.mark.parametrize("value", ["", "auto", "AUTO", "  "])
    def test_blank_and_auto_mean_the_same(self, monkeypatch, value):
        monkeypatch.setenv(lockdown.CONNECTION_ENV, value)
        assert lockdown.preferred_connection() is None

    @pytest.mark.parametrize(
        ("value", "expected"),
        [
            ("usb", "USB"),
            ("USB", "USB"),
            ("wifi", "Network"),
            ("wi-fi", "Network"),
            ("network", "Network"),
            ("  WiFi  ", "Network"),
        ],
    )
    def test_accepts_what_a_person_might_type(self, monkeypatch, value, expected):
        monkeypatch.setenv(lockdown.CONNECTION_ENV, value)
        assert lockdown.preferred_connection() == expected

    def test_a_value_it_cannot_read_is_refused_not_guessed(self, monkeypatch):
        # Silently falling back to automatic would make a typo look like it worked.
        monkeypatch.setenv(lockdown.CONNECTION_ENV, "carrier-pigeon")
        with pytest.raises(EngineError, match="not a transport"):
            lockdown.preferred_connection()


def test_a_forced_transport_is_honoured_not_treated_as_a_hint(usbmux, monkeypatch):
    # Falling back to the other transport would make the setting a lie, and hide a
    # bad cable behind a slow Wi-Fi install.
    monkeypatch.setenv(lockdown.CONNECTION_ENV, "usb")
    attempted: list[str | None] = []

    import pymobiledevice3.lockdown as pml

    def connect(serial=None, connection_type=None):
        attempted.append(connection_type)
        raise OSError("no USB transport")

    monkeypatch.setattr(pml, "create_using_usbmux", connect)
    with pytest.raises(device.DeviceError) as caught:
        run(lockdown.create(UDID))

    assert attempted == ["USB"], "it must not retry over the network"
    assert "not reachable over USB" in str(caught.value)


def test_automatic_still_falls_back_to_the_network(usbmux, monkeypatch):
    monkeypatch.delenv(lockdown.CONNECTION_ENV, raising=False)
    attempted: list[str | None] = []

    import pymobiledevice3.lockdown as pml

    def connect(serial=None, connection_type=None):
        attempted.append(connection_type)
        raise OSError("nope")

    monkeypatch.setattr(pml, "create_using_usbmux", connect)
    with pytest.raises(device.DeviceError):
        run(lockdown.create(UDID))

    assert attempted == ["USB", None], "USB first, then any transport"


def test_cli_prints_one_line_for_an_expected_failure(monkeypatch, capsys):
    monkeypatch.setattr(
        device, "get_device_info", _raise(device.DeviceError("Device X is not connected."))
    )
    assert main(["device-info", "--udid", "X"]) == 1

    captured = capsys.readouterr()
    assert captured.err.strip() == "error: Device X is not connected."
    assert "Traceback" not in captured.err


def test_cli_reports_an_expected_failure_as_json_when_asked(monkeypatch, capsys):
    monkeypatch.setattr(
        device, "get_device_info", _raise(device.DeviceError("Device X is not connected."))
    )
    assert main(["device-info", "--udid", "X", "--json"]) == 1

    payload = capsys.readouterr().out
    assert '"status": "error"' in payload
    assert "Device X is not connected." in payload


def test_cli_keeps_the_traceback_for_a_bug(monkeypatch):
    # Not an EngineError, so it is a bug and the stack is the point.
    monkeypatch.setattr(device, "get_device_info", _raise(ValueError("a genuine bug")))
    with pytest.raises(ValueError, match="a genuine bug"):
        main(["device-info"])


def test_fault_handler_arms_stderr():
    import faulthandler

    from ipaside_engine.__main__ import _enable_fault_handler

    _enable_fault_handler()
    assert faulthandler.is_enabled()


def _raise(error):
    def fail(*_args, **_kwargs):
        raise error

    return fail


def _raised(call):
    try:
        call()
    except Exception as exc:  # noqa: BLE001 - the exception is the assertion subject
        return exc
    raise AssertionError("expected a failure")
