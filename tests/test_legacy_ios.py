"""Sideloading to iOS 10 and earlier, and saying why an install failed (iPASide issue #11).

An iPad 2 on iOS 6.1.3 got ``ApplicationVerificationFailed: None`` for every app. iOS 10 and
earlier only verify a SHA-1 CodeDirectory, and iPASide signs SHA-256-only, so those devices now
get zsign's dual SHA-1 + SHA-256 signature. When an install still fails, the message now states
what can be read off the app and the device (a minimum iOS the device does not have, code for
the wrong CPU) instead of passing Apple's one-liner through bare.
"""

from __future__ import annotations

import struct
from pathlib import Path

import pytest
from _helpers import make_ipa

from ipaside_engine import apps, ipa, signing, sideload

CPU_ARM = 0x0000000C
CPU_ARM64 = 0x0100000C
SUB_ARMV7 = 9
SUB_ARMV7S = 11


def fat(*slices: tuple[int, int]) -> bytes:
    header = struct.pack(">II", 0xCAFEBABE, len(slices))
    offset = 0x4000
    for cputype, cpusubtype in slices:
        header += struct.pack(">IIIII", cputype, cpusubtype, offset, 0x1000, 14)
        offset += 0x4000
    return header


def thin32(cpusubtype: int = SUB_ARMV7, *, cryptid: int | None = None) -> bytes:
    """A thin 32-bit little-endian Mach-O header, with an encryption command if asked."""
    commands = b""
    if cryptid is not None:
        commands = struct.pack("<5I", 0x21, 20, 0x1000, 0x1000, cryptid)
    ncmds = 1 if cryptid is not None else 0
    return struct.pack("<7I", 0xFEEDFACE, CPU_ARM, cpusubtype, 2, ncmds, len(commands), 0) + commands


# --------------------------------------------------------------------------- #
# Signing flag
# --------------------------------------------------------------------------- #


class _Proc:
    returncode = 0
    stdout = "ok"
    stderr = ""


def _capture(monkeypatch: pytest.MonkeyPatch) -> dict:
    captured: dict = {}
    monkeypatch.setattr(signing, "resolve_zsign", lambda: "zsign")

    def fake_run(cmd, **_kwargs):
        captured["cmd"] = cmd
        return _Proc()

    monkeypatch.setattr(signing.subprocess, "run", fake_run)
    return captured


def test_the_legacy_signature_flag_is_only_added_when_asked(monkeypatch: pytest.MonkeyPatch) -> None:
    captured = _capture(monkeypatch)
    common = {"p12_path": "id.p12", "p12_password": "pw", "profile_path": "p.mobileprovision"}
    signing.sign_ipa("in.ipa", "out.ipa", **common)
    assert "-L" not in captured["cmd"], "modern devices keep the SHA-256-only signature"
    signing.sign_ipa("in.ipa", "out.ipa", legacy_sha1=True, **common)
    assert "-L" in captured["cmd"]
    assert captured["cmd"][-1] == "in.ipa", "the input stays the last argument"


def test_the_bundled_signer_really_has_the_dual_signature_option() -> None:
    """The flag is only worth passing if the zsign that ships understands it."""
    import subprocess

    help_text = subprocess.run([signing.resolve_zsign(), "-h"], capture_output=True, text=True).stdout
    assert "--legacy_sha1" in help_text and "SHA1+SHA256" in help_text


# --------------------------------------------------------------------------- #
# Which devices count as old
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    ("text", "expected"),
    [("6.1.3", (6, 1, 3)), ("10.3.4", (10, 3, 4)), ("16.7.15", (16, 7, 15)), ("11", (11,)),
     (" 12.0 ", (12, 0)), ("15.0 beta", (15, 0)), ("", None), (None, None), ("abc", None), ("v6.1", None)],
)
def test_version_text_is_read_as_numbers(text, expected) -> None:
    assert sideload._version_tuple(text) == expected


@pytest.mark.parametrize(
    ("version", "legacy"),
    [("6.1.3", True), ("9.3.5", True), ("10.3.4", True), ("10.99", True),
     ("11.0", False), ("12.5.7", False), ("16.7.15", False), ("26.5.1", False)],
)
def test_ios_10_and_earlier_get_the_legacy_signature(version: str, legacy: bool) -> None:
    assert sideload._needs_legacy_signature({"ProductVersion": version}) is legacy


@pytest.mark.parametrize("values", [{}, {"ProductVersion": ""}, {"ProductVersion": "unknown"}, {"ProductVersion": None}])
def test_an_unreadable_version_never_triggers_the_legacy_signature(values) -> None:
    assert sideload._needs_legacy_signature(values) is False


def test_versions_compare_the_way_people_expect() -> None:
    assert sideload._version_tuple("10.0") > sideload._version_tuple("9.9.9")
    assert sideload._version_tuple("15.0") > sideload._version_tuple("6.1.3")
    assert sideload._version_tuple("6.1.3") == sideload._version_tuple("6.1.3")


# --------------------------------------------------------------------------- #
# Reading the app's CPU code
# --------------------------------------------------------------------------- #


