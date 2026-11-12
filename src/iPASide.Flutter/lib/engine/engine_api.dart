// Ported from iPASide.App/Engine/EngineApi.cs.

import 'dart:async';

import 'engine_client.dart';
import 'engine_exception.dart';
import 'json_utils.dart';
import 'models.dart';

/// The typed facade over the engine transport.
///
/// It is the SOLE consumer of the raw JSON [EngineResult] carries: the UI talks
/// only to these methods and the models in `models.dart`. No screen builds argv
/// or touches JSON. Argv is verbatim from the legacy web UI.
class EngineApi {
  /// Wraps a transport - in production an [EngineClient].
  EngineApi(this._client);

  final EngineCommandRunner _client;

  // ---- IPA / tweaks ------------------------------------------------------ //

  /// Reads an IPA's metadata without modifying it.
  Future<IpaInspection> inspect(String path) => _runTyped<IpaInspection>(
        <String>['inspect', path],
        _asObject(IpaInspection.fromJson),
      );

  /// Resolves a `.deb` or `.dylib` to the injectable dylibs it provides.
  Future<List<TweakDylib>> resolveTweak(String path) =>
      _runTyped<List<TweakDylib>>(
        <String>['resolve-tweak', path],
        (Object data) {
          final Map<String, dynamic>? json = asJsonObject(data);
          if (json == null) {
            return null;
          }
          return jsonObjectList(json, 'dylibs', TweakDylib.fromJson);
        },
      );

  /// Signs and installs an IPA, streaming progress while it runs.
  Future<SideloadResult> sideload(
    String path,
    SideloadOptions options, {
    void Function(SideloadProgress progress)? onProgress,
  }) =>
      _runTyped<SideloadResult>(
        buildSideloadArgs(path, options),
        _asObject(SideloadResult.fromJson),
        onProgress: _progressPump(onProgress),
      );

  /// Applies the sideload options and tweaks, then writes an unsigned IPA.
  ///
  /// No Apple ID, device, or certificate. The file is for signing elsewhere.
  Future<UnsignedExportResult> exportUnsigned(
    String path,
    SideloadOptions options, {
    required String output,
  }) =>
      _runTyped<UnsignedExportResult>(
        buildExportUnsignedArgs(path, options, output: output),
        _asObject(UnsignedExportResult.fromJson),
      );

  // ---- LiveContainer ------------------------------------------------------ //

  /// Reports whether LiveContainer is installed and how far its setup got.
  Future<LiveContainerStatus> liveContainerStatus({
    String? udid,
    String? connection,
  }) =>
      _runTyped<LiveContainerStatus>(
        <String>['livecontainer', ..._targetArgs(udid, connection)],
        _asObject(LiveContainerStatus.fromJson),
      );

  /// The apps running inside LiveContainer, which use none of the three app slots.
  Future<List<GuestApp>> liveContainerGuests({
    String? udid,
    String? connection,
  }) =>
      _runTyped<List<GuestApp>>(
        <String>['livecontainer', ..._targetArgs(udid, connection), '--apps'],
        (Object data) => data is List
            ? <GuestApp>[
                for (final Object? item in data)
                  if (item is Map<String, dynamic>) GuestApp.fromJson(item),
              ]
            : null,
      );

  /// Puts an app inside LiveContainer instead of installing it on the phone.
  ///
  /// Streams `upload` progress. LiveContainer signs it on device afterwards, so nothing
  /// here is provisioned or signed and no app slot is used.
  Future<GuestAppInstall> installGuestApp(
    String path, {
    String? udid,
    String? connection,
    void Function(SideloadProgress progress)? onProgress,
  }) =>
      _runTyped<GuestAppInstall>(
        <String>['livecontainer', ..._targetArgs(udid, connection), '--add', path],
        _asObject(GuestAppInstall.fromJson),
        onProgress: _progressPump(onProgress),
      );

