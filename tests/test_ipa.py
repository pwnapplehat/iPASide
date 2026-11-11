"""IPA inspection + PNG normalization (icon extraction)."""

import zipfile

import pytest

from _helpers import decode_png_filter0, make_cgbi_png, make_ipa, make_png

from ipaside_engine import ipa
from ipaside_engine.errors import EngineError


def test_inspect_reads_identity(tmp_path):
    path = make_ipa(tmp_path / "a.ipa", bundle_id="com.foo.bar", name="Foo",
                    version="2.3", with_extension=True)
    report = ipa.inspect(str(path))
    assert report["bundle_id"] == "com.foo.bar"
    assert report["display_name"] == "Foo"
    assert report["version"] == "2.3"
    assert report["extensions"] == ["Widget.appex"]
    assert report["has_sc_info"] is False


def test_inspect_extracts_icon_as_data_uri(tmp_path):
    path = make_ipa(tmp_path / "b.ipa", icon_png=make_png(8, 8))
    report = ipa.inspect(str(path))
    assert report["icon"] and report["icon"].startswith("data:image/png;base64,")


def test_inspect_icon_absent_is_none(tmp_path):
    report = ipa.inspect(str(make_ipa(tmp_path / "c.ipa", icon_png=None)))
    assert report["icon"] is None


def test_inspect_names_a_file_that_is_no_longer_there(tmp_path):
    # The case that matters: an IPA chosen earlier, then moved or deleted. A sideload
    # and every unattended refresh start here, so this is where the sentence comes from.
    with pytest.raises(ipa.IpaError) as caught:
        ipa.inspect(str(tmp_path / "Instagram.ipa"))

    message = str(caught.value)
    assert "Instagram.ipa" in message, "say which file, refresh-all reads this"
    assert "moved, renamed or deleted" in message


def test_inspect_rejects_something_that_is_not_a_zip(tmp_path):
    path = tmp_path / "notazip.ipa"
    path.write_bytes(b"this is plainly not a zip archive")

    with pytest.raises(ipa.IpaError, match="not a zip archive"):
        ipa.inspect(str(path))


def test_inspect_rejects_a_zip_with_no_app_inside(tmp_path):
    path = tmp_path / "empty.ipa"
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("readme.txt", "no Payload here")

    with pytest.raises(ipa.IpaError) as caught:
        ipa.inspect(str(path))

    message = str(caught.value)
    assert "empty.ipa" in message
    assert "Payload/<App>.app" in message


def test_inspect_rejects_a_damaged_info_plist(tmp_path):
    path = tmp_path / "damaged.ipa"
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("Payload/Foo.app/Info.plist", b"\x00not a plist at all")

    with pytest.raises(ipa.IpaError, match="damaged Info.plist"):
        ipa.inspect(str(path))


def test_an_unreadable_ipa_is_a_situation_not_a_bug():
    # What the CLI and the serve loop key off to print a message instead of a stack.
    assert issubclass(ipa.IpaError, EngineError)


def test_normalize_standard_png_is_passthrough():
    png = make_png(4, 4)
    assert ipa._normalize_png(png) == png


def test_normalize_cgbi_opaque_is_exact():
    w = h = 6
    rgba = bytearray()
    for i in range(w * h):
        rgba += bytes([(i * 11) & 255, (i * 17) & 255, (i * 23) & 255, 255])
    out = ipa._normalize_png(make_cgbi_png(w, h, bytes(rgba)))
    nw, nh, pixels = decode_png_filter0(out)
    assert (nw, nh) == (w, h)
    assert pixels == bytes(rgba)  # BGRA->RGBA swap + unfilter is lossless when opaque


def test_normalize_cgbi_unpremultiplies_correctly():
    w = h = 2
    rgba = bytes([200, 100, 50, 128] * (w * h))
    out = ipa._normalize_png(make_cgbi_png(w, h, rgba))
    _, _, pixels = decode_png_filter0(out)
    assert abs(pixels[0] - 200) <= 2
    assert abs(pixels[1] - 100) <= 2
    assert abs(pixels[2] - 50) <= 2
    assert pixels[3] == 128


def test_app_group_identifiers_are_read_from_the_signature(tmp_path):
    import plistlib

    entitlements = plistlib.dumps({
        "com.apple.security.application-groups": [
            "group.com.ipaside.escapeos",
            "not-a-group",
            "group.com.ipaside.escapeos",
        ],
    })
    binary = b"\xca\xfe\xba\xbe" + b"\x00" * 32 + entitlements + b"\x00trailing"
    path = make_ipa(tmp_path / "grouped.ipa", executable=binary)

    assert ipa.app_group_identifiers(str(path)) == ["group.com.ipaside.escapeos"]


def test_an_ipa_without_a_group_reports_none(tmp_path):
    path = make_ipa(tmp_path / "plain.ipa")
    assert ipa.app_group_identifiers(str(path)) == []
