"""End-to-end sideload orchestration.

A single reusable ``run_sideload`` that provisions, signs, installs, and records
an IPA - used both by the ``sideload`` command and by auto-refresh (which replays
a recorded install with its original options). Progress is reported through a
callback so callers can stream ``provision -> sign -> install`` phases to a UI.

Also owns the lifetime of what signing produces: the ``<source>_Signed.ipa`` that
can optionally be kept, the throwaway scratch directory beside it, and the
reporting/cleanup of a folder full of kept IPAs.
"""

from __future__ import annotations

import datetime
import os
import plistlib
import shutil
import stat
import tempfile
from pathlib import Path
from typing import Any, Callable

from . import (
    apps,
    developer,
    device,
    gsa,
    ipa as ipa_module,
    paths,
    provision,
    refresh,
    signing,
    tweak,
)
from .errors import EngineError

# (phase, percent, step-text) - any of percent/step may be None.
ProgressFn = Callable[[str, Any, "str | None"], None]

# The signed IPA is named after the IPA it came from, so re-signing the same app
# overwrites its own output instead of piling up numbered copies.
SIGNED_SUFFIX = "_Signed.ipa"

# Sign-time scratch: one throwaway directory per run, created inside the same
# folder as the signed output so the heavy I/O follows the user's chosen disk.
#
# Kept deliberately short. Windows caps paths at MAX_PATH for the ANSI file APIs zsign
# uses, and every character spent here is one an app bundle cannot use - see _MAX_PATH.
SCRATCH_PREFIX = "ips_"

# zsign writes temporary `<binary>.archo.N` files beside every Mach-O it re-signs, so
# the scratch directory's own path length decides whether an app can be signed at all.
# A bundle with frameworks nested inside frameworks is deep on its own: a Swift package
# product names itself twice, once as the `.framework` folder and once as the binary
# inside it, which is how LiveContainer+SideStore reaches 178 characters before any
# scratch path is counted. Over the limit zsign dies on an fopen, with both streams
# empty and a -1 exit, so nothing downstream can explain what went wrong.
_MAX_PATH = 259

# Everything zsign adds between the scratch directory and that temporary file: its own
# `zsign_folder_<digits>` subdirectory, two separators, and the `.archo.0` suffix.
# Measured from a run that failed at 264 characters and one that worked at 248, not
# guessed - an estimate 14 too high here would refuse apps that sign perfectly well.
_ZSIGN_HEADROOM = 34


class SideloadError(EngineError):
    """A sideload could not be completed (device, IPA, or option problem)."""


def _resolve_dylibs(entries: list[str] | None) -> list[str]:
    """Turn a mixed list of .deb/.dylib paths into injectable dylib paths.

    A .deb is unpacked to its Mach-O dylib(s); a .dylib is used as-is. Duplicates
    by file name (e.g. the same tweak added for multiple archs) collapse to one.
    """
    resolved: list[str] = []
    seen: set[str] = set()
    for entry in entries or []:
        for item in tweak.resolve(entry):
            key = str(item["name"]).lower()
            if key in seen:
                continue
            seen.add(key)
            resolved.append(str(item["path"]))
    return resolved


# installd's raw Status codes -> friendly, present-tense sub-steps shown in the UI.
_INSTALL_STEPS = {
    "CreatingStagingDirectory": "Staging on device\u2026",
    "ExtractingPackage": "Extracting package\u2026",
    "InspectingPackage": "Inspecting package\u2026",
    "PreflightingApplication": "Preflighting\u2026",
    "InstallingApplication": "Installing\u2026",
    "VerifyingApplication": "Verifying\u2026",
    "CreatingContainer": "Creating container\u2026",
    "InstallingEmbeddedProfile": "Installing profile\u2026",
    "SandboxingApplication": "Sandboxing\u2026",
    "PostflightingApplication": "Postflighting\u2026",
    "GeneratingApplicationMap": "Finalizing\u2026",
}

# installd signals completion with either of these (sometimes with no PercentComplete).
_INSTALL_DONE = {"Complete", "InstallComplete"}


def _humanize_install(status: str | None) -> str:
    if not status:
        return "Installing\u2026"
    if status in _INSTALL_DONE:
        return "Installed"
    return _INSTALL_STEPS.get(status, status)


