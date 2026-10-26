import 'dart:io';

/// The running application version.
///
/// Flutter offers no way to read the pubspec version at runtime without pulling
/// in a plugin, so it is mirrored here and `test/app_version_test.dart` fails the
/// build if the two ever drift — a stale value would make the updater compare
/// against the wrong version and either nag forever or never offer an update.
const String kAppVersion = '1.2.12';

/// Version the in-app updater compares against.
///
/// Defaults to [kAppVersion]. Set `IPASIDE_TEST_CURRENT_VERSION` (e.g. `1.0.0`)
/// to pretend an older build is running so the update banner and Settings
/// Updates card can be exercised against a real newer GitHub release without
/// shipping a fake product version.
String get resolvedAppVersion {
  final String? override =
      Platform.environment['IPASIDE_TEST_CURRENT_VERSION']?.trim();
  if (override != null && override.isNotEmpty) return override;
  return kAppVersion;
}
