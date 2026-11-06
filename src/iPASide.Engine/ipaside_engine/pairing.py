"""Pairing files this PC holds, and the apps on the phone that consume them.

A pairing file is this computer's trusted identity with one iPhone. SideStore,
AltStore, LiveContainer, EscapeOS, and StikDebug each look for that file in their
own Documents folder, under a name of their own. iPASide already had the SideStore
path; this module is the one place that knows every consumer, can export the file,
can create the Remote Pairing half over USB, and can still import a file another
tool wrote.

This is the same job iLoader's pairing manager does, on the same iOS range
iLoader documents for sideload (15.0–15.8.5, 16.0–17.7.7, 18.0–26.x): Trust
creates the lockdown half; iPASide adds Remote Pairing keys over that USB
channel when the phone has CoreDevice (iOS 17+). EscapeOS only supports iOS 18
and 26; other consumers still get a pairing file on iLoader's full range.

Windows usbmux writes the lockdown half (certificates, HostID, escrow) and omits
``UDID`` because the file name carries it. Remote Pairing keys (``identifier``,
Ed25519 ``public_key`` / ``private_key``, ``alt_irk``) are not in that record.
iOS 26.4 and later tunnels that EscapeOS and StikDebug use need those keys.
iPASide creates them itself over the already-trusted USB lockdown channel
(promptless; no second Trust dialog). Importing an iLoader file remains optional.
The phone does not stay plugged in to *use* those apps — USB is only to mint
and place the file.
"""

from __future__ import annotations

import asyncio
import plistlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from . import apps, paths
from .errors import EngineError

#: Where usbmux keeps the pairing records this PC has for its devices.
_APPLE_LOCKDOWN_DIR = Path(r"C:\ProgramData\Apple\Lockdown")
_LOCKDOWN_DIR = _APPLE_LOCKDOWN_DIR

#: Keys iLoader adds so a Remote Pairing tunnel can start. ``alt_irk`` is useful
#: but not required for ``rp_pairing_file_read``.
_RP_REQUIRED_KEYS = ("identifier", "public_key", "private_key")

#: Why a lockdown-only file is not enough for EscapeOS on current iOS.
MISSING_RP_WARNING = (
    "This file has this PC's USB pairing keys, which SideStore and AltStore use "
    "(same as iLoader, including iOS 15–18). "
    "EscapeOS and StikDebug on iOS 26.4 and later also need Remote Pairing keys. "
    "Plug the iPhone in over USB once, let iPASide create them, then place the file. "
    "The cable is not needed afterwards."
)

HAS_RP_NOTE = (
    "This file is the iLoader-style merge: USB pairing plus Remote Pairing keys. "
    "EscapeOS can use it on iOS 18 (lockdown loopback) and iOS 26.4+ (Remote Pairing). "
    "The phone does not need to stay connected to this PC."
)


class PairingError(EngineError):
    """The pairing file could not be read, imported, exported, or placed."""


@dataclass(frozen=True)
class PairingConsumer:
    """One installed app that reads a pairing file out of its own container."""

    id: str
    name: str
    filename: str
    directories: tuple[str, ...]
    needs_rppairing: bool
    prefixes: tuple[str, ...]

    def matches(self, bundle_id: str) -> bool:
        """True when ``bundle_id`` is this app, including a team-id suffix."""
        lowered = bundle_id.lower()
        for prefix in self.prefixes:
            needle = prefix.lower()
            if lowered == needle or lowered.startswith(f"{needle}."):
                return True
        return False


#: LiveContainer's SideStore Documents, kept here so pairing placement and the
#: LiveContainer setup path write the same file to the same place.
SIDESTORE_DOCUMENTS = "/Documents/SideStore/Documents"
ALT_PAIRING_NAME = "ALTPairingFile.mobiledevicepairing"
RP_PAIRING_NAME = "pairingFile.plist"