def _install_relay(update: dict[str, Any], target_name: str = "iPhone") -> tuple[int, str]:
    """Map an ``apps.install`` progress update to ``(overall_percent, step_label)``.

    One monotonic 0-100 bar for the whole install: the upload (the long haul) drives 0-80%,
    installd's on-device phases drive 80-100%, each with a live sub-step label.

    ``target_name`` is what the upload is going to, named rather than assumed: "Uploading
    to iPhone" is wrong the moment somebody points this at an Apple TV, and it is also
    less use than the device's own name when two are attached.
    """
    if update.get("phase") == "upload":
        overall = round((update.get("percent") or 0) * 0.8)
        total, sent = update.get("total") or 0, update.get("sent") or 0
        step = (
            f"Uploading to {target_name} \u00b7 {sent // (1 << 20)} / {total // (1 << 20)} MB"
            if total else f"Uploading to {target_name}\u2026"
        )
        return overall, step
    status = update.get("status")
    if status in _INSTALL_DONE:  # completion may arrive without a percent - pin to 100%
        return 100, "Installed"
    return 80 + round((update.get("percent") or 0) * 0.2), _humanize_install(status)


def resolve_udid(udid: str | None) -> str:
    """The device to sideload to, as a ``SideloadError`` if it cannot be settled."""
    try:
        return device.resolve_serial(udid)
    except device.DeviceError as exc:
        raise SideloadError(str(exc)) from exc


def _signing_profile(
    name: str, team_id: str, bundle_id: str
) -> tuple[list[str], dict[str, Any], list[str]]:
    """Return ``(app groups, entitlements, dylibs)`` for a named signing profile.

    A handful of apps need more than their provisioning profile spells out: app groups
    attached to the App ID, an explicit entitlements plist at sign time, and a dylib of
    ours injected. Rather than let callers pass those in as data, they ask for a profile
    *by name* and it is generated here from the team and bundle id.

    That indirection is what makes auto-refresh correct. The record stores only the name,
    so a re-sign months later regenerates whatever the app requires *today* and finds our
    dylib wherever this build keeps it. Recording the generated values instead would pin
    each record to the requirements - and the install path - that happened to be true on
    the day it was first installed.
    """
    from . import livecontainer  # imported here: livecontainer builds on this module

    if name == livecontainer.SIGNING_PROFILE:
        helper = signing.resolve_helper_dylib()
        return (
            livecontainer.app_group_identifiers(team_id),
            livecontainer.build_entitlements(team_id, bundle_id),
            [helper] if helper else [],
        )
    raise SideloadError(f"Unknown signing profile '{name}'.")


def _profile_pre_sign(
    name: str, ipa_path: str, bundle: dict[str, Any], scratch: str
) -> str | None:
    """Let a named profile rewrite the bundle before it is signed.

    Returns a new IPA path to sign instead of ``ipa_path``, or None to sign it as-is. Runs
    after provisioning, so the certificate is available, and before signing, so anything
    added is covered by the signature. The LiveContainer profile uses this to bake
    iPASide's certificate into a bundled SideStore; a build without SideStore is left
    untouched and signs as normal.
    """
    from . import livecontainer

    if name == livecontainer.SIGNING_PROFILE and livecontainer.has_sidestore(ipa_path):
        return livecontainer.seed_sidestore_certificate(ipa_path, bundle, scratch)
    return None


