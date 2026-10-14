"""Apple's provisioning emulator runs in a helper process, so a native crash cannot kill the engine.

GitHub issue #8: sign-in ended with "engine exited unexpectedly" and nothing else. The
anisette package drives the Unicorn CPU emulator, which JIT-compiles into host memory;
Windows exploit mitigations (Control Flow Guard, hardware shadow stacks, dynamic-code
prohibition) kill such a process outright - no traceback, no result frame. Reproduced
locally by launching the process under each mitigation: exit 0xC0000409 (CFG), 0xC00000FF /
0xC0000409 (shadow stack) and 1 with "Could not allocate dynamic translator buffer" (ACG).

These tests use stand-in helpers that behave the way those crashes do, and pin that the
engine gets an explanation instead of dying, can start a clean helper afterwards, and
never hands the helper the Apple password.
"""

from __future__ import annotations

import json
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from ipaside_engine import anisette

ENGINE_DIR = Path(__file__).resolve().parents[1] / "src" / "iPASide.Engine"


@pytest.fixture(autouse=True)
def _no_leftover_worker():
    anisette._close_worker()
    yield
    anisette._close_worker()


def _command(monkeypatch: pytest.MonkeyPatch, command: list[str]) -> None:
    monkeypatch.setattr(anisette, "_worker_command", lambda: command)


def _write_stub(tmp_path: Path, on_headers: str) -> list[str]:
    """Stub whose reaction to a ``headers`` request is the code in ``on_headers``."""
    script = tmp_path / "stub_worker.py"
    script.write_text(
        "import json, os, sys\n"
        "def reply(obj):\n"
        "    sys.stdout.write(json.dumps(obj) + '\\n'); sys.stdout.flush()\n"
        "reply({'ready': True})\n"
        "for line in sys.stdin:\n"
        "    if not line.strip():\n"
        "        continue\n"
        "    req = json.loads(line)\n"
        "    if req.get('op') == 'shutdown':\n"
        "        break\n"
        + textwrap.indent(textwrap.dedent(on_headers), "    "),
        encoding="utf-8",
    )
    return [sys.executable, str(script)]


# --------------------------------------------------------------------------- #
# Explaining a helper that died
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    ("code", "expected"),
    [
        (0xC0000409, "0xC0000409 (security check failure (fail-fast))"),
        (-1073740791, "0xC0000409"),  # the same status as a signed 32-bit value
        (0xC00000FF, "0xC00000FF (bad function table (stack unwind rejected))"),
        (0xC0000005, "0xC0000005 (access violation)"),
        (7, "0x00000007"),
    ],
)
def test_exit_code_is_named_and_unsigned(code: int, expected: str) -> None:
    message = anisette._describe_worker_exit(code, [])
    assert expected in message
    assert "were not the problem" in message  # not a credentials failure


def test_unknown_exit_code_still_explains() -> None:
    message = anisette._describe_worker_exit(None, [])
    assert "exit code unknown" in message


def test_blocked_dynamic_code_is_called_out_from_what_the_helper_printed() -> None:
    message = anisette._describe_worker_exit(1, ["Could not allocate dynamic translator buffer"])
    assert "executable memory" in message
    assert "Disable dynamic code" in message
    assert "Last output from the helper:\nCould not allocate dynamic translator buffer" in message


def test_message_names_the_program_to_exempt() -> None:
    message = anisette._describe_worker_exit(0xC0000409, [])
    assert sys.executable in message
    assert "Exploit protection" in message


def test_blank_stderr_lines_are_not_quoted() -> None:
    message = anisette._describe_worker_exit(1, ["", "   "])
    assert "Last output" not in message


# --------------------------------------------------------------------------- #
# The environment the helper gets
# --------------------------------------------------------------------------- #


