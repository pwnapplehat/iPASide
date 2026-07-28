"""LiveContainer setup: sign it with what it needs, then hand it the certificate.

LiveContainer runs other apps inside itself, which is how it gets past the three-app
limit a free Apple ID imposes: the phone sees one installed app no matter how many are
loaded into it. To sign those guest apps on device it needs JIT-less mode, and JIT-less
mode needs two things that an ordinary sideload does not provide.

**Entitlements the profile does not spell out.** A free profile grants ``TEAMID.*`` for
keychain access, but LiveContainer looks for 128 explicit
``TEAMID.com.kdt.livecontainer.shared.N`` groups, plus a shared app group. The wildcard
legally covers the explicit entries, so signing with the expanded list is accepted -
which is what :func:`build_entitlements` produces, and why this needs a signing profile
rather than plain defaults. App groups also have to be attached to the App ID before the
provisioning profile is downloaded; :mod:`ipaside_engine.provision` handles that.

**Its own signing certificate.** LiveContainer reads the certificate from the app group's
``UserDefaults`` suite, and that container cannot be written from a PC: house_arrest's AFC
session lists directories through ``..`` but refuses to open or stat anything outside the
app's own container. Normally the user imports the ``.p12`` by hand through LiveContainer's
Settings. Instead we leave an import request in its ``Documents`` - which *is* writable,
because LiveContainer declares ``UIFileSharingEnabled`` - and inject a small dylib that
performs the import on first launch. See tools/lc-cert-import/.

If that dylib is not present in the build, everything still works; the certificate simply
has to be imported by hand, and :func:`setup` says so in its result.
"""

from __future__ import annotations

import asyncio
import plistlib
import shutil
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable

import requests

from . import apps, gsa, ipa as ipa_module, lockdown, provision, signing
from .errors import EngineError

#: LiveContainer's own identifier; the team id is appended for a free account.
BUNDLE_PREFIX = "com.kdt.livecontainer"

#: How many explicit keychain access groups LiveContainer expects. It derives guest-app
#: keychain groups by index, so a short list silently breaks apps that use the keychain.
KEYCHAIN_GROUPS = 128

#: LiveContainer looks for a store's app group and uses the first it can reach, so both
#: are provisioned and signed in - it decides which at runtime.
_GROUP_PREFIXES = (
    "group.com.SideStore.SideStore.",
    "group.com.rileytestut.AltStore.",
)

#: Where the release comes from, and the only place iPASide will download it from.
RELEASES_URL = "https://api.github.com/repos/LiveContainer/LiveContainer/releases/latest"
PROJECT_URL = "https://github.com/LiveContainer/LiveContainer"

#: Written into LiveContainer's Documents for the injected dylib to consume.
REQUEST_NAME = "iPASide-cert-import.plist"
CERTIFICATE_NAME = "iPASide-certificate.p12"

#: Where LiveContainer keeps the apps it runs inside itself, under its own Documents.
#: Reachable over house_arrest, which is what lets iPASide put an app there directly.
GUEST_APPS_DIR = "/Documents/Applications"

#: SideStore's container, virtualised by LiveContainer as one of its guest apps.
SIDESTORE_DOCUMENTS = "/Documents/SideStore/Documents"

#: What SideStore and AltStore call a pairing file. Placed in SideStore's own Documents so
#: it is found on launch, and in LiveContainer's, which the Files app exposes, so it can
#: still be picked by hand if the first location ever stops being right.
PAIRING_NAME = "ALTPairingFile.mobiledevicepairing"

#: Where usbmux keeps the pairing records this PC has for its devices.
_LOCKDOWN_DIR = Path(r"C:\ProgramData\Apple\Lockdown")

#: The SideStore bundled inside the +SideStore build, and the files it reads to reuse a
#: signing certificate instead of minting its own. SideStore still needs a one-time Apple
#: ID sign-in; when that sign-in uses the *same* Apple ID iPASide did, it finds this baked
#: identity by serial and reuses it - no revoke, no extra certificate slot. Named and
#: placed to AltStore/SideStore's own convention, the same one iLoader's isideload uses.
SIDESTORE_FRAMEWORK = "SideStoreApp.framework"
ALT_CERTIFICATE_FILE = "ALTCertificate.p12"
_ALT_CERTIFICATE_ID_KEY = "ALTCertificateID"
_ALT_APP_GROUPS_KEY = "ALTAppGroups"

#: Sign-in seed for the built-in SideStore. Delivered to LiveContainer's Documents and
#: consumed by the injected dylib, which writes the two keychain items SideStore reads on
#: its token-auth path - so it is signed in the moment it opens, with no Apple ID prompt.
#: Named to iPASide, not SideStore, which never writes it and only reads the keychain.
SIGNIN_REQUEST_NAME = "iPASide-signin.plist"

#: SideStore's keychain service, exactly as AltStoreCore/Keychain.swift opens it (its
#: hardcoded bundle id). Handed to the dylib so what it writes is what SideStore reads.
SIDESTORE_KEYCHAIN_SERVICE = "com.SideStore.SideStore"