def _profile_post_install(name: str, udid: str, ipa_path: str) -> dict[str, Any] | None:
    """Whatever a named signing profile still has to do once the app is on the device.

    Runs after a refresh as much as after a first install, which is the whole point.
    LiveContainer keeps its own copy of the signing certificate, so a re-sign that
    reissued that certificate - Apple revoking it, or the cached one going missing -
    would otherwise leave LiveContainer holding one that no longer matches, and nothing
    would say so: it installs, launches, and only fails when it tries to sign.

    What else is needed is read from ``ipa_path``, the app actually being signed, rather
    than from the profile name. Only some LiveContainer builds carry SideStore and so need
    a pairing file, and the artifact is the truth about that: a name recorded by an older
    build would say nothing, and a refresh would silently stop delivering it.

    Never raises. The app is already installed by this point, so a failure here is worth
    reporting, not worth undoing a successful install over.
    """
    from . import livecontainer

    if name != livecontainer.SIGNING_PROFILE:
        return None

    bundle = provision.load_bundle()
    outcome: dict[str, Any] = {
        "certificate": livecontainer.seed_certificate(bundle, udid)
    }

    # A pairing file is a credential for this PC's pairing with the phone, and the sign-in
    # tokens are a credential for the Apple account, so both go only to a build with a store
    # able to use them - and both are re-delivered on every refresh, so a rotated token or a
    # re-paired device keeps the built-in store working without the user touching it.
    if livecontainer.has_sidestore(ipa_path):
        outcome["pairing"] = livecontainer.deliver_pairing(
            bundle["bundle_id"], udid, udid
        )
        outcome["signin"] = livecontainer.deliver_signin(bundle, udid)
    return outcome


def _as_signed_dir(directory: str | None) -> Path:
    """The folder signed IPAs live in: the caller's choice, or the app's own.

    A blank setting counts as unset - a UI that keeps the folder as a string sends ""
    when the user has not chosen one, and resolving that would quietly mean whatever
    directory the engine process happens to be running in. Anything else is made
    absolute so every path reported back names one unambiguous place on disk.
    """
    if not directory or not directory.strip():
        return paths.signed_dir()
    return Path(directory).expanduser().resolve()


def _scratch_root(target: Path, deepest: int) -> Path:
    """Where this run's scratch directory should live, given how deep the IPA is.

    Beside the signed output by preference, so the heavy I/O stays on the disk the user
    chose. That is a performance preference though, and fitting inside the platform's
    path limit is correctness - see :data:`_MAX_PATH` - so a bundle deep enough to
    overflow goes to the system temp directory instead, which is both shorter and where
    every other program puts its scratch.

    Not a retry-on-failure: the choice is computed up front from the IPA, because zsign
    reports an overflow as an fopen failure with no message worth showing.
    """
    if deepest <= 0:
        return target  # nothing read from the IPA to size against
    budget = _MAX_PATH - _ZSIGN_HEADROOM - deepest - len(SCRATCH_PREFIX) - 8
    if len(str(target)) <= budget:
        return target
    return Path(tempfile.gettempdir())


def _open_signed_dir(directory: str | None, deepest: int = 0) -> tuple[Path, Path]:
    """Return ``(signed folder, this run's scratch folder)``, creating both.

    The folder is user-configurable, so it may be a typo, a disconnected drive, or
    somewhere they cannot write. Creating the scratch directory doubles as the write
    test, and either failure is reported as a ``SideloadError`` naming the path -
    something the UI can act on, rather than an OSError raised mid-sign.

    ``deepest`` is the longest path inside the IPA, which decides where the scratch can
    go; see :func:`_scratch_root`.
    """
    try:
        target = _as_signed_dir(directory)
        target.mkdir(parents=True, exist_ok=True)
        root = _scratch_root(target, deepest)
        root.mkdir(parents=True, exist_ok=True)
        scratch = Path(tempfile.mkdtemp(prefix=SCRATCH_PREFIX, dir=root))
    except OSError as exc:
        raise SideloadError(
            f"Cannot use '{directory or exc.filename}' as the folder for signed IPAs: "
            f"{exc.strerror or exc}"
        ) from exc

    # Even the shortest root can be too small for a deep enough bundle on a machine
    # with a long user name. Say so, rather than letting zsign die on an fopen.
    if deepest and len(str(scratch)) + _ZSIGN_HEADROOM + deepest > _MAX_PATH:
        shutil.rmtree(scratch, ignore_errors=True)
        raise SideloadError(
            f"This app's files are nested too deeply to sign on this machine: the "
            f"longest path inside it is {deepest} characters, and the working folder "
            f"'{scratch.parent}' leaves too little of the {_MAX_PATH}-character "
            "Windows path limit. Choosing a shorter folder for signed IPAs in Settings "
            "will fix it."
        )
    return target, scratch


