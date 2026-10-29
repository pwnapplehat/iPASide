"""Re-issuing a certificate must not touch certificates that are not ours.

Apple's development-certificate limit is scoped per machine, not per account, so one free
team routinely holds several at once - verified on hardware holding three: iPASide's, one
registered by SideStore on the phone, and one by Xcode on a Mac. Revoking any of those
stops every app it signed from launching, in tools iPASide has no part in.

iPASide used to revoke every certificate on the team whenever it needed a new one, which
fires on a fresh install, a lost cache, or an expired certificate.
"""

from __future__ import annotations

import base64
import json

import pytest

from ipaside_engine import developer, gsa, paths, provision, signing

TEAM = "ASK9QR9SBC"

OURS = {
    "serialNumber": "29C8EC73C890EBCA0EE74E017975D97B",
    "machineName": provision.CERTIFICATE_MACHINE_NAME,
    "name": "iOS Development: Someone",
}
SIDESTORE = {
    "serialNumber": "6739B3069372332966091DE3341C96BE",
    "machineName": "SideStore - Someone's iPhone",
    "name": "iOS Development: Someone",
}
XCODE = {
    "serialNumber": "63EDA768F91B8C905FC6877994086D66",
    "machineName": "Someone's MacBook Pro",
    "name": "Apple Development: Someone",
}


class _Portal:
    """Records revocations and hands back a freshly issued certificate."""

    def __init__(self, certs, revoke_error=None, csr_error=None):
        self.certs = list(certs)
        self.revoked: list[str] = []
        self.machine_names: list[str] = []
        self.revoke_error = revoke_error
        self.csr_error = csr_error
        self.issued: dict | None = None

    def list_certificates(self, _team_id):
        return list(self.certs) + ([self.issued] if self.issued else [])

    def revoke_certificate(self, _team_id, serial):
        if self.revoke_error is not None:
            raise self.revoke_error
        self.revoked.append(serial)
        self.certs = [c for c in self.certs if c.get("serialNumber") != serial]

    def submit_csr(self, _team_id, _csr_pem, machine_name="iPASide"):
        self.machine_names.append(machine_name)
        if self.csr_error is not None:
            raise self.csr_error
        self.issued = {
            "serialNumber": "NEWLYISSUED0001",
            "machineName": machine_name,
            "certContent": b"der-bytes",
        }
        return {}


@pytest.fixture
def portal(monkeypatch, tmp_path):
    """A fake developer portal, with signing stubbed and the cache in tmp_path."""

    def _make(certs, revoke_error=None, csr_error=None):
        fake = _Portal(certs, revoke_error, csr_error)
        monkeypatch.setattr(developer, "list_certificates", fake.list_certificates)
        monkeypatch.setattr(developer, "revoke_certificate", fake.revoke_certificate)
        monkeypatch.setattr(developer, "submit_csr", fake.submit_csr)
        monkeypatch.setattr(paths, "signing_dir", lambda _slug=None: tmp_path)
        monkeypatch.setattr(
            signing, "generate_key_and_csr", lambda *a, **k: (b"key-pem", "csr-pem")
        )
        # Matching the issued certificate to our key is a crypto detail tested elsewhere.
        monkeypatch.setattr(
            provision,
            "_find_cert_for_key",
            lambda certs, _key: (b"der-bytes", "NEWLYISSUED0001"),
        )
        return fake

    return _make


# --------------------------------------------------------------------------- #
# What may and may not be revoked
# --------------------------------------------------------------------------- #
def test_only_our_own_certificate_is_revoked(portal):
    fake = portal([OURS, SIDESTORE, XCODE])

    provision._ensure_certificate(TEAM, None)

    assert fake.revoked == [OURS["serialNumber"]]


@pytest.mark.parametrize("other", [SIDESTORE, XCODE], ids=["sidestore", "xcode"])
def test_another_tools_certificate_is_left_alone(portal, other):
    """Revoking it would stop every app that tool signed from launching."""
    fake = portal([OURS, other])

    provision._ensure_certificate(TEAM, None)

    assert other["serialNumber"] not in fake.revoked


def test_nothing_is_revoked_when_we_have_no_certificate_yet(portal):
    """A first run on an account already used by Xcode must take nothing away."""
    fake = portal([SIDESTORE, XCODE])

    provision._ensure_certificate(TEAM, None)

    assert fake.revoked == []


def test_a_certificate_without_a_machine_name_is_not_assumed_to_be_ours(portal):
    fake = portal([{"serialNumber": "UNKNOWN01"}])

    provision._ensure_certificate(TEAM, None)

    assert fake.revoked == []


# --------------------------------------------------------------------------- #
# What gets issued
# --------------------------------------------------------------------------- #
def test_the_new_certificate_is_registered_under_our_machine_name(portal):
    """The name is how the next re-issue recognises it; a drifting one orphans it."""
    fake = portal([])

    provision._ensure_certificate(TEAM, None)

    assert fake.machine_names == [provision.CERTIFICATE_MACHINE_NAME]


def test_a_cached_certificate_that_apple_still_lists_is_reused(portal, tmp_path):
    """No revocation, no re-issue: the common path must touch nothing."""
    (tmp_path / "certificate.json").write_text(
        json.dumps(
            {
                "serial": OURS["serialNumber"],
                "key_pem": base64.b64encode(b"key-pem").decode(),
                "cert_der": base64.b64encode(b"der-bytes").decode(),
            }
        ),
        encoding="utf-8",
    )
    fake = portal([OURS, SIDESTORE, XCODE])

    _key, _der, serial = provision._ensure_certificate(TEAM, None)

    assert serial == OURS["serialNumber"]
    assert fake.revoked == []
    assert fake.machine_names == []