#: SideStore's home inside LiveContainer (LiveContainer redirects the guest's HOME here),
#: and its standard-defaults plist under it. SideStore's AppDelegate resets the keychain -
#: wiping the seeded tokens - the first time it launches, gated on ``firstLaunch`` being
#: absent from these defaults. Pre-setting the key makes it skip that reset, so the seed
#: survives. On a fresh install nothing has written this domain yet, so the value written
#: to disk here is what it reads on that first launch.
SIDESTORE_HOME = "/Documents/SideStore"
_SIDESTORE_PREFS = f"{SIDESTORE_HOME}/Library/Preferences/com.SideStore.SideStore.plist"
_FIRST_LAUNCH_KEY = "firstLaunch"

#: Release builds. The SideStore one carries a whole store inside the same bundle id, so
#: it costs no extra app slot, and its refresh is exposed as an App Intent - meaning a
#: Shortcut can run it on a schedule with no PC involved.
VARIANT_SIDESTORE = "sidestore"
VARIANT_PLAIN = "plain"
VARIANTS = (VARIANT_SIDESTORE, VARIANT_PLAIN)

#: Name of the signing profile :mod:`ipaside_engine.sideload` resolves for LiveContainer.
#:
#: One name for both builds. Whether a pairing file is needed is read from the IPA being
#: signed, not from this - see :func:`has_sidestore`. Encoding it in the name would put a
#: label in the refresh registry that a record written by an older build does not carry,
#: and a refresh would then quietly stop delivering the pairing file.
SIGNING_PROFILE = "livecontainer"

_TIMEOUTS = (20, 60)
_CHUNK_BYTES = 1 << 20

# (phase, percent, step) - the same shape sideload reports, so a UI can render both.
ProgressFn = Callable[[str, Any, "str | None"], None]


class LiveContainerError(EngineError):
    """LiveContainer could not be set up."""


def bundle_id_for(team_id: str) -> str:
    """LiveContainer's team-scoped bundle id, which is what its app groups key off."""
    return f"{BUNDLE_PREFIX}.{team_id}"


def app_group_identifiers(team_id: str) -> list[str]:
    """The app groups LiveContainer looks for, in the order it prefers them."""
    return [f"{prefix}{team_id}" for prefix in _GROUP_PREFIXES]


def build_entitlements(team_id: str, bundle_id: str) -> dict[str, Any]:
    """LiveContainer's entitlements with the build variables resolved.

    Deliberately narrower than LiveContainer's own build entitlements: HealthKit and
    ``com.apple.developer.kernel.increased-memory-limit`` are omitted because a free
    profile does not grant them, and asking for an entitlement the profile lacks makes
    the whole signature invalid rather than partially granted. Everything JIT-less mode
    needs - identifier, ``get-task-allow``, app groups, keychain groups - is here.
    """
    prefix = f"{team_id}."
    return {
        "application-identifier": f"{team_id}.{bundle_id}",
        "com.apple.developer.team-identifier": team_id,
        "com.apple.security.application-groups": app_group_identifiers(team_id),
        "get-task-allow": True,
        "keychain-access-groups": (
            [f"{prefix}{BUNDLE_PREFIX}.shared"]
            + [f"{prefix}{BUNDLE_PREFIX}.shared.{n}" for n in range(1, KEYCHAIN_GROUPS)]
        ),
    }


def is_livecontainer(info: dict[str, Any]) -> bool:
    """Whether an inspected IPA is LiveContainer."""
    return str(info.get("bundle_id") or "").startswith(BUNDLE_PREFIX)