CONSUMERS: tuple[PairingConsumer, ...] = (
    PairingConsumer(
        id="escapeos",
        name="EscapeOS",
        filename=RP_PAIRING_NAME,
        directories=("/Documents",),
        needs_rppairing=True,
        prefixes=("com.ipaside.escapeos",),
    ),
    PairingConsumer(
        id="livecontainer",
        name="LiveContainer",
        filename=ALT_PAIRING_NAME,
        directories=(SIDESTORE_DOCUMENTS, "/Documents"),
        needs_rppairing=False,
        prefixes=("com.kdt.livecontainer",),
    ),
    PairingConsumer(
        id="sidestore",
        name="SideStore",
        filename=ALT_PAIRING_NAME,
        directories=("/Documents",),
        needs_rppairing=False,
        prefixes=("com.sidestore.sidestore",),
    ),
    PairingConsumer(
        id="altstore",
        name="AltStore",
        filename=ALT_PAIRING_NAME,
        directories=("/Documents",),
        needs_rppairing=False,
        prefixes=("com.rileytestut.altstore",),
    ),
    PairingConsumer(
        id="stikdebug",
        name="StikDebug",
        filename=RP_PAIRING_NAME,
        directories=("/Documents",),
        needs_rppairing=True,
        prefixes=("com.stik.stikdebug", "com.stik.stikjit"),
    ),
)


def pairing_dir() -> Path:
    """Per-device imported pairing files, outside Apple's Lockdown folder.

    Apple's directory is the usbmux record. A Remote Pairing file iPASide creates
    (or an imported iLoader file) is a different document, and writing it there
    would mix a credential Windows did not write with the one it owns. Keeping it
    under iPASide's data directory means clearing iPASide state drops it without
    touching the USB pairing.
    """
    path = paths.data_dir() / "pairing"
    path.mkdir(parents=True, exist_ok=True)
    return path


def match_consumer(bundle_id: str) -> PairingConsumer | None:
    """The consumer ``bundle_id`` belongs to, or None when it is not one of ours."""
    for consumer in CONSUMERS:
        if consumer.matches(bundle_id):
            return consumer
    return None


def _resolve_installed_consumer(requested: str, installed: dict[str, Any]) -> str | None:
    """Exact installed bundle id, or the team-suffixed install matching ``requested``."""
    if requested in installed:
        return requested
    consumer = match_consumer(requested)
    if consumer is None:
        return None
    for bundle_id in installed:
        if consumer.matches(bundle_id):
            return bundle_id
    return None


def has_lockdown_keys(record: dict[str, Any]) -> bool:
    """True when the record can drive a lockdown / minimuxer session."""
    return bool(record.get("DeviceCertificate") and record.get("HostCertificate"))


def has_rppairing_keys(record: dict[str, Any]) -> bool:
    """True when ``rp_pairing_file_read`` has the keys it actually parses."""
    return all(record.get(key) not in (None, b"", "") for key in _RP_REQUIRED_KEYS)


def lockdown_xml(udid: str, *, lockdown_dir: Path | None = None) -> bytes:
    """This PC's usbmux record for ``udid``, with the ``UDID`` key SideStore needs.

    usbmux writes every key a lockdown session needs but not ``UDID`` - the file
    name carries that. SideStore is handed the file on its own, with no name to
    read, so without the key it rejects an otherwise complete record as invalid.
    """
    record = _load_lockdown(udid, lockdown_dir or _LOCKDOWN_DIR)
    record.setdefault("UDID", udid)
    return plistlib.dumps(record, fmt=plistlib.FMT_XML)


def payload_bytes(udid: str, *, lockdown_dir: Path | None = None) -> bytes:
    """The pairing file that should be exported or placed for ``udid``.

    An imported or iPASide-created file wins, because that is the one that carries
    Remote Pairing keys. Missing lockdown keys in the store are filled from usbmux
    so a Remote-Pairing-only document still works for SideStore. With no store,
    this is the usbmux record plus ``UDID``.
    """
    record = payload_record(udid, lockdown_dir=lockdown_dir)
    return plistlib.dumps(record, fmt=plistlib.FMT_XML)


