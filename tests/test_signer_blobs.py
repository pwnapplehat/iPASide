"""The Tetherless host tests for the signature blobs, in pytest."""

from __future__ import annotations

import hashlib

from ipaside_engine.signer import asn1, code_directory, entitlements, requirements, superblob
from ipaside_engine.signer.format import (
    CODE_DIRECTORY,
    EMBEDDED_DER_ENTITLEMENTS,
    EMBEDDED_ENTITLEMENTS,
    EMBEDDED_SIGNATURE,
    HASH_SHA1,
    HASH_SHA256,
    REQUIREMENT,
    REQUIREMENTS,
    SLOT_CODE_DIRECTORY,
    SLOT_ENTITLEMENTS,
    SLOT_REQUIREMENTS,
    read_u32,
    u32,
)


def _hex(data: bytes) -> str:
    return data.hex()


def _contains(haystack: bytes, needle: bytes) -> bool:
    return needle in haystack


def test_asn1_lengths_oids_and_integers():
    assert asn1.length(5) == b"\x05"
    assert asn1.length(127) == b"\x7f"
    assert asn1.length(128) == b"\x81\x80"
    assert asn1.length(300) == b"\x82\x01\x2c"
    assert _hex(asn1.object_identifier("1.2.840.113549.1.1.1")) == "06092a864886f70d010101"
    assert _hex(asn1.object_identifier("1.2.840.113549.1.1.11")) == "06092a864886f70d01010b"
    assert _hex(asn1.object_identifier("2.5.4.3")) == "0603550403"
    assert _hex(asn1.integer_unsigned(b"\x01")) == "020101"
    assert _hex(asn1.integer_unsigned(b"\x00\x01")) == "020101"
    assert _hex(asn1.integer_unsigned(b"\x80")) == "02020080"
    assert _hex(asn1.integer_unsigned(b"\x00\x80")) == "02020080"
    assert _hex(asn1.integer_unsigned(b"\x00")) == "020100"


def test_asn1_structure_and_set_order():
    assert _hex(asn1.null()) == "0500"
    assert _hex(asn1.sequence([asn1.integer_value(1), asn1.integer_value(2)])) == "3006020101020102"
    assert _hex(asn1.set_of([asn1.integer_value(1)])) == "3103020101"
    assert _hex(asn1.bit_string(b"\xaa\xbb")) == "030300aabb"
    assert _hex(asn1.utf8_string("AB")) == "0c024142"
    assert _hex(asn1.explicit_context(0, asn1.integer_value(1))) == "a003020101"
    assert _hex(asn1.implicit_context(0, b"", constructed=True)) == "a000"

    a, b, c = b"\x01\xff", b"\x02\x00", b"\x03"
    assert asn1.canonical_set_content([c, a, b]) == a + b + c
    short, long_zero, long_one = b"\x05", b"\x05\x00", b"\x05\x01"
    assert asn1.canonical_set_content([long_one, short]) == short + long_one
    assert asn1.canonical_set_content([short, long_zero]) == short + long_zero
    assert asn1.canonical_set_content([long_zero, short]) == long_zero + short
    short_form, long_form = b"\x30\x3d", b"\x30\x81\x90"
    assert asn1.canonical_set_content([long_form, short_form]) == short_form + long_form


def test_code_directory_round_trip():
    one_short = bytes([0xAB]) * (code_directory.PAGE_SIZE - 1)
    assert len(code_directory.code_page_hashes(one_short, HASH_SHA256)) == 1
    two_pages = bytes([0xCD]) * (code_directory.PAGE_SIZE * 2)
    assert len(code_directory.code_page_hashes(two_pages, HASH_SHA256)) == 2
    over = bytes([0xEF]) * (code_directory.PAGE_SIZE + 1)
    assert len(code_directory.code_page_hashes(over, HASH_SHA256)) == 2
    page = two_pages[: code_directory.PAGE_SIZE]
    assert code_directory.code_page_hashes(two_pages, HASH_SHA256)[0] == hashlib.sha256(page).digest()

    code_data = bytes(index % 256 for index in range(code_directory.PAGE_SIZE + 500))
    slots = code_directory.SpecialSlots(
        info_plist=hashlib.sha256(b"fake-info-plist").digest(),
        requirements=hashlib.sha256(b"fake-requirements").digest(),
        resource_directory=hashlib.sha256(b"fake-coderesources").digest(),
        entitlements=hashlib.sha256(b"fake-entitlements").digest(),
        der_entitlements=hashlib.sha256(b"fake-der-entitlements").digest(),
    )
    blob = code_directory.build(
        "com.tetherless.test.ABCD123456", "ABCD123456", code_data, slots, HASH_SHA256
    )
    assert len(blob) == read_u32(blob, 4)
    parsed = code_directory.parse(blob)
    assert parsed.magic == CODE_DIRECTORY
    assert parsed.version == 0x00020400
    assert parsed.identifier == "com.tetherless.test.ABCD123456"
    assert parsed.team_id == "ABCD123456"
    assert parsed.hash_type == HASH_SHA256
    assert parsed.hash_size == 32
    assert parsed.n_special_slots == 7
    assert parsed.code_hashes == code_directory.code_page_hashes(code_data, HASH_SHA256)
    assert parsed.code_limit == len(code_data)
    assert parsed.special_slot_hashes[6] == slots.info_plist
    assert parsed.special_slot_hashes[0] == slots.der_entitlements
    assert parsed.special_slot_hashes[3] == bytes(32)
    assert parsed.special_slot_hashes[1] == bytes(32)

    primary = code_directory.build("x", None, code_data, code_directory.SpecialSlots(), HASH_SHA1)
    parsed_primary = code_directory.parse(primary)
    assert parsed_primary.hash_type == HASH_SHA1
    assert parsed_primary.hash_size == 20
    assert parsed_primary.team_id is None

    try:
        code_directory.parse(b"\x00\x01\x02")
        raise AssertionError("short blob should fail")
    except code_directory.CodeDirectoryError:
        pass
    bad = bytearray(blob)
    bad[0] = 0xFF
    try:
        code_directory.parse(bytes(bad))
        raise AssertionError("bad magic should fail")
    except code_directory.CodeDirectoryError:
        pass


