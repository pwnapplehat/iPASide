import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine.dart';
import 'package:ipaside/services/file_picker.dart';
import 'package:ipaside/services/settings_store.dart';
import 'package:ipaside/ui/shell/app_dialogs.dart';
import 'package:ipaside/ui/shell/nav_destination.dart';
import 'package:ipaside/viewmodels/device_selection.dart';
import 'package:ipaside/viewmodels/live_container_view_model.dart';
import 'package:ipaside/viewmodels/navigation_state.dart';
import 'package:ipaside/viewmodels/sideload_progress_state.dart';

/// A transport stand-in scripted per engine command: records every argv, replays
/// canned frames, and can emit progress lines before the result.
class _FakeRunner with EngineCommandRunner {
  final Map<String, Queue<Object>> _scripted = <String, Queue<Object>>{};
  final Map<String, Object> _defaults = <String, Object>{};

  /// Every argv the facade issued, in order.
  final List<List<String>> calls = <List<String>>[];

  /// Progress lines to emit, keyed by command, before its result.
  final Map<String, List<String>> progress = <String, List<String>>{};

  void always(String command, Object outcome) => _defaults[command] = outcome;

  void next(String command, Object outcome) =>
      (_scripted[command] ??= Queue<Object>()).add(outcome);

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);

    final String command = args.first;
    if (onProgress != null) {
      for (final String line in progress[command] ?? const <String>[]) {
        onProgress(line);
      }
    }

    // `livecontainer --apps` returns a list where the bare command returns an object, so
    // it needs its own script - keyed `livecontainer--apps`. Unscripted it is empty,
    // which is what a test only interested in the status wants and saves every one of
    // them from spelling it out.
    if (args.contains('--apps')) {
      final Queue<Object>? guests = _scripted['livecontainer--apps'];
      final Object outcome = guests != null && guests.isNotEmpty
          ? guests.removeFirst()
          : _defaults['livecontainer--apps'] ??
              const EngineResult(ok: true, data: <dynamic>[]);
      if (outcome is EngineResult) {
        return outcome;
      }
      throw outcome;
    }

    final Queue<Object>? queued = _scripted[command];
    final Object outcome = queued != null && queued.isNotEmpty
        ? queued.removeFirst()
        : _defaults[command] ??
            const EngineResult(ok: true, data: <String, dynamic>{});
    if (outcome is EngineResult) {
      return outcome;
    }
    throw outcome;
  }
}

EngineResult _ok(Object data) => EngineResult(ok: true, data: data);

EngineResult _failed(String error) => EngineResult(ok: false, error: error);

/// A cached, usable Apple ID session.
final EngineResult _authenticated = _ok(<String, dynamic>{'authenticated': true});

final EngineResult _signedOut = _ok(<String, dynamic>{'authenticated': false});

/// An in-memory settings store, so no test touches the real settings file.
class _FakeSettings extends SettingsStore {
  SignedIpaSettings signed = const SignedIpaSettings();
  String? deviceUdid;

  @override
  SignedIpaSettings loadSignedIpa() => signed;

  @override
  String? loadDeviceUdid() => deviceUdid;

  @override
  void saveDeviceUdid(String? udid) => deviceUdid = udid;
}

/// A selection that names no target, which is what one connected phone looks like.
DeviceSelection _noDevice() {
  final DeviceSelection selection = DeviceSelection(
    engine: EngineApi(_FakeRunner()),
    settings: _FakeSettings(),
  );
  addTearDown(selection.dispose);
  return selection;
}

/// A selection resolved to [udid], over its OWN transport so the enumeration never
/// lands in the call list a test is asserting on.
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

Map<String, dynamic> _status({
  bool installed = true,
  String? version = '3.8.0',
  bool pending = false,
  bool launched = true,
}) =>
    <String, dynamic>{
      'installed': installed,
      'bundle_id': 'com.kdt.livecontainer.ASK9QR9SBC',
      'name': 'LiveContainer',
      'version': ?version,
      'certificate_pending': pending,
      'certificate_file_present': true,
      'launched': launched,
    };

Map<String, dynamic> _setup({
  String status = 'installed',
  bool automatic = true,
  bool seeded = true,
  String? error,
  String? instructions,
}) =>
    <String, dynamic>{
      'status': status,
      'bundle_id': 'com.kdt.livecontainer.ASK9QR9SBC',
      'livecontainer_version': '3.8.0',
      'launch_required': automatic && seeded,
      'certificate': <String, dynamic>{
        'seeded': seeded,
        'automatic': automatic,
        'password': 'iPASide',
        'instructions': ?instructions,
        'error': ?error,
      },
    };