def run_sideload(
    ipa_path: str,
    udid: str | None = None,
    *,
    bundle_id: str | None = None,
    display_name: str | None = None,
    bundle_version: str | None = None,
    dylibs: list[str] | None = None,
    weak_dylibs: bool = False,
    inject_into_extensions: bool = False,
    remove_extensions: bool = True,
    remove_uisd: bool = True,
    enable_file_sharing: bool = False,
    keep_signed: bool = False,
    signed_dir: str | None = None,
    record: bool = True,
    allow_other_platform: bool = False,
    profile: str | None = None,
    on_progress: ProgressFn | None = None,
) -> dict[str, Any]:
    """Provision + sign + install an IPA, then record it for auto-refresh.

    ``keep_signed`` leaves the signed ``<source>_Signed.ipa`` on disk and reports it
    as ``signed_ipa``; otherwise it is deleted once the install is over.
    ``signed_dir`` overrides where that file - and the sign-time scratch - is written.

    ``profile`` names a signing profile that contributes app groups and an explicit
    entitlements plist - see :func:`_signing_profile`. Ordinary sideloads leave it unset
    and get exactly what their provisioning profile grants.
    """
    progress: ProgressFn = on_progress or (lambda *_args: None)
    udid = resolve_udid(udid)

    info = ipa_module.inspect(ipa_path)
    if info.get("has_sc_info"):
        raise signing.SigningError(
            "This IPA is App Store-encrypted (FairPlay) and cannot be sideloaded; "
            "use a decrypted IPA."
        )

    # What matters is not the .ipa's platform on its own, but whether it matches the
    # thing being installed to. An .ipa built for tvOS is indistinguishable from an iOS
    # one from the outside - same zip, same Payload/<App>.app - so sent to an iPhone it
    # installs and never launches, and an iOS .ipa sent to an Apple TV does the same.
    #
    # Provisioning is NOT the obstacle it looks like: Apple registers an Apple TV and
    # issues its profile through the same `ios/` endpoints used for a phone, which is why
    # the platform hints on those calls are ignored. The profile is scoped by the device
    # UDIDs in it, not by a platform.
    device_class, target_name = _describe_target(udid)
    if not allow_other_platform:
        _check_platform_matches_device(ipa_path, info, device_class)

    app_name = display_name or info.get("display_name") or info.get("bundle_id")

    progress("provision", None, "Contacting Apple\u2026")
    # A free account can't register a real App Store id, so default to a
    # team-scoped id; honor an explicit override when given.
    target_bundle_id = bundle_id or provision.team_scoped_bundle_id(info.get("bundle_id"))

    app_groups: list[str] = []
    entitlements: dict[str, Any] | None = None
    profile_dylibs: list[str] = []
    if profile:
        # Keyed by team, and the app groups have to exist before the profile is
        # downloaded, so this resolves before provisioning rather than before signing.
        app_groups, entitlements, profile_dylibs = _signing_profile(
            profile, developer.list_teams()[0]["teamId"], target_bundle_id
        )

    bundle = provision.ensure_signing_assets(
        target_bundle_id, udid, app_name=app_name,
        on_step=lambda message: progress("provision", None, message),
        app_groups=app_groups,
    )

    progress("sign", None, "Signing the app\u2026")
    # The user's tweaks, unpacked from any .deb, plus whatever the signing profile
    # contributes. Only the former is recorded: see _signing_profile.
    resolved_dylibs = _resolve_dylibs(dylibs) + profile_dylibs
    target_dir, scratch = _open_signed_dir(signed_dir, ipa_module.deepest_entry(ipa_path))
    output = str(target_dir / f"{Path(ipa_path).stem}{SIGNED_SUFFIX}")
    try:
        entitlements_path: str | None = None
        if entitlements is not None:
            # Into the scratch directory, which is removed in the `finally` below: this
            # plist is derived from the profile and is regenerated on every run, so there
            # is nothing to gain from keeping it beyond the sign.
            written = scratch / "entitlements.plist"
            written.write_bytes(plistlib.dumps(entitlements))
            entitlements_path = str(written)

        # A profile may rewrite the bundle before it is signed - baking a certificate
        # into a store it carries, say. Whatever it hands back is what gets signed, so
        # the added files are covered by the code signature; the seeded copy lives in
        # scratch and goes with it.
        sign_source = ipa_path
        if profile:
            seeded = _profile_pre_sign(profile, ipa_path, bundle, str(scratch))
            if seeded:
                sign_source = seeded

        signing.sign_ipa(
            sign_source, output,
            p12_path=bundle["p12_path"],
            p12_password=bundle["p12_password"],
            profile_path=bundle["profile_path"],
            bundle_id=target_bundle_id,
            display_name=display_name,
            bundle_version=bundle_version,
            remove_extensions=remove_extensions,
            remove_uisd=remove_uisd,
            enable_file_sharing=enable_file_sharing,
            dylibs=resolved_dylibs,
            weak_dylibs=weak_dylibs,
            inject_into_extensions=inject_into_extensions,
            entitlements=entitlements_path,
            temp_folder=str(scratch),
        )

        progress("install", 0, f"Uploading to {target_name}\u2026")
        apps.install(
            output,
            udid,
            progress=lambda u: progress("install", *_install_relay(u, target_name)),
        )

        post_install: dict[str, Any] | None = None
        if profile:
            progress("finalize", None, "Finishing setup\u2026")
            post_install = _profile_post_install(profile, udid, ipa_path)
    finally:
        # Scratch always goes, kept signed IPA or not: it is an unpacked copy of the
        # whole app, worth hundreds of MB, and nothing reads it after signing.
        shutil.rmtree(scratch, ignore_errors=True)
        # Unless the user asked to keep it, so does the signed IPA - install reads it
        # once, refresh re-signs from the recorded *source* IPA, and a retry re-signs
        # anyway, so it is never read again. Leaving it behind used to strand a copy
        # of the largest app ever sideloaded on disk permanently (233 MB here), and
        # this runs on failure too so an aborted upload cannot leak one either.
        if not keep_signed:
            Path(output).unlink(missing_ok=True)

    expires_at: str | None = None
    try:
        expiry = refresh.profile_expiration(Path(bundle["profile_path"]).read_bytes())
        expires_at = expiry.isoformat() if expiry else None
    except OSError:
        pass

    result = {
        "status": "installed",
        "bundle_id": target_bundle_id,
        "name": app_name,
        "icon": info.get("icon"),
        "udid": udid,
        "team_id": bundle.get("team_id"),
        "source_ipa": str(Path(ipa_path).resolve()),
        "signed_ipa": output if keep_signed else None,
        "installed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "expires_at": expires_at,
        "post_install": post_install,
    }
    if record:
        # Everything but signed_ipa: `signed --clean` can remove that file at any
        # time, and refresh re-signs from source_ipa, so recording it would only
        # put a path in the registry that quietly stops being true. post_install is
        # likewise the outcome of this one run, not something to replay.
        _transient = ("signed_ipa", "post_install")
        refresh.record({
            **{key: value for key, value in result.items() if key not in _transient},
            "options": {
                "bundle_id": bundle_id,
                "display_name": display_name,
                "bundle_version": bundle_version,
                "dylibs": dylibs or [],
                "weak_dylibs": weak_dylibs,
                "inject_into_extensions": inject_into_extensions,
                "remove_extensions": remove_extensions,
                "remove_uisd": remove_uisd,
                "enable_file_sharing": enable_file_sharing,
                # By name, not as the generated entitlements - see _signing_profile.
                "profile": profile,
            },
        })
    return result