def payload_record(udid: str, *, lockdown_dir: Path | None = None) -> dict[str, Any]:
    """The pairing dict :func:`payload_bytes` serialises, without dumping it."""
    directory = lockdown_dir or _LOCKDOWN_DIR
    imported = _read_imported(udid)
    lockdown: dict[str, Any] | None = None
    try:
        lockdown = _load_lockdown(udid, directory)
        lockdown.setdefault("UDID", udid)
    except PairingError:
        lockdown = None

    if imported is None and lockdown is None:
        raise PairingError(_missing_record_message())

    if imported is None:
        return lockdown  # type: ignore[return-value]

    # Imported or created keys win: that document already merged both halves.
    merged = {**(lockdown or {}), **imported}
    merged.setdefault("UDID", udid)
    return merged


def inspect_record(udid: str, *, lockdown_dir: Path | None = None) -> dict[str, Any]:
    """What this PC holds for ``udid``, without talking to the phone."""
    directory = lockdown_dir or _LOCKDOWN_DIR
    imported_file = _imported_path(udid)
    imported_present = imported_file.is_file()
    lockdown_present = False
    try:
        _load_lockdown(udid, directory)
        lockdown_present = True
    except PairingError:
        pass

    source = "none"
    record: dict[str, Any] | None = None
    error: str | None = None
    try:
        record = payload_record(udid, lockdown_dir=directory)
        source = "imported" if imported_present else "lockdown"
    except PairingError as exc:
        error = str(exc)

    has_lockdown = has_lockdown_keys(record) if record else lockdown_present
    has_rp = has_rppairing_keys(record) if record else False
    return {
        "udid": udid,
        "source": source,
        "has_lockdown": has_lockdown,
        "has_rppairing": has_rp,
        "imported": imported_present,
        "imported_path": str(imported_file) if imported_present else None,
        "bytes": len(plistlib.dumps(record, fmt=plistlib.FMT_XML)) if record else 0,
        "note": HAS_RP_NOTE if has_rp else (MISSING_RP_WARNING if record else None),
        "error": error,
    }


def status(udid: str, serial: str | None = None, *, lockdown_dir: Path | None = None) -> dict[str, Any]:
    """PC-side pairing health plus which supported apps are actually installed."""
    report = inspect_record(udid, lockdown_dir=lockdown_dir)
    consumers, reachable, device_error = _installed_consumers(serial or udid)
    report["consumers"] = consumers
    report["device_reachable"] = reachable
    report["device_error"] = device_error
    return report


def export_to(udid: str, destination: str | Path, *, lockdown_dir: Path | None = None) -> dict[str, Any]:
    """Write the pairing file for ``udid`` to ``destination`` as XML."""
    payload = payload_bytes(udid, lockdown_dir=lockdown_dir)
    path = Path(destination).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    record = plistlib.loads(payload)
    return {
        "exported": True,
        "path": str(path.resolve()),
        "bytes": len(payload),
        "has_lockdown": has_lockdown_keys(record),
        "has_rppairing": has_rppairing_keys(record),
        "note": HAS_RP_NOTE if has_rppairing_keys(record) else MISSING_RP_WARNING,
    }


