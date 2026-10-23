import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine_api.dart';
import 'package:ipaside/engine/engine_client.dart';
import 'package:ipaside/engine/engine_exception.dart';
import 'package:ipaside/platform/app_paths.dart';
import 'package:ipaside/platform/background_refresh_scheduler.dart';
import 'package:ipaside/services/file_picker.dart';
import 'package:ipaside/services/settings_store.dart';
import 'package:ipaside/ui/shell/app_dialogs.dart';
import 'package:ipaside/ui/shell/nav_destination.dart';
import 'package:ipaside/viewmodels/device_selection.dart';
import 'package:ipaside/viewmodels/navigation_state.dart';
import 'package:ipaside/viewmodels/settings_view_model.dart';

/// A transport stand-in that answers per command, since Settings loads the
/// session, anisette and version at once.
class _FakeRunner with EngineCommandRunner {
  final Map<String, EngineResult> results = <String, EngineResult>{};

  /// Results consumed one per call, for a command whose answer changes between
  /// reads — a folder listed again after being emptied. Falls back to [results]
  /// once drained.
  final Map<String, List<EngineResult>> queued =
      <String, List<EngineResult>>{};
  final Map<String, Object> failures = <String, Object>{};
  final List<List<String>> calls = <List<String>>[];

  static const EngineResult _empty = EngineResult(
    ok: true,
    data: <String, dynamic>{},
  );

  bool ran(List<String> args) =>
      calls.any((List<String> call) => call.join(' ') == args.join(' '));

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);

    final String key = args.join(' ');
    final String first = args.isEmpty ? '' : args.first;
    final Object? failure = failures[key] ??
        (first == 'pairing' ? failures[first] : null);
    if (failure != null) {
      throw failure;
    }

    final List<EngineResult>? queue = queued[key] ??
        (first == 'pairing' ? queued[first] : null);
    if (queue != null && queue.isNotEmpty) {
      return queue.removeAt(0);
    }
    return results[key] ??
        (first == 'pairing' ? results[first] : null) ??
        _empty;
  }
}

/// An OS scheduler stand-in.
class _FakeScheduler implements BackgroundRefreshScheduler {
  _FakeScheduler({this.isSupported = true, this.enabled = false});

  @override
  final bool isSupported;

  bool enabled;

  /// When true, [setEnabled] is recorded but leaves the schedule untouched -
  /// the way a create that silently did nothing would look.
  bool ignoreSet = false;

  /// Thrown by [setEnabled] when set.
  Object? setFailure;

  /// Thrown by [isEnabled] when set.
  Object? queryFailure;

  /// Holds [setEnabled] open so the test can observe the busy state.
  Completer<void>? gate;

  final List<bool> setCalls = <bool>[];
  int queries = 0;

  @override
  Future<bool> isEnabled() async {
    queries++;
    final Object? failure = queryFailure;
    if (failure != null) {
      throw failure;
    }
    return enabled;
  }

  @override
  Future<void> setEnabled(bool value) async {
    setCalls.add(value);

    final Completer<void>? parked = gate;
    if (parked != null) {
      await parked.future;
    }
    final Object? failure = setFailure;
    if (failure != null) {
      throw failure;
    }
    if (!ignoreSet) enabled = value;
  }
}

/// A picker stand-in: hands back whatever the test says the shell would.
class _FakePicker implements FilePickerService {
  /// What [pickSignedFolder] returns; null is a cancelled dialog.
  String? folder;

  int folderPrompts = 0;

  String? pairingToOpen;
  String? pairingToSave;
  int pairingOpenCount = 0;
  int pairingSaveCount = 0;

  @override
  Future<String?> pickSignedFolder() async {
    folderPrompts++;
    return folder;
  }

  @override
  Future<String?> pickIpa() async =>
      throw UnsupportedError('Settings never opens an IPA.');

  @override
  Future<List<String>> pickTweaks() async =>
      throw UnsupportedError('Settings never opens a tweak.');

  @override
  Future<String?> pickPairingFile() async {
    pairingOpenCount++;
    return pairingToOpen;
  }

  @override
  Future<String?> savePairingFile({required String suggestedName}) async {
    pairingSaveCount++;
    return pairingToSave;
  }
}

/// A dialog stand-in: answers [confirm] without a navigator.
class _FakeDialogs extends DialogService {
  _FakeDialogs() : super(GlobalKey<NavigatorState>());

  /// What the user clicks. False is the Cancel button, or Escape.
  bool answer = true;

  final List<String> confirmMessages = <String>[];

