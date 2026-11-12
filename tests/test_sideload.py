"""Tests for sideload orchestration: the install progress mapping that feeds the
UI's single monotonic bar, and the lifetime of everything signing produces - where
the signed IPA lands, what it is called, whether it survives, where the sign-time
scratch goes, and what reporting on / cleaning that folder is allowed to touch.
"""

import datetime
import os
from pathlib import Path

import pytest

from ipaside_engine import ipa as ipa_module, sideload

MB = 1 << 20


def test_upload_drives_first_80_percent():
    overall, step = sideload._install_relay(
        {"phase": "upload", "percent": 50, "sent": 100 * MB, "total": 200 * MB}
    )
    assert overall == 40  # 50% uploaded -> 40% of the overall bar
    assert step == "Uploading to iPhone \u00b7 100 / 200 MB"


def test_upload_start_and_end_bounds():
    assert sideload._install_relay({"phase": "upload", "percent": 0, "sent": 0, "total": 200 * MB})[0] == 0
    assert sideload._install_relay({"phase": "upload", "percent": 100, "sent": 200 * MB, "total": 200 * MB})[0] == 80


def test_upload_without_total_shows_plain_label():
    assert sideload._install_relay({"phase": "upload", "percent": 0})[1] == "Uploading to iPhone\u2026"


def test_installd_drives_last_20_percent_with_labels():
    assert sideload._install_relay({"phase": "install", "percent": 0, "status": "ExtractingPackage"}) == (
        80, "Extracting package\u2026",
    )
    assert sideload._install_relay({"phase": "install", "percent": 70, "status": "PostflightingApplication"}) == (
        94, "Postflighting\u2026",
    )


def test_installd_completion_pins_to_100_even_without_percent():
    # installd's terminal "Complete"/"InstallComplete" can arrive with no PercentComplete;
    # the bar must land on 100%, never fall back to the 80% floor.
    assert sideload._install_relay({"phase": "install", "status": "Complete"}) == (100, "Installed")
    assert sideload._install_relay({"phase": "install", "status": "InstallComplete"}) == (100, "Installed")
    assert sideload._install_relay({"phase": "install", "percent": 100, "status": "InstallComplete"}) == (100, "Installed")


def test_installd_unknown_status_passes_through():
    assert sideload._install_relay({"phase": "install", "percent": 50, "status": "BrandNewPhase"}) == (
        90, "BrandNewPhase",
    )


def test_humanize_install_defaults_when_missing():
    assert sideload._humanize_install(None) == "Installing\u2026"
    assert sideload._humanize_install("VerifyingApplication") == "Verifying\u2026"


UDID = "935cbbb9b82d25d15566e5939bcea5677b1c44ae"
OTHER_UDID = "0f1e2d3c4b5a69788796a5b4c3d2e1f009876543"


@pytest.fixture
def connected(monkeypatch):
    """Set what usbmux reports, one entry per transport as the real one does."""

    def install(*entries):
        monkeypatch.setattr(sideload.device, "list_devices", lambda: list(entries))

    return install


def test_resolve_udid_takes_one_phone_reachable_two_ways(connected):
    connected(
        {"serial": UDID, "connection_type": "USB"},
        {"serial": UDID, "connection_type": "Network"},
    )
    assert sideload.resolve_udid(None) == UDID


def test_resolve_udid_will_not_choose_between_two_phones(connected):
    # Picking one silently is how an app ends up installed on the wrong phone.
    connected(
        {"serial": UDID, "connection_type": "USB"},
        {"serial": OTHER_UDID, "connection_type": "USB"},
    )

    with pytest.raises(sideload.SideloadError) as failure:
        sideload.resolve_udid(None)

    message = str(failure.value)
    assert UDID in message and OTHER_UDID in message
    assert "--udid" in message


def test_resolve_udid_honours_an_explicit_choice(connected):
    connected(
        {"serial": UDID, "connection_type": "USB"},
        {"serial": OTHER_UDID, "connection_type": "USB"},
    )
    assert sideload.resolve_udid(OTHER_UDID) == OTHER_UDID, "the caller already chose"


def test_resolve_udid_with_nothing_connected(connected):
    connected()
    with pytest.raises(sideload.SideloadError, match="No device connected"):
        sideload.resolve_udid(None)


class _StubSign:
    """Stands in for zsign: writes an output file of a known size.

    It also records the scratch folder it was handed and litters it, the way zsign
    fills its temp folder with an unpacked copy of the whole app.
    """

    def __init__(self, size=4096):
        self.size = size
        self.output = None
        self.temp_folder = None

    def __call__(self, _ipa, output, **kwargs):
        self.output = Path(output)
        temp = kwargs.get("temp_folder")
        self.temp_folder = Path(temp) if temp else None
        if self.temp_folder is not None:
            unpacked = self.temp_folder / "zsign_folder_1" / "Payload"
            unpacked.mkdir(parents=True, exist_ok=True)
            (unpacked / "Example").write_bytes(b"\0" * 128)
        self.output.write_bytes(b"\0" * self.size)