def import_from(
    udid: str,
    source: str | Path,
    *,
    lockdown_dir: Path | None = None,
) -> dict[str, Any]:
    """Store ``source`` as this PC's pairing file for ``udid``.

    The file is validated, checked against ``udid`` so another phone's record
    cannot be attached by accident, merged with the usbmux lockdown half when the
    import is Remote-Pairing-only, and written under iPASide's data directory.
    """
    path = Path(source).expanduser()
    if not path.is_file():
        raise PairingError(f"{path} is not a file, so it cannot be imported as a pairing record.")
    try:
        parsed = plistlib.loads(path.read_bytes())
    except (OSError, ValueError) as exc:
        raise PairingError(f"{path} is not a pairing plist: {exc}") from exc
    if not isinstance(parsed, dict):
        raise PairingError(f"{path} is a plist, but not a pairing record (expected a dictionary).")
    if not has_lockdown_keys(parsed) and not has_rppairing_keys(parsed):
        raise PairingError(
            f"{path} has neither USB pairing certificates nor Remote Pairing keys, "
            "so it is not a pairing file."
        )
    _reject_foreign_udid(parsed, udid)

    directory = lockdown_dir or _LOCKDOWN_DIR
    lockdown: dict[str, Any] | None = None
    try:
        lockdown = _load_lockdown(udid, directory)
        lockdown.setdefault("UDID", udid)
    except PairingError:
        lockdown = None
    merged = {**(lockdown or {}), **parsed}
    merged.setdefault("UDID", udid)

    stored = _imported_path(udid)
    stored.write_bytes(plistlib.dumps(merged, fmt=plistlib.FMT_XML))
    return {
        "imported": True,
        "path": str(stored),
        "from": str(path.resolve()),
        "has_lockdown": has_lockdown_keys(merged),
        "has_rppairing": has_rppairing_keys(merged),
        "note": HAS_RP_NOTE if has_rppairing_keys(merged) else MISSING_RP_WARNING,
    }


def create_remote_pairing(
    udid: str,
    serial: str | None = None,
    *,
    force: bool = False,
    lockdown_dir: Path | None = None,
) -> dict[str, Any]:
    """Create this PC's Remote Pairing keys over USB and store the merged file.

    Pair-setup runs on the already-trusted lockdown channel, so the phone does
    not show a second Trust dialog. ``force`` re-runs pair-setup even when a
    complete file is already stored.
    """
    directory = lockdown_dir or _LOCKDOWN_DIR
    existing: dict[str, Any] | None
    try:
        existing = payload_record(udid, lockdown_dir=directory)
    except PairingError:
        existing = None
    if existing is not None and has_rppairing_keys(existing) and not force:
        report = inspect_record(udid, lockdown_dir=directory)
        report["created"] = False
        return report

    rp_keys = _remote_pair_keys(udid, serial)
    # Diagnostic-only -- see `_remote_pair_keys`'s own comment. Must come out before
    # `rp_keys` is merged into the plist that actually gets written to disk.
    wifi_sync_enabled = rp_keys.pop("_wifi_sync_enabled", None)
    lockdown = _load_lockdown(udid, directory)
    lockdown.setdefault("UDID", udid)
    merged = {**lockdown, **rp_keys}
    merged.setdefault("UDID", udid)
    stored = _imported_path(udid)
    stored.write_bytes(plistlib.dumps(merged, fmt=plistlib.FMT_XML))
    report = inspect_record(udid, lockdown_dir=directory)
    report["created"] = True
    report["path"] = str(stored)
    report["wifi_sync_enabled"] = wifi_sync_enabled
    return report


def ensure_remote_pairing(
    udid: str,
    serial: str | None = None,
    *,
    lockdown_dir: Path | None = None,
) -> dict[str, Any]:
    """Create Remote Pairing keys when this PC does not already have them."""
    return create_remote_pairing(
        udid, serial, force=False, lockdown_dir=lockdown_dir
    )


def _uses_apple_lockdown(lockdown_dir: Path | None) -> bool:
    """True when this call is about the real usbmux folder, not a test double."""
    directory = lockdown_dir or _LOCKDOWN_DIR
    return directory == _APPLE_LOCKDOWN_DIR


def _maybe_ensure_remote_pairing(
    udid: str,
    serial: str | None,
    lockdown_dir: Path | None,
) -> None:
    """Best-effort Remote Pairing create before a place, never on unit-test lockdown dirs."""
    if not _uses_apple_lockdown(lockdown_dir):
        return
    try:
        ensure_remote_pairing(udid, serial, lockdown_dir=lockdown_dir)
    except PairingError:
        return


