"""Apple GrandSlam (GSA) authentication.

Implements Apple's modified SRP-6a login against ``gsa.apple.com/grandslam``,
using anisette headers from :mod:`ipaside_engine.anisette`. Ported faithfully
from the community GrandSlam implementations (JJTech0130 / nythepegasus), with
three production changes: (1) anisette comes from our in-process provider rather
than a remote server, (2) TLS verification stays on, and (3) two-factor auth is
a two-step flow (trigger, then submit a code) so it works across separate CLI
invocations and maps cleanly onto a GUI.

The password is never stored; only short-lived session tokens (adsid, IDMS
token) are cached, under the per-user data dir, never in source control.
"""

from __future__ import annotations

import base64
import contextlib
import contextvars
import hashlib
import hmac
import json
import plistlib
from collections.abc import Iterator
from typing import Any

import requests
import srp._pysrp as srp
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from . import anisette, paths, tls
from .errors import EngineError

# Configure the SRP library for Apple's variant (SHA-256, 2048-bit group,
# username excluded from the x computation).
srp.rfc5054_enable()
srp.no_username_in_x()

_GS_ENDPOINT = "https://gsa.apple.com/grandslam/GsService2"
_TRUSTED_TRIGGER = "https://gsa.apple.com/auth/verify/trusteddevice"
_VALIDATE = "https://gsa.apple.com/grandslam/GsService2/validate"
_SMS_ENDPOINT = "https://gsa.apple.com/auth/verify/phone/"
_SMS_SUBMIT = "https://gsa.apple.com/auth/verify/phone/securitycode"

_GS_USER_AGENT = "akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0"
_XCODE_APP_INFO = "com.apple.gs.xcode.auth"
_XCODE_VERSION = "11.2 (11B41)"
_TIMEOUT = 30

_PLIST_PROLOG = (
    b'<?xml version="1.0" encoding="UTF-8"?>\n'
    b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
    b'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
)


class GsaError(EngineError):
    """Raised when Apple returns an authentication error."""


# --------------------------------------------------------------------------- #
# Request plumbing
# --------------------------------------------------------------------------- #
def _cpd(headers: dict[str, str]) -> dict[str, Any]:
    """Client-provided data: flags + anisette (client-info goes in headers)."""
    cpd: dict[str, Any] = {
        "bootstrap": True,
        "icscrec": True,
        "pbe": False,
        "prkgen": True,
        "svct": "iCloud",
        "loc": headers.get("X-Apple-Locale", "en_US"),
    }
    for key, value in headers.items():
        if key != "X-MMe-Client-Info":
            cpd[key] = value
    return cpd


def _gs_request(params: dict[str, Any], headers: dict[str, str]) -> dict[str, Any]:
    body = {
        "Header": {"Version": "1.0.1"},
        "Request": {"cpd": _cpd(headers), **params},
    }
    req_headers = {
        "Content-Type": "text/x-xml-plist",
        "Accept": "*/*",
        "User-Agent": _GS_USER_AGENT,
        "X-MMe-Client-Info": headers.get("X-MMe-Client-Info", ""),
    }
    resp = requests.post(
        _GS_ENDPOINT,
        headers=req_headers,
        data=plistlib.dumps(body),
        timeout=_TIMEOUT,
        verify=tls.ca_bundle(),
    )
    resp.raise_for_status()
    return plistlib.loads(resp.content)["Response"]


def _check(response: dict[str, Any]) -> None:
    status = response.get("Status", response)
    ec = status.get("ec", 0)
    if ec != 0:
        raise GsaError(f"Apple error {ec}: {status.get('em', 'unknown error')}")


# --------------------------------------------------------------------------- #
# SRP crypto
# --------------------------------------------------------------------------- #
def _derive_password(password: str, salt: bytes, iterations: int, s2k_fo: bool) -> bytes:
    digest = hashlib.sha256(password.encode("utf-8")).digest()
    if s2k_fo:
        digest = digest.hex().encode("utf-8")
    return hashlib.pbkdf2_hmac("sha256", digest, salt, iterations, 32)