def seed_sidestore_certificate(ipa_path: str, bundle: dict[str, Any], dest_dir: str) -> str:
    """Bake iPASide's certificate into the bundled SideStore, before the IPA is signed.

    When the user signs into SideStore, it compares the certificates Apple returns for the
    team against an ``ALTCertificateID`` (a serial) in its bundle; on a match it decrypts a
    bundled ``ALTCertificate.p12`` with that certificate's Apple ``machineId`` and reuses
    the identity, instead of revoking one to mint its own. iLoader's isideload bakes it the
    same way; the convention, inside ``Frameworks/SideStoreApp.framework``, is:

    * ``ALTCertificate.p12`` - the identity, encrypted with the certificate's Apple
      ``machineId`` as its password;
    * ``Info.plist`` gains ``ALTCertificateID`` (the serial) and ``ALTAppGroups`` (the
      shared app group).

    Seeding it with *iPASide's own* certificate is the point: when the user signs into
    SideStore with the same Apple ID iPASide used, SideStore reuses iPASide's certificate
    rather than revoking it - so the two share one identity, nothing iPASide already signed
    is invalidated, and no extra certificate slot is spent. It does **not** remove the
    sign-in: SideStore needs an Apple session of its own to reach Apple's developer API
    when it refreshes. Signing into SideStore with a *different* Apple ID makes it mint its
    own certificate on that account - which is one way to end up with a second, conflicting
    LiveContainer.

    Returns the path to a new IPA, written under ``dest_dir``. Must run before signing:
    the files have to be inside the bundle when zsign builds its code-signature manifest,
    or iOS rejects the framework for having contents the signature does not cover.
    """
    key_pem, cert_der, serial = provision.signing_identity()
    machine_id = provision.certificate_machine_id(bundle["team_id"], serial)
    alt_p12 = signing.build_p12(cert_der, key_pem, password=machine_id)
    group = app_group_identifiers(bundle["team_id"])[0]

    work = Path(tempfile.mkdtemp(prefix="ipaside_ss_", dir=dest_dir))
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            archive.extractall(work)

        app = next((work / "Payload").glob("*.app"))
        framework = app / "Frameworks" / SIDESTORE_FRAMEWORK
        if not framework.is_dir():
            raise LiveContainerError(
                f"{Path(ipa_path).name} has no {SIDESTORE_FRAMEWORK}, so it is not a "
                "LiveContainer build with SideStore inside it."
            )

        (framework / ALT_CERTIFICATE_FILE).write_bytes(alt_p12)

        info_path = framework / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info[_ALT_CERTIFICATE_ID_KEY] = serial
        info[_ALT_APP_GROUPS_KEY] = [group]
        info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))

        # Stored, not deflated: this goes straight back into zsign, which re-reads and
        # re-zips it anyway, so spending time compressing here is wasted.
        seeded = Path(dest_dir) / f"{Path(ipa_path).stem}_ss.ipa"
        ipa_module._zip_dir(work, str(seeded), 0)
        return str(seeded)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def has_sidestore(ipa_path: str) -> bool:
    """Whether this LiveContainer build carries SideStore inside it.

    Read from the bundle rather than taken from the file name, which a user may have
    renamed: the SideStore build ships SideStoreApp.framework, and that framework is what
    gives the phone a store able to refresh on its own.
    """
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            return any(
                "SideStoreApp.framework/" in name for name in archive.namelist()
            )
    except (OSError, zipfile.BadZipFile):
        return False


# --------------------------------------------------------------------------- #
# Getting hold of the IPA
# --------------------------------------------------------------------------- #
def latest_release(variant: str = VARIANT_SIDESTORE) -> dict[str, Any]:
    """Describe LiveContainer's newest release, without downloading it.

    ``variant`` picks between the two builds each release carries - see
    :data:`VARIANTS`. The SideStore one is the default because it is what makes an
    on-device refresh possible, and it costs nothing extra: the store lives inside the
    same bundle id, so the phone still counts one installed app.
    """
    if variant not in VARIANTS:
        raise LiveContainerError(
            f"Unknown LiveContainer build '{variant}'. Choose one of: {', '.join(VARIANTS)}."
        )
    try:
        response = requests.get(RELEASES_URL, timeout=_TIMEOUTS)
        response.raise_for_status()
        release = response.json()
    except (requests.RequestException, ValueError) as exc:
        raise LiveContainerError(
            "Could not reach GitHub to check for the latest LiveContainer release. "
            "Check your connection, or download the IPA yourself and pick it."
        ) from exc

    asset = _pick_asset(release.get("assets") or [], variant)
    if asset is None:
        wanted = "with SideStore" if variant == VARIANT_SIDESTORE else "without SideStore"
        raise LiveContainerError(
            f"LiveContainer {release.get('tag_name') or 'latest'} has no .ipa {wanted} "
            f"attached. Download one from {PROJECT_URL}/releases and pick the file."
        )
    return {
        "version": release.get("tag_name"),
        "name": release.get("name"),
        "published_at": release.get("published_at"),
        "notes_url": release.get("html_url"),
        "asset_name": asset.get("name"),
        "url": asset.get("browser_download_url"),
        "bytes": asset.get("size"),
        "variant": variant,
    }


def _pick_asset(
    assets: list[dict[str, Any]], variant: str = VARIANT_SIDESTORE
) -> dict[str, Any] | None:
    """Choose one LiveContainer build from a release's assets.

    A release carries `LiveContainer.ipa` and `LiveContainer+SideStore.ipa`, and telling
    them apart matters: only the second can refresh itself on the phone. Any asset naming
    a variant we cannot provision - notably the TrollStore/jailbreak builds, which expect
    entitlements a free profile will never grant - is skipped, so a download cannot
    silently pick something that installs and then will not run.
    """
    candidates = [a for a in assets if str(a.get("name", "")).lower().endswith(".ipa")]
    excluded = ("trollstore", "jb", "jailbreak", "debug")
    usable = [
        a for a in candidates
        if not any(word in str(a.get("name", "")).lower() for word in excluded)
    ]

    def has_sidestore(asset: dict[str, Any]) -> bool:
        return "sidestore" in str(asset.get("name", "")).lower()

    wanted = [a for a in usable if has_sidestore(a) == (variant == VARIANT_SIDESTORE)]
    # Nothing matching the requested build is a real answer, not a reason to hand back
    # the other one: they differ in whether the phone can refresh itself.
    pool = wanted or ([] if usable else candidates)
    # Shortest name wins: "LiveContainer.ipa" over "LiveContainer.Something.ipa".
    return min(pool, key=lambda a: len(str(a.get("name", "")))) if pool else None