/// Answers the IPA prompt with whatever a test scripted, without a real dialog.
class _FakePicker implements FilePickerService {
  _FakePicker({this.ipa});

  /// What [pickIpa] returns; null means the user cancelled.
  String? ipa;

  int pickCount = 0;

  @override
  Future<String?> pickIpa() async {
    pickCount++;
    return ipa;
  }

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

/// Records what the view model asked, and answers without a navigator.
class _FakeDialogs extends DialogService {
  _FakeDialogs() : super(GlobalKey<NavigatorState>());

  /// What [confirm] returns.
  bool answer = true;

  final List<String> confirms = <String>[];

  @override
  Future<bool> confirm({
    required String title,
    required String message,
    String confirmLabel = 'OK',
    String cancelLabel = 'Cancel',
    bool danger = false,
  }) async {
    confirms.add(title);
    return answer;
  }
}

LiveContainerViewModel _model(
  _FakeRunner runner, {
  DeviceSelection? devices,
  NavigationState? navigation,
  _FakeSettings? settings,
  _FakePicker? picker,
  _FakeDialogs? dialogs,
}) {
  final LiveContainerViewModel vm = LiveContainerViewModel(
    engine: EngineApi(runner),
    navigation: navigation ?? NavigationState(),
    settings: settings ?? _FakeSettings(),
    devices: devices ?? _noDevice(),
    picker: picker ?? _FakePicker(),
    dialogs: dialogs ?? _FakeDialogs(),
  );
  addTearDown(vm.dispose);
  return vm;
}

String _frame(String phase, {double? percent, String? step}) =>
    '{"event":"progress","phase":"$phase"'
    '${percent == null ? '' : ',"percent":$percent'}'
    '${step == null ? '' : ',"step":"$step"'}}';

void main() {
  group('LiveContainerViewModel status', () {
    test('reads the device and reports it installed', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(_status()));

      final LiveContainerViewModel vm = _model(runner);
      await vm.load();

      expect(runner.calls.first, <String>['livecontainer']);
      expect(vm.isInstalled, isTrue);
      expect(vm.status?.version, '3.8.0');
      expect(vm.needsLaunch, isFalse);
      expect(vm.error, isNull);
      expect(vm.isLoading, isFalse);
    });

    test('a device that has none reports not installed', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(<String, dynamic>{'installed': false}));

      final LiveContainerViewModel vm = _model(runner);
      await vm.load();

      expect(vm.isInstalled, isFalse);
      expect(vm.needsLaunch, isFalse);
    });

    test('a pending import means the user must open it', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(_status(pending: true)));

      final LiveContainerViewModel vm = _model(runner);
      await vm.load();

      expect(vm.needsLaunch, isTrue,
          reason: 'the dylib imports on launch, so it has not run yet');
      expect(vm.status?.isReady, isFalse);
    });

    test('the selected device and transport are passed through', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(_status()));

      final LiveContainerViewModel vm =
          _model(runner, devices: await _device('AAAA1111'));
      await vm.load();

      expect(runner.calls.first, <String>['livecontainer', '--udid', 'AAAA1111']);
    });

    test('an engine failure is shown cleaned, not thrown', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _failed('device is locked'));

      final LiveContainerViewModel vm = _model(runner);
      await vm.load();

      expect(vm.error, contains('locked'));
      expect(vm.isLoading, isFalse);
    });

    test('a second load while one is running is ignored', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(_status()));

      final LiveContainerViewModel vm = _model(runner);
      await Future.wait<void>(<Future<void>>[vm.load(), vm.load()]);

      // Counting the status read specifically, rather than every call: a load also
      // fetches the guest apps and the icon, and that mix is not what this is about.
      expect(
        runner.calls
            .where((List<String> c) => c.first == 'livecontainer' && c.length == 1)
            .length,
        1,
      );
    });
  });

  group('LiveContainerViewModel setup', () {
    test('signs, installs, and reports the version', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('livecontainer', _ok(_setup()));

      final LiveContainerViewModel vm = _model(runner);
      await vm.setUp();

      expect(vm.isSucceeded, isTrue);
      expect(vm.isFailed, isFalse);
      expect(vm.result?.version, '3.8.0');
      expect(vm.isRunning, isFalse);
    });

    test('asks for --setup and no --ipa, so the engine fetches the release',
        () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('livecontainer', _ok(_setup()));

      final LiveContainerViewModel vm = _model(runner);
      await vm.setUp();

      final List<String> argv =
          runner.calls.firstWhere((List<String> c) => c.contains('--setup'));
      expect(argv.first, 'livecontainer');
      expect(argv, contains('--setup'));
      expect(argv, isNot(contains('--ipa')));
    });

    test("the user's keep-signed preference is honoured", () async {
      final _FakeSettings settings = _FakeSettings()
        ..signed = const SignedIpaSettings(keep: true, directory: r'D:\signed');
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('livecontainer', _ok(_setup()));

      final LiveContainerViewModel vm = _model(runner, settings: settings);
      await vm.setUp();

      final List<String> argv =
          runner.calls.firstWhere((List<String> c) => c.contains('--setup'));
      expect(argv, contains('--keep-signed'));
      expect(argv[argv.indexOf('--signed-dir') + 1], r'D:\signed');
    });

    test('a signed-out session goes to sign-in without touching the device',
        () async {
      final NavigationState navigation = NavigationState();
      addTearDown(navigation.dispose);
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _signedOut);

      final LiveContainerViewModel vm = _model(runner, navigation: navigation);
      await vm.setUp();

      expect(navigation.current, NavKey.signIn);
      expect(
        runner.calls.every((List<String> c) => c.first == 'login'),
        isTrue,
        reason: 'nothing should be downloaded before Apple has been asked',
      );
      expect(vm.isRunning, isFalse);
    });

    test('a failure is reported and the stepper stays visible', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..next('livecontainer', _failed('zsign failed'));

      final LiveContainerViewModel vm = _model(runner);
      await vm.setUp();

      expect(vm.isFailed, isTrue);
      expect(vm.failureMessage, contains('zsign'));
      expect(vm.showStepper, isTrue);
      expect(vm.isRunning, isFalse);
    });

    test('a second setup while one runs is ignored', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('livecontainer', _ok(_setup()));

      final LiveContainerViewModel vm = _model(runner);
      await Future.wait<void>(<Future<void>>[vm.setUp(), vm.setUp()]);

      expect(
        runner.calls.where((List<String> c) => c.contains('--setup')).length,
        1,
      );
    });

    test('the status is re-read afterwards rather than inferred', () async {
      // The run says what it did; only the device knows whether an import is
      // still waiting, so a status read has to follow.
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..next('livecontainer', _ok(_setup()))
        ..next('livecontainer', _ok(_status(pending: true)));

      final LiveContainerViewModel vm = _model(runner);
      await vm.setUp();

      expect(vm.needsLaunch, isTrue,
          reason: 'read back from the device rather than inferred from the run');
    });
  });

  group('LiveContainerViewModel certificate outcome', () {
    test('an automatic import asks the user only to open the app', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('livecontainer', _ok(_setup()));

      final LiveContainerViewModel vm = _model(runner);
      await vm.setUp();

      expect(vm.manualInstructions, isNull);
      expect(vm.result?.certificate.automatic, isTrue);
    });

    test('a manual import surfaces the engine instructions verbatim', () async {
      const String instructions = 'Open Settings, choose the p12, password iPASide.';
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always(
          'livecontainer',
          _ok(_setup(automatic: false, instructions: instructions)),
        );

      final LiveContainerViewModel vm = _model(runner);
      await vm.setUp();

      expect(vm.isSucceeded, isTrue, reason: 'the app is installed regardless');
      expect(vm.manualInstructions, instructions);
    });

    test('an undelivered certificate still counts as installed', () async {
      // The install succeeded; only the hand-off failed. Reporting the whole
      // setup as a failure would be wrong and would invite a pointless retry.
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always(
          'livecontainer',
          _ok(_setup(
            seeded: false,
            automatic: false,
            error: 'device went away',
            instructions: 'Import it by hand.',
          )),
        );

      final LiveContainerViewModel vm = _model(runner);
      await vm.setUp();

      expect(vm.isSucceeded, isTrue);
      expect(vm.isFailed, isFalse);
      expect(vm.manualInstructions, 'Import it by hand.');
      expect(vm.result?.certificate.error, 'device went away');
    });
  });

  group('LiveContainerViewModel progress', () {
    test('download and install report a percentage; the rest sweep', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('livecontainer', _ok(_setup()));
      runner.progress['livecontainer'] = <String>[
        _frame('download', percent: 45, step: 'Downloading LiveContainer'),
      ];

      final LiveContainerViewModel vm = _model(runner);
      final List<SideloadProgressState> seen = <SideloadProgressState>[];
      vm.addListener(() => seen.add(vm.progress));
      await vm.setUp();

      final SideloadProgressState downloading = seen.firstWhere(
        (SideloadProgressState s) => s.stepText == 'Downloading LiveContainer',
      );
      expect(downloading.activeIndex, 0);
      expect(downloading.percent, 45);
      expect(downloading.isIndeterminate, isFalse);
    });

    test('provision and sign sweep rather than fill', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('livecontainer', _ok(_setup()));
      runner.progress['livecontainer'] = <String>[
        _frame('provision', step: 'Contacting Apple'),
        _frame('sign', step: 'Signing'),
      ];

      final LiveContainerViewModel vm = _model(runner);
      final List<SideloadProgressState> seen = <SideloadProgressState>[];
      vm.addListener(() => seen.add(vm.progress));
      await vm.setUp();

      final SideloadProgressState signing =
          seen.firstWhere((SideloadProgressState s) => s.stepText == 'Signing');
      expect(signing.activeIndex, 2, reason: 'download, provision, then sign');
      expect(signing.isIndeterminate, isTrue);
    });

    test('the finalize phase is the last step, which sideload has no name for',
        () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('livecontainer', _ok(_setup()));
      runner.progress['livecontainer'] = <String>[
        _frame('finalize', step: 'Finishing setup'),
      ];

      final LiveContainerViewModel vm = _model(runner);
      final List<SideloadProgressState> seen = <SideloadProgressState>[];
      vm.addListener(() => seen.add(vm.progress));
      await vm.setUp();

      final SideloadProgressState finishing = seen.firstWhere(
        (SideloadProgressState s) => s.stepText == 'Finishing setup',
      );
      expect(finishing.activeIndex, 4);
      expect(LiveContainerViewModel.schedule.steps.length, 5);
    });

    test('a phase this flow does not draw leaves the state alone', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('login', _authenticated)
        ..always('livecontainer', _ok(_setup()));
      runner.progress['livecontainer'] = <String>[
        _frame('sign', step: 'Signing'),
        _frame('sandboxing', percent: 5),
      ];

      final LiveContainerViewModel vm = _model(runner);
      await vm.setUp();

      // Ends on the completed state, and the unknown frame never moved the
      // stepper somewhere misleading on the way.
      expect(vm.progress.activeIndex, 4);
      expect(vm.progress.percent, 100);
    });
  });

  group('LiveContainerViewModel guest apps', () {
    test('the apps inside it are read alongside the status', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(_status()))
        ..always(
          'livecontainer--apps',
          _ok(<dynamic>[
            <String, dynamic>{'bundle_id': 'com.example.one', 'folder': 'com.example.one.app'},
            <String, dynamic>{'bundle_id': 'com.example.two', 'folder': 'com.example.two.app'},
          ]),
        );

      final LiveContainerViewModel vm = _model(runner);
      await vm.load();

      expect(vm.guests.map((GuestApp g) => g.bundleId), <String>[
        'com.example.one',
        'com.example.two',
      ]);
      expect(
        runner.calls.any((List<String> c) => c.contains('--apps')),
        isTrue,
      );
    });

    test('nothing is asked about when LiveContainer is not installed', () async {
      // The engine would refuse anyway, and an error about a missing LiveContainer is
      // not news on a screen that has just said it is not installed.
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(<String, dynamic>{'installed': false}));

      final LiveContainerViewModel vm = _model(runner);
      await vm.load();

      expect(vm.guests, isEmpty);
      expect(runner.calls.single, isNot(contains('--apps')));
    });

    test('adding an app asks the engine to put it inside LiveContainer', () async {
      // The status read that `load` and `addGuest` both do returns the same object; the
      // add itself is the call under test, and its payload is read as a GuestAppInstall.
      final _FakeRunner runner = _FakeRunner()
        ..always(
          'livecontainer',
          _ok(<String, dynamic>{
            ..._status(),
            'status': 'installed',
            'name': 'Example',
          }),
        );
      final _FakePicker picker = _FakePicker(ipa: r'C:\ipas\Example.ipa');

      final LiveContainerViewModel vm = _model(runner, picker: picker);
      await vm.load();
      await vm.addGuest();

      final List<String> argv =
          runner.calls.firstWhere((List<String> c) => c.contains('--add'));
      expect(argv[argv.indexOf('--add') + 1], r'C:\ipas\Example.ipa');
      expect(vm.guestNotice, contains('Example'));
      expect(vm.isAdding, isFalse);
    });

    test('cancelling the file prompt does nothing at all', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(_status()));
      final _FakePicker picker = _FakePicker();

      final LiveContainerViewModel vm = _model(runner, picker: picker);
      await vm.load();
      final int before = runner.calls.length;
      await vm.addGuest();

      expect(picker.pickCount, 1);
      expect(runner.calls.length, before);
      expect(vm.guestNotice, isNull);
    });

    test('copy progress is surfaced as it arrives', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(_status()));
      runner.progress['livecontainer'] = <String>[
        '{"event":"progress","phase":"upload","percent":40,'
            '"step":"Copying into LiveContainer \u00b7 340 / 844 files"}',
      ];
      final _FakePicker picker = _FakePicker(ipa: r'C:\ipas\Example.ipa');

      final LiveContainerViewModel vm = _model(runner, picker: picker);
      // Adding needs an installed LiveContainer, so the status has to be read first.
      await vm.load();
      final List<String?> seen = <String?>[];
      vm.addListener(() => seen.add(vm.guestProgress));
      await vm.addGuest();

      expect(seen, contains('Copying into LiveContainer \u00b7 340 / 844 files'));
      expect(vm.guestProgress, isNull, reason: 'cleared when the copy is over');
    });

    test('removing an app asks first, then removes it', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(_status()));
      final _FakeDialogs dialogs = _FakeDialogs();

      final LiveContainerViewModel vm = _model(runner, dialogs: dialogs);
      await vm.removeGuest(const GuestApp(bundleId: 'com.example.app'));

      expect(dialogs.confirms, <String>['Remove from LiveContainer?']);
      final List<String> argv =
          runner.calls.firstWhere((List<String> c) => c.contains('--remove'));
      expect(argv[argv.indexOf('--remove') + 1], 'com.example.app');
    });

    test('declining the prompt leaves the app alone', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(_status()));
      final _FakeDialogs dialogs = _FakeDialogs()..answer = false;

      final LiveContainerViewModel vm = _model(runner, dialogs: dialogs);
      await vm.removeGuest(const GuestApp(bundleId: 'com.example.app'));

      expect(
        runner.calls.any((List<String> c) => c.contains('--remove')),
        isFalse,
      );
    });

    test('an app with no bundle id cannot be removed', () async {
      final _FakeRunner runner = _FakeRunner()
        ..always('livecontainer', _ok(_status()));
      final _FakeDialogs dialogs = _FakeDialogs();

      final LiveContainerViewModel vm = _model(runner, dialogs: dialogs);
      await vm.removeGuest(const GuestApp());

      expect(dialogs.confirms, isEmpty, reason: 'nothing to confirm about');
    });
  });

  group('LiveContainerViewModel SideStore build', () {
    test('a build carrying SideStore is reported with its pairing state', () async {
      final _FakeRunner runner = _FakeRunner()
        ..next(
          'livecontainer',
          _ok(<String, dynamic>{
            ..._status(),
            'has_sidestore': true,
            'pairing_present': true,
          }),
        )
        ..always('livecontainer--apps', _ok(<dynamic>[]));

      final LiveContainerViewModel vm = _model(runner);
      await vm.load();

      expect(vm.hasSideStore, isTrue);
      expect(vm.isPaired, isTrue);
    });

    test('a plain build reports neither', () async {
      final _FakeRunner runner = _FakeRunner()
        ..next('livecontainer', _ok(_status()))
        ..always('livecontainer--apps', _ok(<dynamic>[]));

      final LiveContainerViewModel vm = _model(runner);
      await vm.load();

      expect(vm.hasSideStore, isFalse);
      expect(vm.isPaired, isFalse);
    });
  });

  group('ProgressSchedule', () {
    test('the sideload schedule is unchanged', () {
      expect(ProgressSchedule.sideload.indexOf('provision'), 0);
      expect(ProgressSchedule.sideload.indexOf('sign'), 1);
      expect(ProgressSchedule.sideload.indexOf('install'), 2);
      expect(ProgressSchedule.sideload.indexOf('download'), isNull);
      expect(ProgressSchedule.sideload.determinate, <String>{'install'});
    });

    test('the LiveContainer schedule adds a download and a finish', () {
      const ProgressSchedule schedule = ProgressSchedule.liveContainer;
      expect(schedule.indexOf('download'), 0);
      expect(schedule.indexOf('provision'), 1);
      expect(schedule.indexOf('sign'), 2);
      expect(schedule.indexOf('install'), 3);
      expect(schedule.indexOf('finalize'), 4);
      expect(schedule.steps.length, schedule.phases.length);
      expect(schedule.labels.length, schedule.phases.length);
    });

    test('an unknown phase maps to nothing in either schedule', () {
      expect(ProgressSchedule.sideload.indexOf('nonsense'), isNull);
      expect(ProgressSchedule.liveContainer.indexOf(null), isNull);
    });
  });
}