  /// Removes an app from inside LiveContainer.
  Future<void> removeGuestApp(
    String bundleId, {
    String? udid,
    String? connection,
  }) =>
      _runVoid(<String>[
        'livecontainer',
        ..._targetArgs(udid, connection),
        '--remove',
        bundleId,
      ]);

  // ---- Pairing file ------------------------------------------------------ //

  /// What this PC holds for the target device, and which installed apps can use it.
  Future<PairingStatus> pairingStatus({String? udid, String? connection}) =>
      _runTyped<PairingStatus>(
        <String>['pairing', ..._targetArgs(udid, connection)],
        _asObject(PairingStatus.fromJson),
      );

  /// Writes the pairing file to [path] as an XML plist.
  Future<PairingExport> exportPairing(
    String path, {
    String? udid,
    String? connection,
  }) =>
      _runTyped<PairingExport>(
        <String>['pairing', '--export', path, ..._targetArgs(udid, connection)],
        _asObject(PairingExport.fromJson),
      );

  /// Stores [path] as this PC's pairing file for the target device.
  Future<PairingImport> importPairing(
    String path, {
    String? udid,
    String? connection,
  }) =>
      _runTyped<PairingImport>(
        <String>['pairing', '--import', path, ..._targetArgs(udid, connection)],
        _asObject(PairingImport.fromJson),
      );

  /// Creates Remote Pairing keys over USB. No other app is required.
  Future<PairingCreate> createPairing({String? udid, String? connection}) =>
      _runTyped<PairingCreate>(
        <String>['pairing', '--create', ..._targetArgs(udid, connection)],
        _asObject(PairingCreate.fromJson),
      );

  /// Writes the pairing file into supported apps, or only [bundleId] when set.
  Future<PairingDelivery> deliverPairing({
    String? udid,
    String? connection,
    String? bundleId,
  }) =>
      _runTyped<PairingDelivery>(
        <String>[
          'pairing',
          '--deliver',
          if (bundleId != null) ...<String>['--app', bundleId],
          ..._targetArgs(udid, connection),
        ],
        _asObject(PairingDelivery.fromJson),
      );

  // ---- Jailbreak --------------------------------------------------------- //

  /// Whether Dopamine fits the connected device, worked out from its chip + iOS.
  ///
  /// Advice only — nothing is downloaded or installed. The engine reads the device
  /// and returns an [JailbreakAdvice] the UI renders directly.
  Future<JailbreakAdvice> jailbreakAdvice({
    String? udid,
    String? connection,
  }) =>
      _runTyped<JailbreakAdvice>(
        <String>['jailbreak', ..._targetArgs(udid, connection)],
        _asObject(JailbreakAdvice.fromJson),
      );

  /// Signs and installs Dopamine, downloading the latest IPA unless [ipaPath] is set.
  ///
  /// This is an ordinary sideload: the exploit runs on the phone the first time the
  /// user opens Dopamine, never here. Streams the same download → provision → sign →
  /// install phases a LiveContainer setup does.
  Future<JailbreakInstallResult> installJailbreak({
    String? ipaPath,
    String? udid,
    String? connection,
    bool keepSigned = false,
    String? signedDirectory,
    void Function(SideloadProgress progress)? onProgress,
  }) =>
      _runTyped<JailbreakInstallResult>(
        buildJailbreakInstallArgs(
          ipaPath: ipaPath,
          udid: udid,
          connection: connection,
          keepSigned: keepSigned,
          signedDirectory: signedDirectory,
        ),
        _asObject(JailbreakInstallResult.fromJson),
        onProgress: _progressPump(onProgress),
      );

  // ---- Developer account ------------------------------------------------- //

  /// What one Apple ID's developer account holds: certificates, App IDs, devices.
  ///
  /// [email] picks between signed-in Apple IDs; omitted, the active one.
  Future<AccountOverview> accountOverview({String? email}) =>
      _runTyped<AccountOverview>(
        <String>['slots', ..._emailArgs(email)],
        _asObject(AccountOverview.fromJson),
      );