def download(
    directory: str | None = None,
    *,
    variant: str = VARIANT_SIDESTORE,
    on_progress: ProgressFn | None = None,
) -> dict[str, Any]:
    """Download a LiveContainer IPA and return where it landed.

    ``variant`` chooses the build, and is passed straight to :func:`latest_release`, so a
    caller cannot end up downloading a different build than it asked about.
    """
    progress: ProgressFn = on_progress or (lambda *_args: None)
    release = latest_release(variant)

    target_dir = Path(directory).expanduser().resolve() if directory else _default_dir()
    try:
        target_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise LiveContainerError(
            f"Cannot write to {target_dir}: {exc.strerror or exc}"
        ) from exc
    destination = target_dir / str(release["asset_name"])

    progress("download", 0, f"Downloading LiveContainer {release['version']}\u2026")
    written = _stream(str(release["url"]), destination, release.get("bytes") or 0, progress)

    expected = release.get("bytes") or 0
    if expected and written != expected:
        destination.unlink(missing_ok=True)
        raise LiveContainerError(
            f"The LiveContainer download ended early ({written} of {expected} bytes) "
            "and was discarded. Check your connection and try again."
        )

    # An .ipa that is not LiveContainer would sign happily and then make no sense, so
    # confirm what was downloaded before handing the path back.
    info = ipa_module.inspect(str(destination))
    if not is_livecontainer(info):
        destination.unlink(missing_ok=True)
        raise LiveContainerError(
            f"{release['asset_name']} is {info.get('bundle_id')}, not LiveContainer. "
            "The release layout may have changed; download it yourself and pick it."
        )

    return {**release, "path": str(destination), "bytes_written": written}


def _default_dir() -> Path:
    from . import paths

    return paths.downloads_dir()


def _stream(url: str, destination: Path, total: int, progress: ProgressFn) -> int:
    try:
        response = requests.get(url, stream=True, timeout=_TIMEOUTS, allow_redirects=True)
    except requests.RequestException as exc:
        raise LiveContainerError(
            "Could not download LiveContainer. Check your internet connection."
        ) from exc

    with response:
        if response.status_code != 200:
            raise LiveContainerError(
                f"GitHub did not serve the LiveContainer IPA (HTTP {response.status_code})."
            )
        written = 0
        try:
            with destination.open("wb") as handle:
                for chunk in response.iter_content(chunk_size=_CHUNK_BYTES):
                    if not chunk:
                        continue
                    handle.write(chunk)
                    written += len(chunk)
                    percent = round(written * 100 / total) if total else None
                    progress("download", percent, _downloaded_step(written, total))
        except (requests.RequestException, OSError) as exc:
            destination.unlink(missing_ok=True)
            raise LiveContainerError(
                f"The LiveContainer download failed after {written} bytes "
                "and was discarded."
            ) from exc
    return written


def _downloaded_step(written: int, total: int) -> str:
    mb = 1 << 20
    if total:
        return f"Downloading LiveContainer \u00b7 {written // mb} / {total // mb} MB"
    return f"Downloading LiveContainer \u00b7 {written // mb} MB"


# --------------------------------------------------------------------------- #
# Handing over the certificate
# --------------------------------------------------------------------------- #
def _import_request(bundle: dict[str, Any]) -> bytes:
    """The plist tools/lc-cert-import/ reads on first launch."""
    return plistlib.dumps(
        {
            "AppGroupID": app_group_identifiers(bundle["team_id"])[0],
            "CertificateData": Path(bundle["p12_path"]).read_bytes(),
            "CertificatePassword": bundle["p12_password"],
        },
        fmt=plistlib.FMT_BINARY,
    )


async def _write_documents(
    bundle_id: str,
    serial: str | None,
    files: dict[str, bytes],
    *,
    directories: tuple[str, ...] = ("/Documents",),
) -> list[str]:
    """Write files into an installed app's container over house_arrest.

    Each name is written into every directory given, and directories are created first:
    on a fresh install a guest app's container does not exist until that app has been
    opened once, and writing early is what stops it having to ask for the file at all.
    """
    from pymobiledevice3.services.house_arrest import HouseArrestService

    written: list[str] = []
    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            for directory in directories:
                await service.makedirs(directory)
                for name, payload in files.items():
                    target = f"{directory}/{name}"
                    await service.set_file_contents(target, payload)
                    written.append(target)
    finally:
        await lockdown.close(client)
    return written


async def _list_dir(bundle_id: str, serial: str | None, path: str) -> list[str]:
    """One directory listing from inside an app's container."""
    from pymobiledevice3.services.house_arrest import HouseArrestService

    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            return list(await service.listdir(path))
    finally:
        await lockdown.close(client)


