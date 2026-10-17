"""Anisette provider.

Anisette headers are the device-provisioning data Apple's GrandSlam (GSA) servers
require to authenticate an Apple ID from a non-Apple machine. iPASide generates them
fully in-process using the pure-Python ``anisette`` package, which runs Apple's own
portable provisioning libraries. The emulator runs in a small helper process of its
own (``anisette_worker``), not inside the engine: it is native code that Windows exploit
mitigations can kill outright, and that must end one sign-in attempt with an
explanation, not the engine.

Those libraries (about 2 MB, arm64, which the provider emulates regardless of host CPU)
are fetched once from a public host and then cached with the provisioning state in a
single file, so the machine presents as a stable, already-provisioned device on every
run - re-provisioning repeatedly is what trips Apple's anti-abuse checks. The libraries
are Apple's own binaries, so iPASide downloads them rather than redistributing them, but
it does the download itself: it retries, checks the response really is an archive, and
raises a message a user can act on instead of dying on a raw archive-parser error. No
Apple ID information is in anisette data, and none is sent to the library host.
"""

from __future__ import annotations

import atexit
import io
import json
import locale
import os
import queue
import re
import subprocess
import sys
import threading
from collections import deque
from datetime import datetime, timedelta, timezone
from importlib import metadata
from typing import Any

import requests

from . import paths
from .errors import EngineError


class AnisetteError(EngineError):
    """Device provisioning could not be set up (libraries unreachable, or state broken)."""


#: Where the provisioning libraries are fetched from, tried in order. A second, licensing-
#: clean mirror can be appended here; iPASide will not host them itself, as that would be
#: the redistribution the download exists to avoid.
_LIBS_URLS: tuple[str, ...] = (
    "https://anisette.dl.mikealmel.ooo/libs?arch=arm64-v8a",
)

#: The formats the anisette package can read the bundle as. A response that starts with
#: none of these is an error page or a truncated download, not the libraries - caught here
#: so it fails with a clear message rather than a cryptic "not a gzip/tar file" much later.
_ARCHIVE_MAGIC = (b"PK", b"\x1f\x8b", b"BZh", b"\xfd7zXZ")

#: Apple-style locale tags look like ``zh_CN`` / ``en_US`` (SideStore sends
#: ``Locale.current.identifier``). The anisette package uses ``locale.getlocale()``, which
#: on Windows is a *display* name like ``Chinese (Simplified)_China`` - ASCII, so it
#: survives latin-1 encoding, but Apple's trusted-device 2FA endpoint answers HTTP 500 for
#: it and never pushes a code (GitHub issue #5, proven live against gsa.apple.com).
_APPLE_LOCALE = re.compile(r"^[A-Za-z]{2,3}([_-][A-Za-z0-9]+)+$")

#: The device identity sent to Apple (``X-MMe-Client-Info``) on every request.
#:
#: The anisette package reports a Mac with Xcode. Since 2026-10-12 Apple's sign-in server answers
#: that with ``-80045 "This action cannot be completed at this time."`` at the very first SRP
#: request, for any account and any network, which broke AltStore, SideStore, iloader and every
#: other tool that gets its anisette data the same way. Checked live against gsa.apple.com on
#: 2026-10-17 with a nonexistent Apple ID (so no real account is involved): the Mac identity still
#: gets ``-80045``, an Android identity is dropped with HTTP 503, and a Windows identity is accepted
#: (Apple then answers ``-20970``, the ordinary "account information was entered incorrectly").
#: One identity is used for every host (sign-in, two-factor, developer services), the way iloader's
#: sideloading library does it, so the tokens Apple issues and the services that read them agree.
#: Apple has changed this rule repeatedly; if sign-in starts failing again, look here first.
CLIENT_INFO = "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