def _session_hmac(session_key: bytes, label: str) -> bytes:
    return hmac.new(session_key, label.encode(), hashlib.sha256).digest()


def _loads_plist(raw: bytes) -> dict[str, Any]:
    """Parse a GSA plist payload, tolerating a missing XML prolog."""
    try:
        return plistlib.loads(raw)
    except Exception:  # noqa: BLE001 - GSA omits the XML prolog on some responses
        return plistlib.loads(_PLIST_PROLOG + raw)


def _decrypt_spd(session_key: bytes, data: bytes) -> dict[str, Any]:
    key = _session_hmac(session_key, "extra data key:")
    iv = _session_hmac(session_key, "extra data iv:")[:16]
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    decryptor = cipher.decryptor()
    raw = decryptor.update(data) + decryptor.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    raw = unpadder.update(raw) + unpadder.finalize()
    return _loads_plist(raw)


def _authenticate_once(
    email: str, password: str, headers: dict[str, str]
) -> tuple[dict[str, Any], str | None]:
    """Run one full SRP handshake. Returns (session-data, secondary-auth-kind)."""
    usr = srp.User(email, b"", hash_alg=srp.SHA256, ng_type=srp.NG_2048)
    _, a_pub = usr.start_authentication()

    init = _gs_request(
        {"A2k": a_pub, "ps": ["s2k", "s2k_fo"], "u": email, "o": "init"}, headers
    )
    _check(init)

    protocol = init.get("sp", "s2k")
    if protocol not in ("s2k", "s2k_fo"):
        raise GsaError(f"unsupported SRP protocol from server: {protocol}")

    # Feed the salted-and-iterated password in now that we have the salt.
    usr.p = _derive_password(password, init["s"], init["i"], protocol == "s2k_fo")
    m1 = usr.process_challenge(init["s"], init["B"])
    if m1 is None:
        raise GsaError("failed to process SRP challenge (bad server response)")

    complete = _gs_request(
        {"c": init["c"], "M1": m1, "u": email, "o": "complete"}, headers
    )
    _check(complete)

    usr.verify_session(complete["M2"])
    if not usr.authenticated():
        raise GsaError("server session verification failed (possible MITM)")

    spd = _decrypt_spd(usr.get_session_key(), complete["spd"])
    secondary = complete.get("Status", {}).get("au")
    return spd, secondary


# --------------------------------------------------------------------------- #
# Two-factor auth
# --------------------------------------------------------------------------- #
def _identity_token(adsid: str, idms_token: str) -> str:
    return base64.b64encode(f"{adsid}:{idms_token}".encode()).decode()


def _twofa_headers(adsid: str, idms_token: str, headers: dict[str, str]) -> dict[str, str]:
    out = {
        "Content-Type": "text/x-xml-plist",
        "User-Agent": "Xcode",
        "Accept": "text/x-xml-plist",
        "Accept-Language": "en-us",
        "X-Apple-Identity-Token": _identity_token(adsid, idms_token),
        "X-Apple-App-Info": _XCODE_APP_INFO,
        "X-Xcode-Version": _XCODE_VERSION,
    }
    out.update(headers)
    return out


def _trigger_trusted(adsid: str, idms_token: str, headers: dict[str, str]) -> None:
    """Ask Apple to push a trusted-device 2FA code.

    The response body is an HTML interstitial even on success, so status is the signal.
    Ignoring a non-2xx (as we used to) is what made issue #5 look like "code was sent"
    in the UI while Apple had actually rejected the request with HTTP 500 over a bad
    ``X-Apple-Locale``.
    """
    resp = requests.get(
        _TRUSTED_TRIGGER,
        headers=_twofa_headers(adsid, idms_token, headers),
        timeout=_TIMEOUT,
        verify=tls.ca_bundle(),
    )
    if resp.status_code != 200:
        raise GsaError(
            f"Apple did not send a verification code (HTTP {resp.status_code}). "
            "Check your connection and try signing in again."
        )