async def _remove_tree(bundle_id: str, serial: str | None, path: str) -> None:
    """Remove a directory and everything under it, depth first.

    AFC has no recursive delete, and refuses to remove a directory that still has
    contents, so the walk has to happen here.
    """
    from pymobiledevice3.services.house_arrest import HouseArrestService

    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            await _remove_recursive(service, path)
    finally:
        await lockdown.close(client)


async def _remove_recursive(service: Any, path: str) -> None:
    try:
        entries = await service.listdir(path)
    except Exception:  # noqa: BLE001 - a file, or already gone
        await service.rm_single(path)
        return

    for entry in entries:
        if entry in (".", ".."):
            continue
        await _remove_recursive(service, f"{path}/{entry}")
    await service.rm_single(path)


async def _push_bundle(
    bundle_id: str,
    serial: str | None,
    target: str,
    files: dict[str, bytes],
    total: int,
    progress: ProgressFn,
) -> None:
    """Copy an unzipped app bundle into LiveContainer, reporting bytes as they land."""
    from pymobiledevice3.services.house_arrest import HouseArrestService

    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            # Replacing rather than merging: files left over from an older version of the
            # same app would otherwise stay behind and be signed along with the new one.
            try:
                await service.listdir(target)
            except Exception:  # noqa: BLE001 - not there yet, which is the normal case
                pass
            else:
                await _remove_recursive(service, target)

            # Every directory once, up front. AFC creates no parents on write, and doing
            # it per file turns one round trip into thousands.
            await service.makedirs(target)
            directories = sorted(
                {str(PurePosixPath(rel).parent) for rel in files} - {".", ""}
            )
            for directory in directories:
                await service.makedirs(f"{target}/{directory}")

            written = 0
            reported = -1
            count = len(files)
            for index, (rel, payload) in enumerate(sorted(files.items()), 1):
                await service.set_file_contents(f"{target}/{rel}", payload)
                written += len(payload)
                percent = round(written * 100 / total) if total else 0

                # Only when the number moves. An app bundle is hundreds of files, and a
                # frame per file floods the progress stream to say the same thing.
                if percent == reported and index != count:
                    continue
                reported = percent
                progress(
                    "upload",
                    percent,
                    # File counts as well as megabytes, because a bundle's size is
                    # usually concentrated in one or two files: the byte percentage can
                    # sit still through hundreds of small ones and look stalled.
                    f"Copying into LiveContainer \u00b7 {index} / {count} files \u00b7 "
                    f"{written // (1 << 20)} / {total // (1 << 20)} MB",
                )
    finally:
        await lockdown.close(client)


def seed_certificate(
    bundle: dict[str, Any], serial: str | None = None, *, automatic: bool | None = None
) -> dict[str, Any]:
    """Put the signing certificate where LiveContainer can pick it up.

    Always writes the bare ``.p12``, which is what LiveContainer's own
    Settings -> Import Certificate reads. It is rewritten on every install and refresh
    and the dylib leaves it alone, so the manual route stays available on the device even
    if the stored certificate is later removed or rejected.

    ``automatic`` also writes the request the injected dylib consumes. Left as None it
    follows whether this build actually ships that dylib - claiming the certificate will
    import itself when nothing is there to do it would be worse than saying nothing.
    """
    if automatic is None:
        automatic = signing.resolve_helper_dylib() is not None

    files = {CERTIFICATE_NAME: Path(bundle["p12_path"]).read_bytes()}
    if automatic:
        files[REQUEST_NAME] = _import_request(bundle)

    try:
        asyncio.run(_write_documents(bundle["bundle_id"], serial, files))
    except Exception as exc:  # noqa: BLE001 - any transport failure means the same thing
        # Not fatal: LiveContainer is installed and usable, it just cannot sign guest
        # apps until a certificate reaches it. Say exactly that instead of failing the
        # whole setup after the app is already on the phone.
        return {
            "seeded": False,
            "automatic": False,
            "error": str(exc),
            "instructions": _manual_instructions(bundle),
        }

    return {
        "seeded": True,
        "automatic": automatic,
        "password": bundle["p12_password"],
        "instructions": None if automatic else _manual_instructions(bundle),
    }


def _manual_instructions(bundle: dict[str, Any]) -> str:
    return (
        "In LiveContainer, open Settings \u2192 Import Certificate, choose "
        f"On My iPhone \u2192 LiveContainer \u2192 {CERTIFICATE_NAME}, and enter the "
        f"password {bundle['p12_password']}."
    )