#: Windows ``getlocale()`` display names -> the identifier Apple's clients send.
_WINDOWS_LOCALE_TO_APPLE: dict[str, str] = {
    "chinese (simplified)_china": "zh_CN",
    "chinese (simplified)_singapore": "zh_SG",
    "chinese (traditional)_taiwan": "zh_TW",
    "chinese (traditional)_hong kong s.a.r.": "zh_HK",
    "chinese (traditional)_hong kong sar": "zh_HK",
    "chinese (traditional)_macao s.a.r.": "zh_MO",
    "chinese_china": "zh_CN",
    "chinese_taiwan": "zh_TW",
    "english_united states": "en_US",
    "english_united kingdom": "en_GB",
    "english_india": "en_IN",
    "english_australia": "en_AU",
    "english_canada": "en_CA",
    "japanese_japan": "ja_JP",
    "korean_korea": "ko_KR",
    "german_germany": "de_DE",
    "french_france": "fr_FR",
    "french_canada": "fr_CA",
    "spanish_spain": "es_ES",
    "spanish_mexico": "es_MX",
    "portuguese_brazil": "pt_BR",
    "portuguese_portugal": "pt_PT",
    "russian_russia": "ru_RU",
    "italian_italy": "it_IT",
    "dutch_netherlands": "nl_NL",
    "polish_poland": "pl_PL",
    "turkish_turkey": "tr_TR",
    "thai_thailand": "th_TH",
    "vietnamese_vietnam": "vi_VN",
    "arabic_saudi arabia": "ar_SA",
    "hindi_india": "hi_IN",
}

def _download_libs() -> io.BytesIO:
    """Fetch Apple's provisioning libraries, trying each source with retries.

    Raises :class:`AnisetteError` - not the archive parser's error - when nothing usable
    comes back, so the app can say the server is down or the network is blocking it.
    """
    attempts: list[str] = []
    for url in _LIBS_URLS:
        for _ in range(3):
            try:
                response = requests.get(url, timeout=30)
                response.raise_for_status()
                data = response.content
                if not any(data.startswith(magic) for magic in _ARCHIVE_MAGIC):
                    raise ValueError(
                        f"response was not an archive (starts {data[:12]!r})"
                    )
                return io.BytesIO(data)
            except Exception as exc:  # noqa: BLE001 - record every source that failed
                attempts.append(f"{url}: {exc}")
    raise AnisetteError(
        "Could not download Apple's device-provisioning libraries. The provisioning "
        "server may be down, or your network is blocking it - check your connection and "
        "try again.\n\nTried:\n  " + "\n  ".join(attempts)
    )


def _load_provider() -> Any:
    """Return a ready, provisioned Anisette provider, persisting its state.

    A cache that cannot be loaded is discarded and rebuilt rather than re-raised: an
    interrupted first provision, or a first run that saved a bad download, would otherwise
    throw the same archive error on every later launch with no way out but finding and
    deleting the file by hand.
    """
    from anisette import Anisette

    state = paths.anisette_state_file()

    def _fresh() -> Any:
        return Anisette.init(_download_libs())

    if state.exists():
        try:
            provider = Anisette.load(str(state))
        except AnisetteError:
            raise
        except Exception:  # noqa: BLE001 - any load failure means the cache is unusable
            state.unlink(missing_ok=True)
            provider = _fresh()
    else:
        provider = _fresh()

    if not provider.is_provisioned:
        provider.provision()

    provider.save_all(str(state))
    return provider


def _gmt_offset_label(offset: timedelta) -> str:
    """Format a UTC offset the way Apple clients do when they have no abbreviation."""
    total = int(offset.total_seconds())
    sign = "+" if total >= 0 else "-"
    total = abs(total)
    hours, rem = divmod(total, 3600)
    minutes = rem // 60
    return f"GMT{sign}{hours:02d}:{minutes:02d}"


def ascii_timezone(now: datetime | None = None) -> str:
    """Timezone label safe to put on an HTTP header.

    The ``anisette`` package uses ``str(tzinfo)``, which on Windows is the *localized*
    display name - ``India Standard Time`` in English, ``中国标准时间`` on a Chinese
    install. HTTP headers are latin-1 (urllib3 encodes them that way), so a CJK name
    raises ``UnicodeEncodeError`` the moment sign-in reaches the trusted-device 2FA
    request that carries anisette as headers. Apple's own clients send an abbreviation
    (``PDT``, ``CST``) or a ``GMT±HH:MM`` offset - both ASCII - so that is what we emit.
    """
    when = now if now is not None else datetime.now().astimezone()
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)

    name = when.tzname() or ""
    if name.isascii() and name.strip():
        return name.strip()

    offset = when.utcoffset()
    if offset is None:
        return "GMT"
    return _gmt_offset_label(offset)