def test_inspect_reports_the_architectures_of_a_universal_app(tmp_path: Path) -> None:
    path = make_ipa(tmp_path / "u.ipa", executable=fat((CPU_ARM, SUB_ARMV7), (CPU_ARM64, 0)))
    assert ipa.inspect(str(path))["architectures"] == ["arm64", "armv7"]


def test_inspect_reads_a_thin_32_bit_app(tmp_path: Path) -> None:
    """The only kind an iPad 2 can run; it used to be read as 'not a Mach-O'."""
    path = make_ipa(tmp_path / "t.ipa", executable=thin32(SUB_ARMV7))
    assert ipa.inspect(str(path))["architectures"] == ["armv7"]
    path = make_ipa(tmp_path / "s.ipa", executable=thin32(SUB_ARMV7S))
    assert ipa.inspect(str(path))["architectures"] == ["armv7s"]


def test_inspect_reports_nothing_rather_than_guessing(tmp_path: Path) -> None:
    junk = make_ipa(tmp_path / "j.ipa", executable=b"not a mach-o file at all")
    assert ipa.inspect(str(junk))["architectures"] == []
    # A damaged universal header decodes to nonsense CPU numbers; none of it may be reported.
    damaged = make_ipa(tmp_path / "d.ipa")  # the helper's default: a universal magic and junk after it
    assert ipa.inspect(str(damaged))["architectures"] == []


def test_a_simulator_build_is_not_reported_as_a_device_architecture(tmp_path: Path) -> None:
    x86_64 = 0x01000007
    path = make_ipa(tmp_path / "x.ipa", executable=fat((x86_64, 3)))
    assert ipa.inspect(str(path))["architectures"] == []


def test_only_recognised_slices_survive_next_to_a_real_one(tmp_path: Path) -> None:
    x86_64 = 0x01000007
    path = make_ipa(tmp_path / "m.ipa", executable=fat((CPU_ARM64, 0), (x86_64, 3)))
    assert ipa.inspect(str(path))["architectures"] == ["arm64"]


def test_a_thin_32_bit_app_is_checked_for_fairplay_encryption(tmp_path: Path) -> None:
    """Same typo, same fix: these used to come back 'unknown' and slip through."""
    encrypted = tmp_path / "enc"
    encrypted.write_bytes(thin32(cryptid=1))
    clear = tmp_path / "clear"
    clear.write_bytes(thin32(cryptid=0))
    assert ipa.is_encrypted(encrypted) is True
    assert ipa.is_encrypted(clear) is False


# --------------------------------------------------------------------------- #
# The failure explanation
# --------------------------------------------------------------------------- #

OLD_IPAD = {"ProductVersion": "6.1.3", "CPUArchitecture": "armv7", "DeviceName": "iPad 2"}
NEW_PHONE = {"ProductVersion": "16.7.15", "CPUArchitecture": "arm64", "DeviceName": "iPhone"}


def hint(info: dict, values: dict, legacy: bool = False) -> str | None:
    return sideload._install_failure_hint(info, values, values.get("DeviceName", "this device"), legacy)


def test_an_app_that_needs_a_newer_ios_is_named_as_the_reason() -> None:
    text = hint({"display_name": "Dopamine", "minimum_os": "15.0", "architectures": ["arm64"]}, OLD_IPAD)
    assert text is not None
    assert "Dopamine needs iOS 15.0 or later" in text
    assert "iPad 2 is on iOS 6.1.3" in text


def test_an_app_with_no_code_for_the_devices_cpu_is_named_as_the_reason() -> None:
    text = hint({"display_name": "Game", "minimum_os": "6.0", "architectures": ["arm64"]}, OLD_IPAD)
    assert text is not None
    assert "only contains code for arm64" in text and "needs armv7 code" in text


def test_both_reasons_are_given_when_both_apply() -> None:
    text = hint({"display_name": "App", "minimum_os": "12.0", "architectures": ["arm64"]}, OLD_IPAD)
    assert text is not None and "needs iOS 12.0" in text and "only contains code for arm64" in text


@pytest.mark.parametrize(
    ("cpu", "arches", "runs"),
    [
        ("armv7", ["armv7"], True), ("armv7", ["armv7", "arm64"], True), ("armv7", ["arm64"], False),
        ("armv7", ["armv7s"], False), ("armv7s", ["armv7"], True), ("arm64", ["arm64"], True),
        ("arm64", ["armv7"], True), ("arm64e", ["arm64"], True), ("arm64", ["arm64e"], False),
    ],
)
def test_which_cpus_can_run_which_slices(cpu: str, arches: list[str], runs: bool) -> None:
    info = {"display_name": "App", "minimum_os": "6.0", "architectures": arches}
    values = {"ProductVersion": "16.0", "CPUArchitecture": cpu, "DeviceName": "dev"}
    assert (hint(info, values) is None) is runs


def test_an_app_that_fits_an_old_device_gets_an_honest_general_note() -> None:
    """No known mismatch: say it is an old device and what was done, claim nothing else."""
    info = {"display_name": "Old App", "minimum_os": "5.0", "architectures": ["armv7"]}
    plain = hint(info, OLD_IPAD, legacy=False)
    signed = hint(info, OLD_IPAD, legacy=True)
    assert plain is not None and "iOS 6.1.3" in plain and "SHA-1" not in plain
    assert signed is not None and "SHA-1" in signed
    for text in (plain, signed):
        assert "needs iOS" not in text and "only contains code" not in text