def _submit_trusted(adsid: str, idms_token: str, code: str, headers: dict[str, str]) -> None:
    req_headers = _twofa_headers(adsid, idms_token, headers)
    req_headers["security-code"] = code
    resp = requests.get(_VALIDATE, headers=req_headers, timeout=_TIMEOUT, verify=tls.ca_bundle())
    _check(plistlib.loads(resp.content))


# --------------------------------------------------------------------------- #
# App-token exchange (per-service Xcode token for developer services)
# --------------------------------------------------------------------------- #
_XCODE_AUTH_APP = "com.apple.gs.xcode.auth"


def _coerce_bytes(value: Any) -> bytes:
    if isinstance(value, bytes):
        return value
    if isinstance(value, str):
        return base64.b64decode(value)
    raise GsaError("expected bytes or base64 string in session data")


def _app_tokens_checksum(sk: bytes, adsid: str, apps: list[str]) -> bytes:
    mac = hmac.new(sk, b"apptokens" + adsid.encode(), hashlib.sha256)
    for app in apps:
        mac.update(app.encode())
    return mac.digest()


def _decrypt_gcm(sk: bytes, encrypted: bytes) -> bytes:
    # Apple wire format: "XYZ" (3 bytes, also the AAD) | IV (16) | ciphertext | tag (16).
    if len(encrypted) < 35 or encrypted[:3] != b"XYZ":
        raise GsaError("malformed encrypted app token")
    iv = encrypted[3:19]
    ciphertext_and_tag = encrypted[19:]
    return AESGCM(sk).decrypt(iv, ciphertext_and_tag, b"XYZ")


def _fetch_app_token(
    spd: dict[str, Any], headers: dict[str, str], app: str = _XCODE_AUTH_APP
) -> dict[str, Any]:
    """Exchange the GSA session for a scoped Xcode token (X-Apple-GS-Token)."""
    sk = _coerce_bytes(spd["sk"])
    adsid = spd["adsid"]
    params = {
        "u": adsid,
        "app": [app],
        "c": spd["c"],
        "t": spd["GsIdmsToken"],
        "checksum": _app_tokens_checksum(sk, adsid, [app]),
        "o": "apptokens",
    }
    response = _gs_request(params, headers)
    _check(response)
    token_plist = _loads_plist(_decrypt_gcm(sk, response["et"]))
    token_info = token_plist["t"][app]
    return {"token": token_info["token"], "expiry": token_info.get("expiry")}


def _finalize_session(email: str, spd: dict[str, Any], headers: dict[str, str]) -> dict[str, Any]:
    """Mint the developer-services token and persist the authenticated session."""
    app_token = _fetch_app_token(spd, headers)
    _save_account(email, spd, app_token)
    _clear_pending()
    return {
        "status": "authenticated",
        "adsid": spd.get("adsid"),
        "auth_token_acquired": bool(app_token.get("token")),
    }


# --------------------------------------------------------------------------- #
# Session persistence
# --------------------------------------------------------------------------- #
def _save_pending(email: str, adsid: str, idms_token: str, method: str) -> None:
    paths.pending_2fa_file().write_text(
        json.dumps({"email": email, "adsid": adsid, "idms": idms_token, "method": method}),
        encoding="utf-8",
    )


def _load_pending() -> dict[str, Any] | None:
    path = paths.pending_2fa_file()
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _clear_pending() -> None:
    paths.pending_2fa_file().unlink(missing_ok=True)


def _migrate_legacy_account() -> None:
    """Moves a single-account build's session into the multi-account layout.

    Runs on every read, which is cheap and means an upgrade never signs anyone out
    and never leaves two copies of the same session to disagree with each other.
    """
    legacy = paths.legacy_account_file()
    if not legacy.exists():
        return
    try:
        data = json.loads(legacy.read_text(encoding="utf-8"))
        email = data.get("email")
        if email:
            target = paths.account_file(email)
            if not target.exists():
                target.write_text(json.dumps(data), encoding="utf-8")
            _set_active(email)
    except (OSError, ValueError):
        # A corrupt legacy file is not worth failing a login over; it is about to
        # be replaced anyway.
        pass
    legacy.unlink(missing_ok=True)