def _install_ok(*_args, **_kwargs):
    """An apps.install stand-in that just succeeds."""


@pytest.fixture
def sideload_harness(tmp_path, monkeypatch):
    """Drive run_sideload with Apple, zsign and the device all stubbed out.

    ``run(install, source=..., **options)`` forwards any run_sideload option, so a
    test can exercise --keep-signed / --signed-dir or sign a differently named IPA.
    """
    signed_dir = tmp_path / "signed"
    signed_dir.mkdir()
    source_ipa = tmp_path / "app.ipa"
    source_ipa.write_bytes(b"PK\x03\x04")

    signer = _StubSign()
    monkeypatch.setattr(sideload, "resolve_udid", lambda _udid: "UDID")
    monkeypatch.setattr(sideload.ipa_module, "inspect", lambda _p: {"bundle_id": "com.example.app", "display_name": "Example"})
    monkeypatch.setattr(sideload.provision, "team_scoped_bundle_id", lambda b: f"{b}.TEAM")
    # A signing profile resolves its app groups before provisioning, so any test whose
    # bundle id is recognised (EscapeOS) reaches this even with provisioning stubbed.
    monkeypatch.setattr(sideload.developer, "list_teams", lambda: [{"teamId": "TEAM"}])
    monkeypatch.setattr(sideload.paths, "signed_dir", lambda: signed_dir)
    monkeypatch.setattr(
        sideload.provision, "ensure_signing_assets",
        lambda *_a, **_k: {"p12_path": "id.p12", "p12_password": "pw", "profile_path": str(tmp_path / "p.mobileprovision"), "team_id": "TEAM"},
    )
    monkeypatch.setattr(sideload.signing, "sign_ipa", signer)

    def run(install, *, source=None, **options):
        monkeypatch.setattr(sideload.apps, "install", install)
        return sideload.run_sideload(str(source or source_ipa), "UDID", record=False, **options)

    return run, signer, signed_dir


def test_sideloading_a_vanished_ipa_reads_as_a_sentence(tmp_path, monkeypatch):
    """A source IPA can disappear between being chosen and being signed.

    Deliberately does not stub ``inspect``: the point is that the real reader is what
    every entry point goes through, so a moved file cannot reach a user as a stack.
    """
    monkeypatch.setattr(sideload, "resolve_udid", lambda _udid: "UDID")

    with pytest.raises(ipa_module.IpaError) as caught:
        sideload.run_sideload(str(tmp_path / "Instagram.ipa"), "UDID", record=False)

    message = str(caught.value)
    assert "Instagram.ipa" in message
    assert "moved, renamed or deleted" in message


def test_refreshing_a_vanished_source_reads_as_a_sentence(tmp_path, monkeypatch):
    # The likeliest version of this: the daily refresh runs weeks later, unattended,
    # and the IPA it was given has since been tidied away.
    monkeypatch.setattr(sideload, "resolve_udid", lambda _udid: "UDID")

    with pytest.raises(ipa_module.IpaError, match="moved, renamed or deleted"):
        sideload.refresh_record(
            {
                "bundle_id": "com.example.app.TEAM",
                "name": "Example",
                "udid": "UDID",
                "source_ipa": str(tmp_path / "gone.ipa"),
                "options": {},
            }
        )


def test_signed_ipa_is_deleted_after_a_successful_install(sideload_harness):
    # Nothing reads it once the install is done: refresh re-signs from the recorded
    # *source* IPA and a retry re-signs anyway. Keeping it unasked stranded a copy of
    # the largest app ever sideloaded on disk permanently - 233 MB on the test machine.
    run, signer, signed_dir = sideload_harness
    seen = {}

    def install(path, _udid, progress=None):
        seen["existed_during_install"] = Path(path).exists()

    result = run(install)
    assert result["status"] == "installed"
    assert seen["existed_during_install"], "install must still be able to read it"
    assert not signer.output.exists(), "the signed IPA should not survive the install"
    assert result["signed_ipa"] is None, "nothing was kept, so there is no path to report"
    assert list(signed_dir.iterdir()) == []


def test_signed_ipa_is_deleted_even_when_the_install_fails(sideload_harness):
    run, signer, _signed_dir = sideload_harness

    def install(_path, _udid, progress=None):
        raise RuntimeError("device went away mid-upload")

    with pytest.raises(RuntimeError, match="device went away"):
        run(install)
    assert not signer.output.exists(), "a failed install must not leak it either"