def _remote_pair_keys(udid: str, serial: str | None = None) -> dict[str, Any]:
    """Ask the phone for a Remote Pairing identity over USB lockdown.

    Isolated as its own function so tests can supply keys without a device.
    The ``identifier`` written into the plist is the same host id pymobiledevice3
    registered during pair-setup (derived from this PC's hostname).
    """
    from pymobiledevice3.exceptions import RemotePairingCompletedError
    from pymobiledevice3.pair_records import generate_host_id
    from pymobiledevice3.remote.tunnel_service import RemotePairingLockdownService

    from . import lockdown as lockdown_mod
    from ._asyncutil import run

    async def _pair() -> tuple[dict[str, Any], bool]:
        client = await lockdown_mod.create(serial or udid, prefer_usb=True)
        service = None
        try:
            # Best-effort, on the SAME already-trusted USB session -- lets a device
            # exported this way also be reachable over classic lockdown (iOS 15/16,
            # which has no Remote Pairing at all) via the old Wi-Fi Sync mechanism,
            # without a second USB connection or a second Trust dialog. Deliberately
            # does not fail the whole pairing over this: Remote Pairing export (the
            # part every existing consumer actually depends on today) must still
            # succeed even if this one extra call doesn't.
            wifi_sync_enabled = False
            try:
                await client.set_enable_wifi_connections(True)
                wifi_sync_enabled = True
            except Exception:  # noqa: BLE001 - best-effort, see above
                pass

            service = await RemotePairingLockdownService.create(client)
            try:
                await service.connect(autopair=True)
            except RemotePairingCompletedError:
                await service.close()
                service = await RemotePairingLockdownService.create(client)
                await service.connect(autopair=False)
            path = service.pair_record_path
            if not path.is_file():
                raise PairingError(
                    "Remote Pairing finished, but this PC has no pair record to read."
                )
            parsed = plistlib.loads(path.read_bytes())
            if not isinstance(parsed, dict):
                raise PairingError(f"The Remote Pairing record at {path} is not a dictionary.")
            return parsed, wifi_sync_enabled
        finally:
            if service is not None:
                await service.close()
            await lockdown_mod.close(client)

    try:
        parsed, wifi_sync_enabled = run(_pair())
    except PairingError:
        raise
    except Exception as exc:  # noqa: BLE001 - surface as pairing, not a traceback
        raise PairingError(
            "Could not create Remote Pairing keys over USB. Unlock the iPhone, "
            f"keep it plugged in, and trust this PC, then try again. ({exc})"
        ) from exc

    public = parsed.get("public_key")
    private = parsed.get("private_key")
    if not public or not private:
        raise PairingError(
            "Remote Pairing did not write public_key and private_key, so the "
            "file would not work in EscapeOS."
        )
    keys: dict[str, Any] = {
        "identifier": str(parsed.get("identifier") or parsed.get("host_identifier") or generate_host_id()),
        "public_key": public,
        "private_key": private,
    }
    alt = parsed.get("alt_irk")
    if alt:
        keys["alt_irk"] = alt
    # Underscore-prefixed and popped back off by `create_remote_pairing` before the
    # merged dict is written to the exported plist -- a diagnostic signal for the
    # caller, not a real pairing field, so it must never end up in the actual file.
    keys["_wifi_sync_enabled"] = wifi_sync_enabled
    return keys