def test_a_modern_device_gets_no_added_note_for_an_unrelated_failure() -> None:
    info = {"display_name": "App", "minimum_os": "14.0", "architectures": ["arm64"]}
    assert hint(info, NEW_PHONE) is None


def test_unreadable_facts_never_accuse_an_app() -> None:
    assert hint({}, {}) is None
    assert hint({"minimum_os": "garbage", "architectures": []}, {"ProductVersion": "x", "CPUArchitecture": ""}) is None
    # A CPU iPASide does not know about is not a mismatch.
    assert hint({"display_name": "A", "architectures": ["arm64"]}, {"CPUArchitecture": "riscv", "ProductVersion": "16.0"}) is None


# --------------------------------------------------------------------------- #
# Through run_sideload
# --------------------------------------------------------------------------- #


@pytest.fixture
def harness(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    signed_dir = tmp_path / "signed"
    signed_dir.mkdir()
    source = tmp_path / "app.ipa"
    source.write_bytes(b"PK\x03\x04")
    seen: dict = {}

    def signer(_ipa, output, **kwargs):
        seen["legacy_sha1"] = kwargs.get("legacy_sha1")
        Path(output).write_bytes(b"\0" * 64)

    monkeypatch.setattr(sideload, "resolve_udid", lambda _u: "UDID")
    monkeypatch.setattr(sideload.provision, "team_scoped_bundle_id", lambda b: f"{b}.TEAM")
    monkeypatch.setattr(sideload.paths, "signed_dir", lambda: signed_dir)
    monkeypatch.setattr(
        sideload.provision, "ensure_signing_assets",
        lambda *_a, **_k: {"p12_path": "id.p12", "p12_password": "pw", "profile_path": "p.mobileprovision", "team_id": "T"},
    )
    monkeypatch.setattr(sideload.signing, "sign_ipa", signer)

    def run(values: dict | Exception, info: dict, install):
        """``values`` is what the device reports, or an exception for one that cannot be read."""
        base = {"bundle_id": "com.example.app", "display_name": "Example"}

        def device_info(_udid):
            if isinstance(values, Exception):
                raise values
            return values

        monkeypatch.setattr(sideload.ipa_module, "inspect", lambda _p: {**base, **info})
        monkeypatch.setattr(sideload.device, "get_device_info", device_info)
        monkeypatch.setattr(sideload.apps, "install", install)
        return sideload.run_sideload(str(source), "UDID", record=False)

    return run, seen


def _ok(*_a, **_k) -> None:
    return None


def test_an_old_device_is_signed_with_the_legacy_signature(harness) -> None:
    run, seen = harness
    run(OLD_IPAD, {"minimum_os": "5.0", "architectures": ["armv7"]}, _ok)
    assert seen["legacy_sha1"] is True


def test_a_modern_device_keeps_the_sha256_only_signature(harness) -> None:
    run, seen = harness
    run(NEW_PHONE, {"minimum_os": "14.0", "architectures": ["arm64"]}, _ok)
    assert seen["legacy_sha1"] is False


def test_an_unreadable_device_keeps_the_sha256_only_signature(harness) -> None:
    run, seen = harness
    run(OSError("device went away"), {"minimum_os": "14.0", "architectures": ["arm64"]}, _ok)
    assert seen["legacy_sha1"] is False


class _InstallerRefused(Exception):
    pass


def test_a_failed_install_on_an_old_device_explains_itself_and_keeps_apples_words(harness) -> None:
    run, _seen = harness

    def refuse(*_a, **_k):
        raise _InstallerRefused("ApplicationVerificationFailed: None")

    with pytest.raises(sideload.SideloadError) as caught:
        run(OLD_IPAD, {"display_name": "Dopamine", "minimum_os": "15.0", "architectures": ["arm64"]}, refuse)
    message = str(caught.value)
    assert message.startswith("ApplicationVerificationFailed: None")
    assert "Dopamine needs iOS 15.0 or later" in message
    assert isinstance(caught.value.__cause__, _InstallerRefused), "the original error stays attached"


def test_a_failed_install_with_nothing_to_add_raises_the_original_error(harness) -> None:
    run, _seen = harness

    def refuse(*_a, **_k):
        raise _InstallerRefused("some other installd failure")

    with pytest.raises(_InstallerRefused, match="some other installd failure"):
        run(NEW_PHONE, {"minimum_os": "14.0", "architectures": ["arm64"]}, refuse)


def test_the_free_app_limit_message_passes_through_untouched(harness) -> None:
    run, _seen = harness

    def limit(*_a, **_k):
        raise apps.InstallLimitError("Your iPhone already has the most apps a free Apple ID can install.")

    with pytest.raises(apps.InstallLimitError, match="most apps a free Apple ID"):
        run(OLD_IPAD, {"minimum_os": "15.0", "architectures": ["arm64"]}, limit)