# What lockdown's DeviceClass means in terms of the platform an app is built for.
_DEVICE_CLASS_PLATFORM = {
    "iphone": "ios",
    "ipad": "ios",
    "ipod": "ios",
    "appletv": "tvos",
    "realitydevice": "visionos",
    "watch": "watchos",
}

# How to name the target when the two do not agree.
_DEVICE_LABELS = {
    "ios": "an iPhone or iPad",
    "tvos": "an Apple TV",
    "watchos": "an Apple Watch",
    "visionos": "an Apple Vision Pro",
}


def _describe_target(udid: str) -> tuple[str, str]:
    """``(device_class, name)`` for the target, both lowercased/blank if unreachable.

    Read once: the platform check and every "Uploading to ..." label want the same
    answer, and an unreachable device is the install's problem to report, not this
    function's - so a failure here degrades to the old wording rather than raising.
    """
    try:
        values = device.get_device_info(udid)
    except Exception:  # noqa: BLE001
        return "", "iPhone"
    device_class = str(values.get("DeviceClass") or "").strip().lower()
    name = str(values.get("DeviceName") or "").strip()
    if not name:
        name = _DEVICE_LABELS.get(_DEVICE_CLASS_PLATFORM.get(device_class, ""), "iPhone")
    return device_class, name


