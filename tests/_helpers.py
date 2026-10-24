"""Builders for self-contained test fixtures: standard/CgBI PNGs, minimal IPAs,
and synthetic .debs (ar -> data.tar.* -> a fake Mach-O dylib)."""

from __future__ import annotations

import io
import plistlib
import struct
import tarfile
import zipfile
import zlib
from pathlib import Path


def _chunk(ctype: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + ctype + data + struct.pack(">I", zlib.crc32(ctype + data) & 0xFFFFFFFF)


def make_png(width: int = 4, height: int = 4, rgba: bytes | None = None) -> bytes:
    """A standard 8-bit RGBA PNG (filter type 0 per row)."""
    if rgba is None:
        rgba = bytes([120, 80, 200, 255]) * (width * height)
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr)
            + _chunk(b"IDAT", zlib.compress(bytes(raw))) + _chunk(b"IEND", b""))


def make_cgbi_png(width: int, height: int, rgba: bytes) -> bytes:
    """An iOS-optimized (CgBI) PNG: byte-swapped BGRA, premultiplied, headerless DEFLATE."""
    px = bytearray(rgba)
    for i in range(0, len(px), 4):
        r, g, b, a = px[i], px[i + 1], px[i + 2], px[i + 3]
        px[i] = (b * a + 127) // 255
        px[i + 1] = (g * a + 127) // 255
        px[i + 2] = (r * a + 127) // 255
        px[i + 3] = a
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += px[y * stride:(y + 1) * stride]
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    comp = compressor.compress(bytes(raw)) + compressor.flush()
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"CgBI", b"\x50\x00\x20\x06")
            + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", comp) + _chunk(b"IEND", b""))


def decode_png_filter0(data: bytes) -> tuple[int, int, bytes]:
    """Decode a filter-0 8-bit RGBA PNG (as produced by _normalize_png) to raw pixels."""
    off, ihdr, idat = 8, b"", bytearray()
    while off + 12 <= len(data):
        length = struct.unpack_from(">I", data, off)[0]
        ctype = data[off + 4:off + 8]
        body = data[off + 8:off + 8 + length]
        off += 12 + length
        if ctype == b"IHDR":
            ihdr = body
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break
    width, height = struct.unpack_from(">II", ihdr, 0)
    raw = zlib.decompress(bytes(idat))
    stride = width * 4
    out, pos = bytearray(), 0
    for _ in range(height):
        assert raw[pos] == 0, "expected filter type 0"
        pos += 1
        out += raw[pos:pos + stride]
        pos += stride
    return width, height, bytes(out)


def make_ipa(path: Path, *, bundle_id: str = "com.test.app", name: str = "Test App",
             version: str = "1.0", icon_png: bytes | None = None,
             with_extension: bool = False, executable: bytes | None = None,
             minimum_os: str = "14.0") -> Path:
    """A minimal but valid IPA (Payload/<App>.app/Info.plist [+ icon] [+ appex])."""
    info: dict = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleDisplayName": name,
        "CFBundleName": name,
        "CFBundleExecutable": "TestApp",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "1",
        "MinimumOSVersion": minimum_os,
    }
    if icon_png is not None:
        info["CFBundleIcons"] = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon60x60"]}}
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("Payload/Test.app/Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        zf.writestr(
            "Payload/Test.app/TestApp",
            executable if executable is not None else b"\xca\xfe\xba\xbe placeholder",
        )
        if icon_png is not None:
            zf.writestr("Payload/Test.app/AppIcon60x60@2x.png", icon_png)
        if with_extension:
            zf.writestr("Payload/Test.app/PlugIns/Widget.appex/Info.plist",
                        plistlib.dumps({"CFBundleIdentifier": bundle_id + ".widget"}, fmt=plistlib.FMT_BINARY))
    return path


def thin_macho(cputype: int = 0x0100000C, cpusubtype: int = 0) -> bytes:
    """A minimal little-endian 64-bit Mach-O header (on-disk magic bytes CF FA ED FE)."""
    return struct.pack("<8I", 0xFEEDFACF, cputype, cpusubtype, 6, 0, 0, 0, 0)


def _ar_member(name: str, content: bytes) -> bytes:
    header = (
        name.ljust(16)
        + "0".ljust(12)       # mtime
        + "0".ljust(6)        # uid
        + "0".ljust(6)        # gid
        + "100644".ljust(8)   # mode
        + str(len(content)).ljust(10)
        + "`\n"
    ).encode("ascii")
    blob = header + content
    if len(content) & 1:
        blob += b"\n"  # ar members are 2-byte aligned
    return blob


def make_deb(path: Path, dylib: bytes, *, member: str, comp: str = "gz") -> Path:
    """A synthetic .deb: an ar archive of debian-binary + data.tar.<comp> holding one file."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode={"gz": "w:gz", "xz": "w:xz", "bz2": "w:bz2"}[comp]) as tar:
        info = tarfile.TarInfo(member)
        info.size = len(dylib)
        tar.addfile(info, io.BytesIO(dylib))
    path.write_bytes(
        b"!<arch>\n" + _ar_member("debian-binary", b"2.0\n") + _ar_member(f"data.tar.{comp}", buf.getvalue())
    )
    return path