def deliver_to_app(
    bundle_id: str,
    udid: str,
    serial: str | None = None,
    *,
    consumer: PairingConsumer | None = None,
    payload: bytes | None = None,
    lockdown_dir: Path | None = None,
) -> dict[str, Any]:
    """Write the pairing file into one installed app's Documents."""
    matched = consumer or match_consumer(bundle_id)
    if matched is None:
        raise PairingError(
            f"{bundle_id} is not a pairing-file consumer iPASide knows about."
        )
    body = payload if payload is not None else payload_bytes(udid, lockdown_dir=lockdown_dir)
    record = plistlib.loads(body)
    warning = None
    if matched.needs_rppairing and not has_rppairing_keys(record):
        warning = MISSING_RP_WARNING
    try:
        written = _write_into(bundle_id, serial, {matched.filename: body}, matched.directories)
    except Exception as exc:  # noqa: BLE001 - any transport failure means the same thing
        return {
            "id": matched.id,
            "name": matched.name,
            "bundle_id": bundle_id,
            "filename": matched.filename,
            "placed": False,
            "error": str(exc),
            "warning": warning,
        }
    return {
        "id": matched.id,
        "name": matched.name,
        "bundle_id": bundle_id,
        "filename": matched.filename,
        "placed": True,
        "bytes": len(body),
        "written": written,
        "warning": warning,
    }


def deliver_if_consumer(
    bundle_id: str,
    udid: str,
    serial: str | None = None,
    *,
    skip_ids: Iterable[str] = (),
    lockdown_dir: Path | None = None,
) -> dict[str, Any] | None:
    """Place the pairing file after a sideload, or None when the app does not use one.

    LiveContainer's pairing file is delivered by its signing profile, which also
    knows whether that build carries SideStore. Skipping it here stops a plain
    LiveContainer install being handed a credential it has no store to use.
    """
    matched = match_consumer(bundle_id)
    if matched is None or matched.id in set(skip_ids):
        return None
    _maybe_ensure_remote_pairing(udid, serial, lockdown_dir)
    try:
        return deliver_to_app(
            bundle_id, udid, serial, consumer=matched, lockdown_dir=lockdown_dir
        )
    except PairingError as exc:
        return {
            "id": matched.id,
            "name": matched.name,
            "bundle_id": bundle_id,
            "filename": matched.filename,
            "placed": False,
            "error": str(exc),
        }


def deliver_to_device(
    udid: str,
    serial: str | None = None,
    *,
    bundle_ids: Iterable[str] | None = None,
    lockdown_dir: Path | None = None,
) -> dict[str, Any]:
    """Place the pairing file in supported apps, or only those in ``bundle_ids``."""
    _maybe_ensure_remote_pairing(udid, serial, lockdown_dir)
    payload = payload_bytes(udid, lockdown_dir=lockdown_dir)
    record = plistlib.loads(payload)
    installed = apps.list_installed(serial or udid)
    wanted = [b for b in (bundle_ids or ()) if b]
    placed: list[dict[str, Any]] = []
    if wanted:
        for bundle_id in wanted:
            installed_id = _resolve_installed_consumer(bundle_id, installed)
            if installed_id is None:
                matched = match_consumer(bundle_id)
                placed.append(
                    {
                        "id": matched.id if matched else None,
                        "name": matched.name if matched else bundle_id,
                        "bundle_id": bundle_id,
                        "filename": matched.filename if matched else None,
                        "placed": False,
                        "error": f"{bundle_id} is not installed on this iPhone.",
                    }
                )
                continue
            matched = match_consumer(installed_id)
            if matched is None:
                placed.append(
                    {
                        "id": None,
                        "name": bundle_id,
                        "bundle_id": bundle_id,
                        "placed": False,
                        "error": f"{bundle_id} is not a pairing-file consumer iPASide knows about.",
                    }
                )
                continue
            placed.append(
                deliver_to_app(
                    installed_id,
                    udid,
                    serial or udid,
                    consumer=matched,
                    payload=payload,
                    lockdown_dir=lockdown_dir,
                )
            )
    else:
        for bundle_id in sorted(installed):
            matched = match_consumer(bundle_id)
            if matched is None:
                continue
            placed.append(
                deliver_to_app(
                    bundle_id,
                    udid,
                    serial or udid,
                    consumer=matched,
                    payload=payload,
                    lockdown_dir=lockdown_dir,
                )
            )
    return {
        "udid": udid,
        "has_lockdown": has_lockdown_keys(record),
        "has_rppairing": has_rppairing_keys(record),
        "note": HAS_RP_NOTE if has_rppairing_keys(record) else MISSING_RP_WARNING,
        "bytes": len(payload),
        "placed": placed,
        "supported_installed": len(placed),
    }