def test_cleanup_tolerates_an_already_missing_file(sideload_harness):
    run, signer, _signed_dir = sideload_harness

    def install(path, _udid, progress=None):
        Path(path).unlink()  # something else got there first

    run(install)
    assert not signer.output.exists()


def test_signed_ipa_is_named_after_its_source(sideload_harness, tmp_path):
    run, signer, signed_dir = sideload_harness
    source = tmp_path / "com.burbn.instagram_439.0.0.ipa"
    source.write_bytes(b"PK\x03\x04")
    seen = {}

    def install(path, _udid, progress=None):
        seen["installed"] = Path(path)

    run(install, source=source)

    assert signer.output == signed_dir / "com.burbn.instagram_439.0.0_Signed.ipa"
    assert seen["installed"] == signer.output, "the file installed is the one just signed"


def test_resigning_the_same_source_overwrites_its_own_output(sideload_harness):
    run, _signer, signed_dir = sideload_harness

    run(_install_ok, keep_signed=True)
    run(_install_ok, keep_signed=True)

    assert [p.name for p in signed_dir.iterdir()] == ["app_Signed.ipa"], "no numbered copies"


def test_keep_signed_leaves_the_file_and_reports_where(sideload_harness):
    run, signer, signed_dir = sideload_harness

    result = run(_install_ok, keep_signed=True)

    assert signer.output.exists(), "the user asked for it to stay"
    assert signer.output.stat().st_size == signer.size
    assert result["signed_ipa"] == str(signed_dir / "app_Signed.ipa")


def test_a_custom_signed_dir_is_created_and_used(sideload_harness, tmp_path):
    run, signer, default_dir = sideload_harness
    chosen = tmp_path / "big disk" / "iPASide signed"  # two levels, neither exists yet

    result = run(_install_ok, keep_signed=True, signed_dir=str(chosen))

    assert signer.output.name == "app_Signed.ipa"
    assert signer.output.parent.samefile(chosen), "the chosen folder, created on demand"
    assert result["signed_ipa"] == str(signer.output)
    assert list(default_dir.iterdir()) == [], "and nothing in the default folder"


def test_an_unusable_signed_dir_fails_with_the_path_in_the_message(sideload_harness, tmp_path):
    run, _signer, _signed_dir = sideload_harness
    blocked = tmp_path / "not-a-folder.txt"  # nothing can be created inside a file
    blocked.write_text("in the way")

    with pytest.raises(sideload.SideloadError) as failure:
        run(_install_ok, signed_dir=str(blocked))

    assert str(blocked) in str(failure.value), "the UI has to be able to name the folder"


def test_scratch_goes_to_the_signed_dir_and_is_removed_even_when_the_ipa_is_kept(sideload_harness):
    run, signer, signed_dir = sideload_harness

    run(_install_ok, keep_signed=True)

    assert signer.temp_folder is not None, "signing must be told where to work"
    assert signer.temp_folder.parent == signed_dir, "heavy I/O follows the chosen folder"
    assert not signer.temp_folder.exists(), "keep_signed keeps the IPA, never the scratch"
    assert [p.name for p in signed_dir.iterdir()] == ["app_Signed.ipa"]


def test_scratch_is_removed_when_signing_fails(sideload_harness, monkeypatch):
    run, _signer, signed_dir = sideload_harness
    seen = {}

    def explode(_ipa, _output, **kwargs):
        scratch = Path(kwargs["temp_folder"])
        seen["scratch"] = scratch
        seen["was_a_dir"] = scratch.is_dir()
        raise sideload.signing.SigningError("zsign fell over")

    monkeypatch.setattr(sideload.signing, "sign_ipa", explode)

    with pytest.raises(sideload.signing.SigningError):
        run(_install_ok, keep_signed=True)

    assert seen["was_a_dir"], "scratch has to exist before signing starts"
    assert not seen["scratch"].exists()
    assert list(signed_dir.iterdir()) == []


def _write(path: Path, size: int) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\0" * size)
    return path


def test_signed_report_lists_what_is_there_newest_first(tmp_path):
    older = _write(tmp_path / "old_Signed.ipa", 1000)
    newer = _write(tmp_path / "new_Signed.ipa", 2000)
    os.utime(older, (0, 1_000_000_000))
    os.utime(newer, (0, 1_000_000_100))

    report = sideload.signed_status(str(tmp_path))

    assert Path(report["directory"]) == tmp_path.resolve()
    assert report["count"] == 2
    assert report["bytes"] == 3000
    assert [f["name"] for f in report["files"]] == ["new_Signed.ipa", "old_Signed.ipa"]
    assert report["files"][0]["bytes"] == 2000
    modified = datetime.datetime.fromisoformat(report["files"][0]["modified"])
    assert modified == datetime.datetime.fromtimestamp(1_000_000_100, datetime.timezone.utc)


