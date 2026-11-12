"""CMS, certificates, CodeResources, and Mach-O signature replacement."""

from __future__ import annotations

import plistlib
from pathlib import Path

from ipaside_engine.signer import asn1, cms, code_resources, macho, x509_reader

_CERT = bytes.fromhex("""
308203443082022ca00302010202051a2b3c4d5e300d06092a864886f70d01010b050030393124302206035504
030c1b5465746865726c657373205465737420436f6d6d6f6e204e616d653111300f060355040a0c0854657374
204f7267301e170d3236313033303133313035345a170d3237313033303133313035345a30393124302206035504
030c1b5465746865726c657373205465737420436f6d6d6f6e204e616d653111300f060355040a0c0854657374
204f726730820122300d06092a864886f70d01010105000382010f003082010a02820101008a7d1f134650b94b
117d61c2eea650a8d805fa96c31176868ca8e0ebf22d16900b765352b6f5ff24194d9f43418d5c15e2e3aed5d6f0
a9bf342d1d07391a3978605ca419a620a10318c2efa0b7dd5835002b633e52a742041d863416531ae5e6f0bae50f
b5a3ff9a6bbee710c7aaa57cd42e7cf1061b3582c578ebc4f218d6ed9a5c04e391c8db16dda69874986bd10761965
c27f4605e4cb40851ae46dba364bccc96597b4e94a927bc91f895c8410e5516c707e5e1b85ddf4f18258adcd34f0
7654f23c0a87fda44b2f17b2fe214ca89f91e0eb1d9ef0b25f34676b1b3ddc3d2810e118837e8bbf5d395d9108e4
27660f4d3d03fd92d75654f9f5557b113950203010001a3533051301d0603551d0e04160414637d800700863c54
6d6f8c27ade16b62db3a7d99301f0603551d23041830168014637d800700863c546d6f8c27ade16b62db3a7d9930
0f0603551d130101ff040530030101ff300d06092a864886f70d01010b050003820101007dfe2b6a5e9b2497f35
3ca9086478e052c1ae916b18205581be9d7d8530850cd3d03798d9ac23ac6f5597d699e1ab9897e2610fe942f63e
738c943258a434f964b340dc60cd5689675ce598253130fbefd82aae2830bc61bd56de2fd7b1e83cc32303d22aca
25735c049abf8123dbb377bd2fdf04c1c3d359b0daf8239439a7bae911e39aff65e5f540c5b224fab998d7302a74
569481b30463b5a5778caab21ed89c2ad670af18c4b6618aa1ff3e19866b6650d24571c46c11b1d95cdebb0b9a82
82b7c7487a5224c23cfb846f7fb6bb7aba879b6e75b42826d88e9e577bd5f595007bb941a5432f3169e4446fb316
c13f08381fc9dae72ceeccac672e6a219
""".replace("\n", "").replace(" ", ""))


def test_cms_attributes_and_real_certificate():
    plist = cms.cd_hashes_plist([bytes(range(20)), bytes(range(100, 120))])
    assert plist.startswith(b"<?xml")
    parsed = plistlib.loads(plist)
    assert list(parsed["cdhashes"][0]) == list(range(20))

    fake_cd = b"fake-code-directory-bytes"
    fake_plist = b"fake-plist-bytes"
    fake_digest = b"\x11" * 32
    data_to_sign, implicit = cms.prepare_signing(fake_cd, fake_plist, fake_digest)
    assert data_to_sign[0] == 0x31
    assert implicit[0] == 0xA0
    assert data_to_sign[2:] == implicit[2:]

    fields = x509_reader.read(_CERT)
    assert fields.subject_common_name == "Tetherless Test Common Name"
    assert fields.serial_number_content == bytes.fromhex("1a2b3c4d5e")
    signature = bytes(index % 256 for index in range(256))
    assembled = cms.assemble([_CERT], fields.issuer_full_der, fields.serial_number_content, implicit, signature)
    assert assembled[0] == 0x30
    assert _CERT in assembled
    assert signature in assembled
    assert implicit in assembled


def test_x509_rejects_garbage():
    try:
        x509_reader.read(b"\x00\x01\x02")
        raise AssertionError("short certificate should fail")
    except x509_reader.CertificateError:
        pass


def test_code_resources_rules_and_plist_data(tmp_path: Path):
    root = tmp_path / "App.app"
    (root / "en.lproj").mkdir(parents=True)
    (root / "_CodeSignature").mkdir()
    (root / "Info.plist").write_bytes(b"info")
    (root / "TetherlessApp").write_bytes(b"exe")
    (root / "Assets.car").write_bytes(b"assets")
    (root / "en.lproj" / "InfoPlist.strings").write_bytes(b"strings")
    (root / "en.lproj" / "locversion.plist").write_bytes(b"locver")
    (root / "_CodeSignature" / "CodeResources").write_bytes(b"old")
    found = set(code_resources.enumerate_bundle_files(root, "TetherlessApp"))
    assert "TetherlessApp" not in found
    assert "_CodeSignature/CodeResources" not in found
    assert found == {"Info.plist", "Assets.car", "en.lproj/InfoPlist.strings", "en.lproj/locversion.plist"}

    entries = [
        code_resources.FileEntry("Assets.car", b"AAAA", b"BBBB"),
        code_resources.FileEntry("en.lproj/InfoPlist.strings", b"CCCC", b"DDDD"),
        code_resources.FileEntry("en.lproj/locversion.plist", b"EEEE", b"FFFF"),
        code_resources.FileEntry("Info.plist", b"GGGG", b"HHHH"),
        code_resources.FileEntry("PkgInfo", b"IIII", b"JJJJ"),
        code_resources.FileEntry(".DS_Store", b"KKKK", b"LLLL"),
    ]
    result = code_resources.build(entries)
    assert result["files"]["Assets.car"] == b"AAAA"
    assert "en.lproj/locversion.plist" not in result["files"]
    assert "PkgInfo" in result["files"]
    assert "Info.plist" not in result["files2"]
    assert result["files2"]["Assets.car"]["hash2"] == b"BBBB"
    xml = plistlib.dumps(result, fmt=plistlib.FMT_XML)
    assert b"<data>" in xml
    assert b"data:AAAA" not in xml


def _macho(code_limit: int = 256, signature: int = 32) -> bytes:
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
    body += bytes([0xAB]) * (code_limit - len(body))
    body += bytes([0xCD]) * signature
    return body


def test_macho_signature_replacement_grows_linkedit():
    original = _macho()
    info = macho.parse_slice(original)
    assert info.code_limit == 256
    assert info.existing_signature_size == 32
    assert info.is_main_executable
    patched = macho.replace_signature(original, info, b"\x11" * 64)
    again = macho.parse_slice(patched)
    assert again.existing_signature_size == 64
    assert patched[256:] == b"\x11" * 64
    assert macho.code_data(original, info) == original[:256]
    try:
        macho.parse_slice(b"\x00\x01\x02\x03")
        raise AssertionError("not a macho")
    except macho.MachOError:
        pass