  /// Revokes a development certificate.
  ///
  /// Destructive and not undoable: every app that certificate signed stops opening, and
  /// it may belong to another tool entirely. The result says which case it was.
  Future<RevokedCertificate> revokeCertificate(
    String serial, {
    String? email,
  }) =>
      _runTyped<RevokedCertificate>(
        <String>['revoke-cert', serial, ..._emailArgs(email)],
        _asObject(RevokedCertificate.fromJson),
      );

  /// Deletes a registered app identifier.
  ///
  /// Frees the name, not one of the week's registrations - Apple counts those over a
  /// rolling seven days.
  Future<void> deleteAppId(String appIdId, {String? email}) =>
      _runVoid(<String>['delete-app-id', appIdId, ..._emailArgs(email)]);

  /// Installs LiveContainer and hands it the signing certificate.
  ///
  /// With no [ipaPath] the engine downloads the newest release itself, which is
  /// the normal route - there is no version for the caller to choose or pin.
  /// Reports `download` and `finalize` phases either side of the usual
  /// provision/sign/install, so drive the stepper from
  /// [ProgressSchedule.liveContainer] rather than the sideload schedule.
  Future<LiveContainerSetupResult> liveContainerSetup({
    String? ipaPath,
    String? udid,
    String? connection,
    bool keepSigned = false,
    String? signedDirectory,
    void Function(SideloadProgress progress)? onProgress,
  }) =>
      _runTyped<LiveContainerSetupResult>(
        buildLiveContainerArgs(
          ipaPath: ipaPath,
          udid: udid,
          connection: connection,
          keepSigned: keepSigned,
          signedDirectory: signedDirectory,
        ),
        _asObject(LiveContainerSetupResult.fromJson),
        onProgress: _progressPump(onProgress),
      );

  // ---- Apple ID / session ----------------------------------------------- //

  /// Starts (or, with [code], completes) an Apple ID login.
  ///
  /// The password travels via per-request env, NEVER argv, where it would leak
  /// into process listings.
  Future<LoginResult> login(
    String email,
    String password, {
    String? code,
  }) {
    final List<String> args = <String>['login', '--email', email];
    if (code != null && code.isNotEmpty) {
      args.add('--code');
      args.add(code);
    }

    return _runTyped<LoginResult>(
      args,
      _asObject(LoginResult.fromJson),
      env: <String, String>{'IPASIDE_APPLE_PASSWORD': password},
    );
  }

  /// Reports the Apple ID in use, and how many others are signed in.
  Future<LoginStatus> loginStatus() => _runTyped<LoginStatus>(
        <String>['login', '--status'],
        _asObject(LoginStatus.fromJson),
      );

  /// Every signed-in Apple ID, with the active one flagged.
  Future<List<AppleAccount>> accounts() => _runTyped<List<AppleAccount>>(
        <String>['login', '--accounts'],
        (Object data) {
          final Map<String, dynamic>? json = asJsonObject(data);
          if (json == null) {
            return null;
          }
          return jsonObjectList(json, 'accounts', AppleAccount.fromJson);
        },
      );

  /// Switches which signed-in Apple ID new sideloads use.
  ///
  /// No password: the session is already cached, so this only moves a pointer.
  Future<void> useAccount(String email) =>
      _runVoid(<String>['login', '--use', email]);

  /// Signs out one Apple ID, or every one of them when [email] is omitted.
  Future<void> logout({String? email}) => _runVoid(<String>[
        'login',
        '--logout',
        if (email != null && email.isNotEmpty) ...<String>['--email', email],
      ]);

  // ---- Device ------------------------------------------------------------ //

  /// Lists connected iOS devices, ONE ENTRY PER TRANSPORT.
  ///
  /// A phone reachable over both USB and Wi-Fi is listed twice under the same
  /// [DeviceEntry.serial]; callers wanting physical devices must group by it.
  Future<List<DeviceEntry>> devices() => _runTyped<List<DeviceEntry>>(
        <String>['devices'],
        _asObjectList(DeviceEntry.fromJson),
      );