def _check_platform_matches_device(
    ipa_path: str, info: dict[str, Any], device_class: str
) -> None:
    """Refuse an app built for a different kind of device than the one selected.

    Only a genuine mismatch is refused. A tvOS ``.ipa`` going to an Apple TV is fine -
    Apple registers the device and issues its profile through the same ``ios/`` endpoints
    used for a phone, which is why the platform hints on those calls are ignored: the
    profile is scoped by the UDIDs in it, not by a platform. Anything we cannot read
    confidently is allowed through, because "the Info.plist did not say" is not evidence
    of the wrong platform.
    """
    app_platform = info.get("platform")
    if not app_platform:
        return

    device_platform = _DEVICE_CLASS_PLATFORM.get(device_class)
    if not device_platform or device_platform == app_platform:
        return

    app_label = ipa_module.PLATFORM_LABELS.get(app_platform, f"{app_platform} devices")
    target = _DEVICE_LABELS.get(device_platform, device_class or "this device")
    raise SideloadError(
        f"{Path(ipa_path).name} is built for {app_label}, and the selected device is "
        f"{target}. It would install and then refuse to launch. Use a build made for "
        f"{target}, or pass --allow-other-platform to try it anyway."
    )


def _refresh_account(entry: dict[str, Any]) -> str | None:
    """The Apple ID to re-sign this record under, or None to use the active one.

    A refresh has to run as the account that signed the app. Under a different one
    it is re-signed by a different team, and iOS will not install that over the copy
    already on the phone — the app just stops opening, which is the opposite of what
    a refresh is for.

    Raises when the right account is not signed in at all, rather than letting Apple
    refuse to register another team's identifier: that surfaces as bare error 9401
    ("An App ID with Identifier ... is not available"), which reads like a problem
    with the app rather than with which account is in use.
    """
    team_id = entry.get("team_id")
    if not team_id:
        return None  # Recorded before teams were tracked; the active account is all we have.

    account = gsa.account_for_team(team_id)
    if account:
        return account

    # No signed-in account is *known* to provision for that team, but the active one
    # may simply never have been mapped — it is only learned by provisioning. Ask
    # once before giving up, and remember the answer either way.
    session = gsa.load_session()
    email = session.get("email")
    try:
        active_team = developer.list_teams()[0]["teamId"]
    except Exception:  # noqa: BLE001 - offline or Apple unreachable
        return None    # Let the refresh itself fail with the real reason.

    if email:
        gsa.remember_team(email, active_team)
    if active_team == team_id:
        return None

    name = entry.get("name") or entry.get("bundle_id") or "This app"
    raise SideloadError(
        f"{name} was signed by a different Apple ID (team {team_id}), and that "
        f"account is not signed in — {email or 'the current account'} is on team "
        f"{active_team}. Sign in as the Apple ID that installed it to refresh it, "
        f"or sideload it again with this one."
    )


