import '../engine/engine.dart';
import '../platform/background_refresh_scheduler.dart';
import '../services/file_picker.dart';
import '../services/settings_store.dart';
import '../ui/shell/app_dialogs.dart';
import '../ui/shell/nav_destination.dart';
import 'base_view_model.dart';
import 'device_selection.dart';
import 'navigation_state.dart';

/// Settings: the engine-, OS- and disk-facing sections.
///
/// Auto-refresh drives the OS scheduler (the section is hidden entirely when the
/// platform has none), Signed IPAs owns the persisted keep/folder choice and the
/// files it produces, Account reflects the cached Apple ID session, Anisette
/// reports the provisioning package, Pairing is this PC's file for the selected
/// phone, and About carries the engine version.
/// Each section loads independently so one failure never blanks the screen.
///
/// Appearance is deliberately absent: the theme button is a pure view concern
/// bound straight to `ThemeController`, exactly as it was in the previous
/// build's code-behind.
class SettingsViewModel extends BaseViewModel {
  /// Creates the view model and starts every section's load.
  SettingsViewModel({
    required this._engine,
    required this._navigation,
    required this._scheduler,
    required this._settings,
    required this._picker,
    required this._dialogs,
    required this._devices,
  }) {
    // Synchronous, so the toggle and folder are already right on the first
    // frame; only the figures they describe have to be fetched.
    _signedIpa = _settings.loadSignedIpa();

    _devices.addListener(_onDeviceChanged);
    _loadAutoRefresh();
    _loadAccount();
    _loadAnisette();
    _loadVersion();
    _loadSignedUsage();
    _loadPairing();
  }

  final EngineApi _engine;
  final NavigationState _navigation;
  final BackgroundRefreshScheduler _scheduler;
  final SettingsStore _settings;
  final FilePickerService _picker;
  final DialogService _dialogs;
  final DeviceSelection _devices;

  @override
  void dispose() {
    _devices.removeListener(_onDeviceChanged);
    super.dispose();
  }

  // ---- Auto-refresh card ----

  bool _autoRefreshEnabled = false;
  bool _autoRefreshBusy = false;
  String _autoRefreshMessage = '';
  bool _isAutoRefreshMessageError = false;

  /// False hides the whole Auto-refresh card: this OS has no scheduler.
  bool get autoRefreshSupported => _scheduler.isSupported;

  /// Whether the daily background schedule currently exists.
  bool get autoRefreshEnabled => _autoRefreshEnabled;

  /// True while a create/delete round-trip runs; the toggle is disabled.
  bool get autoRefreshBusy => _autoRefreshBusy;

  /// Confirmation or failure text for the last toggle; empty when there is
  /// none.
  String get autoRefreshMessage => _autoRefreshMessage;

  bool get hasAutoRefreshMessage => _autoRefreshMessage.isNotEmpty;

  bool get isAutoRefreshMessageError => _isAutoRefreshMessageError;

  /// Creates or removes the schedule, then re-reads what the OS actually has.
  ///
  /// The toggle moves immediately and snaps back if the scheduler refuses.
  Future<void> setAutoRefreshEnabled(bool enabled) async {
    if (_autoRefreshBusy || enabled == _autoRefreshEnabled) return;

    _autoRefreshEnabled = enabled;
    _autoRefreshBusy = true;
    notify();

    try {
      await _scheduler.setEnabled(enabled);
      final actual = await _scheduler.isEnabled();
      _autoRefreshEnabled = actual;
      _isAutoRefreshMessageError = false;
      _autoRefreshMessage = actual ? 'On \u2014 runs daily at noon.' : 'Off.';
    } catch (error) {
      _autoRefreshEnabled = !enabled;
      _isAutoRefreshMessageError = true;
      _autoRefreshMessage = _schedulerErrorText(error);
    } finally {
      _autoRefreshBusy = false;
      notify();
    }
  }

  // ---- Signed IPAs section ----

  SignedIpaSettings _signedIpa = const SignedIpaSettings();
  String? _engineSignedDirectory;
  bool _isSignedLoading = true;
  bool _isSignedUnreadable = false;
  int _signedCount = 0;
  int _signedBytes = 0;
  bool _signedBusy = false;
  String _signedMessage = '';
  bool _isSignedMessageError = false;