  /// Live usbmux Attached/Detached listings from the serve process.
  ///
  /// Same row shape as [devices]. Scripted fakes emit nothing unless they
  /// override [EngineCommandRunner.events].
  Stream<List<DeviceEntry>> get deviceEvents => _client.events
      .where(
        (Map<String, dynamic> frame) =>
            isUnsolicitedEngineEvent(frame) && frame['name'] == 'devices',
      )
      .map(_parseDeviceEvent);

  /// Reads identity details for the target device.
  Future<DeviceInfo> deviceInfo({String? udid, String? connection}) =>
      _runTyped<DeviceInfo>(
        <String>['device-info', ..._targetArgs(udid, connection)],
        _asObject(DeviceInfo.fromJson),
      );

  /// Lists installed user apps, keyed by bundle id.
  Future<Map<String, InstalledApp>> apps({String? udid, String? connection}) =>
      _runTyped<Map<String, InstalledApp>>(
        <String>['apps', ..._targetArgs(udid, connection)],
        (Object data) {
          final Map<String, dynamic>? json = asJsonObject(data);
          if (json == null) {
            return null;
          }
          final Map<String, InstalledApp> apps = <String, InstalledApp>{};
          for (final MapEntry<String, dynamic> entry in json.entries) {
            final Map<String, dynamic>? app = asJsonObject(entry.value);
            if (app != null) {
              apps[entry.key] = InstalledApp.fromJson(app);
            }
          }
          return apps;
        },
      );

  /// Home-screen icons as PNG data URIs, keyed by bundle id.
  ///
  /// SpringBoard serves one icon per round trip, so callers should treat this
  /// as a second pass after [apps] rather than block the list on it. Apps whose
  /// icon cannot be read are absent from the map.
  Future<Map<String, String>> appIcons({String? udid, String? connection}) =>
      _runTyped<Map<String, String>>(
        <String>['app-icons', ..._targetArgs(udid, connection)],
        (Object data) {
          final Map<String, dynamic>? json = asJsonObject(data);
          if (json == null) {
            return null;
          }
          return <String, String>{
            for (final MapEntry<String, dynamic> entry in json.entries)
              if (entry.value case final String icon) entry.key: icon,
          };
        },
      );

  /// Uninstalls an app from the device.
  Future<void> uninstall(String bundleId, {String? udid, String? connection}) =>
      _runVoid(
        <String>['uninstall', bundleId, ..._targetArgs(udid, connection)],
      );

  // ---- Library / refresh ------------------------------------------------- //

  /// Lists recorded sideloads with their expiry.
  Future<List<InstallRecord>> installs() => _runTyped<List<InstallRecord>>(
        <String>['installs'],
        _asObjectList(InstallRecord.fromJson),
      );

  /// Re-signs and reinstalls sideloaded apps to extend their signature.
  ///
  /// With [bundleId] only that app is refreshed; otherwise [all] decides between
  /// every recorded app and only those that are due. [keepSigned] and
  /// [signedDirectory] mean what they do on a sideload: a refresh re-signs, so it
  /// produces the same file.
  ///
  /// Deliberately takes NO udid: `refresh` does not accept `--udid`, because each
  /// recorded sideload already remembers the device it went to and a refresh
  /// reinstalls onto that same one. Retargeting an app at a different phone is a
  /// fresh sideload, not a refresh.
  ///
  /// It does take [connection], because that is a preference about this PC rather
  /// than about a record: without it the unattended daily run would go over the air
  /// after the user asked for USB only.
  ///
  /// The engine reports `ok` even when individual apps fail, so callers MUST
  /// inspect [RefreshSummary.refreshed].
  Future<RefreshSummary> refresh({
    String? bundleId,
    bool all = false,
    bool keepSigned = false,
    String? signedDirectory,
    String? connection,
    void Function(SideloadProgress progress)? onProgress,
  }) {
    final List<String> args = <String>['refresh'];
    if (bundleId != null) {
      args.add('--bundle-id');
      args.add(bundleId);
    } else if (all) {
      args.add('--all');
    }
    args.addAll(_targetArgs(null, connection));
    args.addAll(_signedOutputArgs(keepSigned, signedDirectory));

    return _runTyped<RefreshSummary>(
      args,
      _asObject(RefreshSummary.fromJson),
      onProgress: _progressPump(onProgress),
    );
  }