def _installed_consumers(serial: str) -> tuple[list[dict[str, Any]], bool, str | None]:
    """Supported apps on the phone, or an empty list when the phone cannot be listed."""
    try:
        installed = apps.list_installed(serial)
    except Exception as exc:  # noqa: BLE001 - status must still describe the PC-side file
        return [], False, str(exc)
    consumers: list[dict[str, Any]] = []
    for bundle_id in sorted(installed):
        matched = match_consumer(bundle_id)
        if matched is None:
            continue
        meta = installed[bundle_id]
        consumers.append(
            {
                "id": matched.id,
                "name": matched.name,
                "bundle_id": bundle_id,
                "app_name": meta.get("name") or matched.name,
                "filename": matched.filename,
                "needs_rppairing": matched.needs_rppairing,
            }
        )
    return consumers, True, None


def _load_lockdown(udid: str, lockdown_dir: Path) -> dict[str, Any]:
    """The usbmux plist for ``udid``, or PairingError when there is none."""
    source = _find_lockdown_file(udid, lockdown_dir)
    if source is None:
        raise PairingError(_missing_record_message())
    try:
        parsed = plistlib.loads(source.read_bytes())
    except (OSError, ValueError) as exc:
        raise PairingError(f"The pairing record at {source} could not be read: {exc}") from exc
    if not isinstance(parsed, dict):
        raise PairingError(f"The pairing record at {source} is not a dictionary.")
    return parsed


def _find_lockdown_file(udid: str, lockdown_dir: Path) -> Path | None:
    """The usbmux file for ``udid``, matching on the file name first, then the UDID key."""
    if not lockdown_dir.is_dir():
        return None
    exact = lockdown_dir / f"{udid}.plist"
    if exact.exists():
        return exact
    wanted = _folded_udid(udid)
    for path in sorted(lockdown_dir.glob("*.plist")):
        try:
            parsed = plistlib.loads(path.read_bytes())
        except (OSError, ValueError):
            continue
        if not isinstance(parsed, dict):
            continue
        if _folded_udid(str(parsed.get("UDID", ""))) == wanted:
            return path
    return None


def _imported_path(udid: str) -> Path:
    """Where an imported file for ``udid`` is stored, creating no file."""
    directory = pairing_dir()
    exact = directory / f"{udid}.plist"
    if exact.exists():
        return exact
    wanted = _folded_udid(udid)
    for path in directory.glob("*.plist"):
        if _folded_udid(path.stem) == wanted:
            return path
    return exact


def _read_imported(udid: str) -> dict[str, Any] | None:
    path = _imported_path(udid)
    if not path.is_file():
        return None
    try:
        parsed = plistlib.loads(path.read_bytes())
    except (OSError, ValueError):
        return None
    return parsed if isinstance(parsed, dict) else None


def _reject_foreign_udid(record: dict[str, Any], udid: str) -> None:
    """Refuse a file that already names a different device."""
    listed = record.get("UDID")
    if not listed:
        return
    if _folded_udid(str(listed)) != _folded_udid(udid):
        raise PairingError(
            f"That pairing file is for {listed}, not {udid}. Use a pairing file "
            "that was made with this iPhone."
        )


def _write_into(
    bundle_id: str,
    serial: str | None,
    files: dict[str, bytes],
    directories: tuple[str, ...],
) -> list[str]:
    """House Arrest write, delegated so LiveContainer tests can still patch it."""
    from . import livecontainer

    return asyncio.run(
        livecontainer._write_documents(
            bundle_id, serial, files, directories=directories
        )
    )


def _folded_udid(value: str) -> str:
    return value.replace("-", "").lower()


def _missing_record_message() -> str:
    return (
        "This PC has no pairing record for the device, so on-device refresh cannot "
        "be set up. Reconnect it over USB and trust this computer, then try again."
    )
