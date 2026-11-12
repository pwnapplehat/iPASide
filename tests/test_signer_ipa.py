"""Sign a synthetic IPA and check the signature, the extension rule, and zip passthrough."""

from __future__ import annotations

import datetime
import io
import plistlib
import zipfile

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

from ipaside_engine import signing
from ipaside_engine.signer import asn1, code_directory, macho, superblob
from ipaside_engine.signer.format import HASH_SHA1, HASH_SHA256
from ipaside_engine.signer.package import sign_package


def _macho(code_limit: int = 512, signature: int = 64) -> bytes:
    def u32(value: int) -> bytes:
        return value.to_bytes(4, "little")

    def u64(value: int) -> bytes:
        return value.to_bytes(8, "little")

    def name(text: str) -> bytes:
        return text.encode() + bytes(16 - len(text))

    text = u32(0x19) + u32(72) + name("__TEXT") + u64(0) + u64(0x4000) + u64(0) + u64(code_limit)
    text += u32(7) + u32(5) + u32(0) + u32(0)
    link = u32(0x19) + u32(72) + name("__LINKEDIT") + u64(code_limit) + u64(signature)
    link += u64(code_limit) + u64(signature) + u32(7) + u32(1) + u32(0) + u32(0)
    sig = u32(0x1D) + u32(16) + u32(code_limit) + u32(signature)
    commands = text + link + sig
    header = u32(0xFEEDFACF) + u32(0x0100000C) + u32(0) + u32(2) + u32(3) + u32(len(commands)) + u32(0) + u32(0)
    body = header + commands
    return body + bytes(code_limit - len(body)) + bytes(signature)


def _plist(**values) -> bytes:
    return plistlib.dumps(values, fmt=plistlib.FMT_XML)


def _profile(entitlements: dict) -> bytes:
    payload = plistlib.dumps({
        "TeamIdentifier": ["TEAM"],
        "Entitlements": entitlements,
        "ProvisionedDevices": ["UDID"],
    })
    encap = asn1.sequence([
        asn1.object_identifier("1.2.840.113549.1.7.1"),
        asn1.explicit_context(0, asn1.octet_string(payload)),
    ])
    signed = asn1.sequence([asn1.integer_value(1), asn1.set_of([asn1.null()]), encap])
    return asn1.sequence([
        asn1.object_identifier("1.2.840.113549.1.7.2"),
        asn1.explicit_context(0, signed),
    ])


def _identity():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "iPhone Developer: Test")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(0x11)
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=30))
        .sign(key, hashes.SHA256())
    )
    cert_der = cert.public_bytes(serialization.Encoding.DER)
    key_der = key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    p12 = serialization.pkcs12.serialize_key_and_certificates(b"test", key, cert, None, serialization.NoEncryption())
    return cert_der, key_der, p12


def _ipa() -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("Payload/Demo.app/Info.plist", _plist(
            CFBundleIdentifier="com.example",
            CFBundleExecutable="Demo",
            UISupportedDevices=["iPhone16,2"],
        ))
        archive.writestr("Payload/Demo.app/Demo", _macho())
        stored = zipfile.ZipInfo("Payload/Demo.app/Assets.car")
        stored.compress_type = zipfile.ZIP_STORED
        archive.writestr(stored, b"assets-stay")
        archive.writestr("Payload/Demo.app/Frameworks/Lib.framework/Info.plist", _plist(
            CFBundleIdentifier="com.example.Lib", CFBundleExecutable="Lib",
        ))
        archive.writestr("Payload/Demo.app/Frameworks/Lib.framework/Lib", _macho())
        archive.writestr("Payload/Demo.app/PlugIns/Widget.appex/Info.plist", _plist(
            CFBundleIdentifier="com.example.Widget", CFBundleExecutable="Widget",
        ))
        archive.writestr("Payload/Demo.app/PlugIns/Widget.appex/Widget", _macho())
        archive.writestr("Payload/Demo.app/Extensions/Odd.appex/Info.plist", _plist(
            CFBundleIdentifier="com.example.Odd", CFBundleExecutable="Odd",
        ))
        archive.writestr("Payload/Demo.app/Extensions/Odd.appex/Odd", _macho())
        archive.writestr("Payload/Demo.app/Watch/Watch.app/Info.plist", b"watch")
    return buffer.getvalue()