  /// Drops an app from the sideload registry without touching the device.
  Future<void> forget(String bundleId) =>
      _runVoid(<String>['forget', bundleId]);

  // ---- Signed IPAs ------------------------------------------------------- //

  /// Reports the signed `.ipa`s kept after installing: where they are, how many
  /// and how much space they take.
  ///
  /// [directory] lists a specific folder; omitted, the engine reports on - and
  /// names - its own default.
  Future<SignedIpaListing> signed({String? directory}) =>
      _runTyped<SignedIpaListing>(
        _signedArgs(directory: directory),
        _asObject(SignedIpaListing.fromJson),
      );

  /// Deletes every signed `.ipa` in the directory and reports what went.
  ///
  /// Destructive and not undoable; the caller owns asking first.
  Future<SignedIpaCleanup> cleanSigned({String? directory}) =>
      _runTyped<SignedIpaCleanup>(
        _signedArgs(directory: directory, clean: true),
        _asObject(SignedIpaCleanup.fromJson),
      );

  // ---- Diagnostics / meta ------------------------------------------------ //

  /// Checks the environment for sideloading readiness.
  ///
  /// DEVIATION from the C# client: the engine exits 1 when the overall status is
  /// `fail`, so the frame arrives with `ok: false` even though `data` still holds
  /// the complete report. The C# version threw there, which would hide the very
  /// report the diagnostics screen exists to show. Here a usable payload always
  /// wins; only a missing or unrecognisable one raises.
  Future<DoctorReport> doctor() async {
    final EngineResult result = await _client.run(<String>['doctor']);
    final Map<String, dynamic>? report = asJsonObject(result.data);
    if (report != null &&
        (report['overall'] is String || report['checks'] is List)) {
      return DoctorReport.fromJson(report);
    }

    if (!result.ok) {
      throw EngineException.fromResult(result.data, result.error);
    }
    if (result.data == null) {
      throw EngineException('The engine returned no data.');
    }
    throw EngineException('The engine returned an unexpected null payload.');
  }

  /// Reports the anisette package version and whether state is cached.
  Future<AnisetteStatus> anisette() => _runTyped<AnisetteStatus>(
        <String>['anisette'],
        _asObject(AnisetteStatus.fromJson),
      );

  // ---- Apple device support ---------------------------------------------- //

  /// Reports whether Apple Mobile Device Service is running, stopped or absent.
  ///
  /// This is the one probe: `doctor`'s row reports the same answer, so the screens
  /// that block work on it and the screen that diagnoses it cannot disagree.
  ///
  /// Never fails for a broken environment — a machine with no Apple stack at all
  /// is a *status*, not an error, and the engine exits zero reporting it.
  Future<AppleSupportStatus> appleSupport() => _runTyped<AppleSupportStatus>(
        <String>['apple-support'],
        _asObject(AppleSupportStatus.fromJson),
      );

  /// Downloads Apple's current iTunes installer and verifies Apple signed it.
  ///
  /// Streams the same progress shape a sideload does, so ~200 MB shows a real
  /// percentage instead of a spinner. It does NOT run the installer: the engine
  /// hands back a path only once Windows has confirmed the signature, and the app
  /// launches it — the same split `UpdateService` uses for iPASide's own updater.
  ///
  /// Raises when the download or the signature check fails; the engine deletes an
  /// unverified file rather than returning it.
  Future<ItunesDownload> downloadItunes({
    String? directory,
    void Function(SideloadProgress progress)? onProgress,
  }) =>
      _runTyped<ItunesDownload>(
        _appleSupportArgs(download: true, directory: directory),
        _asObject(ItunesDownload.fromJson),
        onProgress: _progressPump(onProgress),
      );

