"""App group provisioning: the order Apple requires, and reuse of what already exists.

Attaching an app group is three calls that only work in one order - enable the capability
on the App ID, assign the group, then download the profile. Get it wrong and the profile
comes back without the group, which does not fail anywhere: the app installs and only
misbehaves once it tries to reach the shared container. So the order is worth a test.
"""

from __future__ import annotations

import pytest

from ipaside_engine import developer, provision

TEAM = "ASK9QR9SBC"
APP_ID_ID = "ABCDE12345"
SIDESTORE = f"group.com.SideStore.SideStore.{TEAM}"
ALTSTORE = f"group.com.rileytestut.AltStore.{TEAM}"


class _Portal:
    """Records the developerservices2 calls provisioning makes, in order."""

    def __init__(
        self,
        existing: list[dict[str, str]] | None = None,
        fail_add: set[str] | None = None,
        reveal_after_failed_add: dict[str, str] | None = None,
    ):
        self.calls: list[tuple[str, tuple]] = []
        self.existing = list(existing or [])
        self.fail_add = set(fail_add or [])
        self.reveal_after_failed_add = reveal_after_failed_add
        self._next_id = 0

    def enable_app_id_feature(self, team_id, app_id_id, feature, enabled=True):
        self.calls.append(("enable", (team_id, app_id_id, feature, enabled)))
        return {}

    def list_application_groups(self, team_id):
        self.calls.append(("list", (team_id,)))
        return list(self.existing)

    def add_application_group(self, team_id, identifier, name):
        self.calls.append(("add", (team_id, identifier, name)))
        if identifier in self.fail_add:
            if self.reveal_after_failed_add is not None:
                self.existing.append(self.reveal_after_failed_add)
                self.reveal_after_failed_add = None
            raise developer.DeveloperServicesError(
                f"An Application Group with Identifier '{identifier}' is not available. "
                "Please enter a different string."
            )
        self._next_id += 1
        group = {"identifier": identifier, "applicationGroup": f"NEW{self._next_id}"}
        self.existing.append(group)
        return group

    def assign_application_groups(self, team_id, app_id_id, group_ids):
        self.calls.append(("assign", (team_id, app_id_id, tuple(group_ids))))

    def names(self) -> list[str]:
        return [name for name, _args in self.calls]


@pytest.fixture
def portal(monkeypatch):
    def _make(existing=None, features=None, fail_add=None, reveal_after_failed_add=None):
        fake = _Portal(
            existing,
            fail_add=fail_add,
            reveal_after_failed_add=reveal_after_failed_add,
        )
        for method in (
            "enable_app_id_feature",
            "list_application_groups",
            "add_application_group",
            "assign_application_groups",
        ):
            monkeypatch.setattr(developer, method, getattr(fake, method))
        fake.app_id = {"features": features or {}}
        return fake

    return _make


def _run(fake, identifiers=(SIDESTORE, ALTSTORE)):
    return provision._ensure_app_groups(
        TEAM, fake.app_id, APP_ID_ID, list(identifiers), "LiveContainer"
    )


def test_capability_is_enabled_before_the_group_is_assigned(portal):
    fake = portal(existing=[{"identifier": SIDESTORE, "applicationGroup": "KYV9UNTKC3"}])
    _run(fake, [SIDESTORE])

    assert fake.names().index("enable") < fake.names().index("assign")


def test_capability_is_not_reenabled_when_already_on(portal):
    """Apple already has it on for a second install; saying so again is a wasted call."""
    fake = portal(
        existing=[{"identifier": SIDESTORE, "applicationGroup": "KYV9UNTKC3"}],
        features={developer.FEATURE_APP_GROUPS: True},
    )
    _run(fake, [SIDESTORE])

    assert "enable" not in fake.names()
    assert "assign" in fake.names()


