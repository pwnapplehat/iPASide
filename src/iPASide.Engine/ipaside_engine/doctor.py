"""Environment doctor for iPASide.

Reports whether the local machine has everything iPASide needs to sideload:
the Apple Mobile Device Service (usbmuxd) for USB device I/O, the anisette
building blocks used to authenticate an Apple ID, optional Bonjour for Wi-Fi
discovery, the Flutter SDK for the desktop shell, and any connected iOS devices.

Each check returns a status of ``ok``, ``warn`` (degraded / optional), or
``fail`` (a blocker for the affected feature).
"""

from __future__ import annotations

import ctypes
import json
import os
import re
import shutil
import subprocess
import sys
from importlib import metadata
from pathlib import Path
from typing import Any

Check = dict[str, Any]

OK = "ok"
WARN = "warn"
FAIL = "fail"


#: ``SERVICE_STATUS.dwCurrentState`` values, by the names ``sc query`` prints for them.
_SERVICE_STATES = {
    1: "STOPPED",
    2: "START_PENDING",
    3: "STOP_PENDING",
    4: "RUNNING",
    5: "CONTINUE_PENDING",
    6: "PAUSE_PENDING",
    7: "PAUSED",
}
_SC_MANAGER_CONNECT = 0x0001
_SERVICE_QUERY_STATUS = 0x0004
_ERROR_SERVICE_DOES_NOT_EXIST = 1060

#: The state line of ``sc query``: a label that Windows translates, then ``4  RUNNING``. Only the
#: number and the English state name are relied on, and the name must be a known one so the
#: ``TYPE : 10  WIN32_OWN_PROCESS`` line cannot be mistaken for it.
_SC_STATE_LINE = re.compile(r"^[^:\r\n]+:\s*(\d+)\s+([A-Z_]+)\s*$", re.MULTILINE)


class _ServiceStatus(ctypes.Structure):
    _fields_ = [
        ("dwServiceType", ctypes.c_uint32),
        ("dwCurrentState", ctypes.c_uint32),
        ("dwControlsAccepted", ctypes.c_uint32),
        ("dwWin32ExitCode", ctypes.c_uint32),
        ("dwServiceSpecificExitCode", ctypes.c_uint32),
        ("dwCheckPoint", ctypes.c_uint32),
        ("dwWaitHint", ctypes.c_uint32),
    ]


def _service_state_from_api(service_name: str) -> str | None:
    """The state of a Windows service from the service manager, or ``None`` if it is not installed.

    Raises ``OSError`` when the service manager itself cannot be asked, so the caller can fall
    back to ``sc`` rather than call an installed service missing.
    """
    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    advapi32.OpenSCManagerW.restype = ctypes.c_void_p
    advapi32.OpenSCManagerW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32]
    advapi32.OpenServiceW.restype = ctypes.c_void_p
    advapi32.OpenServiceW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint32]
    advapi32.QueryServiceStatus.restype = ctypes.c_int
    advapi32.QueryServiceStatus.argtypes = [ctypes.c_void_p, ctypes.POINTER(_ServiceStatus)]
    advapi32.CloseServiceHandle.restype = ctypes.c_int
    advapi32.CloseServiceHandle.argtypes = [ctypes.c_void_p]

    manager = advapi32.OpenSCManagerW(None, None, _SC_MANAGER_CONNECT)
    if not manager:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        service = advapi32.OpenServiceW(manager, service_name, _SERVICE_QUERY_STATUS)
        if not service:
            error = ctypes.get_last_error()
            if error == _ERROR_SERVICE_DOES_NOT_EXIST:
                return None
            raise ctypes.WinError(error)
        try:
            status = _ServiceStatus()
            if not advapi32.QueryServiceStatus(service, ctypes.byref(status)):
                raise ctypes.WinError(ctypes.get_last_error())
            return _SERVICE_STATES.get(status.dwCurrentState)
        finally:
            advapi32.CloseServiceHandle(service)
    finally:
        advapi32.CloseServiceHandle(manager)


def _parse_sc_state(output: str) -> str | None:
    """The service state in ``sc query`` output, whatever language Windows prints its labels in."""
    for number, name in _SC_STATE_LINE.findall(output):
        if _SERVICE_STATES.get(int(number)) == name:
            return name
    return None


