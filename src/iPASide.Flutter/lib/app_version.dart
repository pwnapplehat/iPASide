/// The running application version.
///
/// Flutter offers no way to read the pubspec version at runtime without pulling
/// in a plugin, so it is mirrored here and `test/app_version_test.dart` fails the
/// build if the two ever drift — a stale value would make the updater compare
/// against the wrong version and either nag forever or never offer an update.
const String kAppVersion = '1.1.2';