def _hash_types(blob: bytes) -> list[int]:
    info = macho.parse_slice(blob)
    signature = blob[info.code_limit:info.code_limit + info.existing_signature_size]
    found = []
    parsed = superblob.parse(signature)
    for entry in parsed.entries:
        component = superblob.component_data(signature, entry)
        if component[:4] == b"\xfa\xde\x0c\x02":
            found.append(code_directory.parse(component).hash_type)
    return found


def test_signed_ipa_strips_extensions_and_keeps_compressed_files(tmp_path, monkeypatch):
    cert_der, key_der, p12 = _identity()
    monkeypatch.setattr("ipaside_engine.signer.wwdr.fetch", lambda _cert: cert_der)
    ipa = tmp_path / "Demo.ipa"
    out = tmp_path / "Demo.signed.ipa"
    profile = tmp_path / "app.mobileprovision"
    identity = tmp_path / "id.p12"
    ipa.write_bytes(_ipa())
    entitlements = {
        "application-identifier": "TEAM.com.example.TEAM",
        "get-task-allow": True,
    }
    profile.write_bytes(_profile(entitlements))
    identity.write_bytes(p12)

    signing.sign_ipa(
        str(ipa), str(out),
        p12_path=str(identity), p12_password="", profile_path=str(profile),
        bundle_id="com.example.TEAM", display_name="Renamed", bundle_version="9.9",
        enable_file_sharing=True, remove_extensions=True, legacy_sha1=True,
        temp_folder=str(tmp_path),
    )

    with zipfile.ZipFile(out) as archive:
        names = set(archive.namelist())
        assert not any("PlugIns/" in name or "Extensions/" in name or "Watch/" in name for name in names)
        assert "Payload/Demo.app/Frameworks/Lib.framework/Lib" in names
        info = plistlib.loads(archive.read("Payload/Demo.app/Info.plist"))
        assert info["CFBundleIdentifier"] == "com.example.TEAM"
        assert info["CFBundleDisplayName"] == "Renamed"
        assert info["CFBundleShortVersionString"] == "9.9"
        assert info["UIFileSharingEnabled"] is True
        assert "UISupportedDevices" not in info
        assets = archive.getinfo("Payload/Demo.app/Assets.car")
        assert assets.compress_type == zipfile.ZIP_STORED
        assert archive.read("Payload/Demo.app/Assets.car") == b"assets-stay"
        demo = archive.read("Payload/Demo.app/Demo")
        lib = archive.read("Payload/Demo.app/Frameworks/Lib.framework/Lib")
        resources = archive.read("Payload/Demo.app/_CodeSignature/CodeResources")
    assert _hash_types(demo) == [HASH_SHA1, HASH_SHA256]
    assert HASH_SHA256 in _hash_types(lib)
    assert b"Payload/Demo.app/Frameworks/Lib.framework/Lib" not in resources
    assert b"Lib" in resources


def test_a_kept_extension_stays_prefixed_by_the_app_id(tmp_path):
    cert_der, key_der, _p12 = _identity()
    ipa = tmp_path / "Demo.ipa"
    out = tmp_path / "kept.ipa"
    ipa.write_bytes(_ipa())
    sign_package(
        str(ipa), str(out),
        certificate_der=cert_der, private_key_der=key_der,
        profile=_profile({"application-identifier": "TEAM.com.example.TEAM", "get-task-allow": True}),
        wwdr_der=cert_der, bundle_id="com.example.TEAM",
        remove_extensions=False, remove_watch=True,
    )
    with zipfile.ZipFile(out) as archive:
        widget = plistlib.loads(archive.read("Payload/Demo.app/PlugIns/Widget.appex/Info.plist"))
        odd = plistlib.loads(archive.read("Payload/Demo.app/Extensions/Odd.appex/Info.plist"))
        signed_odd = archive.read("Payload/Demo.app/Extensions/Odd.appex/Odd")
        assert "Watch/" not in "".join(archive.namelist())
    assert widget["CFBundleIdentifier"] == "com.example.TEAM.Widget"
    assert odd["CFBundleIdentifier"] == "com.example.TEAM.Odd"
    assert b"\xfa\xde\x0c\xc0" in signed_odd
