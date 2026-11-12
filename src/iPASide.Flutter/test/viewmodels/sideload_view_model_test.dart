import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/services/file_picker.dart';
import 'package:ipaside/services/icon_cache.dart';
import 'package:ipaside/services/settings_store.dart';
import 'package:ipaside/ui/shell/app_dialogs.dart';
import 'package:ipaside/ui/shell/nav_destination.dart';
import 'package:ipaside/viewmodels/device_selection.dart';
import 'package:ipaside/viewmodels/navigation_state.dart';
import 'package:ipaside/viewmodels/sideload_view_model.dart';

/// A transport stand-in scripted per engine command: it records every argv and
/// replays canned result frames (or throws a canned error).
class _FakeRunner with EngineCommandRunner {
  final Map<String, Queue<Object>> _scripted = <String, Queue<Object>>{};
  final Map<String, Object> _defaults = <String, Object>{};

  /// Every argv the facade issued, in order.
  final List<List<String>> calls = <List<String>>[];

  void always(String command, Object outcome) => _defaults[command] = outcome;

  List<List<String>> callsTo(String command) => <List<String>>[
        for (final List<String> argv in calls)
          if (argv.first == command) argv,
      ];

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);

    final String command = args.first;
    final Queue<Object>? queued = _scripted[command];
    final Object outcome = queued != null && queued.isNotEmpty
        ? queued.removeFirst()
        : _defaults[command] ??
            const EngineResult(ok: true, data: <String, dynamic>{});
    if (outcome is EngineResult) return outcome;
    throw outcome;
  }
}

/// Answers without a navigator; nothing here needs to record.
class _FakeDialogs extends DialogService {
  _FakeDialogs() : super(GlobalKey<NavigatorState>());

  @override
  Future<bool> confirm({
    required String title,
    required String message,
    String confirmLabel = 'OK',
    String cancelLabel = 'Cancel',
    bool danger = false,
  }) async =>
      true;

  @override
  Future<void> alert({required String title, required String message}) async {}
}

class _FakePicker implements FilePickerService {
  @override
  Future<String?> pickIpa() async => null;

  @override
  Future<List<String>> pickTweaks() async => const <String>[];

  @override
  Future<String?> pickSignedFolder() async => null;

  @override
  Future<String?> pickPairingFile() async => null;

  @override
  Future<String?> savePairingFile({required String suggestedName}) async =>
      null;

  @override
  Future<String?> saveUnsignedIpa({required String suggestedName}) async =>
      null;
}

/// An in-memory settings store: nothing here touches the real settings file, and
/// a test can change a value between two runs to prove the model rereads it.
class _FakeSettings extends SettingsStore {
  SignedIpaSettings signedIpa = const SignedIpaSettings();
  String? deviceUdid;

  @override
  SignedIpaSettings loadSignedIpa() => signedIpa;

  @override
  void saveSignedIpa(SignedIpaSettings settings) => signedIpa = settings;

  @override
  String? loadDeviceUdid() => deviceUdid;

  @override
  void saveDeviceUdid(String? udid) => deviceUdid = udid;
}

EngineResult _ok(Object data) => EngineResult(ok: true, data: data);

/// `inspect` for a signable app: no `sc_info`, so nothing blocks the run.
EngineResult get _inspection => _ok(<String, dynamic>{
      'bundle_id': 'com.example.app',
      'display_name': 'Example',
      'version': '1.0',
    });

EngineResult get _authenticated =>
    _ok(<String, dynamic>{'authenticated': true, 'email': 'a@example.com'});

EngineResult get _installed =>
    _ok(<String, dynamic>{'status': 'installed', 'name': 'Example'});

/// A selection that has enumerated nothing, so it names no target.
DeviceSelection _noDevice() {
  final DeviceSelection selection = DeviceSelection(
    engine: EngineApi(_FakeRunner()),
    settings: _FakeSettings(),
  );
  addTearDown(selection.dispose);
  return selection;
}

/// A selection already resolved to [udid], over its OWN transport so the device
/// enumeration never lands in the call list the test is asserting on.
Future<DeviceSelection> _device(String udid) async {
  final _FakeRunner runner = _FakeRunner()
    ..always(
      'devices',
      _ok(<dynamic>[
        <String, dynamic>{'serial': udid, 'connection_type': 'USB'},
      ]),
    )
    ..always('device-info', _ok(<String, dynamic>{'DeviceName': 'Test iPhone'}));

  final DeviceSelection selection = DeviceSelection(
    engine: EngineApi(runner),
    settings: _FakeSettings(),
  );
  addTearDown(selection.dispose);
  await selection.refresh();
  return selection;
}

/// A session with an IPA already inspected in, ready to run.
Future<SideloadViewModel> _withIpa(
  _FakeRunner runner, {
  SettingsStore? settings,
  DeviceSelection? devices,
  NavigationState? navigation,
}) async {
  runner
    ..always('inspect', _inspection)
    ..always('login', _authenticated)
    ..always('sideload', _installed);

  final SideloadViewModel vm = SideloadViewModel(
    engine: EngineApi(runner),
    navigation: navigation ?? NavigationState(),
    dialogs: _FakeDialogs(),
    picker: _FakePicker(),
    icons: IconCache(),
    settings: settings ?? _FakeSettings(),
    devices: devices ?? _noDevice(),
  );
  addTearDown(vm.dispose);

  await vm.loadIpa(r'C:\ipas\Example.ipa');
  return vm;
}