def ascii_locale(preferred: str | None = None) -> str:
    """Locale tag Apple's GrandSlam endpoints accept on the wire.

    Must be both latin-1-safe *and* an identifier Apple understands. Keeping a Windows
    display name just because it is ASCII is not enough: ``Chinese (Simplified)_China``
    encodes fine, then ``/auth/verify/trusteddevice`` returns HTTP 500 and no code is
    pushed to the phone (issue #5, reproduced live). Map Windows names to Apple-style
    tags (``zh_CN``), accept tags that already look like ``zh_CN`` / ``en_US``, and fall
    back to ``en_US``.
    """
    candidates: list[str] = []
    if preferred:
        candidates.append(preferred)
    # Windows often exposes the POSIX tag here (zh_CN / en_IN) even when getlocale()
    # returns the localized display form the anisette package copies into headers.
    try:
        import warnings

        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            default = locale.getdefaultlocale()[0]
    except Exception:  # noqa: BLE001 - locale stack varies by platform
        default = None
    if default:
        candidates.append(default)
    try:
        current = locale.getlocale()[0]
    except Exception:  # noqa: BLE001
        current = None
    if current:
        candidates.append(current)

    for candidate in candidates:
        mapped = _apple_locale_tag(candidate)
        if mapped:
            return mapped
    return "en_US"


def _apple_locale_tag(value: str) -> str | None:
    """Return an Apple-style locale tag for ``value``, or None if it cannot be mapped."""
    if not value or not value.isascii():
        return None
    cleaned = value.strip().replace("-", "_")
    if _APPLE_LOCALE.fullmatch(cleaned):
        # Normalise script/region casing lightly: zh_cn -> zh_CN when 2-letter region.
        parts = cleaned.split("_")
        if len(parts) >= 2 and len(parts[1]) == 2:
            parts[1] = parts[1].upper()
        parts[0] = parts[0].lower()
        return "_".join(parts)
    return _WINDOWS_LOCALE_TO_APPLE.get(value.strip().lower())


def _wire_safe_headers(raw: dict[str, Any]) -> dict[str, Any]:
    """Rewrite anisette fields that must be both latin-1-safe and Apple-accepted.

    ``X-MMe-Client-Info`` is replaced by :data:`CLIENT_INFO`; ``X-Apple-I-TimeZone`` and
    ``X-Apple-Locale`` come from the OS as localized or Windows-display strings. Every other anisette value is already ASCII (base64, UUIDs,
    ISO timestamps). Rewriting them here - at the single place every caller goes through -
    covers GrandSlam 2FA, developer services, and anything else that dumps anisette into
    request headers.
    """
    headers = dict(raw)
    headers["X-MMe-Client-Info"] = CLIENT_INFO
    headers["X-Apple-I-TimeZone"] = ascii_timezone()
    existing_locale = headers.get("X-Apple-Locale")
    headers["X-Apple-Locale"] = ascii_locale(
        existing_locale if isinstance(existing_locale, str) else None
    )
    return headers

#: Set to ``1`` to run the emulator inside this process, as iPASide did before 1.2.7.
#: Only for debugging: a native crash then takes the whole engine down with it.
_INPROCESS_ENV = "IPASIDE_ANISETTE_INPROCESS"

#: Longest one request may take. A first provision downloads the libraries (three tries
#: of up to 30 s) and then emulates the provisioning handshake, so this is deliberately
#: far above the few seconds it normally needs.
_REQUEST_TIMEOUT = 300.0

#: How many of the worker's last stderr lines are kept for the error message.
_STDERR_KEEP = 40

#: Windows exit codes (NTSTATUS) a mitigation or a native fault produces, in the words a
#: user can act on. Matched on the unsigned value Popen reports.
_NATIVE_EXIT_NAMES: dict[int, str] = {
    0xC0000005: "access violation",
    0xC000001D: "illegal instruction",
    0xC0000409: "security check failure (fail-fast)",
    0xC00000FF: "bad function table (stack unwind rejected)",
    0xC000070A: "user shadow-stack violation",
    0xC0000374: "heap corruption detected",
    0xC0000142: "DLL initialization failed",
}


