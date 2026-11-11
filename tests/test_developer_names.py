"""Apple portal names are ASCII. The phone's display name is not this string."""

from ipaside_engine.developer import _sanitize_name


def test_accented_app_names_become_ascii():
    # Issue 17: Apple result 35, appIdName 'Pokémon GO'.
    assert _sanitize_name("Pokémon GO") == "Pokemon GO"


def test_non_ascii_that_cannot_fold_is_dropped():
    assert _sanitize_name("游戏 Pokémon") == "Pokemon"


def test_a_name_with_no_ascii_letters_uses_the_fallback():
    assert _sanitize_name("游戏") == "iPASide"


def test_punctuation_and_extra_spaces_are_removed():
    assert _sanitize_name("  Hello,  World!  ") == "Hello World"