void main() {
  group('SideloadViewModel keep-signed setting', () {
    test('sends neither flag while the setting is off', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(runner);

      await vm.sideload();

      expect(
        runner.callsTo('sideload').single,
        <String>['sideload', r'C:\ipas\Example.ipa'],
      );
      expect(vm.isSucceeded, isTrue);
    });

    test('passes --keep-signed once the setting is on', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(
        runner,
        settings: _FakeSettings()
          ..signedIpa = const SignedIpaSettings(keep: true),
      );

      await vm.sideload();

      expect(
        runner.callsTo('sideload').single,
        <String>['sideload', r'C:\ipas\Example.ipa', '--keep-signed'],
      );
    });

    test('passes the configured folder alongside it', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(
        runner,
        settings: _FakeSettings()
          ..signedIpa = const SignedIpaSettings(
            keep: true,
            directory: r'D:\Signed',
          ),
      );

      await vm.sideload();

      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--keep-signed',
        '--signed-dir',
        r'D:\Signed',
      ]);
    });

    test('passes a folder chosen without keeping', () async {
      // The folder follows the directory rather than the keeping: it is also
      // where a `signed` listing would look.
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(
        runner,
        settings: _FakeSettings()
          ..signedIpa = const SignedIpaSettings(directory: r'D:\Signed'),
      );

      await vm.sideload();

      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--signed-dir',
        r'D:\Signed',
      ]);
    });

    test('a change to the setting reaches the very next run', () async {
      // The point of reading at run time: this model is app-scoped and outlives
      // every visit to Settings, so a value cached at construction would be the
      // one the app launched with, for the rest of the session.
      final _FakeRunner runner = _FakeRunner();
      final _FakeSettings settings = _FakeSettings();
      final SideloadViewModel vm = await _withIpa(runner, settings: settings);

      await vm.sideload();
      settings.signedIpa = const SignedIpaSettings(keep: true);
      await vm.sideload();

      expect(runner.callsTo('sideload'), <List<String>>[
        <String>['sideload', r'C:\ipas\Example.ipa'],
        <String>['sideload', r'C:\ipas\Example.ipa', '--keep-signed'],
      ]);
    });
  });

  group('SideloadViewModel device target', () {
    test('installs to the selected device', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm =
          await _withIpa(runner, devices: await _device('BBBB2222'));

      await vm.sideload();

      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--udid',
        'BBBB2222',
      ]);
    });

    test('a retarget between runs is honoured', () async {
      final _FakeRunner selectionRunner = _FakeRunner()
        ..always(
          'devices',
          _ok(<dynamic>[
            <String, dynamic>{'serial': 'AAAA1111', 'connection_type': 'USB'},
            <String, dynamic>{'serial': 'BBBB2222', 'connection_type': 'USB'},
          ]),
        );
      final DeviceSelection devices = DeviceSelection(
        engine: EngineApi(selectionRunner),
        settings: _FakeSettings(),
      );
      addTearDown(devices.dispose);
      await devices.refresh();

      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(runner, devices: devices);

      await vm.sideload();
      devices.select('BBBB2222');
      await vm.sideload();

      expect(
        runner.callsTo('sideload').map((List<String> argv) => argv.last),
        <String>['AAAA1111', 'BBBB2222'],
      );
    });

    test('both the target and the setting travel together', () async {
      final _FakeRunner runner = _FakeRunner();
      final SideloadViewModel vm = await _withIpa(
        runner,
        settings: _FakeSettings()
          ..signedIpa = const SignedIpaSettings(keep: true),
        devices: await _device('BBBB2222'),
      );

      await vm.sideload();

      expect(runner.callsTo('sideload').single, <String>[
        'sideload',
        r'C:\ipas\Example.ipa',
        '--udid',
        'BBBB2222',
        '--keep-signed',
      ]);
    });
  });

  group('SideloadViewModel pre-flight', () {
    test('a signed-out session goes to sign-in and runs nothing', () async {
      final _FakeRunner runner = _FakeRunner();
      final NavigationState navigation = NavigationState();
      addTearDown(navigation.dispose);
      final SideloadViewModel vm =
          await _withIpa(runner, navigation: navigation);
      runner.always('login', _ok(<String, dynamic>{'authenticated': false}));

      await vm.sideload();

      expect(navigation.current, NavKey.signIn);
      expect(runner.callsTo('sideload'), isEmpty);
    });

    test('two sideloads in one frame install once', () async {
      // The button is disabled while a run is on, but the guard has to hold on its
      // own: both calls would otherwise clear the sign-in probe before either set
      // the running flag, and the app would be installed twice.
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('sideload', _installed);
      final SideloadViewModel vm = await _withIpa(runner);

      await Future.wait<void>(<Future<void>>[vm.sideload(), vm.sideload()]);

      expect(runner.callsTo('sideload').length, 1);
      expect(vm.isSucceeded, isTrue);
      expect(vm.isRunning, isFalse);
    });

    test('a signed-out session leaves no half-started run on screen', () async {
      // The running flag is claimed before the probe, so bailing out to sign-in
      // has to put it back or the stepper would sit there forever.
      final _FakeRunner runner = _FakeRunner();
      final NavigationState navigation = NavigationState();
      addTearDown(navigation.dispose);
      final SideloadViewModel vm =
          await _withIpa(runner, navigation: navigation);
      runner.always('login', _ok(<String, dynamic>{'authenticated': false}));

      await vm.sideload();

      expect(vm.isRunning, isFalse);
      expect(vm.isFailed, isFalse);
      expect(vm.isSucceeded, isFalse);
    });

    test('no IPA selected runs nothing', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated);
      final SideloadViewModel vm = SideloadViewModel(
        engine: EngineApi(runner),
        navigation: NavigationState(),
        dialogs: _FakeDialogs(),
        picker: _FakePicker(),
        icons: IconCache(),
        settings: _FakeSettings(),
        devices: _noDevice(),
      );
      addTearDown(vm.dispose);

      await vm.sideload();

      expect(runner.calls, isEmpty);
    });
  });
}