def test_requirements_match_an_independent_layout():
    bundle_id = "com.tetherless.test"
    subject = "iPhone Developer: Test User (ABCDEF1234)"
    wwdr = bytes([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x06, 0x02, 0x01])

    def padded(data: bytes) -> bytes:
        pad = (4 - (len(data) % 4)) % 4
        return u32(len(data)) + data + bytes(pad)

    expr = bytearray()
    expr += u32(1) + u32(6) + u32(2) + padded(bundle_id.encode())
    expr += u32(6) + u32(15)
    expr += u32(6) + u32(11) + u32(0) + padded(b"subject.CN") + u32(1) + padded(subject.encode())
    expr += u32(14) + u32(1) + padded(wwdr) + u32(0)
    inner = 8 + len(expr)
    expected = u32(REQUIREMENTS) + u32(20 + inner) + u32(1) + u32(3) + u32(20)
    expected += u32(REQUIREMENT) + u32(inner) + bytes(expr)
    actual = requirements.build(bundle_id, subject)
    assert actual == expected
    assert read_u32(actual, 4) == len(actual)
    assert read_u32(actual, 20) == REQUIREMENT
    assert len(actual) % 4 == 0
    assert bundle_id.encode() in actual and subject.encode() in actual and wwdr in actual
    empty = requirements.build_empty()
    assert empty == u32(REQUIREMENTS) + u32(12) + u32(0)


def test_entitlements_plain_and_der():
    xml = b"<plist><dict/></plist>"
    plain = entitlements.build_plain(xml)
    assert read_u32(plain, 0) == EMBEDDED_ENTITLEMENTS
    assert read_u32(plain, 4) == len(xml) + 8
    assert plain[8:] == xml
    assert entitlements.encode_value(True) == asn1.boolean(True)
    assert entitlements.encode_value(42) == asn1.integer_value(42)
    data = {
        "get-task-allow": True,
        "application-identifier": "TEAM123.com.tetherless.test",
    }
    entries = [
        asn1.sequence([asn1.utf8_string("application-identifier"), asn1.utf8_string("TEAM123.com.tetherless.test")]),
        asn1.sequence([asn1.utf8_string("get-task-allow"), asn1.boolean(True)]),
    ]
    expected_dict = asn1.tlv(0xB0, b"".join(entries))
    assert entitlements.encode_value(data) == expected_dict
    full = entitlements.build_der(data)
    assert read_u32(full, 0) == EMBEDDED_DER_ENTITLEMENTS
    inner = asn1.tlv(0x70, asn1.integer_value(1) + expected_dict)
    assert full[8:] == inner


def test_superblob_round_trip():
    req = b"fake-requirements-blob"
    ent = b"fake-entitlements-blob"
    components = [
        superblob.Component(SLOT_REQUIREMENTS, req),
        superblob.Component(SLOT_CODE_DIRECTORY, b"fake-cd"),
        superblob.Component(SLOT_ENTITLEMENTS, ent),
    ]
    blob = superblob.build(components)
    assert read_u32(blob, 0) == EMBEDDED_SIGNATURE
    assert read_u32(blob, 4) == len(blob)
    parsed = superblob.parse(blob)
    assert [entry.slot for entry in parsed.entries] == [
        SLOT_REQUIREMENTS,
        SLOT_CODE_DIRECTORY,
        SLOT_ENTITLEMENTS,
    ]
    offsets = [entry.offset for entry in parsed.entries]
    assert offsets == sorted(offsets) and len(set(offsets)) == 3
    assert blob[parsed.entries[0].offset:parsed.entries[0].offset + len(req)] == req
    real = requirements.build("com.test.app", "Tester")
    wrapped = superblob.build([superblob.Component(SLOT_REQUIREMENTS, real)])
    extracted = superblob.component_data(wrapped, superblob.parse(wrapped).entries[0])
    assert extracted == real
    try:
        superblob.parse(b"\x00\x01\x02")
        raise AssertionError("short blob should fail")
    except superblob.SuperBlobError:
        pass