# --------------------------------------------------------------------------- #
# Signing the built-in SideStore in, with no Apple ID prompt
# --------------------------------------------------------------------------- #
def _signin_request(bundle: dict[str, Any]) -> bytes:
    """The plist tools/lc-cert-import/ reads to seed SideStore's sign-in tokens.

    SideStore authenticates by token when its keychain already holds an ``adsid`` and the
    ``com.apple.gs.xcode.auth`` GrandSlam token - the password-less branch of its
    ``AuthenticationOperation.signIn``. iPASide already has both for the account that
    signed this LiveContainer, so handing them over is what lets the built-in store open
    already signed in and refresh with no prompt. The token itself is long-lived (Apple
    dates it about a year out), so it outlasts every seven-day app expiry in between.

    They go to every keychain group LiveContainer might place SideStore's guest in: it
    picks one at random per container, and the dylib, running unhooked in the host, writes
    into all of them so whichever it lands on is covered. This is exactly the
    :func:`build_entitlements` keychain list, so the seed and the signed entitlements
    cannot drift apart.
    """
    session = gsa.load_session()
    return plistlib.dumps(
        {
            "AppleIDAdsid": session["adsid"],
            "AppleIDXcodeToken": session["auth_token"],
            "KeychainService": SIDESTORE_KEYCHAIN_SERVICE,
            "AccessGroups": build_entitlements(bundle["team_id"], bundle["bundle_id"])[
                "keychain-access-groups"
            ],
        },
        fmt=plistlib.FMT_BINARY,
    )


def deliver_signin(bundle: dict[str, Any], serial: str | None = None) -> dict[str, Any]:
    """Seed the built-in SideStore's sign-in, so it opens already signed in.

    Writes the request the injected dylib consumes into LiveContainer's Documents, but only
    when this build actually ships that dylib: with nothing to consume it, a live account
    token would sit on the device for nothing, so the seed is skipped and SideStore's own
    one-time sign-in is left as the way in.

    Never raises. Like the pairing file, LiveContainer is already installed by the time this
    runs, so a failure to seed is reported rather than allowed to undo the install - the
    user can still sign into SideStore by hand.
    """
    if signing.resolve_helper_dylib() is None:
        return {
            "seeded": False,
            "automatic": False,
            "reason": "no import helper in this build",
        }

    try:
        request = _signin_request(bundle)
    except gsa.GsaError as exc:
        return {"seeded": False, "automatic": False, "error": str(exc)}

    try:
        suppressed = asyncio.run(
            _seed_signin_async(bundle["bundle_id"], serial, request)
        )
    except Exception as exc:  # noqa: BLE001 - any transport failure means the same thing
        return {"seeded": False, "automatic": False, "error": str(exc)}

    return {"seeded": True, "automatic": True, "first_launch_suppressed": suppressed}


async def _seed_signin_async(bundle_id: str, serial: str | None, request: bytes) -> bool:
    """Deliver the token request and suppress the first-launch reset in one session.

    Both are needed for the seed to take: the dylib imports the tokens from the request,
    but SideStore's AppDelegate resets the keychain the first time it launches - erasing
    them - unless ``firstLaunch`` is already set. Returns whether that key is now in place.
    """
    from pymobiledevice3.services.house_arrest import HouseArrestService

    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as svc:
            await svc.makedirs("/Documents")
            await svc.set_file_contents(f"/Documents/{SIGNIN_REQUEST_NAME}", request)
            return await _suppress_first_launch(svc)
    finally:
        await lockdown.close(client)


async def _suppress_first_launch(svc: Any) -> bool:
    """Set SideStore's ``firstLaunch`` default so it does not reset the keychain on launch.

    Merges into whatever prefs already exist and leaves an earlier date untouched, so a
    store that really has launched keeps its own first-launch date. Any read failure just
    means the file is not there yet, which is the fresh-install case a value is written for.
    """
    prefs: dict[str, Any] = {}
    try:
        loaded = plistlib.loads(await svc.get_file_contents(_SIDESTORE_PREFS))
        if isinstance(loaded, dict):
            prefs = loaded
    except Exception:  # noqa: BLE001 - absent or unreadable both mean "write a fresh one"
        prefs = {}

    if prefs.get(_FIRST_LAUNCH_KEY) is not None:
        return True

    # Naive: plistlib's binary writer subtracts a naive epoch and rejects aware datetimes.
    # The value only has to be non-nil for SideStore to skip the reset, so UTC-now is fine.
    prefs[_FIRST_LAUNCH_KEY] = datetime.now(timezone.utc).replace(tzinfo=None)
    directory = _SIDESTORE_PREFS.rsplit("/", 1)[0]
    await svc.makedirs(directory)
    await svc.set_file_contents(
        _SIDESTORE_PREFS, plistlib.dumps(prefs, fmt=plistlib.FMT_BINARY)
    )
    return True


# --------------------------------------------------------------------------- #
# The pairing file the built-in SideStore needs
# --------------------------------------------------------------------------- #
def pairing_record(udid: str) -> bytes:
    """This PC's pairing record for a device, in the form SideStore accepts.

    usbmux writes every key a lockdown session needs but *not* ``UDID`` - the file name
    carries that. SideStore is handed the file on its own, with no name to read, so
    without the key it cannot tell which device the record is for and rejects it as
    "invalid or missing". Adding it is the whole difference between a record that is
    complete and one that is usable; confirmed by SideStore's own log, which lists the
    keys it loaded.
    """
    exact = _LOCKDOWN_DIR / f"{udid}.plist"
    source: Path | None = exact if exact.exists() else None

    if source is None:
        # A connected serial can be formatted differently from the file name (newer
        # devices carry a dash), so fall back to matching a record's own UDID.
        wanted = udid.replace("-", "").lower()
        for path in sorted(_LOCKDOWN_DIR.glob("*.plist")):
            try:
                parsed = plistlib.loads(path.read_bytes())
            except (OSError, ValueError):
                continue
            if str(parsed.get("UDID", "")).replace("-", "").lower() == wanted:
                source = path
                break

    if source is None:
        raise LiveContainerError(
            "This PC has no pairing record for the device, so on-device refresh cannot "
            "be set up. Reconnect it over USB and trust this computer, then try again."
        )

    try:
        record = plistlib.loads(source.read_bytes())
    except (OSError, ValueError) as exc:
        raise LiveContainerError(
            f"The pairing record at {source} could not be read: {exc}"
        ) from exc

    record.setdefault("UDID", udid)
    # XML, as AltStore and SideStore write their own.
    return plistlib.dumps(record, fmt=plistlib.FMT_XML)