def _windows_service_state(service_name: str) -> str | None:
    """Return the raw Windows service state (e.g. ``RUNNING``) or ``None``.

    Asks the service manager directly, which has no language. Parsing ``sc query`` was how this
    first worked, and it reported the device service missing on an Italian Windows, where the line
    is labelled ``STATO`` instead of ``STATE`` (issue #13). ``sc`` is only the fallback now, and
    reads the numeric code and state name rather than the label.
    """
    if os.name != "nt":
        return None
    try:
        return _service_state_from_api(service_name)
    except (OSError, AttributeError):
        pass
    try:
        proc = subprocess.run(
            ["sc", "query", service_name],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return _parse_sc_state(proc.stdout)


def _check_python() -> Check:
    version = ".".join(str(part) for part in sys.version_info[:3])
    status = OK if sys.version_info >= (3, 9) else FAIL
    return {
        "name": "Python runtime",
        "status": status,
        "detail": f"Python {version}",
    }


def _check_pymobiledevice3() -> Check:
    try:
        version = metadata.version("pymobiledevice3")
    except metadata.PackageNotFoundError:
        return {
            "name": "pymobiledevice3",
            "status": FAIL,
            "detail": "not installed (pip install -r requirements.txt)",
        }
    return {"name": "pymobiledevice3", "status": OK, "detail": f"v{version}"}


def _check_amds() -> Check:
    """Apple Mobile Device Service ships usbmuxd on Windows; required for USB.

    Reports whatever ``apple_support.status`` found rather than probing again: the
    Home and Sideload screens act on that answer and offer to fix it, so a second
    probe here could only ever disagree with the thing the user was told.
    """
    from . import apple_support

    report = apple_support.status()
    # Only the two states that genuinely block a sideload fail. A host with no such
    # service, or a state a future build reports that this one cannot read, warns:
    # failing the whole report over a word we do not recognise would be a guess.
    status = {
        apple_support.RUNNING: OK,
        apple_support.STOPPED: FAIL,
        apple_support.MISSING: FAIL,
    }.get(report["state"], WARN)
    return {
        "name": "Apple Mobile Device Service",
        "status": status,
        "detail": report["detail"],
    }


def _check_anisette() -> Check:
    """The anisette provider: a remote Mac service by default, or the local emulator.

    Apple stopped accepting locally generated anisette in October 2026, so by default the
    headers come from a Mac anisette service (see ``anisette_remote``). The local `anisette`
    package is only needed when ``IPASIDE_ANISETTE=local`` selects it.
    """
    from urllib.parse import urlparse

    from . import anisette

    status = anisette.status()
    if status["provider"] == "remote":
        hosts = ", ".join(urlparse(server).hostname or server for server in status["servers"])
        state = "identity provisioned" if status["state_cached"] else "will provision on first login"
        return {
            "name": "Anisette provider",
            "status": OK,
            "detail": f"remote Mac service ({hosts}); {state}",
        }
    try:
        version = metadata.version("Anisette")
    except metadata.PackageNotFoundError:
        return {
            "name": "Anisette provider",
            "status": FAIL,
            "detail": "anisette package not installed (pip install -r requirements.txt)",
        }
    from . import paths

    cached = paths.anisette_state_file().exists()
    state = "provisioning state cached" if cached else "will provision on first login"
    return {
        "name": "Anisette provider",
        "status": OK,
        "detail": f"anisette v{version} ({state})",
    }


def _check_bonjour() -> Check:
    """Optional: Bonjour enables Wi-Fi device discovery (USB works without it)."""
    if os.name != "nt":
        return {"name": "Bonjour (Wi-Fi discovery)", "status": WARN, "detail": "optional"}
    state = _windows_service_state("Bonjour Service")
    if state == "RUNNING":
        return {"name": "Bonjour (Wi-Fi discovery)", "status": OK, "detail": "running"}
    return {
        "name": "Bonjour (Wi-Fi discovery)",
        "status": WARN,
        "detail": "not installed - optional, only needed for wireless install",
    }


def _check_flutter() -> Check:
    """The desktop shell is built with Flutter; needed to build the GUI, not to run it."""
    name = "Flutter SDK (desktop shell)"
    exe = shutil.which("flutter")
    if not exe:
        return {
            "name": name,
            "status": WARN,
            "detail": "not found - needed to build the GUI, not the engine",
        }
    return {"name": name, "status": OK, "detail": f"v{_flutter_version(exe)}"}


def _flutter_version(exe: str) -> str:
    """Read the SDK version from disk.

    `flutter --version` costs seconds because it may bootstrap the tool, and the
    doctor screen blocks on this, so the version files are read directly.
    """
    root = Path(exe).resolve().parent.parent  # <sdk>/bin/flutter[.bat] -> <sdk>
    plain = root / "version"
    try:
        if plain.is_file():
            text = plain.read_text(encoding="utf-8").strip()
            if text:
                return text
    except OSError:
        pass
    try:
        cached = root / "bin" / "cache" / "flutter.version.json"
        if cached.is_file():
            data = json.loads(cached.read_text(encoding="utf-8"))
            version = data.get("flutterVersion")
            if isinstance(version, str) and version:
                return version
    except (OSError, ValueError):
        pass
    return "unknown"


def _check_devices() -> Check:
    try:
        from . import device

        devices = device.list_devices()
    except Exception as exc:  # noqa: BLE001 - report any failure as a check result
        return {
            "name": "Connected iOS devices",
            "status": WARN,
            "detail": f"could not enumerate: {exc}",
        }
    if not devices:
        return {
            "name": "Connected iOS devices",
            "status": WARN,
            "detail": "none visible - plug in via USB, unlock, and tap 'Trust'",
        }
    # usbmux reports one entry per transport, so a phone that is plugged in *and*
    # reachable over Wi-Fi appears twice. Group by UDID so the count is physical
    # devices and each one lists the ways it can be reached.
    transports_by_serial: dict[str, list[str]] = {}
    for entry in devices:
        serial = str(entry.get("serial", "?"))
        transport = str(entry.get("connection_type", "?"))
        transports = transports_by_serial.setdefault(serial, [])
        if transport not in transports:
            transports.append(transport)
    summary = ", ".join(
        # USB first, matching the connection policy that prefers it.
        f"{serial} ({'/'.join(sorted(transports, key=lambda t: t.upper() != 'USB'))})"
        for serial, transports in transports_by_serial.items()
    )
    count = len(transports_by_serial)
    return {
        "name": "Connected iOS devices",
        "status": OK,
        "detail": f"{count} device{'' if count == 1 else 's'}: {summary}",
    }


def run_doctor() -> dict[str, Any]:
    """Run every check and return a structured report."""
    checks = [
        _check_python(),
        _check_pymobiledevice3(),
        _check_amds(),
        _check_anisette(),
        _check_bonjour(),
        _check_flutter(),
        _check_devices(),
    ]
    has_fail = any(c["status"] == FAIL for c in checks)
    has_warn = any(c["status"] == WARN for c in checks)
    overall = FAIL if has_fail else (WARN if has_warn else OK)
    return {"overall": overall, "checks": checks}