def _set_active(email: str) -> None:
    paths.active_account_file().write_text(
        json.dumps({"email": email}), encoding="utf-8"
    )


def _active_email() -> str | None:
    path = paths.active_account_file()
    if path.exists():
        try:
            email = json.loads(path.read_text(encoding="utf-8")).get("email")
        except ValueError:
            email = None
        if email and paths.account_file(email).exists():
            return email

    # No pointer, or it names an account that has since been removed: fall back to
    # the only one there is, so a single-account user never has to choose.
    known = list_accounts()
    if len(known) == 1:
        _set_active(known[0]["email"])
        return known[0]["email"]
    return None


def _save_account(email: str, spd: dict[str, Any], app_token: dict[str, Any]) -> None:
    path = paths.account_file(email)
    existing: dict[str, Any] = {}
    if path.exists():
        try:
            existing = json.loads(path.read_text(encoding="utf-8"))
        except ValueError:
            existing = {}

    path.write_text(
        json.dumps(
            {
                # team_id is learned later, by provisioning; carry it across a
                # re-login so refreshing an app can still find its account.
                **{k: v for k, v in existing.items() if k == "team_id"},
                "email": email,
                "adsid": spd.get("adsid"),
                "GsIdmsToken": spd.get("GsIdmsToken"),
                "auth_token": app_token.get("token"),
                "auth_token_expiry": app_token.get("expiry"),
            }
        ),
        encoding="utf-8",
    )
    _set_active(email)


def _read_account(email: str) -> dict[str, Any]:
    path = paths.account_file(email)
    if not path.exists():
        raise GsaError(f"{email} is not signed in.")
    return json.loads(path.read_text(encoding="utf-8"))


def list_accounts() -> list[dict[str, Any]]:
    """Every signed-in Apple ID, newest sign-in first."""
    accounts = []
    for path in paths.accounts_dir().glob("*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not data.get("email"):
            continue
        accounts.append(
            {
                "email": data["email"],
                "adsid": data.get("adsid"),
                "team_id": data.get("team_id"),
                "has_auth_token": bool(data.get("auth_token")),
                "signed_in_at": path.stat().st_mtime,
            }
        )
    accounts.sort(key=lambda a: a["signed_in_at"], reverse=True)
    return accounts


def accounts() -> dict[str, Any]:
    """The signed-in accounts and which one is active."""
    _migrate_legacy_account()
    known = list_accounts()
    active = _active_email()
    for account in known:
        account["active"] = account["email"] == active
    return {"accounts": known, "active": active}


def use_account(email: str) -> dict[str, Any]:
    """Make an already signed-in account the active one."""
    _migrate_legacy_account()
    data = _read_account(email)
    if not data.get("auth_token"):
        raise GsaError(f"{email} has no developer token; sign in again.")
    _set_active(data["email"])
    return {"status": "active", "email": data["email"]}


def remember_team(email: str, team_id: str) -> None:
    """Records which developer team an account provisions under.

    This is what lets a refresh run under the Apple ID that signed the app rather
    than whichever one happens to be active — sign in with a second account and
    refresh without it, and the app is re-signed by a different team, which iOS
    will not install over the existing copy.
    """
    path = paths.account_file(email)
    if not path.exists():
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return
    if data.get("team_id") == team_id:
        return
    data["team_id"] = team_id
    path.write_text(json.dumps(data), encoding="utf-8")


def account_for_team(team_id: str) -> str | None:
    """The signed-in account that provisions under [team_id], if any."""
    _migrate_legacy_account()
    for account in list_accounts():
        if account.get("team_id") == team_id:
            return account["email"]
    return None


_acting_as: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "ipaside_acting_as", default=None
)