def deliver_pairing(bundle_id: str, udid: str, serial: str | None = None) -> dict[str, Any]:
    """Give the built-in SideStore its pairing file, so it never asks for one.

    Written to two places. SideStore's own Documents is where it looks on launch, and
    LiveContainer's Documents is exposed by the Files app, so the file can still be picked
    by hand if that location ever changes. On a fresh install SideStore's container does
    not exist until it is first opened, so the directory is created rather than assumed.
    """
    payload = pairing_record(udid)
    try:
        written = asyncio.run(
            _write_documents(
                bundle_id,
                serial,
                {PAIRING_NAME: payload},
                directories=(SIDESTORE_DOCUMENTS, "/Documents"),
            )
        )
    except Exception as exc:  # noqa: BLE001 - any transport failure means the same thing
        return {"paired": False, "error": str(exc)}
    return {"paired": True, "bytes": len(payload), "written": written}


# --------------------------------------------------------------------------- #
# Apps that run inside LiveContainer
# --------------------------------------------------------------------------- #
def guest_apps(bundle_id: str, serial: str | None = None) -> list[dict[str, Any]]:
    """The apps installed inside LiveContainer, which cost no app slot of their own."""
    try:
        names = asyncio.run(_list_dir(bundle_id, serial, GUEST_APPS_DIR))
    except Exception:  # noqa: BLE001 - a locked or busy device is not a failure here
        return []
    return [
        {"folder": name, "bundle_id": name[: -len(".app")]}
        for name in sorted(names)
        if name.endswith(".app")
    ]


def install_guest(
    ipa_path: str,
    bundle_id: str,
    serial: str | None = None,
    *,
    on_progress: ProgressFn | None = None,
) -> dict[str, Any]:
    """Put an app inside LiveContainer, without installing it on the phone.

    This is the whole point of LiveContainer: the phone counts one installed app however
    many are loaded into it, so an app placed here does not use one of the three slots a
    free Apple ID allows.

    All it takes is the unzipped bundle in the right place. LiveContainer's own importer
    does no more than move it there and then patch and sign it, and the patch is triggered
    by the absence of its revision marker - so an app written here is picked up, patched
    and signed by LiveContainer itself. Nothing about its private format is reproduced,
    and it is not signed here: LiveContainer signs guest apps on device with the
    certificate iPASide gave it.
    """
    progress: ProgressFn = on_progress or (lambda *_args: None)

    info = ipa_module.inspect(ipa_path)
    guest_id = info.get("bundle_id")
    if not guest_id:
        raise LiveContainerError(
            f"{Path(ipa_path).name} has no bundle identifier, so LiveContainer would have "
            "nowhere to put it."
        )
    if info.get("has_sc_info"):
        raise LiveContainerError(
            f"{Path(ipa_path).name} is App Store-encrypted (FairPlay). LiveContainer "
            "cannot run it any more than a sideload could; use a decrypted IPA."
        )

    progress("read", None, f"Reading {Path(ipa_path).name}\u2026")
    files = _bundle_files(ipa_path)
    total = sum(len(data) for data in files.values())

    target = f"{GUEST_APPS_DIR}/{guest_id}.app"
    progress("upload", 0, f"Copying into LiveContainer\u2026")
    asyncio.run(_push_bundle(bundle_id, serial, target, files, total, progress))

    return {
        "status": "installed",
        "bundle_id": guest_id,
        "name": info.get("display_name") or guest_id,
        "version": info.get("version"),
        "icon": info.get("icon"),
        "files": len(files),
        "bytes": total,
        "host": bundle_id,
    }


def remove_guest(guest_id: str, bundle_id: str, serial: str | None = None) -> None:
    """Delete an app from inside LiveContainer."""
    asyncio.run(_remove_tree(bundle_id, serial, f"{GUEST_APPS_DIR}/{guest_id}.app"))


