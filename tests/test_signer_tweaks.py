"""Compression, Substrate injection, and extension App ID nesting."""

from __future__ import annotations

import zipfile

from ipaside_engine import zip_copy
from ipaside_engine.provision import scoped_extension_bundle_id
from ipaside_engine.signer import macho, tweaks


def _u32(value: int) -> bytes:
    return value.to_bytes(4, "little")


def _u64(value: int) -> bytes:
    return value.to_bytes(8, "little")


def _name(text: str) -> bytes:
    return text.encode() + bytes(16 - len(text))


def _load(path: str) -> bytes:
    encoded = path.encode()
    padded = ((len(encoded) // 8) + 1) * 8
    return _u32(0xC) + _u32(24 + padded) + _u32(24) + _u32(0) + _u32(0) + _u32(0) + encoded + bytes(padded - len(encoded))


def _macho(code_limit: int = 4096, extra: bytes = b"") -> bytes:
    signature = 64
    text = _u32(0x19) + _u32(72) + _name("__TEXT") + _u64(0) + _u64(0x4000) + _u64(0) + _u64(code_limit)
    text += _u32(7) + _u32(5) + _u32(0) + _u32(0)
    link = _u32(0x19) + _u32(72) + _name("__LINKEDIT") + _u64(code_limit) + _u64(signature)
    link += _u64(code_limit) + _u64(signature) + _u32(7) + _u32(1) + _u32(0) + _u32(0)
    sig = _u32(0x1D) + _u32(16) + _u32(code_limit) + _u32(signature)
    commands = text + extra + link + sig
    header = _u32(0xFEEDFACF) + _u32(0x0100000C) + _u32(0) + _u32(2)
    header += _u32(3 + (1 if extra else 0)) + _u32(len(commands)) + _u32(0) + _u32(0)
    body = header + commands
    return body + bytes(code_limit - len(body)) + bytes(signature)


def test_changed_files_are_stored_when_deflate_does_not_shrink(tmp_path):
    method, payload = zip_copy._compress_if_smaller(b"a" * 1000, 6)
    assert method == zipfile.ZIP_DEFLATED
    assert len(payload) < 1000
    assert zip_copy._compress_if_smaller(b"a" * 1000, 0)[0] == zipfile.ZIP_STORED

    source = tmp_path / "in.zip"
    output = tmp_path / "out.zip"
    with zipfile.ZipFile(source, "w") as archive:
        archive.writestr("pad.txt", b"a" * 1000)
    zip_copy.repack(source, output, replace={"pad.txt": b"a" * 1000})
    with zipfile.ZipFile(output) as archive:
        assert archive.getinfo("pad.txt").compress_type == zipfile.ZIP_DEFLATED
        assert archive.read("pad.txt") == b"a" * 1000


def test_a_substrate_tweak_is_rewritten_and_loaded_from_frameworks(tmp_path):
    app = tmp_path / "Payload" / "Demo.app"
    app.mkdir(parents=True)
    main = "Payload/Demo.app/Demo"
    (tmp_path / main).write_bytes(_macho())
    tweak = tmp_path / "Widget.dylib"
    tweak.write_bytes(_macho(extra=_load("/usr/lib/libsubstrate.dylib")))
    files: dict[str, bytes] = {main: (tmp_path / main).read_bytes()}

    def read(name: str) -> bytes:
        return files[name]

    def write(name: str, data: bytes) -> None:
        files[name] = data

    loaded = tweaks.inject(
        read, write, "Payload/Demo.app/", main, [str(tweak)], provider="legacy",
    )
    assert loaded == ["@executable_path/Frameworks/Widget.dylib"]
    found = macho.find_dylib_load_command(files[main], lambda path: path.endswith("Widget.dylib"))
    assert found is not None and found[2].endswith("Widget.dylib")
    rewritten = files["Payload/Demo.app/Frameworks/Widget.dylib"]
    provider = macho.find_dylib_load_command(rewritten, tweaks.is_substrate_reference)
    assert provider is not None
    assert provider[2] == "@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
    assert files["Payload/Demo.app/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"]


def test_an_extension_app_id_stays_under_the_scoped_app_id():
    assert scoped_extension_bundle_id(
        "com.example", "com.example.TEAM", "com.example.Widget",
    ) == "com.example.TEAM.Widget"
    try:
        scoped_extension_bundle_id("com.example", "com.example.TEAM", "com.other.Widget")
        raise AssertionError("a mismatched extension id should fail")
    except Exception as exc:
        assert "com.other.Widget" in str(exc)