  /// Whether the signed `.ipa` is kept after a successful install.
  bool get keepSignedIpa => _signedIpa.keep;

  /// Whether the folder is the engine's own, so there is nothing to reset.
  bool get usesDefaultSignedDirectory => _signedIpa.usesDefaultDirectory;

  /// The folder signed IPAs go to.
  ///
  /// The user's choice when there is one; otherwise the engine's default, which
  /// only the engine can name — so until it answers there is a placeholder here
  /// rather than a guess.
  String get signedDirectoryText =>
      _signedIpa.directory ?? _engineSignedDirectory ?? _pending;

  /// True until the first listing settles, one way or the other.
  bool get isSignedLoading => _isSignedLoading;

  /// One line describing what is on disk right now.
  ///
  /// A folder that does not exist yet and one that exists empty are the same
  /// thing to the user, and both are ordinary: the engine reports either as
  /// empty, and nothing has been kept. Only a failure to ask at all — which may
  /// be the folder or may be the engine — leaves the question unanswered, and
  /// then the reason goes underneath rather than into this line.
  String get signedUsageText {
    if (_isSignedLoading) return 'Checking\u2026';
    if (_isSignedUnreadable) return "Couldn't check.";
    if (_signedCount == 0) return 'Nothing kept yet.';
    return '${describeFileCount(_signedCount)} \u00b7 '
        '${describeBytes(_signedBytes)}';
  }

  /// True while a delete runs; the button shows a spinner and blocks re-entry.
  bool get signedBusy => _signedBusy;

  /// Whether there is anything to delete, and nothing already in flight.
  bool get canDeleteSignedIpas =>
      !_signedBusy && !_isSignedLoading && _signedCount > 0;

  /// The outcome of the last delete, or why the folder could not be read; empty
  /// when there is neither.
  String get signedMessage => _signedMessage;

  bool get hasSignedMessage => _signedMessage.isNotEmpty;

  bool get isSignedMessageError => _isSignedMessageError;

  /// Persists whether the signed `.ipa` survives an install.
  ///
  /// Nothing on disk changes here: the flag only decides what the next sideload
  /// leaves behind.
  void setKeepSignedIpa(bool keep) {
    if (keep == _signedIpa.keep) return;

    _signedIpa = _signedIpa.withKeep(keep);
    _settings.saveSignedIpa(_signedIpa);
    notify();
  }

  /// Asks the shell for a folder and, if the user picks one, persists it and
  /// re-reads what is in it.
  Future<void> chooseSignedDirectory() async {
    final String? chosen = await _picker.pickSignedFolder();
    if (chosen == null || chosen.trim().isEmpty) return; // cancelled

    await _applySignedDirectory(chosen.trim());
  }

  /// Hands the folder back to the engine's default.
  Future<void> resetSignedDirectory() async {
    if (_signedIpa.usesDefaultDirectory) return;

    await _applySignedDirectory(null);
  }