  @override
  Future<bool> confirm({
    required String title,
    required String message,
    String confirmLabel = 'OK',
    String cancelLabel = 'Cancel',
    bool danger = false,
  }) async {
    confirmMessages.add(message);
    return answer;
  }
}

/// Drains the microtask queue so the loads started in the constructor have
/// settled.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// A `signed` payload for [count] files of [bytes] each.
EngineResult _signedListing({
  required String directory,
  int count = 0,
  int bytes = 0,
}) => EngineResult(
  ok: true,
  data: <String, dynamic>{
    'directory': directory,
    'count': count,
    'bytes': bytes,
    'files': <dynamic>[
      for (int i = 0; i < count; i++)
        <String, dynamic>{
          'name': 'app$i.ipa',
          'bytes': count == 0 ? 0 : bytes ~/ count,
          'modified': '2026-07-25T12:00:00Z',
        },
    ],
  },
);

void main() {
  late _FakeRunner runner;
  late _FakeScheduler scheduler;
  late NavigationState navigation;
  late _FakePicker picker;
  late _FakeDialogs dialogs;
  late Directory temp;
  late SettingsStore settings;
  SettingsViewModel? viewModel;
  DeviceSelection? devices;

  setUp(() {
    runner = _FakeRunner();
    scheduler = _FakeScheduler();
    navigation = NavigationState()..navigateTo(NavKey.settings);
    picker = _FakePicker();
    dialogs = _FakeDialogs();
    temp = Directory.systemTemp.createTempSync('ipaside_settings_vm');
    settings = SettingsStore(paths: AppPaths.rooted(temp.path));
  });

  tearDown(() {
    final SettingsViewModel? model = viewModel;
    viewModel = null;
    if (model != null && !model.isDisposed) model.dispose();
    final DeviceSelection? selection = devices;
    devices = null;
    if (selection != null && !selection.isDisposed) selection.dispose();
    temp.deleteSync(recursive: true);
  });

  Future<SettingsViewModel> load() async {
    devices = DeviceSelection(engine: EngineApi(runner), settings: settings);
    final SettingsViewModel model = SettingsViewModel(
      engine: EngineApi(runner),
      navigation: navigation,
      scheduler: scheduler,
      settings: settings,
      picker: picker,
      dialogs: dialogs,
      devices: devices!,
    );
    viewModel = model;
    await _settle();
    return model;
  }

  group('SettingsViewModel auto-refresh', () {
    test('is unsupported when the OS has no scheduler', () async {
      scheduler = _FakeScheduler(isSupported: false, enabled: true);

      final SettingsViewModel model = await load();

      expect(model.autoRefreshSupported, isFalse);
      expect(model.autoRefreshEnabled, isFalse);
      expect(scheduler.queries, 0, reason: 'the schedule is never queried');
    });

    test('reflects an existing schedule on load', () async {
      scheduler = _FakeScheduler(enabled: true);

      final SettingsViewModel model = await load();

      expect(model.autoRefreshSupported, isTrue);
      expect(model.autoRefreshEnabled, isTrue);
      expect(model.hasAutoRefreshMessage, isFalse);
    });

    test('leaves the toggle off when the schedule cannot be read', () async {
      scheduler.queryFailure = BackgroundRefreshException('schtasks failed');

      final SettingsViewModel model = await load();

      expect(model.autoRefreshEnabled, isFalse);
      expect(model.hasAutoRefreshMessage, isFalse);
    });

    test('enabling confirms the daily schedule', () async {
      final SettingsViewModel model = await load();

      await model.setAutoRefreshEnabled(true);

      expect(scheduler.setCalls, <bool>[true]);
      expect(scheduler.enabled, isTrue);
      expect(model.autoRefreshEnabled, isTrue);
      expect(model.autoRefreshMessage, 'On \u2014 runs daily at noon.');
      expect(model.hasAutoRefreshMessage, isTrue);
      expect(model.isAutoRefreshMessageError, isFalse);
      expect(model.autoRefreshBusy, isFalse);
    });

    test('disabling confirms the schedule is gone', () async {
      scheduler = _FakeScheduler(enabled: true);
      final SettingsViewModel model = await load();

      await model.setAutoRefreshEnabled(false);

      expect(scheduler.setCalls, <bool>[false]);
      expect(model.autoRefreshEnabled, isFalse);
      expect(model.autoRefreshMessage, 'Off.');
      expect(model.isAutoRefreshMessageError, isFalse);
    });

    test('the message follows what the OS actually has', () async {
      scheduler.ignoreSet = true;
      final SettingsViewModel model = await load();

      await model.setAutoRefreshEnabled(true);

      expect(model.autoRefreshEnabled, isFalse);
      expect(model.autoRefreshMessage, 'Off.');
    });

    test('a refused change rolls the toggle back and reports why', () async {
      scheduler.setFailure = BackgroundRefreshException(
        'schtasks failed: Access is denied.',
      );
      final SettingsViewModel model = await load();

      await model.setAutoRefreshEnabled(true);

      expect(model.autoRefreshEnabled, isFalse);
      expect(model.autoRefreshMessage, 'schtasks failed: Access is denied.');
      expect(model.isAutoRefreshMessageError, isTrue);
      expect(model.autoRefreshBusy, isFalse);
    });

    test('a refused disable rolls the toggle back on', () async {
      scheduler = _FakeScheduler(enabled: true);
      scheduler.setFailure = BackgroundRefreshException('schtasks failed');
      final SettingsViewModel model = await load();

      await model.setAutoRefreshEnabled(false);

      expect(model.autoRefreshEnabled, isTrue);
      expect(model.isAutoRefreshMessageError, isTrue);
    });

    test('the toggle moves and blocks while the change runs', () async {
      scheduler.gate = Completer<void>();
      final SettingsViewModel model = await load();

      final Future<void> pending = model.setAutoRefreshEnabled(true);
      await _settle();

      expect(model.autoRefreshBusy, isTrue);
      expect(model.autoRefreshEnabled, isTrue);
      expect(model.hasAutoRefreshMessage, isFalse);

      await model.setAutoRefreshEnabled(false);
      expect(scheduler.setCalls, <bool>[true], reason: 'busy blocks re-entry');

      scheduler.gate!.complete();
      await pending;

      expect(model.autoRefreshBusy, isFalse);
      expect(model.autoRefreshMessage, 'On \u2014 runs daily at noon.');
    });

    test('setting the value it already has does nothing', () async {
      final SettingsViewModel model = await load();

      await model.setAutoRefreshEnabled(false);

      expect(scheduler.setCalls, isEmpty);
      expect(model.hasAutoRefreshMessage, isFalse);
    });
  });

  group('SettingsViewModel account', () {
    test('shows the signed-in Apple ID', () async {
      runner.results['login --status'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{'authenticated': true, 'email': 'user@example.com'},
      );

      final SettingsViewModel model = await load();

      expect(model.isAccountLoading, isFalse);
      expect(model.isAuthenticated, isTrue);
      expect(model.accountEmail, 'user@example.com');
      expect(model.isAccountSignedOut, isFalse);
      expect(model.hasAccountError, isFalse);
    });

    test('shows the signed-out state when there is no session', () async {
      final SettingsViewModel model = await load();

      expect(model.isAuthenticated, isFalse);
      expect(model.isAccountSignedOut, isTrue);
      expect(model.accountEmail, isEmpty);
    });

    test('shows a cleaned failure instead of either state', () async {
      runner.results['login --status'] = const EngineResult(
        ok: false,
        error: 'Engine exited with code 1. keychain is locked',
      );

      final SettingsViewModel model = await load();

      expect(model.accountError, 'keychain is locked');
      expect(model.hasAccountError, isTrue);
      expect(model.isAccountSignedOut, isFalse);
      expect(model.isAuthenticated, isFalse);
    });

    test('a shutdown leaves no error behind', () async {
      runner.failures['login --status'] = EngineShutdownException();

      final SettingsViewModel model = await load();

      expect(model.hasAccountError, isFalse);
      expect(model.isAccountLoading, isFalse);
    });

    test('signing out remounts Settings', () async {
      runner.results['login --status'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{'authenticated': true, 'email': 'user@example.com'},
      );
      final SettingsViewModel model = await load();
      final int epoch = navigation.epoch;

      await model.signOut();

      expect(runner.ran(<String>['login', '--logout']), isTrue);
      expect(navigation.current, NavKey.settings);
      expect(navigation.epoch, greaterThan(epoch));
      expect(model.hasAccountError, isFalse);
    });

    test('a failed sign-out reports why and stays put', () async {
      runner.results['login --logout'] = const EngineResult(
        ok: false,
        error: 'keychain is locked',
      );
      final SettingsViewModel model = await load();
      final int epoch = navigation.epoch;

      await model.signOut();

      expect(model.accountError, 'keychain is locked');
      expect(navigation.epoch, epoch);
    });

    test('a sign-out interrupted by shutdown navigates nowhere', () async {
      runner.failures['login --logout'] = EngineShutdownException();
      final SettingsViewModel model = await load();
      final int epoch = navigation.epoch;

      await model.signOut();

      expect(model.hasAccountError, isFalse);
      expect(navigation.epoch, epoch);
    });

    test('signing in opens the sign-in screen', () async {
      final SettingsViewModel model = await load();

      model.signIn();

      expect(navigation.current, NavKey.signIn);
    });
  });

  group('SettingsViewModel anisette', () {
    test('reports the package and provisioned state', () async {
      runner.results['anisette'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{'package_version': '1.2.4', 'state_cached': true},
      );

      final SettingsViewModel model = await load();

      expect(model.isAnisetteLoading, isFalse);
      expect(model.anisetteProvider, 'anisette 1.2.4');
      expect(model.anisetteState, 'provisioned');
      expect(model.hasAnisetteError, isFalse);
    });

    test('a remote provider is named, with its services as host names', () async {
      runner.results['anisette'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{
          'provider': 'remote',
          'state_cached': true,
          'servers': <String>[
            'https://mac-ani.jkcoxson.com',
            'https://new.ani.sidestore.io',
            'https://ani3.stikstore.app',
          ],
        },
      );

      final SettingsViewModel model = await load();

      expect(model.anisetteIsRemote, isTrue);
      expect(model.anisetteProvider, 'Remote Mac service');
      expect(
        model.anisetteServers,
        'mac-ani.jkcoxson.com, new.ani.sidestore.io, ani3.stikstore.app',
      );
      expect(model.anisetteState, 'provisioned');
    });

    test('the local provider keeps the package text and shows no services', () async {
      runner.results['anisette'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{
          'provider': 'local',
          'package_version': '1.2.4',
          'servers': <String>[],
        },
      );

      final SettingsViewModel model = await load();

      expect(model.anisetteIsRemote, isFalse);
      expect(model.anisetteProvider, 'anisette 1.2.4');
      expect(model.anisetteServers, isEmpty);
    });

    test('reports first-use when no state is cached', () async {
      runner.results['anisette'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{'package_version': '1.2.4'},
      );

      final SettingsViewModel model = await load();

      expect(model.anisetteState, 'first-use');
    });

    test('a missing package version renders as a question mark', () async {
      final SettingsViewModel model = await load();

      expect(model.anisetteProvider, 'anisette ?');
    });

    test('a failure is shown cleaned', () async {
      runner.results['anisette'] = const EngineResult(
        ok: false,
        error: 'anisette is not installed',
      );

      final SettingsViewModel model = await load();

      expect(model.anisetteError, 'anisette is not installed');
      expect(model.hasAnisetteError, isTrue);
      expect(model.isAnisetteLoading, isFalse);
    });
  });

  group('SettingsViewModel about', () {
    test('shows the engine version', () async {
      runner.results['version'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{'version': '0.1.0'},
      );

      final SettingsViewModel model = await load();

      expect(model.engineVersionText, '0.1.0');
    });

    test('an empty version renders as a question mark', () async {
      runner.results['version'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{'version': ''},
      );

      final SettingsViewModel model = await load();

      expect(model.engineVersionText, '?');
    });

    test('a failure leaves the placeholder in place', () async {
      runner.results['version'] = const EngineResult(
        ok: false,
        error: 'engine is not installed',
      );

      final SettingsViewModel model = await load();

      expect(model.engineVersionText, '\u2026');
    });
  });

  group('SettingsViewModel signed IPAs', () {
    const int mb = 1 << 20;
    const String engineFolder = r'C:\Users\me\AppData\Local\iPASide\signed';
    const String chosenFolder = r'D:\signed';

    setUp(() {
      runner.results['signed'] = _signedListing(directory: engineFolder);
    });

    test('starts from the engine defaults with nothing kept', () async {
      final SettingsViewModel model = await load();

      expect(model.keepSignedIpa, isFalse);
      expect(model.usesDefaultSignedDirectory, isTrue);
      expect(model.signedDirectoryText, engineFolder);
      expect(model.isSignedLoading, isFalse);
      expect(model.signedUsageText, 'Nothing kept yet.');
      expect(model.canDeleteSignedIpas, isFalse);
      expect(model.hasSignedMessage, isFalse);
      expect(
        runner.ran(<String>['signed']),
        isTrue,
        reason: 'no --dir, so the engine names its own folder',
      );
    });

    test('shows the persisted choice on the first frame', () async {
      settings.saveSignedIpa(
        const SignedIpaSettings(keep: true, directory: chosenFolder),
      );
      runner.results['signed --dir $chosenFolder'] = _signedListing(
        directory: chosenFolder,
      );

      devices = DeviceSelection(engine: EngineApi(runner), settings: settings);
      final SettingsViewModel model = SettingsViewModel(
        engine: EngineApi(runner),
        navigation: navigation,
        scheduler: scheduler,
        settings: settings,
        picker: picker,
        dialogs: dialogs,
        devices: devices!,
      );
      viewModel = model;

      // Before any await: the store is read synchronously so the toggle and the
      // folder are never wrong on screen, even for one frame.
      expect(model.keepSignedIpa, isTrue);
      expect(model.signedDirectoryText, chosenFolder);
      expect(model.isSignedLoading, isTrue);

      await _settle();
      expect(model.usesDefaultSignedDirectory, isFalse);
      expect(runner.ran(<String>['signed', '--dir', chosenFolder]), isTrue);
    });

    test('the keep toggle is persisted', () async {
      final SettingsViewModel model = await load();

      model.setKeepSignedIpa(true);

      expect(model.keepSignedIpa, isTrue);
      expect(settings.loadSignedIpa().keep, isTrue);
      expect(
        settings.loadSignedIpa().directory,
        isNull,
        reason: 'the folder is not touched by the toggle',
      );
    });

    test('turning the toggle back off is persisted too', () async {
      settings.saveSignedIpa(const SignedIpaSettings(keep: true));
      final SettingsViewModel model = await load();

      model.setKeepSignedIpa(false);

      expect(model.keepSignedIpa, isFalse);
      expect(settings.loadSignedIpa().keep, isFalse);
    });

    test('setting the value it already has writes nothing', () async {
      final SettingsViewModel model = await load();
      int notifications = 0;
      model.addListener(() => notifications++);

      model.setKeepSignedIpa(false);

      expect(notifications, 0);
    });

    test('choosing a folder persists it and reads that folder', () async {
      picker.folder = chosenFolder;
      runner.results['signed --dir $chosenFolder'] = _signedListing(
        directory: chosenFolder,
        count: 2,
        bytes: 400 * mb,
      );
      final SettingsViewModel model = await load();

      await model.chooseSignedDirectory();

      expect(picker.folderPrompts, 1);
      expect(settings.loadSignedIpa().directory, chosenFolder);
      expect(model.usesDefaultSignedDirectory, isFalse);
      expect(model.signedDirectoryText, chosenFolder);
      expect(model.signedUsageText, '2 files \u00b7 400 MB');
      expect(model.canDeleteSignedIpas, isTrue);
    });

    test('a chosen folder is trimmed before it is stored', () async {
      picker.folder = '  $chosenFolder  ';
      final SettingsViewModel model = await load();

      await model.chooseSignedDirectory();

      expect(settings.loadSignedIpa().directory, chosenFolder);
    });

    test('cancelling the folder dialog changes nothing', () async {
      picker.folder = null;
      final SettingsViewModel model = await load();

      await model.chooseSignedDirectory();

      expect(picker.folderPrompts, 1);
      expect(settings.loadSignedIpa().directory, isNull);
      expect(model.signedDirectoryText, engineFolder);
    });

    test('a blank folder from the shell is treated as a cancel', () async {
      picker.folder = '   ';
      final SettingsViewModel model = await load();

      await model.chooseSignedDirectory();

      expect(settings.loadSignedIpa().directory, isNull);
    });

    test('resetting hands the folder back to the engine', () async {
      settings.saveSignedIpa(
        const SignedIpaSettings(keep: true, directory: chosenFolder),
      );
      runner.results['signed --dir $chosenFolder'] = _signedListing(
        directory: chosenFolder,
        count: 1,
        bytes: 233 * mb,
      );
      final SettingsViewModel model = await load();
      expect(model.usesDefaultSignedDirectory, isFalse);

      await model.resetSignedDirectory();

      expect(settings.loadSignedIpa().directory, isNull);
      expect(
        settings.loadSignedIpa().keep,
        isTrue,
        reason: 'the reset is of the folder only',
      );
      expect(model.usesDefaultSignedDirectory, isTrue);
      expect(model.signedDirectoryText, engineFolder);
      expect(model.signedUsageText, 'Nothing kept yet.');
    });

    test('resetting a folder that is already the default does nothing', () async {
      final SettingsViewModel model = await load();
      final int reads = runner.calls.length;

      await model.resetSignedDirectory();

      expect(runner.calls, hasLength(reads));
    });

    test('reports what is stored in whole units', () async {
      runner.results['signed'] = _signedListing(
        directory: engineFolder,
        count: 1,
        bytes: 233 * mb,
      );

      final SettingsViewModel model = await load();

      expect(model.signedUsageText, '1 file \u00b7 233 MB');
    });

    test('a folder that cannot be read says so, cleaned', () async {
      runner.results['signed'] = const EngineResult(
        ok: false,
        error: 'Engine exited with code 1. permission denied',
      );

      final SettingsViewModel model = await load();

      expect(model.signedUsageText, "Couldn't check.");
      expect(model.signedMessage, 'permission denied');
      expect(model.isSignedMessageError, isTrue);
      expect(model.canDeleteSignedIpas, isFalse);
    });

    test('a shutdown while reading leaves no error behind', () async {
      runner.failures['signed'] = EngineShutdownException();

      final SettingsViewModel model = await load();

      expect(model.hasSignedMessage, isFalse);
      expect(model.isSignedLoading, isFalse);
      expect(model.signedUsageText, 'Nothing kept yet.');
    });

    test('deleting asks first, stating the count and the space', () async {
      runner.results['signed'] = _signedListing(
        directory: engineFolder,
        count: 3,
        bytes: 699 * mb,
      );
      runner.results['signed --clean'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{
          'directory': engineFolder,
          'removed': 3,
          'bytes_freed': 732823552,
        },
      );
      final SettingsViewModel model = await load();

      await model.deleteSignedIpas();

      expect(dialogs.confirmMessages, hasLength(1));
      expect(dialogs.confirmMessages.single, contains('3 files'));
      expect(dialogs.confirmMessages.single, contains('699 MB'));
      expect(dialogs.confirmMessages.single, contains(engineFolder));
      expect(runner.ran(<String>['signed', '--clean']), isTrue);
      expect(model.signedMessage, 'Deleted 3 files, freed 699 MB.');
      expect(model.isSignedMessageError, isFalse);
      expect(model.signedBusy, isFalse);
    });

    test('the figures are re-read once the files are gone', () async {
      runner.queued['signed'] = <EngineResult>[
        _signedListing(directory: engineFolder, count: 3, bytes: 699 * mb),
        _signedListing(directory: engineFolder),
      ];
      runner.results['signed --clean'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{'removed': 3, 'bytes_freed': 732823552},
      );
      final SettingsViewModel model = await load();
      expect(model.signedUsageText, '3 files \u00b7 699 MB');

      await model.deleteSignedIpas();

      expect(model.signedUsageText, 'Nothing kept yet.');
      expect(model.canDeleteSignedIpas, isFalse);
      expect(
        model.signedMessage,
        'Deleted 3 files, freed 699 MB.',
        reason: 'the re-read must not wipe the confirmation it followed',
      );
    });

    test('a declined confirmation deletes nothing', () async {
      runner.results['signed'] = _signedListing(
        directory: engineFolder,
        count: 3,
        bytes: 699 * mb,
      );
      dialogs.answer = false;
      final SettingsViewModel model = await load();

      await model.deleteSignedIpas();

      expect(dialogs.confirmMessages, hasLength(1));
      expect(runner.ran(<String>['signed', '--clean']), isFalse);
      expect(model.hasSignedMessage, isFalse);
      expect(model.signedUsageText, '3 files \u00b7 699 MB');
      expect(model.signedBusy, isFalse);
    });

    test('deleting targets the chosen folder when there is one', () async {
      settings.saveSignedIpa(
        const SignedIpaSettings(keep: true, directory: chosenFolder),
      );
      runner.results['signed --dir $chosenFolder'] = _signedListing(
        directory: chosenFolder,
        count: 1,
        bytes: 233 * mb,
      );
      runner.results['signed --clean --dir $chosenFolder'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{'removed': 1, 'bytes_freed': 244318208},
      );
      final SettingsViewModel model = await load();

      await model.deleteSignedIpas();

      expect(
        runner.ran(<String>['signed', '--clean', '--dir', chosenFolder]),
        isTrue,
      );
      expect(model.signedMessage, 'Deleted 1 file, freed 233 MB.');
    });

    test('a failed delete is reported cleaned, not raw', () async {
      runner.results['signed'] = _signedListing(
        directory: engineFolder,
        count: 2,
        bytes: 400 * mb,
      );
      runner.results['signed --clean'] = const EngineResult(
        ok: false,
        error: 'Engine exited with code 1. a file is in use',
      );
      final SettingsViewModel model = await load();

      await model.deleteSignedIpas();

      expect(model.signedMessage, 'a file is in use');
      expect(model.isSignedMessageError, isTrue);
      expect(model.signedBusy, isFalse);
      expect(
        model.signedUsageText,
        '2 files \u00b7 400 MB',
        reason: 'nothing was deleted, so the figures still stand',
      );
    });

    test('a delete that found nothing says so rather than claiming a win',
        () async {
      runner.results['signed'] = _signedListing(
        directory: engineFolder,
        count: 1,
        bytes: 233 * mb,
      );
      runner.results['signed --clean'] = const EngineResult(
        ok: true,
        data: <String, dynamic>{'removed': 0, 'bytes_freed': 0},
      );
      final SettingsViewModel model = await load();

      await model.deleteSignedIpas();

      expect(model.signedMessage, 'There was nothing left to delete.');
      expect(model.isSignedMessageError, isFalse);
    });

    test('an empty folder cannot be deleted, and is never asked about',
        () async {
      final SettingsViewModel model = await load();

      await model.deleteSignedIpas();

      expect(dialogs.confirmMessages, isEmpty);
      expect(runner.ran(<String>['signed', '--clean']), isFalse);
    });

    test('a shutdown during a delete leaves no message behind', () async {
      runner.results['signed'] = _signedListing(
        directory: engineFolder,
        count: 1,
        bytes: 233 * mb,
      );
      runner.failures['signed --clean'] = EngineShutdownException();
      final SettingsViewModel model = await load();

      await model.deleteSignedIpas();

      expect(model.hasSignedMessage, isFalse);
      expect(model.signedBusy, isFalse);
    });
  });

  group('SettingsViewModel.describeBytes', () {
    test('names the unit a file manager would', () {
      expect(SettingsViewModel.describeBytes(0), '0 B');
      expect(SettingsViewModel.describeBytes(512), '512 B');
      expect(SettingsViewModel.describeBytes(1 << 10), '1 KB');
      expect(SettingsViewModel.describeBytes(1 << 20), '1 MB');
      expect(SettingsViewModel.describeBytes(233 * (1 << 20)), '233 MB');
      expect(SettingsViewModel.describeBytes(1 << 30), '1.0 GB');
      expect(SettingsViewModel.describeBytes(3 * (1 << 30) + (1 << 29)), '3.5 GB');
    });

    test('rounds to whole units below a gigabyte', () {
      expect(SettingsViewModel.describeBytes(1536), '2 KB');
      expect(SettingsViewModel.describeBytes((1.4 * (1 << 20)).round()), '1 MB');
      expect(SettingsViewModel.describeBytes((1.6 * (1 << 20)).round()), '2 MB');
    });

    test('never leaves a bare number for one file', () {
      expect(SettingsViewModel.describeFileCount(0), '0 files');
      expect(SettingsViewModel.describeFileCount(1), '1 file');
      expect(SettingsViewModel.describeFileCount(2), '2 files');
    });
  });

  group('SettingsViewModel pairing', () {
    const String udid = '935cbbb9b82d25d15566e5939bcea5677b1c44ae';

    Map<String, dynamic> pairingPayload({
      String source = 'lockdown',
      bool hasLockdown = true,
      bool hasRppairing = false,
      bool reachable = true,
      List<Map<String, dynamic>> consumers = const <Map<String, dynamic>>[],
    }) =>
        <String, dynamic>{
          'udid': udid,
          'source': source,
          'has_lockdown': hasLockdown,
          'has_rppairing': hasRppairing,
          'imported': source == 'imported',
          'device_reachable': reachable,
          'consumers': consumers,
          'note': hasRppairing ? 'has remote pairing' : 'needs remote pairing',
        };

    void withPhone() {
      runner.results['devices'] = EngineResult(
        ok: true,
        data: <dynamic>[
          <String, dynamic>{'serial': udid, 'connection_type': 'USB'},
        ],
      );
    }

    test('loads the pairing file for the selected device', () async {
      withPhone();
      runner.results['pairing'] = EngineResult(
        ok: true,
        data: pairingPayload(),
      );

      final SettingsViewModel model = await load();

      expect(model.isPairingLoading, isFalse);
      expect(model.hasPairingPayload, isTrue);
      expect(model.pairingUsbText, 'Present');
      expect(model.pairingRemoteText, 'Missing');
      expect(
        runner.calls.any(
          (List<String> call) =>
              call.length >= 3 &&
              call[0] == 'pairing' &&
              call[1] == '--udid' &&
              call[2] == udid,
        ),
        isTrue,
      );
    });

    test('import stores the picked file and reloads status', () async {
      withPhone();
      picker.pairingToOpen = r'C:\Users\me\Downloads\pairingFile.plist';
      runner.results['pairing'] = EngineResult(
        ok: true,
        data: pairingPayload(),
      );
      final SettingsViewModel model = await load();
      runner.queued['pairing'] = <EngineResult>[
        const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'imported': true,
            'has_rppairing': true,
            'path': r'C:\data\pairing.plist',
          },
        ),
      ];
      runner.results['pairing'] = EngineResult(
        ok: true,
        data: pairingPayload(source: 'imported', hasRppairing: true),
      );

      await model.importPairing();

      expect(picker.pairingOpenCount, 1);
      expect(
        runner.ran(<String>[
          'pairing',
          '--import',
          r'C:\Users\me\Downloads\pairingFile.plist',
          '--udid',
          udid,
        ]),
        isTrue,
      );
      expect(model.pairing?.hasRppairing, isTrue);
      expect(model.pairingMessage, contains('Imported'));
      expect(model.isPairingMessageError, isFalse);
    });

    test('export writes to the path the save dialog returned', () async {
      withPhone();
      picker.pairingToSave = r'D:\pairingFile.plist';
      runner.results['pairing'] = EngineResult(
        ok: true,
        data: pairingPayload(hasRppairing: true),
      );
      final SettingsViewModel model = await load();
      runner.queued['pairing'] = <EngineResult>[
        const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'exported': true,
            'path': r'D:\pairingFile.plist',
            'bytes': 12,
            'has_rppairing': true,
          },
        ),
      ];

      await model.exportPairing();

      expect(picker.pairingSaveCount, 1);
      expect(
        runner.calls.any(
          (List<String> call) =>
              call.contains('--export') &&
              call.contains(r'D:\pairingFile.plist'),
        ),
        isTrue,
      );
      expect(model.pairingMessage, contains('Wrote'));
    });

    test('place creates Remote Pairing keys then writes when they were missing',
        () async {
      withPhone();
      runner.results['pairing'] = EngineResult(
        ok: true,
        data: pairingPayload(
          consumers: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'escapeos',
              'name': 'EscapeOS',
              'bundle_id': 'com.ipaside.escapeos.TEAM',
              'needs_rppairing': true,
            },
          ],
        ),
      );
      final SettingsViewModel model = await load();
      runner.queued['pairing'] = <EngineResult>[
        const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'created': true,
            'has_rppairing': true,
            'has_lockdown': true,
          },
        ),
        const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'has_rppairing': true,
            'supported_installed': 1,
            'placed': <dynamic>[
              <String, dynamic>{
                'id': 'escapeos',
                'name': 'EscapeOS',
                'filename': 'pairingFile.plist',
                'placed': true,
              },
            ],
          },
        ),
      ];

      await model.placePairing();

      expect(
        runner.calls.any(
          (List<String> call) =>
              call.first == 'pairing' && call.contains('--create'),
        ),
        isTrue,
      );
      expect(
        runner.calls.any(
          (List<String> call) =>
              call.first == 'pairing' && call.contains('--deliver'),
        ),
        isTrue,
      );
      expect(model.pairingMessage, contains('EscapeOS'));
      expect(model.isPairingMessageError, isFalse);
    });

    test('place does not write when Remote Pairing create fails', () async {
      withPhone();
      runner.results['pairing'] = EngineResult(
        ok: true,
        data: pairingPayload(
          consumers: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'escapeos',
              'name': 'EscapeOS',
              'bundle_id': 'com.ipaside.escapeos.TEAM',
              'needs_rppairing': true,
            },
          ],
        ),
      );
      final SettingsViewModel model = await load();

      await model.placePairing();

      expect(model.isPairingMessageError, isTrue);
      expect(
        runner.calls.where(
          (List<String> call) =>
              call.first == 'pairing' && call.contains('--deliver'),
        ),
        isEmpty,
      );
    });

    test('place on one app forwards --app', () async {
      withPhone();
      runner.results['pairing'] = EngineResult(
        ok: true,
        data: pairingPayload(
          hasRppairing: true,
          consumers: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'escapeos',
              'name': 'EscapeOS',
              'app_name': 'EscapeOS',
              'bundle_id': 'com.ipaside.escapeos.TEAM',
              'filename': 'pairingFile.plist',
              'needs_rppairing': true,
            },
          ],
        ),
      );
      final SettingsViewModel model = await load();
      runner.queued['pairing'] = <EngineResult>[
        const EngineResult(
          ok: true,
          data: <String, dynamic>{
            'has_rppairing': true,
            'placed': <dynamic>[
              <String, dynamic>{
                'name': 'EscapeOS',
                'filename': 'pairingFile.plist',
                'placed': true,
              },
            ],
          },
        ),
      ];

      await model.placePairingOn(model.pairing!.consumers.single);

      expect(
        runner.calls.any(
          (List<String> call) =>
              call.contains('--deliver') &&
              call.contains('--app') &&
              call.contains('com.ipaside.escapeos.TEAM'),
        ),
        isTrue,
      );
    });
  });
}