def test_helper_environment_never_carries_the_password(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("IPASIDE_APPLE_PASSWORD", "hunter2")
    monkeypatch.setenv("IPASIDE_ZSIGN", "x")
    monkeypatch.setenv("LOCALAPPDATA", "C:/somewhere")
    env = anisette._worker_env()
    assert not any(key.startswith("IPASIDE_") for key in env)
    assert env["LOCALAPPDATA"] == "C:/somewhere"  # where the cached state lives


def test_isolated_interpreter_flag_is_mirrored(monkeypatch: pytest.MonkeyPatch) -> None:
    class _Flags:
        ignore_environment = 1
        utf8_mode = 1

    monkeypatch.setattr(anisette.sys, "flags", _Flags())
    command = anisette._worker_command()
    assert command[0] == sys.executable
    assert "-E" in command
    assert command[command.index("-X") + 1] == "utf8"
    assert command[-2:] == ["-m", "ipaside_engine.anisette_worker"]


def test_plain_interpreter_gets_no_extra_flags(monkeypatch: pytest.MonkeyPatch) -> None:
    class _Flags:
        ignore_environment = 0
        utf8_mode = 0

    monkeypatch.setattr(anisette.sys, "flags", _Flags())
    assert anisette._worker_command() == [sys.executable, "-m", "ipaside_engine.anisette_worker"]


def test_frozen_engine_keeps_the_in_process_path(monkeypatch: pytest.MonkeyPatch) -> None:
    class _Provider:
        def get_data(self) -> dict[str, str]:
            return {"X-Apple-I-MD": "frozen"}

    monkeypatch.setattr(anisette.sys, "frozen", True, raising=False)
    monkeypatch.setattr(anisette, "_load_provider", lambda: _Provider())
    monkeypatch.setattr(
        anisette, "_worker_command", lambda: pytest.fail("a frozen engine cannot start -m")
    )
    assert anisette._raw_headers() == {"X-Apple-I-MD": "frozen"}


# --------------------------------------------------------------------------- #
# Talking to the helper
# --------------------------------------------------------------------------- #


def test_headers_come_back_and_are_wire_safe(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    command = _write_stub(
        tmp_path,
        """
        if req.get("op") == "headers":
            reply({"ok": True, "headers": {"X-Apple-I-MD": "abc", "X-Apple-I-TimeZone": "中国标准时间"}})
        """,
    )
    _command(monkeypatch, command)
    headers = anisette.get_headers()
    assert headers["X-Apple-I-MD"] == "abc"
    headers["X-Apple-I-TimeZone"].encode("latin-1")  # still rewritten to ASCII by the engine


def test_one_helper_serves_every_request(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    command = _write_stub(
        tmp_path,
        """
        if req.get("op") == "headers":
            reply({"ok": True, "headers": {"pid": os.getpid()}})
        """,
    )
    _command(monkeypatch, command)
    first = anisette._raw_headers()["pid"]
    second = anisette._raw_headers()["pid"]
    assert first == second


def test_helper_dying_mid_request_becomes_an_error_not_a_dead_engine(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    command = _write_stub(
        tmp_path,
        """
        if req.get("op") == "headers":
            sys.stderr.write("Windows fatal exception: simulated\\n"); sys.stderr.flush()
            os._exit(0xC0000409)
        """,
    )
    _command(monkeypatch, command)
    with pytest.raises(anisette.AnisetteError) as caught:
        anisette.get_headers()
    text = str(caught.value)
    assert "0xC0000409" in text
    assert "Windows fatal exception: simulated" in text  # what it last printed is quoted


def test_a_clean_helper_starts_after_one_died(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    flag = tmp_path / "already-crashed"
    command = _write_stub(
        tmp_path,
        f"""
        if req.get("op") == "headers":
            if not os.path.exists({str(flag)!r}):
                open({str(flag)!r}, "w").close()
                os._exit(1)
            reply({{"ok": True, "headers": {{"X-Apple-I-MD": "second-helper"}}}})
        """,
    )
    _command(monkeypatch, command)
    with pytest.raises(anisette.AnisetteError):
        anisette._raw_headers()
    assert anisette._raw_headers()["X-Apple-I-MD"] == "second-helper"


def test_helper_that_died_while_idle_is_replaced(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    command = _write_stub(
        tmp_path,
        """
        if req.get("op") == "headers":
            reply({"ok": True, "headers": {"pid": os.getpid()}})
        """,
    )
    _command(monkeypatch, command)
    first = anisette._raw_headers()["pid"]
    worker = anisette._worker
    assert worker is not None
    worker._proc.kill()
    worker._proc.wait()
    assert anisette._raw_headers()["pid"] != first


def test_errors_the_helper_reports_keep_their_text(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    command = _write_stub(
        tmp_path,
        """
        if req.get("op") == "headers":
            reply({"ok": False, "error": "Could not download Apple's libraries"})
        """,
    )
    _command(monkeypatch, command)
    with pytest.raises(anisette.AnisetteError, match="Could not download Apple's libraries"):
        anisette.get_headers()


def test_unparseable_lines_are_skipped(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    command = _write_stub(
        tmp_path,
        """
        if req.get("op") == "headers":
            sys.stdout.write("not json at all\\n"); sys.stdout.flush()
            reply({"ok": True, "headers": {"X-Apple-I-MD": "after-noise"}})
        """,
    )
    _command(monkeypatch, command)
    assert anisette._raw_headers()["X-Apple-I-MD"] == "after-noise"


def test_silent_helper_times_out_and_is_stopped(tmp_path: Path) -> None:
    command = _write_stub(
        tmp_path,
        """
        if req.get("op") == "headers":
            import time; time.sleep(60)
        """,
    )
    worker = anisette._AnisetteWorker(command)
    with pytest.raises(anisette.AnisetteError, match="did not answer"):
        worker.headers(timeout=0.5)
    assert not worker.alive()


def test_a_helper_that_cannot_start_is_reported(monkeypatch: pytest.MonkeyPatch) -> None:
    _command(monkeypatch, ["C:/definitely/not/a/real/python.exe"])
    with pytest.raises(anisette.AnisetteError, match="Could not start"):
        anisette._raw_headers()


def test_in_process_mode_skips_the_helper(monkeypatch: pytest.MonkeyPatch) -> None:
    class _Provider:
        def get_data(self) -> dict[str, str]:
            return {"X-Apple-I-MD": "inline"}

    monkeypatch.setenv("IPASIDE_ANISETTE_INPROCESS", "1")
    monkeypatch.setattr(anisette, "_load_provider", lambda: _Provider())
    monkeypatch.setattr(
        anisette, "_worker_command", lambda: pytest.fail("a helper must not be started")
    )
    assert anisette._raw_headers() == {"X-Apple-I-MD": "inline"}


# --------------------------------------------------------------------------- #
# The real helper module (no network: it is only asked protocol questions)
# --------------------------------------------------------------------------- #


def _real_worker() -> subprocess.Popen:
    env = {"PYTHONPATH": str(ENGINE_DIR), "SYSTEMROOT": __import__("os").environ.get("SYSTEMROOT", "")}
    return subprocess.Popen(
        [sys.executable, "-m", "ipaside_engine.anisette_worker"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        env=env,
    )


def test_real_helper_speaks_only_json_on_stdout_and_exits_on_shutdown() -> None:
    proc = _real_worker()
    try:
        assert proc.stdin and proc.stdout
        proc.stdin.write(json.dumps({"op": "nonsense"}) + "\n")
        proc.stdin.write(json.dumps({"op": "shutdown"}) + "\n")
        proc.stdin.flush()
        out, _err = proc.communicate(timeout=60)
    finally:
        proc.kill()
    frames = [json.loads(line) for line in out.splitlines() if line.strip()]
    assert frames[0] == {"ready": True}
    assert frames[1]["ok"] is False
    assert "nonsense" in frames[1]["error"]
    assert proc.returncode == 0


def test_real_helper_exits_when_the_engine_goes_away() -> None:
    proc = _real_worker()
    assert proc.stdin and proc.stdout
    assert json.loads(proc.stdout.readline()) == {"ready": True}
    proc.stdin.close()  # what the engine dying looks like from the helper's side
    assert proc.wait(timeout=30) == 0
    proc.stdout.close()
    assert proc.stderr is not None
    proc.stderr.close()