  /// Deletes every signed `.ipa` in the folder, once the user has agreed to it.
  ///
  /// Destructive and not undoable, so the count and the space are put in front
  /// of the user first; declining leaves the disk exactly as it was.
  Future<void> deleteSignedIpas() async {
    if (!canDeleteSignedIpas) return;

    final bool confirmed = await _dialogs.confirm(
      title: 'Delete kept signed IPAs?',
      message:
          'This permanently deletes ${describeFileCount(_signedCount)} from '
          '$signedDirectoryText and frees ${describeBytes(_signedBytes)}.\n\n'
          'The apps already installed on your iPhone are not touched. iPASide '
          'will simply sign an app again the next time you install it.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!confirmed) return;

    _signedBusy = true;
    _setSignedMessage('');
    notify();

    try {
      final SignedIpaCleanup cleanup = await _engine.cleanSigned(
        directory: _signedIpa.directory,
      );
      _setSignedMessage(
        cleanup.removed == 0
            ? 'There was nothing left to delete.'
            : 'Deleted ${describeFileCount(cleanup.removed)}, freed '
                  '${describeBytes(cleanup.bytesFreed)}.',
      );
    } on EngineShutdownException {
      _signedBusy = false;
      return; // the app is closing
    } catch (error) {
      _setSignedMessage(BaseViewModel.errorText(error), isError: true);
    }

    _signedBusy = false;
    notify();

    // Whether it worked or not, what is on disk now is the only honest figure.
    await _loadSignedUsage();
  }

  /// Renders a byte count the way a file manager would.
  ///
  /// Rounded to whole units below a gigabyte — a signed IPA is tens or hundreds
  /// of megabytes and nobody is counting its kilobytes — and to one decimal
  /// above, where whole gigabytes would hide most of the difference.
  static String describeBytes(int bytes) {
    const int kb = 1 << 10;
    const int mb = 1 << 20;
    const int gb = 1 << 30;

    if (bytes < kb) return '$bytes B';
    if (bytes < mb) return '${(bytes / kb).round()} KB';
    if (bytes < gb) return '${(bytes / mb).round()} MB';
    return '${(bytes / gb).toStringAsFixed(1)} GB';
  }

  /// `1 file` / `3 files`, spelled out rather than left as a bare number.
  static String describeFileCount(int count) =>
      count == 1 ? '1 file' : '$count files';

  // ---- Pairing file ----

  bool _isPairingLoading = true;
  String? _pairingError;
  PairingStatus? _pairing;
  bool _isPairingBusy = false;
  int _pairingLoadToken = 0;
  String _pairingMessage = '';
  bool _isPairingMessageError = false;
  String? _pairingShownUdid;
  String? _pairingShownConnection;

  bool get isPairingLoading => _isPairingLoading;
  String? get pairingError => _pairingError;
  PairingStatus? get pairing => _pairing;
  bool get isPairingBusy => _isPairingBusy;
  bool get hasPairingError => _pairingError != null;
  bool get hasPairingPayload => _pairing?.hasPayload ?? false;
  bool get canExportPairing => hasPairingPayload && !_isPairingBusy;
  bool get canImportPairing => !_isPairingBusy && _devices.selectedUdid != null;
  bool get canCreatePairing =>
      !_isPairingBusy && (_pairing?.deviceReachable ?? false);
  bool get canPlacePairing =>
      hasPairingPayload &&
      !_isPairingBusy &&
      (_pairing?.deviceReachable ?? false);

  String get pairingMessage => _pairingMessage;
  bool get hasPairingMessage => _pairingMessage.isNotEmpty;
  bool get isPairingMessageError => _isPairingMessageError;

  String get pairingUsbText {
    final PairingStatus? status = _pairing;
    if (status == null || !status.hasPayload) return '\u2014';
    return status.hasLockdown ? 'Present' : 'Missing';
  }

  String get pairingRemoteText {
    final PairingStatus? status = _pairing;
    if (status == null || !status.hasPayload) return '\u2014';
    return status.hasRppairing ? 'Present' : 'Missing';
  }

  Future<void> importPairing() async {
    if (!canImportPairing) return;
    final String? path = await _picker.pickPairingFile();
    if (path == null || isDisposed) return;

    _isPairingBusy = true;
    _setPairingMessage('');
    notify();
    try {
      final PairingImport result = await _engine.importPairing(
        path,
        udid: _devices.selectedUdid,
        connection: _devices.connectionArg,
      );
      if (isDisposed) return;
      await _loadPairing();
      if (isDisposed) return;
      _setPairingMessage(
        result.hasRppairing
            ? 'Imported. Remote Pairing keys are present.'
            : (result.note ?? 'Imported. Place it on the iPhone next.'),
      );
    } on EngineShutdownException {
      return;
    } catch (error) {
      if (!isDisposed) {
        _setPairingMessage(BaseViewModel.errorText(error), isError: true);
      }
    } finally {
      if (!isDisposed) {
        _isPairingBusy = false;
        notify();
      }
    }
  }

  Future<void> exportPairing() async {
    if (!canExportPairing) return;
    final String? path = await _picker.savePairingFile(
      suggestedName: 'pairingFile.plist',
    );
    if (path == null || isDisposed) return;

    _isPairingBusy = true;
    _setPairingMessage('');
    notify();
    try {
      final PairingExport result = await _engine.exportPairing(
        path,
        udid: _devices.selectedUdid,
        connection: _devices.connectionArg,
      );
      if (isDisposed) return;
      final String where = result.path ?? path;
      _setPairingMessage(
        result.hasRppairing
            ? 'Wrote $where, with Remote Pairing keys.'
            : 'Wrote $where. Create keys if EscapeOS on iOS 26.4+ needs them (iOS 18 can use USB pairing alone).',
      );
    } on EngineShutdownException {
      return;
    } catch (error) {
      if (!isDisposed) {
        _setPairingMessage(BaseViewModel.errorText(error), isError: true);
      }
    } finally {
      if (!isDisposed) {
        _isPairingBusy = false;
        notify();
      }
    }
  }

  Future<void> createPairing() async {
    if (!canCreatePairing) return;
    _isPairingBusy = true;
    _setPairingMessage('');
    notify();
    try {
      final PairingCreate result = await _engine.createPairing(
        udid: _devices.selectedUdid,
        connection: _devices.connectionArg,
      );
      if (isDisposed) return;
      await _loadPairing();
      if (isDisposed) return;
      if (!result.hasRppairing) {
        _setPairingMessage(
          result.error ??
              result.note ??
              'Unlock the iPhone, keep it plugged in over USB, and trust this PC.',
          isError: true,
        );
        return;
      }
      _setPairingMessage(
        result.created
            ? 'Remote Pairing keys created.'
            : 'Remote Pairing keys were already present.',
      );
    } on EngineShutdownException {
      return;
    } catch (error) {
      if (!isDisposed) {
        _setPairingMessage(BaseViewModel.errorText(error), isError: true);
      }
    } finally {
      if (!isDisposed) {
        _isPairingBusy = false;
        notify();
      }
    }
  }

  Future<void> placePairing() async {
    if (!canPlacePairing) return;
    final PairingStatus? snapshot = _pairing;
    if (snapshot == null) return;

    if (snapshot.consumers.isEmpty) {
      _setPairingMessage(
        'No supported apps are installed. Sideload EscapeOS, SideStore, '
        'AltStore, LiveContainer, or StikDebug first.',
        isError: true,
      );
      notify();
      return;
    }

    _isPairingBusy = true;
    _setPairingMessage('');
    notify();
    try {
      if (!snapshot.hasRppairing) {
        final PairingCreate created = await _engine.createPairing(
          udid: _devices.selectedUdid,
          connection: _devices.connectionArg,
        );
        if (isDisposed) return;
        if (!created.hasRppairing) {
          _setPairingMessage(
            created.error ??
                created.note ??
                'Unlock the iPhone, keep it plugged in over USB, and trust this PC.',
            isError: true,
          );
          return;
        }
      }
      final PairingDelivery result = await _engine.deliverPairing(
        udid: _devices.selectedUdid,
        connection: _devices.connectionArg,
      );
      if (isDisposed) return;
      await _loadPairing();
      if (isDisposed) return;
      _setPairingMessage(
        _placementMessage(result),
        isError: !result.allPlaced,
      );
    } on EngineShutdownException {
      return;
    } catch (error) {
      if (!isDisposed) {
        _setPairingMessage(BaseViewModel.errorText(error), isError: true);
      }
    } finally {
      if (!isDisposed) {
        _isPairingBusy = false;
        notify();
      }
    }
  }

  Future<void> placePairingOn(PairingConsumerInfo app) async {
    final String? bundleId = app.bundleId;
    if (bundleId == null || bundleId.isEmpty || !canPlacePairing) return;

    _isPairingBusy = true;
    _setPairingMessage('');
    notify();
    try {
      if (!(_pairing?.hasRppairing ?? false) && app.needsRppairing) {
        final PairingCreate created = await _engine.createPairing(
          udid: _devices.selectedUdid,
          connection: _devices.connectionArg,
        );
        if (isDisposed) return;
        if (!created.hasRppairing) {
          _setPairingMessage(
            created.error ??
                created.note ??
                'Unlock the iPhone, keep it plugged in over USB, and trust this PC.',
            isError: true,
          );
          return;
        }
      }
      final PairingDelivery result = await _engine.deliverPairing(
        udid: _devices.selectedUdid,
        connection: _devices.connectionArg,
        bundleId: bundleId,
      );
      if (isDisposed) return;
      await _loadPairing();
      if (isDisposed) return;
      _setPairingMessage(
        _placementMessage(result),
        isError: !result.allPlaced,
      );
    } on EngineShutdownException {
      return;
    } catch (error) {
      if (!isDisposed) {
        _setPairingMessage(BaseViewModel.errorText(error), isError: true);
      }
    } finally {
      if (!isDisposed) {
        _isPairingBusy = false;
        notify();
      }
    }
  }

  static String _placementMessage(PairingDelivery result) {
    if (result.placed.isEmpty) {
      return 'No supported apps are installed on this iPhone.';
    }
    final StringBuffer buffer = StringBuffer();
    for (final PairingPlacement item in result.placed) {
      final String name = item.name ?? item.bundleId ?? 'App';
      if (item.placed) {
        buffer.writeln('$name: wrote ${item.filename}.');
      } else {
        buffer.writeln('$name: ${item.error ?? 'could not be written'}.');
      }
    }
    if (result.note != null && !result.hasRppairing) {
      buffer.writeln();
      buffer.write(result.note);
    }
    return buffer.toString().trim();
  }

  void _setPairingMessage(String message, {bool isError = false}) {
    _pairingMessage = message;
    _isPairingMessageError = isError;
  }

  void _onDeviceChanged() {
    if (isDisposed) return;
    final String? udid = _devices.selectedUdid;
    final String? connection = _devices.connectionArg;
    if (udid == _pairingShownUdid && connection == _pairingShownConnection) {
      return;
    }
    _pairing = null;
    _pairingError = null;
    _isPairingLoading = true;
    _setPairingMessage('');
    notify();
    _loadPairing();
  }

  Future<void> _loadPairing() async {
    final int token = ++_pairingLoadToken;
    final String? udid = await _devices.targetUdid();
    final String? connection = _devices.connectionArg;
    if (isDisposed || token != _pairingLoadToken) return;
    _pairingShownUdid = udid;
    _pairingShownConnection = connection;

    if (udid == null || udid.isEmpty) {
      _pairing = null;
      _pairingError = null;
      _isPairingLoading = false;
      notify();
      return;
    }

    try {
      final PairingStatus status = await _engine.pairingStatus(
        udid: udid,
        connection: connection,
      );
      if (token != _pairingLoadToken) return;
      _pairing = status;
      _pairingError = null;
    } catch (error) {
      if (token != _pairingLoadToken) return;
      if (!BaseViewModel.isShutdown(error)) {
        _pairingError = BaseViewModel.errorText(error);
        _pairing = null;
      }
    } finally {
      if (token == _pairingLoadToken) {
        _isPairingLoading = false;
        notify();
      }
    }
  }

  // ---- Account card ----

  bool _isAccountLoading = true;
  String? _accountError;
  bool _isAuthenticated = false;
  String _accountEmail = '';

  bool get isAccountLoading => _isAccountLoading;
  String? get accountError => _accountError;
  bool get hasAccountError => _accountError != null;
  bool get isAuthenticated => _isAuthenticated;
  String get accountEmail => _accountEmail;
  bool get isAccountSignedOut =>
      !_isAccountLoading && _accountError == null && !_isAuthenticated;

  /// Drops the cached session, then remounts Settings so every card reloads.
  Future<void> signOut() async {
    try {
      await _engine.logout();
    } on EngineShutdownException {
      return; // the app is closing
    } catch (error) {
      _accountError = BaseViewModel.errorText(error);
      notify();
      return;
    }
    _navigation.navigateTo(NavKey.settings);
  }

  void signIn() => _navigation.navigateTo(NavKey.signIn);

  // ---- Anisette card ----

  bool _isAnisetteLoading = true;
  String? _anisetteError;
  String _anisetteProvider = '';
  String _anisetteState = '';
  String _anisetteServers = '';
  bool _anisetteIsRemote = false;

  bool get isAnisetteLoading => _isAnisetteLoading;
  String? get anisetteError => _anisetteError;
  bool get hasAnisetteError => _anisetteError != null;

  /// Which provider makes the anisette data: `Remote Mac service`, or for the local emulator
  /// (and older engines that only had it) the package in use, e.g. `anisette 1.2.4`.
  String get anisetteProvider => _anisetteProvider;

  /// The anisette services tried in order, as host names, or empty for the local emulator.
  String get anisetteServers => _anisetteServers;

  /// True when anisette comes from a remote service, so the privacy note is shown.
  bool get anisetteIsRemote => _anisetteIsRemote;

  /// `provisioned` once state is cached on disk, otherwise `first-use`.
  String get anisetteState => _anisetteState;

  // ---- About card ----

  String _engineVersionText = _pending;

  /// The engine's version, or the placeholder until it answers.
  String get engineVersionText => _engineVersionText;

  // ---- Loads ----

  /// Stands in for a value only the engine can supply, until it has.
  static const String _pending = '\u2026';

  Future<void> _loadAutoRefresh() async {
    if (!_scheduler.isSupported) return;
    try {
      _autoRefreshEnabled = await _scheduler.isEnabled();
      notify();
    } catch (_) {
      // The toggle simply stays off when the schedule cannot be read.
    }
  }

  Future<void> _loadAccount() async {
    try {
      final status = await _engine.loginStatus();
      if (status.authenticated) {
        _accountEmail = status.email ?? '';
        _isAuthenticated = true;
      }
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _accountError = BaseViewModel.errorText(error);
      }
    } finally {
      _isAccountLoading = false;
      notify();
    }
  }