def test_signed_report_on_a_folder_that_does_not_exist_is_not_an_error(tmp_path):
    missing = tmp_path / "not chosen yet"

    report = sideload.signed_status(str(missing))

    assert Path(report["directory"]) == missing.resolve(), "say where it looked"
    assert report["count"] == 0
    assert report["bytes"] == 0
    assert report["files"] == []
    assert not missing.exists(), "reporting must not create it"


def test_signed_report_defaults_to_the_apps_own_folder(isolated_data):
    report = sideload.signed_status()

    assert Path(report["directory"]) == isolated_data / "iPASide" / "signed"
    assert report["count"] == 0


def test_clean_removes_signed_ipas_and_leaves_everything_else_alone(tmp_path):
    # The folder is whatever the user pointed the setting at, so assume it is full of
    # things iPASide did not write - including the source IPAs refresh re-signs from.
    signed = _write(tmp_path / "app_Signed.ipa", 4096)
    source = _write(tmp_path / "app.ipa", 8192)
    notes = _write(tmp_path / "notes.txt", 10)
    nested = _write(tmp_path / "archive" / "old_Signed.ipa", 2048)

    result = sideload.clean_signed(str(tmp_path))

    assert result["removed"] == 1
    assert result["bytes_freed"] == 4096
    assert not signed.exists()
    assert source.stat().st_size == 8192, "a source IPA is the user's data, and refresh needs it"
    assert notes.exists(), "an unrelated file is none of our business"
    assert nested.exists(), "clean must not recurse into subdirectories"
    assert (tmp_path / "archive").is_dir(), "and must not remove directories"
    assert tmp_path.is_dir(), "least of all the folder itself"


def test_clean_never_follows_a_link_out_of_the_folder(tmp_path):
    outside = _write(tmp_path / "elsewhere" / "precious_Signed.ipa", 64)
    folder = tmp_path / "signed"
    folder.mkdir()
    link = folder / "link_Signed.ipa"
    try:
        link.symlink_to(outside)
    except (OSError, NotImplementedError) as exc:  # Windows needs Developer Mode or admin
        pytest.skip(f"symlinks unavailable here: {exc}")

    result = sideload.clean_signed(str(folder))

    assert result["removed"] == 0
    assert outside.exists(), "the target lives outside the folder entirely"
    assert link.is_symlink(), "a link is not a file we wrote"
    assert sideload.signed_status(str(folder))["count"] == 0, "nor is it reported as one"


def test_clean_on_a_folder_that_does_not_exist_reports_nothing_removed(tmp_path):
    result = sideload.clean_signed(str(tmp_path / "not chosen yet"))

    assert result["removed"] == 0
    assert result["bytes_freed"] == 0


def test_sideload_places_a_pairing_file_into_escapeos(sideload_harness, monkeypatch):
    run, _signer, _signed_dir = sideload_harness
    monkeypatch.setattr(
        sideload.ipa_module,
        "inspect",
        lambda _p: {"bundle_id": "com.ipaside.escapeos", "display_name": "EscapeOS"},
    )
    seen: dict = {}

    def fake_deliver(bundle_id, udid, serial, *, skip_ids=()):
        seen.update(bundle_id=bundle_id, udid=udid, skip_ids=set(skip_ids))
        return {"placed": True, "id": "escapeos", "bundle_id": bundle_id}

    monkeypatch.setattr(
        "ipaside_engine.pairing.deliver_if_consumer", fake_deliver
    )

    result = run(lambda *_a, **_k: None)

    assert result["status"] == "installed"
    assert result["post_install"]["pairing"]["placed"] is True
    assert seen["bundle_id"].startswith("com.ipaside.escapeos")
    assert "livecontainer" in seen["skip_ids"]


def test_sideload_does_not_fail_when_pairing_placement_cannot_run(
    sideload_harness, monkeypatch
):
    run, _signer, _signed_dir = sideload_harness
    monkeypatch.setattr(
        sideload.ipa_module,
        "inspect",
        lambda _p: {"bundle_id": "com.ipaside.escapeos", "display_name": "EscapeOS"},
    )
    monkeypatch.setattr(
        "ipaside_engine.pairing.deliver_if_consumer",
        lambda *_a, **_k: {"placed": False, "error": "no pairing record"},
    )

    result = run(lambda *_a, **_k: None)

    assert result["status"] == "installed"
    assert result["post_install"]["pairing"]["placed"] is False