def _describe_worker_exit(code: int | None, stderr_tail: list[str]) -> str:
    """Explain why the provisioning helper ended without answering.

    Names the exit code and quotes what it last printed, then says what usually causes
    this on Windows. Worded as a likely cause, not a certainty: the exit code alone
    cannot tell a user's Exploit-protection setting from a security product that
    enforces the same thing.
    """
    unsigned = None if code is None else code & 0xFFFFFFFF
    shown = "unknown" if unsigned is None else f"0x{unsigned:08X}"
    name = _NATIVE_EXIT_NAMES.get(unsigned) if unsigned is not None else None
    if name:
        shown += f" ({name})"

    tail_text = "\n".join(line for line in stderr_tail if line.strip())
    blocked_code = "dynamic translator buffer" in tail_text
    # A Python error (a missing module, a failed import) is a software fault, not a Windows
    # setting; saying otherwise sends people to switch off protections that were never the cause.
    software_fault = any(
        marker in tail_text
        for marker in ("Traceback (most recent call last)", "ModuleNotFoundError", "ImportError",
                       "Error while finding module")
    )
    if software_fault:
        return (
            f"Apple's device-provisioning step could not start: its helper process ended with "
            f"exit code {shown} because of a software error, not a Windows setting. Your Apple ID "
            f"and password were not the problem and were not sent. Reinstalling iPASide usually "
            f"fixes a damaged install; please report this if it keeps happening.\n\n"
            f"Last output from the helper:\n{tail_text}"
        )
    cause = (
        "Windows or a security product refused to let it allocate executable memory "
        "(Exploit protection: 'Disable dynamic code' / ACG)."
        if blocked_code
        else "This is what happens when Windows Exploit protection or a security product "
        "enforces Control Flow Guard, hardware-enforced stack protection or dynamic-code "
        "blocking on this program."
    )
    message = (
        f"Apple's device-provisioning step could not run: its helper process ended "
        f"with exit code {shown} before it produced an answer. Your Apple ID and "
        f"password were not the problem and were not sent.\n\n{cause}\n\n"
        f"To allow it: Windows Security > App & browser control > Exploit protection > "
        f"Program settings > add this program, and switch the mitigations above to Off:\n"
        f"  {sys.executable}\n"
        f"If you use another security product, allow that program there too."
    )
    if tail_text:
        message += "\n\nLast output from the helper:\n" + tail_text
    return message


def _worker_command() -> list[str]:
    """The interpreter command that starts the provisioning helper.

    Mirrors how this process was started: the shipped engine runs with ``-E`` so a
    stray PYTHONPATH cannot shadow its bundled packages, and the helper must too.
    """
    command = [sys.executable]
    if sys.flags.ignore_environment:
        command.append("-E")
    if sys.flags.utf8_mode:
        command += ["-X", "utf8"]
    command += ["-m", "ipaside_engine.anisette_worker"]
    return command


def _worker_env() -> dict[str, str]:
    """This process's environment, minus anything per-request such as the password.

    The serve loop puts ``IPASIDE_APPLE_PASSWORD`` into ``os.environ`` for the length of
    a login. The helper never needs it, so it is not handed to it.
    """
    return {key: value for key, value in os.environ.items() if not key.startswith("IPASIDE_")}


