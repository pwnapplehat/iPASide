"""The Windows service check must not depend on the language Windows prints in.

GitHub issue #13: on an Italian Windows ``sc query`` labels the state line ``STATO``, not ``STATE``,
so iPASide read nothing, called the running Apple Mobile Device Service missing and told the person
to reinstall iTunes. The state is now asked of the service manager, which has no language, and the
``sc`` fallback reads the number and the English state name instead of the label.
"""

from __future__ import annotations

import os
import subprocess
from types import SimpleNamespace
from typing import Any

import pytest

from ipaside_engine import doctor

# What `sc query "Apple Mobile Device Service"` prints, by Windows display language. Only the labels
# are translated; the state number and its name are not.
_SC_OUTPUT = {
    "english": (
        "SERVICE_NAME: Apple Mobile Device Service\n"
        "        TYPE               : 10  WIN32_OWN_PROCESS\n"
        "        STATE              : 4  RUNNING\n"
        "                                (STOPPABLE, NOT_PAUSABLE, IGNORES_SHUTDOWN)\n"
        "        WIN32_EXIT_CODE    : 0  (0x0)\n"
    ),
    "italian": (
        "NOME_SERVIZIO: Apple Mobile Device Service\n"
        "        TIPO               : 10  WIN32_OWN_PROCESS\n"
        "        STATO              : 4  RUNNING\n"
        "                                (STOPPABLE, NOT_PAUSABLE, IGNORES_SHUTDOWN)\n"
        "        CODICE_USCITA_WIN32: 0  (0x0)\n"
    ),
    "german": (
        "SERVICE_NAME: Apple Mobile Device Service\n"
        "        TYP                : 10  WIN32_OWN_PROCESS\n"
        "        ZUSTAND            : 4  RUNNING\n"
        "        WIN32_EXITCODE     : 0  (0x0)\n"
    ),
    "french": (
        "NOM_SERVICE : Apple Mobile Device Service\n"
        "        TYPE               : 10  WIN32_OWN_PROCESS\n"
        "        ETAT               : 4  RUNNING\n"
        "        CODE_SORTIE_WIN32  : 0  (0x0)\n"
    ),
}


@pytest.mark.parametrize("language", sorted(_SC_OUTPUT))
def test_the_state_is_read_whatever_the_label_says(language: str) -> None:
    assert doctor._parse_sc_state(_SC_OUTPUT[language]) == "RUNNING"


@pytest.mark.parametrize(
    ("code", "name"),
    [(1, "STOPPED"), (2, "START_PENDING"), (3, "STOP_PENDING"), (4, "RUNNING"), (7, "PAUSED")],
)
def test_every_state_is_recognised_in_a_translated_listing(code: int, name: str) -> None:
    listing = f"NOME_SERVIZIO: X\n        TIPO               : 10  WIN32_OWN_PROCESS\n        STATO              : {code}  {name}\n"
    assert doctor._parse_sc_state(listing) == name


def test_the_type_line_is_never_mistaken_for_the_state() -> None:
    """``TYPE : 10  WIN32_OWN_PROCESS`` has the same shape as the state line."""
    assert doctor._parse_sc_state("        TYPE               : 10  WIN32_OWN_PROCESS\n") is None
    assert doctor._parse_sc_state("") is None
    assert doctor._parse_sc_state("[SC] EnumQueryServicesStatus:OpenService FAILED 1060:\n") is None


def test_a_state_number_that_disagrees_with_its_name_is_not_trusted() -> None:
    assert doctor._parse_sc_state("        STATO              : 1  RUNNING\n") is None


# --------------------------------------------------------------------------- #
# _windows_service_state
# --------------------------------------------------------------------------- #
@pytest.fixture
def on_windows(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(doctor.os, "name", "nt")


def _sc(monkeypatch: pytest.MonkeyPatch, stdout: str, returncode: int = 0) -> list[list[str]]:
    calls: list[list[str]] = []

    def fake_run(cmd: list[str], **kwargs: Any) -> Any:
        calls.append(cmd)
        return SimpleNamespace(returncode=returncode, stdout=stdout)

    monkeypatch.setattr(doctor.subprocess, "run", fake_run)
    return calls


def test_the_service_manager_answer_is_used_without_running_sc(
    monkeypatch: pytest.MonkeyPatch, on_windows: None
) -> None:
    monkeypatch.setattr(doctor, "_service_state_from_api", lambda name: "RUNNING")
    calls = _sc(monkeypatch, "")
    assert doctor._windows_service_state("Apple Mobile Device Service") == "RUNNING"
    assert calls == []


def test_a_service_the_manager_says_is_not_installed_is_missing_not_unknown(
    monkeypatch: pytest.MonkeyPatch, on_windows: None
) -> None:
    monkeypatch.setattr(doctor, "_service_state_from_api", lambda name: None)
    calls = _sc(monkeypatch, _SC_OUTPUT["english"])  # must not be consulted and contradict it
    assert doctor._windows_service_state("Bonjour Service") is None
    assert calls == []


def test_when_the_manager_cannot_be_asked_sc_is_the_fallback_in_any_language(
    monkeypatch: pytest.MonkeyPatch, on_windows: None
) -> None:
    def broken(name: str) -> str | None:
        raise OSError("service manager unavailable")

    monkeypatch.setattr(doctor, "_service_state_from_api", broken)
    calls = _sc(monkeypatch, _SC_OUTPUT["italian"])
    assert doctor._windows_service_state("Apple Mobile Device Service") == "RUNNING"
    assert calls == [["sc", "query", "Apple Mobile Device Service"]]


def test_the_fallback_reports_a_failed_sc_as_not_found(
    monkeypatch: pytest.MonkeyPatch, on_windows: None
) -> None:
    def broken(name: str) -> str | None:
        raise OSError("service manager unavailable")

    monkeypatch.setattr(doctor, "_service_state_from_api", broken)
    _sc(monkeypatch, "[SC] EnumQueryServicesStatus:OpenService FAILED 1060:\n", returncode=1060)
    assert doctor._windows_service_state("Nope") is None


def test_the_fallback_does_not_trust_the_output_of_a_failed_sc(
    monkeypatch: pytest.MonkeyPatch, on_windows: None
) -> None:
    def broken(name: str) -> str | None:
        raise OSError("service manager unavailable")

    monkeypatch.setattr(doctor, "_service_state_from_api", broken)
    _sc(monkeypatch, _SC_OUTPUT["english"], returncode=1)
    assert doctor._windows_service_state("Anything") is None


def test_the_fallback_survives_sc_itself_being_unavailable(
    monkeypatch: pytest.MonkeyPatch, on_windows: None
) -> None:
    def broken(name: str) -> str | None:
        raise OSError("service manager unavailable")

    def no_sc(cmd: list[str], **kwargs: Any) -> Any:
        raise subprocess.TimeoutExpired(cmd, 10)

    monkeypatch.setattr(doctor, "_service_state_from_api", broken)
    monkeypatch.setattr(doctor.subprocess, "run", no_sc)
    assert doctor._windows_service_state("Anything") is None


def test_other_systems_have_no_windows_services(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(doctor.os, "name", "posix")
    assert doctor._windows_service_state("Apple Mobile Device Service") is None


@pytest.mark.skipif(os.name != "nt", reason="needs the Windows service manager")
def test_the_real_service_manager_reports_a_running_service_and_a_missing_one() -> None:
    """The Event Log service always runs; no service is called this."""
    assert doctor._windows_service_state("EventLog") == "RUNNING"
    assert doctor._windows_service_state("IPASide No Such Service") is None