  Future<void> _loadAnisette() async {
    try {
      final status = await _engine.anisette();
      _anisetteIsRemote = status.provider == 'remote';
      _anisetteProvider = _anisetteIsRemote
          ? 'Remote Mac service'
          : 'anisette ${status.packageVersion ?? '?'}';
      _anisetteServers = status.servers
          .map((String s) => Uri.tryParse(s)?.host ?? s)
          .where((String host) => host.isNotEmpty)
          .join(', ');
      _anisetteState = status.stateCached ? 'provisioned' : 'first-use';
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _anisetteError = BaseViewModel.errorText(error);
      }
    } finally {
      _isAnisetteLoading = false;
      notify();
    }
  }

  Future<void> _loadVersion() async {
    try {
      final version = await _engine.version();
      final text = version.version;
      _engineVersionText = text == null || text.isEmpty ? '?' : text;
      notify();
    } catch (_) {
      // About keeps its placeholder; the version is not worth an error state.
    }
  }

  /// Re-reads the folder: where it is, how many files and how big.
  ///
  /// A folder that does not exist yet is not a failure — the engine reports an
  /// empty one — and neither is an empty one. A folder that genuinely cannot be
  /// read leaves the figures at zero, says so on the row, and puts the engine's
  /// own cleaned reason underneath; nothing raw ever reaches the screen.
  ///
  /// A success deliberately leaves [signedMessage] alone, so the confirmation of
  /// a delete survives the re-read that follows it.
  Future<void> _loadSignedUsage() async {
    try {
      final SignedIpaListing listing = await _engine.signed(
        directory: _signedIpa.directory,
      );
      _engineSignedDirectory = listing.directory;
      _signedCount = listing.count;
      _signedBytes = listing.bytes;
      _isSignedUnreadable = false;
    } catch (error) {
      if (!BaseViewModel.isShutdown(error)) {
        _signedCount = 0;
        _signedBytes = 0;
        _isSignedUnreadable = true;
        _setSignedMessage(BaseViewModel.errorText(error), isError: true);
      }
    } finally {
      _isSignedLoading = false;
      notify();
    }
  }

  /// Persists a new folder — or the default, for null — and re-reads it.
  Future<void> _applySignedDirectory(String? directory) async {
    _signedIpa = _signedIpa.withDirectory(directory);
    _settings.saveSignedIpa(_signedIpa);

    // The old folder's figures describe a folder nobody is looking at now.
    _isSignedLoading = true;
    _isSignedUnreadable = false;
    _setSignedMessage('');
    notify();

    await _loadSignedUsage();
  }

  /// Sets the section's one message channel, so the text and the tone can never
  /// drift apart.
  void _setSignedMessage(String message, {bool isError = false}) {
    _signedMessage = message;
    _isSignedMessageError = isError;
  }

  /// [BackgroundRefreshException.message] is already presentable, so it is
  /// cleaned directly rather than through the exception's `toString`.
  static String _schedulerErrorText(Object error) =>
      error is BackgroundRefreshException
      ? EngineException.cleanError(error.message)
      : BaseViewModel.errorText(error);
}
