"""Unsigned IPA export: a load command is inserted and nothing is signed."""

from __future__ import annotations

import plistlib
import struct
import zipfile
from pathlib import Path

from ipaside_engine import ipa
from ipaside_engine.macho_inject import inject_load_dylib


def _thin_executable() -> bytearray:
    """A 64-bit little-endian Mach-O whose __text starts at offset 4096."""
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 152, 0, 0)
    segment = bytearray(72)
    struct.pack_into("<II", segment, 0, 0x19, 152)
    segment[8:14] = b"__TEXT"
    struct.pack_into("<I", segment, 64, 1)  # nsects
    section = bytearray(80)
    section[0:6] = b"__text"
    section[16:22] = b"__TEXT"
    struct.pack_into("<I", section, 48, 4096)
    blob = bytearray(4096)
    blob[:32] = header
    blob[32:32 + 72] = segment
    blob[32 + 72:32 + 72 + 80] = section
    return blob


def test_inject_adds_one_weak_load_command():
    blob = _thin_executable()
    inject_load_dylib(blob, "@executable_path/Tweak.dylib", weak=True)
    ncmds, sizeofcmds = struct.unpack_from("<II", blob, 16)
    assert ncmds == 2
    assert b"@executable_path/Tweak.dylib" in bytes(blob)
    assert sizeofcmds > 152
    inject_load_dylib(blob, "@executable_path/Tweak.dylib", weak=True)
    assert struct.unpack_from("<I", blob, 16)[0] == 2


def test_export_unsigned_keeps_the_tweak_and_skips_signing(tmp_path: Path):
    app = tmp_path / "src" / "Payload" / "Demo.app"
    app.mkdir(parents=True)
    info = {
        "CFBundleExecutable": "Demo",
        "CFBundleIdentifier": "com.example.demo",
        "CFBundleDisplayName": "Demo",
        "UISupportedDevices": ["iPhone14,2"],
    }
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    (app / "Demo").write_bytes(_thin_executable())
    plugins = app / "PlugIns" / "Widget.appex"
    plugins.mkdir(parents=True)
    (plugins / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.widget"}))
    tweak = tmp_path / "DemoTweak.dylib"
    tweak.write_bytes(_thin_executable())
    source = tmp_path / "Demo.ipa"
    with zipfile.ZipFile(source, "w") as zf:
        for path in (tmp_path / "src").rglob("*"):
            if path.is_file():
                zf.write(path, path.relative_to(tmp_path / "src").as_posix())

    output = tmp_path / "out" / "Demo.ipa"
    report = ipa.export_unsigned(
        str(source),
        str(output),
        display_name="Tweaked",
        enable_file_sharing=True,
        dylibs=[str(tweak)],
        weak_dylibs=True,
    )

    assert report["injected"] == ["@executable_path/DemoTweak.dylib"]
    assert report["removed"] == ["PlugIns"]
    with zipfile.ZipFile(output) as zf:
        names = set(zf.namelist())
        assert "Payload/Demo.app/PlugIns/Widget.appex/Info.plist" not in names
        assert "Payload/Demo.app/DemoTweak.dylib" in names
        exe = zf.read("Payload/Demo.app/Demo")
        plist = plistlib.loads(zf.read("Payload/Demo.app/Info.plist"))
    assert b"@executable_path/DemoTweak.dylib" in exe
    assert plist["CFBundleDisplayName"] == "Tweaked"
    assert plist["UIFileSharingEnabled"] is True
    assert "UISupportedDevices" not in plist
    assert b"Apple" not in exe[:32]