# --------------------------------------------------------------------------- #
# When it goes wrong
# --------------------------------------------------------------------------- #
def test_a_failed_revocation_explains_a_failed_request(portal):
    """The two failures together are the diagnosis; neither alone says much."""
    fake = portal(
        [OURS],
        revoke_error=developer.DeveloperServicesError("7460: cannot revoke"),
        csr_error=developer.DeveloperServicesError("7460: maximum certificates reached"),
    )

    with pytest.raises(gsa.GsaError) as excinfo:
        provision._ensure_certificate(TEAM, None)

    message = str(excinfo.value)
    assert "maximum certificates reached" in message
    assert "cannot revoke" in message
    assert "Apple Developer portal" in message, "say how to get out of it"
    assert fake.machine_names, "the request should still have been attempted"


# Apple's own sentence for the limit says "you already have a current certificate", which reads
# as if iPASide had made one. On a free account holding two other tools' certificates it had not
# (GitHub issue #14): the message must name them and say how to get out.
LIMIT_TEXT = "You already have a current iOS Development certificate or a pending certificate request."
ILOADER = {"serialNumber": "AAAA01", "machineName": "iloader", "name": "iOS Development: Someone"}
CUSTOM = {"serialNumber": "BBBB02", "machineName": "Work laptop", "name": "iOS Development: Someone"}


def test_the_certificate_limit_names_the_other_tools_and_says_how_to_continue(portal):
    fake = portal([ILOADER, CUSTOM], csr_error=developer.DeveloperServicesError(f"7460: {LIMIT_TEXT}"))

    with pytest.raises(gsa.GsaError) as excinfo:
        provision._ensure_certificate(TEAM, None)

    message = str(excinfo.value)
    assert "iloader" in message and "Work laptop" in message
    assert "Account page" in message and "revoke one of them" in message
    assert "never revokes a certificate it did not create" in message
    assert "stop opening" in message, "say what revoking costs"
    assert LIMIT_TEXT in message, "Apple's own words stay in it"
    assert fake.revoked == [], "another tool's certificate must still be left alone"


def test_the_limit_is_recognised_by_apples_words_when_the_code_is_missing(portal):
    portal([ILOADER], csr_error=developer.DeveloperServicesError(LIMIT_TEXT))

    with pytest.raises(gsa.GsaError, match="revoke one of them"):
        provision._ensure_certificate(TEAM, None)


def test_the_limit_after_our_own_certificate_was_revoked_still_names_the_others(portal):
    fake = portal([OURS, ILOADER], csr_error=developer.DeveloperServicesError(f"7460: {LIMIT_TEXT}"))

    with pytest.raises(gsa.GsaError) as excinfo:
        provision._ensure_certificate(TEAM, None)

    message = str(excinfo.value)
    assert "(iloader)" in message, "only the other tool is listed; our own certificate is not 'another tool'"
    assert fake.revoked == [OURS["serialNumber"]]


def test_an_unnamed_certificate_is_still_reported(portal):
    portal([{"serialNumber": "NONAME01"}], csr_error=developer.DeveloperServicesError("7460: limit"))

    with pytest.raises(gsa.GsaError, match="an unnamed certificate"):
        provision._ensure_certificate(TEAM, None)


def test_each_other_tool_is_named_once(portal):
    twin = dict(ILOADER, serialNumber="AAAA02")
    portal([ILOADER, twin], csr_error=developer.DeveloperServicesError("7460: limit"))

    with pytest.raises(gsa.GsaError) as excinfo:
        provision._ensure_certificate(TEAM, None)

    assert str(excinfo.value).count("iloader") == 1


def test_the_limit_with_nothing_else_on_the_account_is_reported_as_apple_put_it(portal):
    portal([], csr_error=developer.DeveloperServicesError(f"7460: {LIMIT_TEXT}"))

    with pytest.raises(developer.DeveloperServicesError, match="already have a current"):
        provision._ensure_certificate(TEAM, None)


def test_another_refusal_is_not_blamed_on_other_tools_certificates(portal):
    portal([ILOADER], csr_error=developer.DeveloperServicesError("3004: something else entirely"))

    with pytest.raises(developer.DeveloperServicesError, match="something else entirely"):
        provision._ensure_certificate(TEAM, None)


def test_a_failed_request_alone_is_reported_as_apple_put_it(portal):
    """With nothing else to add, Apple's own message is the most useful one."""
    portal([], csr_error=developer.DeveloperServicesError("7460: something else"))

    with pytest.raises(developer.DeveloperServicesError, match="something else"):
        provision._ensure_certificate(TEAM, None)


def test_a_failed_revocation_alone_does_not_stop_a_working_request(portal):
    """The certificate may simply already be gone; the request is the real test."""
    fake = portal([OURS], revoke_error=developer.DeveloperServicesError("already revoked"))

    _key, _der, serial = provision._ensure_certificate(TEAM, None)

    assert serial == "NEWLYISSUED0001"
    assert fake.machine_names == [provision.CERTIFICATE_MACHINE_NAME]
