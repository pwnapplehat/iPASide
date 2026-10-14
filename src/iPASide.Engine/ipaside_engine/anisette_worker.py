"""Child process that runs Apple's provisioning emulator, one request per line.

Anisette headers come from the Unicorn CPU emulator executing Apple's own arm64
libraries. Unicorn is native code that JIT-compiles into host memory, which is exactly
what Windows exploit mitigations (Control Flow Guard, hardware shadow stacks, dynamic
code prohibition) and some security products object to. When one of them objects the
process does not raise a Python exception: it is killed outright, with nothing on
stdout and no traceback.

Running the emulator here instead of inside the engine means that failure ends only
this child. The engine sees it exit, reads the exit code and the last lines it printed,
and turns them into an error the user can act on (see ``anisette._describe_worker_exit``)
rather than losing the whole engine - and the sign-in screen with it.

Protocol: the parent writes ``{"op": "headers"}`` per line on stdin; this process
answers one JSON line on the *original* stdout. File descriptor 1 is re-pointed at
stderr before anything else runs, so a stray ``print`` from a library cannot corrupt a
reply frame.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, TextIO


def _protocol_channel() -> TextIO:
    """Keep the real stdout for replies; send everything else to stderr."""
    channel = os.fdopen(os.dup(1), "w", encoding="utf-8", newline="\n")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return channel


def _reply(channel: TextIO, payload: dict[str, Any]) -> None:
    channel.write(json.dumps(payload, default=str) + "\n")
    channel.flush()


def _headers_reply() -> dict[str, Any]:
    from . import anisette

    try:
        provider = anisette._load_provider()
        return {"ok": True, "headers": dict(provider.get_data())}
    except Exception as exc:  # noqa: BLE001 - every failure travels back as text
        return {"ok": False, "error": str(exc) or type(exc).__name__}


def main() -> int:
    channel = _protocol_channel()
    reconfigure = getattr(sys.stdin, "reconfigure", None)
    if reconfigure is not None:
        try:
            reconfigure(encoding="utf-8")
        except (ValueError, OSError):
            pass

    _reply(channel, {"ready": True})
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            request = json.loads(raw)
        except json.JSONDecodeError:
            continue
        op = request.get("op") if isinstance(request, dict) else None
        if op == "headers":
            _reply(channel, _headers_reply())
        elif op == "shutdown":
            break
        else:
            _reply(channel, {"ok": False, "error": f"unknown operation {op!r}"})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
