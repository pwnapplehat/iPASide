"""The signer is called with the sideload options. Behavior is covered in test_signer_ipa."""

from ipaside_engine import signing


def test_resolve_helper_dylib_honours_the_env_override(monkeypatch, tmp_path):
    dylib = tmp_path / "iPASideCertImport.dylib"
    dylib.write_bytes(b"\xcf\xfa\xed\xfe")
    monkeypatch.setenv("IPASIDE_CERT_IMPORT_DYLIB", str(dylib))
    assert signing.resolve_helper_dylib() == str(dylib)


def test_resolve_helper_dylib_is_none_when_not_shipped(monkeypatch, tmp_path):
    """A build without the dylib falls back to a manual import rather than failing."""
    monkeypatch.delenv("IPASIDE_CERT_IMPORT_DYLIB", raising=False)
    monkeypatch.setattr(signing.paths, "resource_dir", lambda: tmp_path)
    monkeypatch.setattr(signing.sys, "executable", str(tmp_path / "python.exe"))
    assert signing.resolve_helper_dylib() is None


def test_sign_ipa_raises_when_the_identity_is_missing():
    try:
        signing.sign_ipa("in.ipa", "out.ipa", p12_path="missing.p12", p12_password="w", profile_path="m")
        raise AssertionError("expected SigningError")
    except signing.SigningError as exc:
        assert "missing.p12" in str(exc)
