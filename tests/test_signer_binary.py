"""A synthetic Mach-O signed with a throwaway key must verify against its certificate."""

from __future__ import annotations

import datetime

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

from ipaside_engine.signer import binary, macho
from ipaside_engine.signer.apple_root import APPLE_ROOT_CA


def _macho() -> bytes:
    def u32(value: int) -> bytes:
        return value.to_bytes(4, "little")

    def u64(value: int) -> bytes:
        return value.to_bytes(8, "little")

    code_limit, signature = 512, 64
    text = u32(0x19) + u32(72) + b"__TEXT" + bytes(10)
    text += u64(0) + u64(0x4000) + u64(0) + u64(code_limit) + u32(7) + u32(5) + u32(0) + u32(0)
    link = u32(0x19) + u32(72) + b"__LINKEDIT" + bytes(6)
    link += u64(code_limit) + u64(signature) + u64(code_limit) + u64(signature) + u32(7) + u32(1) + u32(0) + u32(0)
    sig = u32(0x1D) + u32(16) + u32(code_limit) + u32(signature)
    commands = text + link + sig
    header = u32(0xFEEDFACF) + u32(0x0100000C) + u32(0) + u32(2) + u32(3) + u32(len(commands)) + u32(0) + u32(0)
    body = header + commands
    return body + bytes(code_limit - len(body)) + bytes(signature)


def test_signed_macho_matches_its_certificate():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "iPhone Developer: Test")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(0x1A2B3C4D5E)
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=30))
        .sign(key, hashes.SHA256())
    )
    signed = binary.sign_macho(
        _macho(),
        "com.example.app",
        "TEAMID1234",
        cert.public_bytes(serialization.Encoding.DER),
        key.private_bytes(
            serialization.Encoding.DER,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ),
        cert.public_bytes(serialization.Encoding.DER),
        info_plist=b"<plist/>",
        entitlement_values={"get-task-allow": True, "application-identifier": "TEAMID1234.com.example.app"},
    )
    info = macho.parse_slice(signed)
    assert signed[info.code_limit:info.code_limit + 4] == b"\xfa\xde\x0c\xc0"
    assert info.existing_signature_size == len(signed) - info.code_limit
    assert APPLE_ROOT_CA in signed
    assert b"com.example.app" in signed


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
    return (
        cert.public_bytes(serialization.Encoding.DER),
        key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()),
    )


def _unsigned() -> bytes:
    def u32(value: int) -> bytes:
        return value.to_bytes(4, "little")

    def u64(value: int) -> bytes:
        return value.to_bytes(8, "little")

    code_limit = 512
    text = u32(0x19) + u32(72) + b"__TEXT" + bytes(10)
    text += u64(0) + u64(0x4000) + u64(0) + u64(code_limit) + u32(7) + u32(5) + u32(0) + u32(0)
    link = u32(0x19) + u32(72) + b"__LINKEDIT" + bytes(6)
    link += u64(code_limit) + u64(0) + u64(code_limit) + u64(0) + u32(7) + u32(1) + u32(0) + u32(0)
    commands = text + link
    header = u32(0xFEEDFACF) + u32(0x0100000C) + u32(0) + u32(2) + u32(2) + u32(len(commands)) + u32(0) + u32(0)
    body = header + commands
    return body + bytes(code_limit - len(body))


def test_a_macho_without_a_signature_can_be_signed():
    cert, key = _identity()
    signed = binary.sign_macho(
        _unsigned(), "com.example.helper", "TEAMID1234", cert, key, cert,
    )
    info = macho.parse_slice(signed)
    assert signed[info.code_limit:info.code_limit + 4] == b"\xfa\xde\x0c\xc0"
    assert info.existing_signature_size > 0


def test_the_livecontainer_helper_dylib_can_be_signed():
    from pathlib import Path

    helper = Path(__file__).resolve().parents[1] / "src/iPASide.Engine/ipaside_engine/vendor/iPASideCertImport.dylib"
    if not helper.is_file():
        return
    cert, key = _identity()
    signed = binary.sign_macho(helper.read_bytes(), "com.ipaside.certimport", "TEAMID1234", cert, key, cert)
    info = macho.parse_slice(signed)
    assert signed[info.code_limit:info.code_limit + 4] == b"\xfa\xde\x0c\xc0"