def refresh_record(
    entry: dict[str, Any],
    on_progress: ProgressFn | None = None,
    *,
    keep_signed: bool = False,
    signed_dir: str | None = None,
) -> dict[str, Any]:
    """Re-sign + reinstall a previously recorded sideload using its saved options.

    ``keep_signed``/``signed_dir`` are not part of the record: they are the user's
    current preference, which the caller (the ``refresh`` command, including the
    headless auto-refresh run) passes in so a refresh honours whatever the setting
    says today rather than what it said when the app was first sideloaded.
    """
    source = entry.get("source_ipa")
    if not source:
        raise SideloadError(
            f"{entry.get('name') or 'This app'} has no recorded source IPA, so it "
            "cannot be refreshed. Sideload it again to start tracking it."
        )
    if not Path(source).exists():
        # Checked before resolve_udid so a refresh-all does not spend a lockdown round
        # trip per app to discover a file is gone; ipa.inspect would catch it either way.
        raise ipa_module.missing_ipa_error(source)
    options = entry.get("options") or {}

    account = _refresh_account(entry)
    with gsa.acting_as(account):
        return run_sideload(
            source,
            entry.get("udid"),
            bundle_id=entry.get("bundle_id"),
            display_name=options.get("display_name"),
            bundle_version=options.get("bundle_version"),
            dylibs=options.get("dylibs") or [],
            weak_dylibs=bool(options.get("weak_dylibs")),
            inject_into_extensions=bool(options.get("inject_into_extensions")),
            remove_extensions=options.get("remove_extensions", True),
            remove_uisd=options.get("remove_uisd", True),
            enable_file_sharing=bool(options.get("enable_file_sharing")),
            keep_signed=keep_signed,
            signed_dir=signed_dir,
            profile=options.get("profile"),
            on_progress=on_progress,
        )


def _kept_signed_ipas(directory: Path) -> list[tuple[Path, os.stat_result]]:
    """The signed IPAs in ``directory``, newest first, as ``(path, lstat)`` pairs.

    This one filter is the entire blast radius of ``clean_signed``, and the folder is
    whatever the user configured - possibly Documents, a downloads folder, or the disk
    root, full of files iPASide never wrote. So it only matches what we know we wrote,
    and deliberately cannot reach anything else:

    * ``iterdir()``, never ``rglob()``/``walk()``: a subdirectory's contents are out of
      scope, and directory entries themselves are never returned, so nothing here can
      remove a directory - including the folder itself.
    * ``lstat()`` + ``S_ISREG``: the entry must be a *regular file in its own right*.
      A symlink or Windows junction named ``..._Signed.ipa`` fails this (``lstat``
      describes the link, not its target), so a link can never be followed out of the
      folder. One call also leaves no window between the type check and size/mtime.
    * the ``SIGNED_SUFFIX`` that ``run_sideload`` writes, matched case-insensitively -
      not merely ``*.ipa``. The narrower rule is the point: someone who sets the folder
      to where they keep their IPAs would otherwise have ``--clean`` delete the source
      IPAs too, which is both their data and what auto-refresh re-signs from.

    Sign-time scratch is a directory, so the rules above already exclude it;
    ``run_sideload`` removes it in a ``finally`` instead. A missing or unreadable
    folder is empty, not an error - the UI reports on a path that may not exist yet.
    """
    try:
        entries = list(directory.iterdir())
    except OSError:
        return []

    suffix = SIGNED_SUFFIX.lower()
    found: list[tuple[Path, os.stat_result]] = []
    for entry in entries:
        if not entry.name.lower().endswith(suffix):
            continue
        try:
            info = entry.lstat()
        except OSError:  # vanished, or we are not allowed to look at it
            continue
        if stat.S_ISREG(info.st_mode):
            found.append((entry, info))
    found.sort(key=lambda item: item[1].st_mtime, reverse=True)
    return found


def signed_status(directory: str | None = None) -> dict[str, Any]:
    """Report the signed IPAs kept in ``directory`` (default: the app's own folder)."""
    target = _as_signed_dir(directory)
    found = _kept_signed_ipas(target)
    return {
        "directory": str(target),
        "count": len(found),
        "bytes": sum(info.st_size for _path, info in found),
        "files": [
            {
                "name": path.name,
                "bytes": info.st_size,
                "modified": datetime.datetime.fromtimestamp(
                    info.st_mtime, datetime.timezone.utc
                ).isoformat(),
            }
            for path, info in found
        ],
    }


def clean_signed(directory: str | None = None) -> dict[str, Any]:
    """Delete the signed IPAs in ``directory``, and only those (see ``_kept_signed_ipas``).

    Reports what actually went, so a file another process is holding open (a common
    Windows case) is skipped rather than counted or raised.
    """
    target = _as_signed_dir(directory)
    removed, freed = 0, 0
    for path, info in _kept_signed_ipas(target):
        try:
            path.unlink()
        except OSError:
            continue
        removed += 1
        freed += info.st_size
    return {"directory": str(target), "removed": removed, "bytes_freed": freed}