  /// Starts Apple Mobile Device Service, which prompts the user for elevation.
  ///
  /// Declining that prompt resolves normally with [AppleServiceStart.started]
  /// false: refusing to hand over administrator rights is an answer, not a fault.
  Future<AppleServiceStart> startAppleService() => _runTyped<AppleServiceStart>(
        _appleSupportArgs(startService: true),
        _asObject(AppleServiceStart.fromJson),
      );

  /// Reads the engine's own version.
  Future<EngineVersion> version() => _runTyped<EngineVersion>(
        <String>['version'],
        _asObject(EngineVersion.fromJson),
      );

  // ---- argv / progress (pure, unit-tested) ------------------------------- //

  /// Builds the sideload argv verbatim from the legacy web UI: the positional
  /// path, the target `--udid`, optional trimmed `--bundle-id` / `--name`, the
  /// negated remove flags only when their box is unchecked, file sharing when
  /// checked, the signed-IPA pair, one `--dylib` per tweak, and `--weak-dylibs`
  /// only when tweaks exist AND weak is checked.
  ///
  /// `--udid` leads because it says which phone the whole command is about.
  static List<String> buildSideloadArgs(String path, SideloadOptions options) {
    final List<String> args = <String>[
      'sideload',
      path,
      ..._targetArgs(options.udid, options.connection),
    ];

    final String? bundleId = options.bundleId;
    if (bundleId != null && bundleId.trim().isNotEmpty) {
      args.add('--bundle-id');
      args.add(bundleId.trim());
    }

    final String? name = options.name;
    if (name != null && name.trim().isNotEmpty) {
      args.add('--name');
      args.add(name.trim());
    }

    if (!options.removeExtensions) {
      args.add('--no-remove-extensions');
      for (final String extension in options.keepExtensions) {
        args.add('--keep-extension');
        args.add(extension);
      }
      if (options.ownExtensionAppIds) {
        args.add('--own-extension-app-ids');
      }
    }
    if (!options.removeDeviceRestrictions) {
      args.add('--no-remove-device-restrictions');
    }
    if (options.enableFileSharing) {
      args.add('--enable-file-sharing');
    }

    args.addAll(
      _signedOutputArgs(options.keepSigned, options.signedDirectory),
    );

    for (final String dylib in options.dylibs) {
      args.add('--dylib');
      args.add(dylib);
    }

    if (options.dylibs.isNotEmpty && options.weakDylibs) {
      args.add('--weak-dylibs');
    }
    if (options.dylibs.isNotEmpty && options.substrateProvider == 'ellekit') {
      args.add('--substrate');
      args.add('ellekit');
    }

    return args;
  }

  /// Builds the `export-unsigned` argv: the same option flags as a sideload,
  /// without a device, an Apple ID, or a kept signed copy.
  static List<String> buildExportUnsignedArgs(
    String path,
    SideloadOptions options, {
    required String output,
  }) {
    final List<String> args = <String>[
      'export-unsigned',
      path,
      '--output',
      output,
    ];

    final String? bundleId = options.bundleId;
    if (bundleId != null && bundleId.trim().isNotEmpty) {
      args.add('--bundle-id');
      args.add(bundleId.trim());
    }

    final String? name = options.name;
    if (name != null && name.trim().isNotEmpty) {
      args.add('--name');
      args.add(name.trim());
    }

    if (!options.removeExtensions) {
      args.add('--no-remove-extensions');
      for (final String extension in options.keepExtensions) {
        args.add('--keep-extension');
        args.add(extension);
      }
    }
    if (!options.removeDeviceRestrictions) {
      args.add('--no-remove-device-restrictions');
    }
    if (options.enableFileSharing) {
      args.add('--enable-file-sharing');
    }

    for (final String dylib in options.dylibs) {
      args.add('--dylib');
      args.add(dylib);
    }

    if (options.dylibs.isNotEmpty && options.weakDylibs) {
      args.add('--weak-dylibs');
    }

    return args;
  }