class _AnisetteWorker:
    """One running provisioning helper and the pipes to it."""

    def __init__(self, command: list[str]) -> None:
        self._replies: queue.Queue[str | None] = queue.Queue()
        self._stderr_tail: deque[str] = deque(maxlen=_STDERR_KEEP)
        self._proc = subprocess.Popen(  # noqa: S603 - fixed command built above
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            env=_worker_env(),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        self._pumps = [
            threading.Thread(target=self._pump_stdout, daemon=True, name="anisette-out"),
            threading.Thread(target=self._pump_stderr, daemon=True, name="anisette-err"),
        ]
        for pump in self._pumps:
            pump.start()

    def _pump_stdout(self) -> None:
        assert self._proc.stdout is not None
        try:
            for line in self._proc.stdout:
                self._replies.put(line)
        except (OSError, ValueError):
            pass
        finally:
            self._replies.put(None)

    def _pump_stderr(self) -> None:
        assert self._proc.stderr is not None
        try:
            for line in self._proc.stderr:
                self._stderr_tail.append(line.rstrip())
        except (OSError, ValueError):
            pass

    def alive(self) -> bool:
        return self._proc.poll() is None

    def headers(self, timeout: float = _REQUEST_TIMEOUT) -> dict[str, Any]:
        """Ask the helper for one set of raw headers; raise AnisetteError if it cannot."""
        assert self._proc.stdin is not None
        try:
            self._proc.stdin.write(json.dumps({"op": "headers"}) + "\n")
            self._proc.stdin.flush()
        except (OSError, ValueError):
            raise AnisetteError(self._death_message()) from None

        while True:
            try:
                line = self._replies.get(timeout=timeout)
            except queue.Empty:
                self.close()
                raise AnisetteError(
                    "Apple's device-provisioning helper did not answer within "
                    f"{int(timeout)} seconds. Check your connection and try again."
                ) from None
            if line is None:
                raise AnisetteError(self._death_message())
            try:
                frame = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(frame, dict) or "ok" not in frame:
                continue  # the {"ready": true} greeting
            if frame["ok"]:
                headers = frame.get("headers")
                if not isinstance(headers, dict):
                    raise AnisetteError("the provisioning helper returned no headers")
                return headers
            raise AnisetteError(str(frame.get("error") or "provisioning failed"))

    def _death_message(self) -> str:
        try:
            code: int | None = self._proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            code = None
        for pump in self._pumps:
            pump.join(timeout=2)  # let the last stderr lines land before quoting them
        return _describe_worker_exit(code, list(self._stderr_tail))

    def close(self) -> None:
        proc = self._proc
        try:
            if proc.poll() is None and proc.stdin is not None:
                proc.stdin.write(json.dumps({"op": "shutdown"}) + "\n")
                proc.stdin.flush()
                proc.stdin.close()
                proc.wait(timeout=3)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            pass
        if proc.poll() is None:
            proc.kill()
            proc.wait()


_worker: _AnisetteWorker | None = None
_worker_lock = threading.Lock()


def _close_worker() -> None:
    global _worker
    with _worker_lock:
        if _worker is not None:
            _worker.close()
            _worker = None


atexit.register(_close_worker)


def _raw_headers() -> dict[str, Any]:
    """Unsanitised anisette headers from the isolated helper (or in-process, if asked)."""
    # A frozen engine executable has no interpreter to start ``-m`` on, so it keeps the
    # old in-process behaviour. The shipped engine is a portable CPython, never frozen.
    if os.environ.get(_INPROCESS_ENV) == "1" or getattr(sys, "frozen", False):
        return dict(_load_provider().get_data())

    global _worker
    with _worker_lock:
        if _worker is not None and not _worker.alive():
            _worker.close()  # it died while idle; the next start is a clean one
            _worker = None
        if _worker is None:
            try:
                _worker = _AnisetteWorker(_worker_command())
            except OSError as exc:
                raise AnisetteError(
                    f"Could not start Apple's device-provisioning helper ({exc}). "
                    "Security software may be blocking iPASide's engine from starting "
                    "a second process."
                ) from exc
        worker = _worker
        try:
            return worker.headers()
        except AnisetteError:
            # Whatever went wrong, do not reuse a helper in an unknown state.
            worker.close()
            _worker = None
            raise


def get_headers() -> dict[str, Any]:
    """Return a fresh set of anisette headers for a GSA request."""
    return _wire_safe_headers(_raw_headers())


def status() -> dict[str, Any]:
    """Report anisette readiness without forcing provisioning."""
    try:
        version: str | None = metadata.version("Anisette")
    except metadata.PackageNotFoundError:
        version = None
    state = paths.anisette_state_file()
    return {
        "available": version is not None,
        "package_version": version,
        "state_cached": state.exists(),
        "state_path": str(state),
    }