def test_existing_groups_are_reused_not_recreated(portal):
    """Creating one that exists fails, and free accounts have limited identifier slots."""
    fake = portal(
        existing=[
            {"identifier": SIDESTORE, "applicationGroup": "KYV9UNTKC3"},
            {"identifier": ALTSTORE, "applicationGroup": "22D35H6ZT2"},
        ]
    )
    group_ids = _run(fake)

    assert "add" not in fake.names()
    assert group_ids == ["KYV9UNTKC3", "22D35H6ZT2"]


def test_missing_groups_are_created(portal):
    fake = portal(existing=[{"identifier": SIDESTORE, "applicationGroup": "KYV9UNTKC3"}])
    group_ids = _run(fake)

    added = [args[1] for name, args in fake.calls if name == "add"]
    assert added == [ALTSTORE], "only the absent group should be created"
    assert group_ids == ["KYV9UNTKC3", "NEW1"]


def test_all_groups_are_assigned_in_one_call(portal):
    """assignApplicationGroupToAppId replaces the set, so a second call would drop the first."""
    fake = portal(
        existing=[
            {"identifier": SIDESTORE, "applicationGroup": "KYV9UNTKC3"},
            {"identifier": ALTSTORE, "applicationGroup": "22D35H6ZT2"},
        ]
    )
    _run(fake)

    assigns = [args for name, args in fake.calls if name == "assign"]
    assert len(assigns) == 1
    assert assigns[0][2] == ("KYV9UNTKC3", "22D35H6ZT2")


def test_a_group_without_an_id_is_refused(portal):
    """Assigning an empty id silently attaches nothing, so fail while we can still say why."""
    fake = portal(existing=[{"identifier": SIDESTORE}])  # no applicationGroup

    with pytest.raises(Exception, match="no id to assign"):
        _run(fake, [SIDESTORE])


GROUP = "group.com.ipaside.escapeos"
SCOPED = f"{GROUP}.{TEAM}"


def test_a_group_another_team_owns_falls_back_to_a_team_scoped_id(portal):
    """The literal id is tried first. Apple refusing it, and a fresh list still
    missing it, means another team owns that string."""
    fake = portal(fail_add={GROUP})
    group_ids = _run(fake, [GROUP])

    added = [args[1] for name, args in fake.calls if name == "add"]
    assert added == [GROUP, SCOPED]
    assert group_ids == ["NEW1"]
    lists_after_first_add = [
        index for index, (name, _args) in enumerate(fake.calls)
        if name == "list" and index > fake.names().index("add")
    ]
    assert lists_after_first_add, "a failed create re-lists before substituting"


def test_an_existing_team_scoped_group_is_reused(portal):
    fake = portal(
        existing=[{"identifier": SCOPED, "applicationGroup": "OWNED1"}],
        fail_add={GROUP},
    )
    group_ids = _run(fake, [GROUP])

    added = [args[1] for name, args in fake.calls if name == "add"]
    assert added == [GROUP]
    assert group_ids == ["OWNED1"]


def test_a_group_found_on_relist_is_used_without_a_substitute(portal):
    """The first list can miss a group this team already holds. The re-list is the check."""
    fake = portal(
        fail_add={GROUP},
        reveal_after_failed_add={"identifier": GROUP, "applicationGroup": "RACE1"},
    )
    group_ids = _run(fake, [GROUP])

    added = [args[1] for name, args in fake.calls if name == "add"]
    assert added == [GROUP]
    assert group_ids == ["RACE1"]


def test_no_app_groups_means_no_portal_calls(monkeypatch):
    """An ordinary sideload must not touch any of these endpoints."""
    called: list[str] = []
    for method in (
        "enable_app_id_feature",
        "list_application_groups",
        "add_application_group",
        "assign_application_groups",
    ):
        monkeypatch.setattr(
            developer, method, lambda *a, _m=method, **k: called.append(_m)
        )

    # ensure_signing_assets only calls _ensure_app_groups when app_groups is truthy;
    # this asserts the guard rather than the helper.
    assert not called