  /// Which device a command is for, and how to reach it.
  ///
  /// Omitting the UDID leaves the choice to the engine, which takes the one
  /// connected device and raises rather than guessing between several — so it is
  /// only optional on a single-device machine.
  ///
  /// `--connection` is omitted for automatic, which is the engine's own default
  /// (prefer USB, fall back to Wi-Fi), following this file's rule that a flag is
  /// spelled out only where the choice departs from the default.
  /// `--email` only when a specific Apple ID is meant; omitted means the active one.
  static List<String> _emailArgs(String? email) {
    final String? trimmed = email?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return const <String>[];
    }
    return <String>['--email', trimmed];
  }

  static List<String> _targetArgs(String? udid, [String? connection]) {
    final List<String> args = <String>[];
    if (udid != null && udid.trim().isNotEmpty) {
      args.addAll(<String>['--udid', udid.trim()]);
    }
    final String? transport = connection?.trim();
    if (transport != null && transport.isNotEmpty && transport != 'auto') {
      args.addAll(<String>['--connection', transport]);
    }
    return args;
  }

  /// The `--keep-signed` / `--signed-dir` pair shared by `sideload` and
  /// `refresh`.
  ///
  /// `--keep-signed` appears only when the signed file is being kept: the engine
  /// already deletes it by default, so `--no-keep-signed` would say nothing, and
  /// this file's rule is that a flag is spelled out only where the choice departs
  /// from the default (the same reason `--remove-extensions` is never emitted and
  /// its negation is). `--signed-dir` follows the directory rather than the
  /// keeping, because it is also where a `signed` listing would look.
  static List<String> _signedOutputArgs(bool keepSigned, String? directory) {
    final List<String> args = <String>[];
    if (keepSigned) {
      args.add('--keep-signed');
    }
    if (directory != null && directory.trim().isNotEmpty) {
      args.add('--signed-dir');
      args.add(directory.trim());
    }
    return args;
  }

  /// The `livecontainer --setup` argv.
  ///
  /// `--ipa` only when the caller has a file already; without it the engine
  /// fetches the newest release, which is what the UI does. The signed-output pair
  /// is included because a LiveContainer install is a sideload underneath and the
  /// user's keep-signed preference applies to it like any other.
  static List<String> buildLiveContainerArgs({
    String? ipaPath,
    String? udid,
    String? connection,
    bool keepSigned = false,
    String? signedDirectory,
  }) {
    final List<String> args = <String>[
      'livecontainer',
      ..._targetArgs(udid, connection),
      '--setup',
    ];
    final String? path = ipaPath?.trim();
    if (path != null && path.isNotEmpty) {
      args.addAll(<String>['--ipa', path]);
    }
    args.addAll(_signedOutputArgs(keepSigned, signedDirectory));
    return args;
  }

  /// The `jailbreak --install` argv.
  ///
  /// `--ipa` only when the caller already has a file; without it the engine fetches
  /// the newest Dopamine release, which is what the UI does. The signed-output pair is
  /// carried because a jailbreak install is a sideload underneath, so the user's
  /// keep-signed preference applies to it like any other.
  static List<String> buildJailbreakInstallArgs({
    String? ipaPath,
    String? udid,
    String? connection,
    bool keepSigned = false,
    String? signedDirectory,
  }) {
    final List<String> args = <String>[
      'jailbreak',
      ..._targetArgs(udid, connection),
      '--install',
    ];
    final String? path = ipaPath?.trim();
    if (path != null && path.isNotEmpty) {
      args.addAll(<String>['--ipa', path]);
    }
    args.addAll(_signedOutputArgs(keepSigned, signedDirectory));
    return args;
  }

  /// The `signed` argv: the subcommand, `--clean` when deleting, and `--dir` only
  /// when a folder other than the engine's default is meant.
  static List<String> _signedArgs({String? directory, bool clean = false}) {
    final List<String> args = <String>['signed'];
    if (clean) {
      args.add('--clean');
    }
    if (directory != null && directory.trim().isNotEmpty) {
      args.add('--dir');
      args.add(directory.trim());
    }
    return args;
  }

  /// The `apple-support` argv: the subcommand, the action when one is asked for,
  /// and `--dir` only when a folder other than the engine's default is meant.
  ///
  /// Status is what the command does unasked, so it emits no flag at all — the
  /// same rule the rest of this file follows.
  static List<String> _appleSupportArgs({
    bool download = false,
    bool startService = false,
    String? directory,
  }) {
    final List<String> args = <String>['apple-support'];
    if (download) {
      args.add('--download');
    }
    if (startService) {
      args.add('--start-service');
    }
    if (directory != null && directory.trim().isNotEmpty) {
      args.add('--dir');
      args.add(directory.trim());
    }
    return args;
  }

  /// Parses one progress-frame line.
  ///
  /// The transport hands over the frame's `line` field, which is ITSELF a JSON
  /// document the engine printed to stderr - hence the second decode here.
  /// Returns null unless that inner document is an object with
  /// `event == "progress"`, so ordinary engine chatter on stderr is ignored.
  static SideloadProgress? parseProgress(String line) {
    final Map<String, dynamic>? event = tryDecodeJsonObject(line);
    if (event == null || event['event'] != 'progress') {
      return null;
    }

    return SideloadProgress(
      phase: jsonString(event, 'phase'),
      percent: jsonDouble(event, 'percent'),
      step: jsonString(event, 'step'),
      bundleId: jsonString(event, 'bundle_id'),
    );
  }

  static void Function(String line)? _progressPump(
    void Function(SideloadProgress progress)? onProgress,
  ) {
    if (onProgress == null) {
      return null;
    }
    return (String line) {
      final SideloadProgress? mapped = parseProgress(line);
      if (mapped != null) {
        onProgress(mapped);
      }
    };
  }

  // ---- plumbing ---------------------------------------------------------- //

  Future<T> _runTyped<T extends Object>(
    List<String> args,
    T? Function(Object data) parse, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    final EngineResult result =
        await _client.run(args, onProgress: onProgress, env: env);
    if (!result.ok) {
      throw EngineException.fromResult(result.data, result.error);
    }

    final Object? data = result.data;
    if (data == null) {
      throw EngineException('The engine returned no data.');
    }

    final T? parsed = parse(data);
    if (parsed == null) {
      throw EngineException('The engine returned an unexpected null payload.');
    }
    return parsed;
  }

  Future<void> _runVoid(
    List<String> args, {
    Map<String, String>? env,
  }) async {
    final EngineResult result = await _client.run(args, env: env);
    if (!result.ok) {
      throw EngineException.fromResult(result.data, result.error);
    }
  }

  /// Adapts a `fromJson` factory: anything that is not a JSON object is an
  /// unusable payload.
  static T? Function(Object data) _asObject<T extends Object>(
    T Function(Map<String, dynamic> json) fromJson,
  ) =>
      (Object data) {
        final Map<String, dynamic>? json = asJsonObject(data);
        return json == null ? null : fromJson(json);
      };

  /// Adapts a `fromJson` factory to a JSON array, skipping non-object elements.
  /// An empty array yields an empty list; a non-array payload is unusable.
  static List<T>? Function(Object data) _asObjectList<T extends Object>(
    T Function(Map<String, dynamic> json) fromJson,
  ) =>
      (Object data) {
        if (data is! List) {
          return null;
        }
        return <T>[
          for (final Object? item in data)
            if (item is Map<String, dynamic>) fromJson(item),
        ];
      };

  static List<DeviceEntry> _parseDeviceEvent(Map<String, dynamic> frame) {
    final Object? data = frame['data'];
    if (data is! List) {
      return const <DeviceEntry>[];
    }
    return _asObjectList(DeviceEntry.fromJson)(data) ?? const <DeviceEntry>[];
  }
}