@contextlib.contextmanager
def acting_as(email: str | None) -> Iterator[None]:
    """Run a block as [email] rather than the active account.

    Every call into Apple's developer services loads the session for itself, so a
    refresh that must run under the Apple ID which signed the app cannot simply
    pass an address down — there are a dozen call sites in between. Overriding it
    here, for the duration of the block, keeps that plumbing out of the callers and
    leaves the user's own choice of active account untouched on disk.
    """
    if not email:
        yield
        return
    token = _acting_as.set(email)
    try:
        yield
    finally:
        _acting_as.reset(token)


def load_session(email: str | None = None) -> dict[str, Any]:
    """Return a cached developer-services session (adsid + Xcode auth token).

    Defaults to whichever account [acting_as] names, then the active one; pass
    [email] to be explicit.
    """
    _migrate_legacy_account()
    target = email or _acting_as.get() or _active_email()
    if not target:
        if list_accounts():
            raise GsaError(
                "more than one Apple ID is signed in and none is selected; "
                "choose one with 'login --use <email>'."
            )
        raise GsaError("not signed in; run 'login' first")

    data = _read_account(target)
    if not data.get("auth_token"):
        raise GsaError("cached session has no developer token; sign in again")
    return {
        "adsid": data["adsid"],
        "auth_token": data["auth_token"],
        "email": data.get("email"),
    }


# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #
def begin_login(email: str, password: str) -> dict[str, Any]:
    """Start login. Returns an 'authenticated' or '2fa_required' result."""
    headers = anisette.get_headers()
    spd, secondary = _authenticate_once(email, password, headers)
    if not secondary:
        return _finalize_session(email, spd, headers)

    adsid, idms = spd["adsid"], spd["GsIdmsToken"]
    method = "trusteddevice" if secondary == "trustedDeviceSecondaryAuth" else "sms"
    if method == "trusteddevice":
        _trigger_trusted(adsid, idms, anisette.get_headers())
    _save_pending(email, adsid, idms, method)
    return {"status": "2fa_required", "method": method}


def complete_2fa(email: str, password: str, code: str) -> dict[str, Any]:
    """Submit a 2FA code, then re-authenticate to obtain the session tokens."""
    pending = _load_pending()
    if not pending:
        raise GsaError("no pending 2FA request; run 'login' first")
    if pending["method"] == "trusteddevice":
        _submit_trusted(pending["adsid"], pending["idms"], code, anisette.get_headers())
    else:
        raise GsaError("SMS 2FA submission is not implemented yet")

    headers = anisette.get_headers()
    spd, secondary = _authenticate_once(email, password, headers)
    if secondary:
        raise GsaError(f"account still requires secondary auth after 2FA: {secondary}")
    return _finalize_session(email, spd, headers)


def status() -> dict[str, Any]:
    """Report the active account, and how many others are signed in."""
    _migrate_legacy_account()
    known = list_accounts()
    active = _active_email()
    if not active:
        return {"authenticated": False, "account_count": len(known)}

    data = _read_account(active)
    return {
        "authenticated": True,
        "email": data.get("email"),
        "adsid": data.get("adsid"),
        "team_id": data.get("team_id"),
        "has_idms_token": bool(data.get("GsIdmsToken")),
        "has_auth_token": bool(data.get("auth_token")),
        "account_count": len(known),
    }


def logout(email: str | None = None) -> dict[str, Any]:
    """Sign out one account, or every account when [email] is omitted."""
    _migrate_legacy_account()
    _clear_pending()

    if email is None:
        removed = [a["email"] for a in list_accounts()]
        for address in removed:
            paths.account_file(address).unlink(missing_ok=True)
        paths.active_account_file().unlink(missing_ok=True)
        return {"status": "signed_out", "removed": removed}

    path = paths.account_file(email)
    if not path.exists():
        raise GsaError(f"{email} is not signed in.")
    path.unlink()
    if _active_email() is None:
        paths.active_account_file().unlink(missing_ok=True)
    return {"status": "signed_out", "removed": [email], "active": _active_email()}