def _bundle_files(ipa_path: str) -> dict[str, bytes]:
    """The contents of an IPA's ``.app``, keyed by path relative to the bundle."""
    with zipfile.ZipFile(ipa_path) as archive:
        names = archive.namelist()
        app_dir = next(
            (
                name.split("/")[1]
                for name in names
                if name.startswith("Payload/") and name.split("/")[1].endswith(".app")
            ),
            None,
        )
        if app_dir is None:
            raise LiveContainerError(
                f"{Path(ipa_path).name} has no Payload/<App>.app inside, so it is not "
                "an app bundle LiveContainer can run."
            )
        prefix = f"Payload/{app_dir}/"
        return {
            name[len(prefix):]: archive.read(name)
            for name in names
            if name.startswith(prefix) and not name.endswith("/")
        }


# --------------------------------------------------------------------------- #
# The whole flow
# --------------------------------------------------------------------------- #
def setup(
    ipa_path: str,
    udid: str | None = None,
    *,
    keep_signed: bool = False,
    signed_dir: str | None = None,
    automatic_certificate: bool = True,
    on_progress: ProgressFn | None = None,
) -> dict[str, Any]:
    """Sign and install LiveContainer, then give it the certificate.

    Runs through the ordinary sideload path with LiveContainer's signing profile, so it
    is recorded for auto-refresh like any other app and re-signed with the same
    entitlements when its profile expires.
    """
    from . import sideload  # imported here: sideload resolves our signing profile

    progress: ProgressFn = on_progress or (lambda *_args: None)

    info = ipa_module.inspect(ipa_path)
    if not is_livecontainer(info):
        raise LiveContainerError(
            f"{Path(ipa_path).name} is {info.get('bundle_id') or 'not an app'}, not "
            f"LiveContainer. Download it from {PROJECT_URL}/releases."
        )

    # The signing profile injects this and delivers the certificate afterwards; we only
    # read it here to report which route the user is on.
    helper = signing.resolve_helper_dylib()
    sidestore = has_sidestore(ipa_path)

    result = sideload.run_sideload(
        ipa_path,
        udid,
        # Its extensions are kept, unlike an ordinary sideload: LiveProcess.appex is how
        # LiveContainer runs a guest app alongside another, and stripping it removes that
        # without any visible sign that something was taken away.
        remove_extensions=False,
        remove_uisd=False,
        keep_signed=keep_signed,
        signed_dir=signed_dir,
        profile=SIGNING_PROFILE,
        on_progress=progress,
    )

    # Both delivered by the profile's post-install step, so that a refresh does it too
    # rather than only a first install. Asking for a manual import re-does the
    # certificate with the request left out, which is cheap - a few KB over USB.
    outcome = result.get("post_install") or {}
    certificate = outcome.get("certificate", outcome)
    if not automatic_certificate and certificate.get("seeded"):
        certificate = seed_certificate(
            provision.load_bundle(), result.get("udid"), automatic=False
        )

    return {
        **result,
        "livecontainer_version": info.get("version"),
        "has_sidestore": sidestore,
        "certificate": certificate,
        "pairing": outcome.get("pairing"),
        "helper_dylib": helper,
        "launch_required": bool(certificate.get("automatic")),
    }


def status(serial: str | None = None) -> dict[str, Any]:
    """Report whether LiveContainer is installed and whether it holds a certificate.

    The certificate itself lives in the app group, which cannot be read from here, so the
    honest answer is drawn from what *is* visible in Documents. A pending request means
    the dylib has not run yet; its absence means the certificate was stored. The ``.p12``
    is expected to be there either way - it is left behind on purpose so a manual import
    is always possible - so it says nothing about whether setup finished.
    """
    installed = apps.list_installed(serial)
    entry = next(
        (
            {"bundle_id": key, **value}
            for key, value in installed.items()
            if key.startswith(BUNDLE_PREFIX)
        ),
        None,
    )
    if entry is None:
        return {"installed": False}

    documents: list[str] = []
    try:
        documents = asyncio.run(_list_documents(entry["bundle_id"], serial))
    except Exception:  # noqa: BLE001 - a locked or busy device is not a failure here
        documents = []

    # Which build is on the phone cannot be read from the container - its frameworks are in
    # the app bundle, which house_arrest does not vend - so the answer comes from the IPA
    # the refresh registry recorded, which is the file that was signed and installed.
    from . import refresh as refresh_module

    record = refresh_module.get(entry["bundle_id"]) or {}
    source = record.get("source_ipa")
    sidestore = bool(source) and has_sidestore(str(source))

    return {
        "installed": True,
        "bundle_id": entry["bundle_id"],
        "name": entry.get("name"),
        "version": entry.get("version"),
        "has_sidestore": sidestore,
        "pairing_present": PAIRING_NAME in documents,
        "certificate_pending": REQUEST_NAME in documents,
        "certificate_file_present": CERTIFICATE_NAME in documents,
        # LiveContainer creates these on first launch, so their absence means it has
        # been installed but never opened.
        "launched": "Applications" in documents,
    }


async def _list_documents(bundle_id: str, serial: str | None) -> list[str]:
    from pymobiledevice3.services.house_arrest import HouseArrestService

    client = await lockdown.create(serial)
    try:
        async with await HouseArrestService.create(client, bundle_id) as service:
            return list(await service.listdir("/Documents"))
    finally:
        await lockdown.close(client)
