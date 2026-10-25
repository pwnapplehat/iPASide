// Lean models mapping ONLY the engine fields the UI consumes, ported from
// iPASide.App/Engine/Models.cs.
//
// Wire keys are spelled out per field and never fuzzy-matched: the engine mixes
// conventions (lockdown values are PascalCase, inventory values are snake_case,
// `apps` returns a dict keyed by bundle id).
//
// Two deliberate departures from the C# records:
//  * Parsing is tolerant. A missing or wrongly-typed field degrades to
//    null/false/empty; System.Text.Json would have thrown and taken the whole
//    screen with it.
//  * List-valued fields are never null (the C# records used nullable lists that
//    every caller coalesced). They must be treated as read-only.
//
// Value equality is implemented by hand so the UI can suppress rebuilds by
// comparing snapshots, the way it could with C# records.

import 'json_utils.dart';

/// Lockdown device identity, using the PascalCase keys pymobiledevice3 returns.
class DeviceInfo {
  /// Creates a device identity.
  const DeviceInfo({
    this.deviceName,
    this.productType,
    this.productVersion,
    this.buildVersion,
    this.uniqueDeviceId,
  });

  /// Parses one `device-info` payload.
  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        deviceName: jsonString(json, 'DeviceName'),
        productType: jsonString(json, 'ProductType'),
        productVersion: jsonString(json, 'ProductVersion'),
        buildVersion: jsonString(json, 'BuildVersion'),
        uniqueDeviceId: jsonString(json, 'UniqueDeviceID'),
      );

  /// User-chosen device name, e.g. `iOS_hAT's iPhone`.
  final String? deviceName;

  /// Hardware model identifier, e.g. `iPhone10,2`.
  final String? productType;

  /// iOS version, e.g. `16.7.15`.
  final String? productVersion;

  /// iOS build number, e.g. `20H380`.
  final String? buildVersion;

  /// 40-character UDID.
  final String? uniqueDeviceId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceInfo &&
          other.deviceName == deviceName &&
          other.productType == productType &&
          other.productVersion == productVersion &&
          other.buildVersion == buildVersion &&
          other.uniqueDeviceId == uniqueDeviceId;

  @override
  int get hashCode => Object.hash(
        deviceName,
        productType,
        productVersion,
        buildVersion,
        uniqueDeviceId,
      );

  @override
  String toString() => 'DeviceInfo(deviceName: $deviceName, '
      'productType: $productType, productVersion: $productVersion, '
      'buildVersion: $buildVersion, uniqueDeviceId: $uniqueDeviceId)';
}

/// One entry from `devices`.
///
/// usbmux reports one entry PER TRANSPORT, so a phone that is plugged in and
/// also reachable over Wi-Fi appears twice under the same [serial]. That is one
/// device with two ways in, not two devices; grouping them back into physical
/// devices is [DeviceSelection]'s job.
class DeviceEntry {
  /// Creates a device list entry.
  const DeviceEntry({this.serial, this.connectionType});

  /// Parses one element of the `devices` array.
  ///
  /// `device_id` is deliberately not read: it is usbmux's per-transport handle,
  /// not an identity — the same phone has a different one on each transport and
  /// they change across reconnects, so nothing in the UI can use it.
  factory DeviceEntry.fromJson(Map<String, dynamic> json) => DeviceEntry(
        serial: jsonString(json, 'serial'),
        connectionType: jsonString(json, 'connection_type'),
      );

  /// The device's UDID, and the only thing that identifies it across
  /// transports. Null for an entry usbmux could not name, which can never be a
  /// target.
  final String? serial;

  /// `USB` or `Network`, as reported by usbmux.
  final String? connectionType;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceEntry &&
          other.serial == serial &&
          other.connectionType == connectionType;

  @override
  int get hashCode => Object.hash(serial, connectionType);

  @override
  String toString() =>
      'DeviceEntry(serial: $serial, connectionType: $connectionType)';
}

/// Result of `login --status`.
class LoginStatus {
  /// Creates a session status.
  const LoginStatus({
    this.authenticated = false,
    this.email,
    this.teamId,
    this.accountCount = 0,
  });

  /// Parses a `login --status` payload.
  factory LoginStatus.fromJson(Map<String, dynamic> json) => LoginStatus(
        authenticated: jsonBool(json, 'authenticated'),
        email: jsonString(json, 'email'),
        teamId: jsonString(json, 'team_id'),
        accountCount: jsonInt(json, 'account_count'),
      );

  /// Whether a usable Apple ID session is cached.
  final bool authenticated;

  /// The Apple ID in use, when there is one.
  final String? email;

  /// The developer team that account provisions under, once it has provisioned.
  final String? teamId;

  /// How many Apple IDs are signed in, in use or not.
  final int accountCount;

  /// Whether there is more than one account to choose between.
  bool get hasChoice => accountCount > 1;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoginStatus &&
          other.authenticated == authenticated &&
          other.email == email &&
          other.teamId == teamId &&
          other.accountCount == accountCount;

  @override
  int get hashCode => Object.hash(authenticated, email, teamId, accountCount);

  @override
  String toString() => 'LoginStatus(authenticated: $authenticated, '
      'email: $email, teamId: $teamId, accountCount: $accountCount)';
}

/// One Apple ID that is signed in, from `login --accounts`.
///
/// Several can be kept at once. Which one is [active] decides who signs a new
/// sideload; a refresh instead uses whichever account provisions under the team
/// that signed the app originally, because re-signing it with a different team's
/// identity leaves iOS unable to install it over the copy already installed.
class AppleAccount {
  /// Creates an account entry.
  const AppleAccount({
    required this.email,
    this.teamId,
    this.active = false,
  });

  /// Parses one entry of a `login --accounts` payload.
  factory AppleAccount.fromJson(Map<String, dynamic> json) => AppleAccount(
        email: jsonString(json, 'email') ?? '',
        teamId: jsonString(json, 'team_id'),
        active: jsonBool(json, 'active'),
      );

  /// The Apple ID.
  final String email;

  /// The developer team it provisions under, once it has provisioned once.
  final String? teamId;

  /// Whether this is the account new sideloads will use.
  final bool active;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppleAccount &&
          other.email == email &&
          other.teamId == teamId &&
          other.active == active;

  @override
  int get hashCode => Object.hash(email, teamId, active);

  @override
  String toString() =>
      'AppleAccount(email: $email, teamId: $teamId, active: $active)';
}

/// Result of `login` / `login --code`.
class LoginResult {
  /// Creates a login outcome.
  const LoginResult({this.status, this.method, this.notice});

  /// Parses a `login` payload.
  factory LoginResult.fromJson(Map<String, dynamic> json) => LoginResult(
        status: jsonString(json, 'status'),
        method: jsonString(json, 'method'),
        notice: jsonString(json, 'notice'),
      );

  /// `2fa_required` or `authenticated`.
  final String? status;

  /// How the verification code was delivered, when 2FA is required.
  final String? method;

  /// What to tell the person instead of the usual "a code was sent" line, when the engine could
  /// not deliver the code the usual way (Apple refused the text message).
  final String? notice;

  /// Whether the engine is waiting for a two-factor code.
  bool get requiresTwoFactor => status == '2fa_required';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoginResult &&
          other.status == status &&
          other.method == method &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(status, method, notice);

  @override
  String toString() =>
      'LoginResult(status: $status, method: $method, notice: $notice)';
}

/// Result of `inspect`.
class IpaInspection {
  /// Creates an IPA inspection.
  const IpaInspection({
    this.bundleId,
    this.displayName,
    this.icon,
    this.version,
    this.minimumOs,
    this.frameworks = const <String>[],
    this.extensions = const <String>[],
    this.hasScInfo = false,
  });

  /// Parses an `inspect` payload.
  factory IpaInspection.fromJson(Map<String, dynamic> json) => IpaInspection(
        bundleId: jsonString(json, 'bundle_id'),
        displayName: jsonString(json, 'display_name'),
        icon: jsonString(json, 'icon'),
        version: jsonString(json, 'version'),
        minimumOs: jsonString(json, 'minimum_os'),
        frameworks: jsonStringList(json, 'frameworks'),
        extensions: jsonStringList(json, 'extensions'),
        hasScInfo: jsonBool(json, 'has_sc_info'),
      );

  /// The IPA's own bundle identifier, before any override.
  final String? bundleId;

  /// `CFBundleDisplayName`, falling back to `CFBundleName`.
  final String? displayName;

  /// Base64-encoded PNG app icon, when the IPA carries one.
  final String? icon;

  /// `CFBundleShortVersionString`.
  final String? version;

  /// `MinimumOSVersion`.
  final String? minimumOs;

  /// Embedded framework names. Read-only.
  final List<String> frameworks;

  /// App-extension (`.appex`) names, including any watch app. Read-only.
  final List<String> extensions;

  /// Whether an `SC_Info` directory is present, i.e. the payload is FairPlay
  /// encrypted and cannot be re-signed.
  final bool hasScInfo;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IpaInspection &&
          other.bundleId == bundleId &&
          other.displayName == displayName &&
          other.icon == icon &&
          other.version == version &&
          other.minimumOs == minimumOs &&
          _listEquals(other.frameworks, frameworks) &&
          _listEquals(other.extensions, extensions) &&
          other.hasScInfo == hasScInfo;

  @override
  int get hashCode => Object.hash(
        bundleId,
        displayName,
        icon,
        version,
        minimumOs,
        Object.hashAll(frameworks),
        Object.hashAll(extensions),
        hasScInfo,
      );

  @override
  String toString() => 'IpaInspection(bundleId: $bundleId, '
      'displayName: $displayName, version: $version, '
      'minimumOs: $minimumOs, frameworks: ${frameworks.length}, '
      'extensions: ${extensions.length}, hasScInfo: $hasScInfo, '
      'icon: ${_describeIcon(icon)})';
}

/// One value from the `apps` dict (which is keyed by bundle id).
class InstalledApp {
  /// Creates an installed-app entry.
  const InstalledApp({this.name, this.version});

  /// Parses one value of the `apps` dict.
  factory InstalledApp.fromJson(Map<String, dynamic> json) => InstalledApp(
        name: jsonString(json, 'name'),
        version: jsonString(json, 'version'),
      );

  /// Display name as installed on the device.
  final String? name;

  /// Installed short version string.
  final String? version;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InstalledApp && other.name == name && other.version == version;

  @override
  int get hashCode => Object.hash(name, version);

  @override
  String toString() => 'InstalledApp(name: $name, version: $version)';
}

/// The recorded sideload options carried on an [InstallRecord].
class InstallOptions {
  /// Creates a recorded option set.
  const InstallOptions({this.dylibs = const <String>[]});

  /// Parses the `options` object of an `installs` entry.
  factory InstallOptions.fromJson(Map<String, dynamic> json) =>
      InstallOptions(dylibs: jsonStringList(json, 'dylibs'));

  /// Dylib paths injected during the original sideload. Read-only.
  final List<String> dylibs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InstallOptions && _listEquals(other.dylibs, dylibs);

  @override
  int get hashCode => Object.hashAll(dylibs);

  @override
  String toString() => 'InstallOptions(dylibs: $dylibs)';
}

/// One entry from `installs`: a recorded sideload plus its expiry.
class InstallRecord {
  /// Creates a library record.
  const InstallRecord({
    this.bundleId,
    this.name,
    this.icon,
    this.daysLeft,
    this.expired = false,
    this.options,
    this.udid,
  });

  /// Parses one element of the `installs` array.
  factory InstallRecord.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? options = asJsonObject(json['options']);
    return InstallRecord(
      bundleId: jsonString(json, 'bundle_id'),
      name: jsonString(json, 'name'),
      icon: jsonString(json, 'icon'),
      daysLeft: jsonDouble(json, 'days_left'),
      expired: jsonBool(json, 'expired'),
      options: options == null ? null : InstallOptions.fromJson(options),
      udid: jsonString(json, 'udid'),
    );
  }

  /// Installed bundle identifier (the override, when one was used).
  final String? bundleId;

  /// Display name recorded at sideload time.
  final String? name;

  /// Base64-encoded PNG app icon, when one was recorded.
  final String? icon;

  /// Days until the free provisioning profile expires; null when unknown.
  final double? daysLeft;

  /// Whether the recorded profile has already expired.
  final bool expired;

  /// Options the app was sideloaded with; null when the record predates them.
  final InstallOptions? options;

  /// The device this app was installed onto.
  ///
  /// Row actions are issued against this rather than whichever device happens to
  /// be selected now, so removing an app cannot uninstall it from another phone.
  final String? udid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InstallRecord &&
          other.bundleId == bundleId &&
          other.name == name &&
          other.icon == icon &&
          other.daysLeft == daysLeft &&
          other.expired == expired &&
          other.options == options;

  @override
  int get hashCode =>
      Object.hash(bundleId, name, icon, daysLeft, expired, options);

  @override
  String toString() => 'InstallRecord(bundleId: $bundleId, name: $name, '
      'daysLeft: $daysLeft, expired: $expired, options: $options, '
      'icon: ${_describeIcon(icon)})';
}

/// Per-app outcome inside a [RefreshSummary].
class RefreshEntry {
  /// Creates a per-app refresh outcome.
  const RefreshEntry({this.bundleId, this.status, this.error});

  /// Parses one element of the `refreshed` array.
  factory RefreshEntry.fromJson(Map<String, dynamic> json) => RefreshEntry(
        bundleId: jsonString(json, 'bundle_id'),
        status: jsonString(json, 'status'),
        error: jsonString(json, 'error'),
      );

  /// The app that was refreshed.
  final String? bundleId;

  /// `refreshed`, `skipped`, `error`, ...
  final String? status;

  /// Raw failure text; only meaningful when [status] is `error`.
  final String? error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RefreshEntry &&
          other.bundleId == bundleId &&
          other.status == status &&
          other.error == error;

  @override
  int get hashCode => Object.hash(bundleId, status, error);

  @override
  String toString() =>
      'RefreshEntry(bundleId: $bundleId, status: $status, error: $error)';
}

/// Result of `refresh`.
///
/// The engine returns `ok: true` even when individual apps fail, so callers
/// MUST inspect [refreshed].
class RefreshSummary {
  /// Creates a refresh summary.
  const RefreshSummary({this.refreshed = const <RefreshEntry>[]});

  /// Parses a `refresh` payload.
  factory RefreshSummary.fromJson(Map<String, dynamic> json) => RefreshSummary(
        refreshed: jsonObjectList(json, 'refreshed', RefreshEntry.fromJson),
      );

  /// One entry per app the run touched. Read-only.
  final List<RefreshEntry> refreshed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RefreshSummary && _listEquals(other.refreshed, refreshed);

  @override
  int get hashCode => Object.hashAll(refreshed);

  @override
  String toString() => 'RefreshSummary(refreshed: $refreshed)';
}

/// Result of `sideload` (status is `installed` on success).
class SideloadResult {
  /// Creates a sideload outcome.
  const SideloadResult({this.status, this.name, this.bundleId});

  /// Parses a `sideload` payload.
  factory SideloadResult.fromJson(Map<String, dynamic> json) => SideloadResult(
        status: jsonString(json, 'status'),
        name: jsonString(json, 'name'),
        bundleId: jsonString(json, 'bundle_id'),
      );

  /// `installed` on success.
  final String? status;

  /// Display name the app was installed under.
  final String? name;

  /// Bundle identifier the app was installed under.
  final String? bundleId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SideloadResult &&
          other.status == status &&
          other.name == name &&
          other.bundleId == bundleId;

  @override
  int get hashCode => Object.hash(status, name, bundleId);

  @override
  String toString() => 'SideloadResult(status: $status, name: $name, '
      'bundleId: $bundleId)';
}

/// One development certificate on a team, and who registered it.
///
/// Apple scopes its certificate limit per machine rather than per account, so one team
/// routinely holds several - iPASide's alongside Xcode's on a Mac and SideStore's on a
/// phone. Revoking one stops every app *it* signed from opening, which may belong to a
/// different tool, so who owns each is the part that matters.
class AccountCertificate {
  /// Creates a certificate entry.
  const AccountCertificate({
    this.serial,
    this.name,
    this.machine,
    this.type,
    this.expires,
    this.ours = false,
    this.inUseHere = false,
  });

  /// Parses one element of `slots`' `certificates`.
  factory AccountCertificate.fromJson(Map<String, dynamic> json) =>
      AccountCertificate(
        serial: jsonString(json, 'serial'),
        name: jsonString(json, 'name'),
        machine: jsonString(json, 'machine'),
        type: jsonString(json, 'type'),
        expires: jsonDateTime(json, 'expires'),
        ours: jsonBool(json, 'ours'),
        inUseHere: jsonBool(json, 'in_use_here'),
      );

  /// Serial number, which is what identifies it to Apple.
  final String? serial;

  /// Apple's own name for it, e.g. `iOS Development: Someone`.
  final String? name;

  /// The machine that registered it - how one tool's is told from another's.
  final String? machine;

  /// Certificate type, e.g. `iOS Development`.
  final String? type;

  /// When Apple stops honouring it; null when the engine reported nothing readable.
  final DateTime? expires;

  /// Registered by iPASide, on this machine or another.
  final bool ours;

  /// The one this machine holds the private key for and signs with now. Revoking it
  /// stops the apps installed from here from opening.
  final bool inUseHere;

  /// Who registered it, in words for a person rather than a machine name.
  String get owner {
    if (inUseHere) return 'iPASide · signing with it now';
    if (ours) return 'iPASide · another machine';
    return machine ?? 'Unknown';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountCertificate &&
          other.serial == serial &&
          other.name == name &&
          other.machine == machine &&
          other.type == type &&
          other.expires == expires &&
          other.ours == ours &&
          other.inUseHere == inUseHere;

  @override
  int get hashCode =>
      Object.hash(serial, name, machine, type, expires, ours, inUseHere);

  @override
  String toString() => 'AccountCertificate(serial: $serial, owner: $owner)';
}

/// One registered app identifier.
class AccountAppId {
  /// Creates an app identifier entry.
  const AccountAppId({this.id, this.identifier, this.name});

  /// Parses one element of `slots`' `app_ids`.
  factory AccountAppId.fromJson(Map<String, dynamic> json) => AccountAppId(
        id: jsonString(json, 'id'),
        identifier: jsonString(json, 'identifier'),
        name: jsonString(json, 'name'),
      );

  /// Apple's internal id, which is what deleting it takes.
  final String? id;

  /// The identifier itself, e.g. `com.example.app.TEAMID`.
  final String? identifier;

  /// Display name it was registered under.
  final String? name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountAppId &&
          other.id == id &&
          other.identifier == identifier &&
          other.name == name;

  @override
  int get hashCode => Object.hash(id, identifier, name);

  @override
  String toString() => 'AccountAppId(identifier: $identifier)';
}

/// One device registered to the team.
class AccountDevice {
  /// Creates a device entry.
  const AccountDevice({this.id, this.name, this.udid});

  /// Parses one element of `slots`' `devices`.
  factory AccountDevice.fromJson(Map<String, dynamic> json) => AccountDevice(
        id: jsonString(json, 'id'),
        name: jsonString(json, 'name'),
        udid: jsonString(json, 'udid'),
      );

  /// Apple's internal id.
  final String? id;

  /// Name the device was registered under.
  final String? name;

  /// Its UDID.
  final String? udid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountDevice &&
          other.id == id &&
          other.name == name &&
          other.udid == udid;

  @override
  int get hashCode => Object.hash(id, name, udid);

  @override
  String toString() => 'AccountDevice(udid: $udid)';
}

/// What one Apple ID's developer account holds.
class AccountOverview {
  /// Creates an overview.
  const AccountOverview({
    this.account,
    this.teamId,
    this.teamName,
    this.teamType,
    this.certificates = const <AccountCertificate>[],
    this.appIds = const <AccountAppId>[],
    this.devices = const <AccountDevice>[],
    this.registeredAppIds = 0,
    this.weeklyAppIdLimit = 10,
  });

  /// Parses a `slots` payload.
  factory AccountOverview.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> team = jsonObject(json, 'team');
    return AccountOverview(
      account: jsonString(json, 'account'),
      teamId: jsonString(team, 'id'),
      teamName: jsonString(team, 'name'),
      teamType: jsonString(team, 'type'),
      certificates: jsonObjectList(json, 'certificates', AccountCertificate.fromJson),
      appIds: jsonObjectList(json, 'app_ids', AccountAppId.fromJson),
      devices: jsonObjectList(json, 'devices', AccountDevice.fromJson),
      registeredAppIds: jsonInt(json, 'registered_app_ids'),
      weeklyAppIdLimit: jsonInt(json, 'weekly_app_id_limit', orElse: 10),
    );
  }

  /// The Apple ID this describes.
  final String? account;

  /// Team identifier, name and kind.
  final String? teamId;
  final String? teamName;
  final String? teamType;

  /// Certificates on the team. Read-only.
  final List<AccountCertificate> certificates;

  /// App identifiers currently registered. Read-only.
  final List<AccountAppId> appIds;

  /// Devices on the team. Read-only.
  final List<AccountDevice> devices;

  /// How many identifiers exist now.
  final int registeredAppIds;

  /// How many *new* identifiers Apple allows per rolling 7 days.
  ///
  /// Deliberately not a fraction with [registeredAppIds]: that ceiling counts
  /// registrations over a week, while the list is what exists. Shown as one number they
  /// read as spare capacity that may already be spent.
  final int weeklyAppIdLimit;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountOverview &&
          other.account == account &&
          other.teamId == teamId &&
          other.teamName == teamName &&
          other.teamType == teamType &&
          _listEquals(other.certificates, certificates) &&
          _listEquals(other.appIds, appIds) &&
          _listEquals(other.devices, devices) &&
          other.registeredAppIds == registeredAppIds &&
          other.weeklyAppIdLimit == weeklyAppIdLimit;

  @override
  int get hashCode => Object.hash(
        account,
        teamId,
        teamName,
        teamType,
        Object.hashAll(certificates),
        Object.hashAll(appIds),
        Object.hashAll(devices),
        registeredAppIds,
        weeklyAppIdLimit,
      );

  @override
  String toString() => 'AccountOverview(account: $account, team: $teamId, '
      'certificates: ${certificates.length})';
}

/// What revoking a certificate cost.
class RevokedCertificate {
  /// Creates a revocation outcome.
  const RevokedCertificate({
    this.serial,
    this.machine,
    this.wasOurs = false,
    this.invalidatesLocalApps = false,
  });

  /// Parses a `revoke-cert` payload.
  factory RevokedCertificate.fromJson(Map<String, dynamic> json) =>
      RevokedCertificate(
        serial: jsonString(json, 'revoked'),
        machine: jsonString(json, 'machine'),
        wasOurs: jsonBool(json, 'was_ours'),
        invalidatesLocalApps: jsonBool(json, 'invalidates_local_apps'),
      );

  /// The serial that was revoked.
  final String? serial;

  /// The machine that had registered it.
  final String? machine;

  /// Whether iPASide registered it.
  final bool wasOurs;

  /// Whether the apps installed from this machine have just stopped working.
  final bool invalidatesLocalApps;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RevokedCertificate &&
          other.serial == serial &&
          other.machine == machine &&
          other.wasOurs == wasOurs &&
          other.invalidatesLocalApps == invalidatesLocalApps;

  @override
  int get hashCode => Object.hash(serial, machine, wasOurs, invalidatesLocalApps);

  @override
  String toString() => 'RevokedCertificate(serial: $serial, '
      'invalidatesLocalApps: $invalidatesLocalApps)';
}

/// One app running inside LiveContainer rather than installed on the phone.
class GuestApp {
  /// Creates a guest app entry.
  const GuestApp({this.bundleId, this.folder});

  /// Parses one element of `livecontainer --apps`.
  factory GuestApp.fromJson(Map<String, dynamic> json) => GuestApp(
        bundleId: jsonString(json, 'bundle_id'),
        folder: jsonString(json, 'folder'),
      );

  /// The app's own identifier.
  final String? bundleId;

  /// The folder it lives in inside LiveContainer.
  final String? folder;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GuestApp && other.bundleId == bundleId && other.folder == folder;

  @override
  int get hashCode => Object.hash(bundleId, folder);

  @override
  String toString() => 'GuestApp(bundleId: $bundleId)';
}

/// The outcome of putting an app inside LiveContainer.
class GuestAppInstall {
  /// Creates a guest-install outcome.
  const GuestAppInstall({
    this.status,
    this.bundleId,
    this.name,
    this.version,
    this.files = 0,
    this.bytes = 0,
  });

  /// Parses a `livecontainer --add` payload.
  factory GuestAppInstall.fromJson(Map<String, dynamic> json) => GuestAppInstall(
        status: jsonString(json, 'status'),
        bundleId: jsonString(json, 'bundle_id'),
        name: jsonString(json, 'name'),
        version: jsonString(json, 'version'),
        files: jsonInt(json, 'files'),
        bytes: jsonInt(json, 'bytes'),
      );

  /// `installed` on success.
  final String? status;

  /// The app's identifier.
  final String? bundleId;

  /// Its display name.
  final String? name;

  /// Its version.
  final String? version;

  /// How many files were copied, and how many bytes.
  final int files;
  final int bytes;

  /// Whether it landed.
  bool get isInstalled => status == 'installed';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GuestAppInstall &&
          other.status == status &&
          other.bundleId == bundleId &&
          other.name == name &&
          other.version == version &&
          other.files == files &&
          other.bytes == bytes;

  @override
  int get hashCode => Object.hash(status, bundleId, name, version, files, bytes);

  @override
  String toString() => 'GuestAppInstall(bundleId: $bundleId, name: $name)';
}

/// Whether LiveContainer is installed, and how far its setup got.
///
/// The certificate itself lives in a shared app group that cannot be read from a
/// PC, so the engine reports what it *can* see in LiveContainer's Documents. A
/// pending import means the injected dylib has not run yet, which it does on the
/// next launch.
class LiveContainerStatus {
  /// Creates a status snapshot.
  const LiveContainerStatus({
    this.installed = false,
    this.bundleId,
    this.name,
    this.version,
    this.certificatePending = false,
    this.certificateFilePresent = false,
    this.launched = false,
    this.hasSidestore = false,
    this.pairingPresent = false,
  });

  /// Parses a `livecontainer` payload.
  factory LiveContainerStatus.fromJson(Map<String, dynamic> json) =>
      LiveContainerStatus(
        installed: jsonBool(json, 'installed'),
        bundleId: jsonString(json, 'bundle_id'),
        name: jsonString(json, 'name'),
        version: jsonString(json, 'version'),
        certificatePending: jsonBool(json, 'certificate_pending'),
        certificateFilePresent: jsonBool(json, 'certificate_file_present'),
        launched: jsonBool(json, 'launched'),
        hasSidestore: jsonBool(json, 'has_sidestore'),
        pairingPresent: jsonBool(json, 'pairing_present'),
      );

  /// Whether LiveContainer is on the device at all.
  final bool installed;

  /// Team-scoped identifier it was installed under.
  final String? bundleId;

  /// Display name, as the device reports it.
  final String? name;

  /// LiveContainer's own version, e.g. `3.8.0`.
  final String? version;

  /// An import is waiting for LiveContainer's next launch.
  final bool certificatePending;

  /// The certificate is on the device for a manual import. Left in place on
  /// purpose, so this says nothing about whether setup finished.
  final bool certificateFilePresent;

  /// Whether LiveContainer has ever been opened; it builds its folders then.
  final bool launched;

  /// Whether this build carries SideStore, so the phone can refresh apps itself.
  ///
  /// Read from the IPA the refresh registry recorded, because the frameworks that would
  /// prove it live in the app bundle, which `house_arrest` does not vend.
  final bool hasSidestore;

  /// Whether the pairing file on-device refresh needs has reached the device.
  final bool pairingPresent;

  /// Installed, opened, and no import still waiting.
  bool get isReady => installed && launched && !certificatePending;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveContainerStatus &&
          other.installed == installed &&
          other.bundleId == bundleId &&
          other.name == name &&
          other.version == version &&
          other.certificatePending == certificatePending &&
          other.certificateFilePresent == certificateFilePresent &&
          other.launched == launched &&
          other.hasSidestore == hasSidestore &&
          other.pairingPresent == pairingPresent;

  @override
  int get hashCode => Object.hash(installed, bundleId, name, version,
      certificatePending, certificateFilePresent, launched, hasSidestore,
      pairingPresent);

  @override
  String toString() => 'LiveContainerStatus(installed: $installed, '
      'version: $version, certificatePending: $certificatePending, '
      'launched: $launched)';
}

/// One installed app that reads a pairing file out of its own Documents folder.
class PairingConsumerInfo {
  /// Creates a consumer row.
  const PairingConsumerInfo({
    this.id,
    this.name,
    this.bundleId,
    this.appName,
    this.filename,
    this.needsRppairing = false,
  });

  /// Parses one `consumers[]` entry from `pairing`.
  factory PairingConsumerInfo.fromJson(Map<String, dynamic> json) =>
      PairingConsumerInfo(
        id: jsonString(json, 'id'),
        name: jsonString(json, 'name'),
        bundleId: jsonString(json, 'bundle_id'),
        appName: jsonString(json, 'app_name'),
        filename: jsonString(json, 'filename'),
        needsRppairing: jsonBool(json, 'needs_rppairing'),
      );

  /// Catalogue id, e.g. `escapeos`.
  final String? id;

  /// Product name iPASide uses, e.g. `EscapeOS`.
  final String? name;

  /// Team-scoped bundle id on the phone.
  final String? bundleId;

  /// Display name the device reports.
  final String? appName;

  /// File name that app looks for in Documents.
  final String? filename;

  /// Whether that app's iOS 26 path needs Remote Pairing keys, not USB lockdown alone.
  final bool needsRppairing;

  /// The name the card should show: the phone's label, then the catalogue name.
  String get label => appName ?? name ?? bundleId ?? 'App';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PairingConsumerInfo &&
          other.id == id &&
          other.name == name &&
          other.bundleId == bundleId &&
          other.appName == appName &&
          other.filename == filename &&
          other.needsRppairing == needsRppairing;

  @override
  int get hashCode =>
      Object.hash(id, name, bundleId, appName, filename, needsRppairing);

  @override
  String toString() =>
      'PairingConsumerInfo($id, $bundleId, needsRppairing: $needsRppairing)';
}

/// What this PC holds for one device's pairing file, and which apps can consume it.
class PairingStatus {
  /// Creates a pairing snapshot.
  const PairingStatus({
    this.udid,
    this.source = 'none',
    this.hasLockdown = false,
    this.hasRppairing = false,
    this.imported = false,
    this.importedPath,
    this.bytes = 0,
    this.note,
    this.error,
    this.consumers = const <PairingConsumerInfo>[],
    this.deviceReachable = false,
    this.deviceError,
  });

  /// Parses a `pairing` status payload.
  factory PairingStatus.fromJson(Map<String, dynamic> json) => PairingStatus(
        udid: jsonString(json, 'udid'),
        source: jsonString(json, 'source') ?? 'none',
        hasLockdown: jsonBool(json, 'has_lockdown'),
        hasRppairing: jsonBool(json, 'has_rppairing'),
        imported: jsonBool(json, 'imported'),
        importedPath: jsonString(json, 'imported_path'),
        bytes: jsonInt(json, 'bytes'),
        note: jsonString(json, 'note'),
        error: jsonString(json, 'error'),
        consumers: jsonObjectList(json, 'consumers', PairingConsumerInfo.fromJson),
        deviceReachable: jsonBool(json, 'device_reachable'),
        deviceError: jsonString(json, 'device_error'),
      );

  /// Device this record is for.
  final String? udid;

  /// `imported`, `lockdown`, or `none`.
  final String source;

  /// Whether USB pairing certificates are present.
  final bool hasLockdown;

  /// Whether Remote Pairing keys EscapeOS needs on iOS 26.4+ are present.
  final bool hasRppairing;

  /// Whether iPASide is storing a created or imported pairing file for this UDID.
  final bool imported;

  /// Path of that imported file on this PC, when [imported] is true.
  final String? importedPath;

  /// Size of the XML payload that would be exported or placed.
  final int bytes;

  /// Honest sentence about whether the file is enough for current iOS.
  final String? note;

  /// Why no payload could be built, when [source] is `none`.
  final String? error;

  /// Supported apps currently installed on the phone.
  final List<PairingConsumerInfo> consumers;

  /// Whether the engine could list apps on the device.
  final bool deviceReachable;

  /// Why the device could not be listed, when [deviceReachable] is false.
  final String? deviceError;

  /// A file exists that export and place can write.
  bool get hasPayload => source == 'imported' || source == 'lockdown';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PairingStatus &&
          other.udid == udid &&
          other.source == source &&
          other.hasLockdown == hasLockdown &&
          other.hasRppairing == hasRppairing &&
          other.imported == imported &&
          other.importedPath == importedPath &&
          other.bytes == bytes &&
          other.note == note &&
          other.error == error &&
          _listEquals(other.consumers, consumers) &&
          other.deviceReachable == deviceReachable &&
          other.deviceError == deviceError;

  @override
  int get hashCode => Object.hash(
        udid,
        source,
        hasLockdown,
        hasRppairing,
        imported,
        importedPath,
        bytes,
        note,
        error,
        Object.hashAll(consumers),
        deviceReachable,
        deviceError,
      );

  @override
  String toString() =>
      'PairingStatus(source: $source, hasRppairing: $hasRppairing, '
      'consumers: ${consumers.length})';
}

/// Outcome of writing the pairing file to disk.
class PairingExport {
  /// Creates an export outcome.
  const PairingExport({
    this.exported = false,
    this.path,
    this.bytes = 0,
    this.hasLockdown = false,
    this.hasRppairing = false,
    this.note,
  });

  /// Parses a `pairing --export` payload.
  factory PairingExport.fromJson(Map<String, dynamic> json) => PairingExport(
        exported: jsonBool(json, 'exported'),
        path: jsonString(json, 'path'),
        bytes: jsonInt(json, 'bytes'),
        hasLockdown: jsonBool(json, 'has_lockdown'),
        hasRppairing: jsonBool(json, 'has_rppairing'),
        note: jsonString(json, 'note'),
      );

  /// Whether the file landed on disk.
  final bool exported;

  /// Absolute path written.
  final String? path;

  /// Size of the XML written.
  final int bytes;

  /// Whether the exported file has USB pairing certificates.
  final bool hasLockdown;

  /// Whether the exported file has Remote Pairing keys.
  final bool hasRppairing;

  /// Honest sentence about iOS 26 completeness.
  final String? note;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PairingExport &&
          other.exported == exported &&
          other.path == path &&
          other.bytes == bytes &&
          other.hasLockdown == hasLockdown &&
          other.hasRppairing == hasRppairing &&
          other.note == note;

  @override
  int get hashCode =>
      Object.hash(exported, path, bytes, hasLockdown, hasRppairing, note);

  @override
  String toString() => 'PairingExport(path: $path, bytes: $bytes)';
}

/// Outcome of storing an imported pairing plist for this device.
class PairingImport {
  /// Creates an import outcome.
  const PairingImport({
    this.imported = false,
    this.path,
    this.from,
    this.hasLockdown = false,
    this.hasRppairing = false,
    this.note,
  });

  /// Parses a `pairing --import` payload.
  factory PairingImport.fromJson(Map<String, dynamic> json) => PairingImport(
        imported: jsonBool(json, 'imported'),
        path: jsonString(json, 'path'),
        from: jsonString(json, 'from'),
        hasLockdown: jsonBool(json, 'has_lockdown'),
        hasRppairing: jsonBool(json, 'has_rppairing'),
        note: jsonString(json, 'note'),
      );

  /// Whether the file was stored.
  final bool imported;

  /// Where iPASide stored it.
  final String? path;

  /// The file the user picked.
  final String? from;

  /// Whether the stored file has USB pairing certificates.
  final bool hasLockdown;

  /// Whether the stored file has Remote Pairing keys.
  final bool hasRppairing;

  /// Honest sentence about iOS 26 completeness.
  final String? note;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PairingImport &&
          other.imported == imported &&
          other.path == path &&
          other.from == from &&
          other.hasLockdown == hasLockdown &&
          other.hasRppairing == hasRppairing &&
          other.note == note;

  @override
  int get hashCode =>
      Object.hash(imported, path, from, hasLockdown, hasRppairing, note);

  @override
  String toString() => 'PairingImport(from: $from, hasRppairing: $hasRppairing)';
}

/// Outcome of creating Remote Pairing keys over USB.
class PairingCreate {
  /// Creates a create-keys outcome.
  const PairingCreate({
    this.created = false,
    this.path,
    this.hasLockdown = false,
    this.hasRppairing = false,
    this.note,
    this.error,
  });

  /// Parses a `pairing --create` payload.
  factory PairingCreate.fromJson(Map<String, dynamic> json) => PairingCreate(
        created: jsonBool(json, 'created'),
        path: jsonString(json, 'path'),
        hasLockdown: jsonBool(json, 'has_lockdown'),
        hasRppairing: jsonBool(json, 'has_rppairing'),
        note: jsonString(json, 'note'),
        error: jsonString(json, 'error'),
      );

  /// Whether pair-setup ran this call, rather than reusing keys already stored.
  final bool created;

  /// Where iPASide stored the merged file.
  final String? path;

  /// Whether USB pairing certificates are present.
  final bool hasLockdown;

  /// Whether Remote Pairing keys are present after this call.
  final bool hasRppairing;

  /// Honest sentence about iOS 26 completeness.
  final String? note;

  /// Why creation failed, when the engine returned an error field.
  final String? error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PairingCreate &&
          other.created == created &&
          other.path == path &&
          other.hasLockdown == hasLockdown &&
          other.hasRppairing == hasRppairing &&
          other.note == note &&
          other.error == error;

  @override
  int get hashCode =>
      Object.hash(created, path, hasLockdown, hasRppairing, note, error);

  @override
  String toString() =>
      'PairingCreate(created: $created, hasRppairing: $hasRppairing)';
}

/// One app the pairing file was written into, or the reason it was not.
class PairingPlacement {
  /// Creates a per-app placement outcome.
  const PairingPlacement({
    this.id,
    this.name,
    this.bundleId,
    this.filename,
    this.placed = false,
    this.bytes = 0,
    this.written = const <String>[],
    this.error,
    this.warning,
  });

  /// Parses one `placed[]` entry from `pairing --deliver`.
  factory PairingPlacement.fromJson(Map<String, dynamic> json) =>
      PairingPlacement(
        id: jsonString(json, 'id'),
        name: jsonString(json, 'name'),
        bundleId: jsonString(json, 'bundle_id'),
        filename: jsonString(json, 'filename'),
        placed: jsonBool(json, 'placed'),
        bytes: jsonInt(json, 'bytes'),
        written: jsonStringList(json, 'written'),
        error: jsonString(json, 'error'),
        warning: jsonString(json, 'warning'),
      );

  /// Catalogue id.
  final String? id;

  /// Product name.
  final String? name;

  /// Bundle id written into.
  final String? bundleId;

  /// File name written.
  final String? filename;

  /// Whether House Arrest accepted the write.
  final bool placed;

  /// Size of the payload written.
  final int bytes;

  /// Container paths written.
  final List<String> written;

  /// Why the write failed, when [placed] is false.
  final String? error;

  /// iOS 26 completeness warning that did not block the write.
  final String? warning;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PairingPlacement &&
          other.id == id &&
          other.name == name &&
          other.bundleId == bundleId &&
          other.filename == filename &&
          other.placed == placed &&
          other.bytes == bytes &&
          _listEquals(other.written, written) &&
          other.error == error &&
          other.warning == warning;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        bundleId,
        filename,
        placed,
        bytes,
        Object.hashAll(written),
        error,
        warning,
      );

  @override
  String toString() =>
      'PairingPlacement($name, placed: $placed, error: $error)';
}

/// Outcome of writing the pairing file into every supported app on the phone.
class PairingDelivery {
  /// Creates a delivery outcome.
  const PairingDelivery({
    this.udid,
    this.hasLockdown = false,
    this.hasRppairing = false,
    this.note,
    this.bytes = 0,
    this.placed = const <PairingPlacement>[],
    this.supportedInstalled = 0,
  });

  /// Parses a `pairing --deliver` payload.
  factory PairingDelivery.fromJson(Map<String, dynamic> json) => PairingDelivery(
        udid: jsonString(json, 'udid'),
        hasLockdown: jsonBool(json, 'has_lockdown'),
        hasRppairing: jsonBool(json, 'has_rppairing'),
        note: jsonString(json, 'note'),
        bytes: jsonInt(json, 'bytes'),
        placed: jsonObjectList(json, 'placed', PairingPlacement.fromJson),
        supportedInstalled: jsonInt(json, 'supported_installed'),
      );

  /// Device the file was placed on.
  final String? udid;

  /// Whether the payload had USB pairing certificates.
  final bool hasLockdown;

  /// Whether the payload had Remote Pairing keys.
  final bool hasRppairing;

  /// Honest sentence about iOS 26 completeness.
  final String? note;

  /// Size of the payload written.
  final int bytes;

  /// Per-app outcomes, in bundle-id order.
  final List<PairingPlacement> placed;

  /// How many supported apps were installed, including failed writes.
  final int supportedInstalled;

  /// Every targeted app accepted the file.
  bool get allPlaced =>
      placed.isNotEmpty && placed.every((PairingPlacement item) => item.placed);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PairingDelivery &&
          other.udid == udid &&
          other.hasLockdown == hasLockdown &&
          other.hasRppairing == hasRppairing &&
          other.note == note &&
          other.bytes == bytes &&
          _listEquals(other.placed, placed) &&
          other.supportedInstalled == supportedInstalled;

  @override
  int get hashCode => Object.hash(
        udid,
        hasLockdown,
        hasRppairing,
        note,
        bytes,
        Object.hashAll(placed),
        supportedInstalled,
      );

  @override
  String toString() =>
      'PairingDelivery(placed: ${placed.length}, hasRppairing: $hasRppairing)';
}

/// How the signing certificate was delivered at the end of a setup.
class LiveContainerCertificate {
  /// Creates a delivery outcome.
  const LiveContainerCertificate({
    this.seeded = false,
    this.automatic = false,
    this.password,
    this.instructions,
    this.error,
  });

  /// Parses the `certificate` object of a setup payload.
  factory LiveContainerCertificate.fromJson(Map<String, dynamic> json) =>
      LiveContainerCertificate(
        seeded: jsonBool(json, 'seeded'),
        automatic: jsonBool(json, 'automatic'),
        password: jsonString(json, 'password'),
        instructions: jsonString(json, 'instructions'),
        error: jsonString(json, 'error'),
      );

  /// Whether the certificate reached the device.
  final bool seeded;

  /// Whether LiveContainer will import it itself on next launch. False means the
  /// user has to do it through LiveContainer's own Settings.
  final bool automatic;

  /// Password for a manual import.
  final String? password;

  /// What to tell the user when the import is not automatic.
  final String? instructions;

  /// Why delivery failed, when it did.
  final String? error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveContainerCertificate &&
          other.seeded == seeded &&
          other.automatic == automatic &&
          other.password == password &&
          other.instructions == instructions &&
          other.error == error;

  @override
  int get hashCode =>
      Object.hash(seeded, automatic, password, instructions, error);

  @override
  String toString() => 'LiveContainerCertificate(seeded: $seeded, '
      'automatic: $automatic, error: $error)';
}

/// The outcome of a LiveContainer setup.
class LiveContainerSetupResult {
  /// Creates a setup outcome.
  const LiveContainerSetupResult({
    this.status,
    this.bundleId,
    this.version,
    this.certificate = const LiveContainerCertificate(),
    this.launchRequired = false,
  });

  /// Parses a `livecontainer --setup` payload.
  factory LiveContainerSetupResult.fromJson(Map<String, dynamic> json) =>
      LiveContainerSetupResult(
        status: jsonString(json, 'status'),
        bundleId: jsonString(json, 'bundle_id'),
        version: jsonString(json, 'livecontainer_version'),
        certificate: LiveContainerCertificate.fromJson(
          jsonObject(json, 'certificate'),
        ),
        launchRequired: jsonBool(json, 'launch_required'),
      );

  /// `installed` on success.
  final String? status;

  /// Identifier LiveContainer was installed under.
  final String? bundleId;

  /// LiveContainer's version, read from the IPA that was signed.
  final String? version;

  /// How the certificate was delivered.
  final LiveContainerCertificate certificate;

  /// Whether the user still has to open LiveContainer once to finish the import.
  final bool launchRequired;

  /// Whether the install itself succeeded, regardless of the certificate.
  bool get isInstalled => status == 'installed';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveContainerSetupResult &&
          other.status == status &&
          other.bundleId == bundleId &&
          other.version == version &&
          other.certificate == certificate &&
          other.launchRequired == launchRequired;

  @override
  int get hashCode =>
      Object.hash(status, bundleId, version, certificate, launchRequired);

  @override
  String toString() => 'LiveContainerSetupResult(status: $status, '
      'version: $version, launchRequired: $launchRequired)';
}

/// One file in the signed-IPA directory, from a `signed` listing.
class SignedIpaFile {
  /// Creates a signed-IPA file entry.
  const SignedIpaFile({this.name, this.bytes = 0, this.modified});

  /// Parses one element of the `files` array.
  factory SignedIpaFile.fromJson(Map<String, dynamic> json) => SignedIpaFile(
        name: jsonString(json, 'name'),
        bytes: jsonInt(json, 'bytes'),
        modified: jsonDateTime(json, 'modified'),
      );

  /// File name inside the directory, not a full path.
  final String? name;

  /// Size on disk; 0 when the engine did not report one.
  final int bytes;

  /// When it was written, parsed from the engine's ISO 8601 string; null when
  /// that string was missing or unreadable.
  final DateTime? modified;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SignedIpaFile &&
          other.name == name &&
          other.bytes == bytes &&
          other.modified == modified;

  @override
  int get hashCode => Object.hash(name, bytes, modified);

  @override
  String toString() => 'SignedIpaFile(name: $name, bytes: $bytes, '
      'modified: $modified)';
}

/// Result of `signed`: what is sitting in the signed-IPA directory right now.
///
/// [count] and [bytes] are the engine's own totals rather than something derived
/// from [files], so a listing that had to skip an unreadable entry still reports
/// the truth about the folder.
class SignedIpaListing {
  /// Creates a signed-IPA listing.
  const SignedIpaListing({
    this.directory,
    this.count = 0,
    this.bytes = 0,
    this.files = const <SignedIpaFile>[],
  });

  /// Parses a `signed` payload.
  factory SignedIpaListing.fromJson(Map<String, dynamic> json) =>
      SignedIpaListing(
        directory: jsonString(json, 'directory'),
        count: jsonInt(json, 'count'),
        bytes: jsonInt(json, 'bytes'),
        files: jsonObjectList(json, 'files', SignedIpaFile.fromJson),
      );

  /// The directory that was listed — the engine's default unless one was asked
  /// for.
  final String? directory;

  /// How many signed `.ipa`s are stored.
  final int count;

  /// What they occupy in total.
  final int bytes;

  /// One entry per file. Read-only.
  final List<SignedIpaFile> files;

  /// Whether the directory holds nothing worth offering to delete.
  bool get isEmpty => count == 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SignedIpaListing &&
          other.directory == directory &&
          other.count == count &&
          other.bytes == bytes &&
          _listEquals(other.files, files);

  @override
  int get hashCode =>
      Object.hash(directory, count, bytes, Object.hashAll(files));

  @override
  String toString() => 'SignedIpaListing(directory: $directory, '
      'count: $count, bytes: $bytes, files: ${files.length})';
}

/// Result of `signed --clean`.
class SignedIpaCleanup {
  /// Creates a cleanup outcome.
  const SignedIpaCleanup({this.directory, this.removed = 0, this.bytesFreed = 0});

  /// Parses a `signed --clean` payload.
  factory SignedIpaCleanup.fromJson(Map<String, dynamic> json) =>
      SignedIpaCleanup(
        directory: jsonString(json, 'directory'),
        removed: jsonInt(json, 'removed'),
        bytesFreed: jsonInt(json, 'bytes_freed'),
      );

  /// The directory that was emptied.
  final String? directory;

  /// How many files were deleted.
  final int removed;

  /// How much space that reclaimed.
  final int bytesFreed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SignedIpaCleanup &&
          other.directory == directory &&
          other.removed == removed &&
          other.bytesFreed == bytesFreed;

  @override
  int get hashCode => Object.hash(directory, removed, bytesFreed);

  @override
  String toString() => 'SignedIpaCleanup(directory: $directory, '
      'removed: $removed, bytesFreed: $bytesFreed)';
}

/// One injectable dylib resolved from a `.deb` or `.dylib` by `resolve-tweak`.
class TweakDylib {
  /// Creates a resolved dylib.
  const TweakDylib({
    this.path,
    this.name,
    this.arches = const <String>[],
    this.fromDeb,
  });

  /// Parses one element of the `dylibs` array.
  factory TweakDylib.fromJson(Map<String, dynamic> json) => TweakDylib(
        path: jsonString(json, 'path'),
        name: jsonString(json, 'name'),
        arches: jsonStringList(json, 'arches'),
        fromDeb: jsonString(json, 'from_deb'),
      );

  /// Absolute path of the extracted dylib; the de-duplication key.
  final String? path;

  /// File name shown in the tweak list.
  final String? name;

  /// Mach-O architectures the dylib provides. Read-only.
  final List<String> arches;

  /// The `.deb` this dylib was extracted from, when it came from one.
  final String? fromDeb;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TweakDylib &&
          other.path == path &&
          other.name == name &&
          _listEquals(other.arches, arches) &&
          other.fromDeb == fromDeb;

  @override
  int get hashCode => Object.hash(path, name, Object.hashAll(arches), fromDeb);

  @override
  String toString() => 'TweakDylib(path: $path, name: $name, '
      'arches: $arches, fromDeb: $fromDeb)';
}

/// One row of a [DoctorReport].
class DoctorCheck {
  /// Creates a diagnostic row.
  const DoctorCheck({this.status, this.name, this.detail});

  /// Parses one element of the `checks` array.
  factory DoctorCheck.fromJson(Map<String, dynamic> json) => DoctorCheck(
        status: jsonString(json, 'status'),
        name: jsonString(json, 'name'),
        detail: jsonString(json, 'detail'),
      );

  /// `ok`, `warn` or `fail`.
  final String? status;

  /// What was checked.
  final String? name;

  /// Human-readable outcome, including remediation hints.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DoctorCheck &&
          other.status == status &&
          other.name == name &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(status, name, detail);

  @override
  String toString() =>
      'DoctorCheck(status: $status, name: $name, detail: $detail)';
}

/// Result of `doctor`.
class DoctorReport {
  /// Creates a diagnostic report.
  const DoctorReport({this.overall, this.checks = const <DoctorCheck>[]});

  /// Parses a `doctor` payload.
  factory DoctorReport.fromJson(Map<String, dynamic> json) => DoctorReport(
        overall: jsonString(json, 'overall'),
        checks: jsonObjectList(json, 'checks', DoctorCheck.fromJson),
      );

  /// `ok`, `warn` or `fail`; the worst status across [checks].
  final String? overall;

  /// One row per environment check. Read-only.
  final List<DoctorCheck> checks;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DoctorReport &&
          other.overall == overall &&
          _listEquals(other.checks, checks);

  @override
  int get hashCode => Object.hash(overall, Object.hashAll(checks));

  @override
  String toString() => 'DoctorReport(overall: $overall, checks: $checks)';
}

/// Result of `anisette`.
class AnisetteStatus {
  /// Creates an anisette status.
  const AnisetteStatus({
    this.packageVersion,
    this.stateCached = false,
    this.provider,
    this.servers = const <String>[],
  });

  /// Parses an `anisette` payload.
  factory AnisetteStatus.fromJson(Map<String, dynamic> json) {
    final Object? rawServers = json['servers'];
    return AnisetteStatus(
      packageVersion: jsonString(json, 'package_version'),
      stateCached: jsonBool(json, 'state_cached'),
      provider: jsonString(json, 'provider'),
      servers: rawServers is List
          ? rawServers.whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }

  /// `remote` (a Mac anisette service) or `local` (the emulator). Null from an older engine,
  /// which only had the local provider.
  final String? provider;

  /// The anisette services tried in order when [provider] is `remote`.
  final List<String> servers;

  /// Version of the `anisette` Python package in use.
  final String? packageVersion;

  /// Whether provisioned anisette state is already cached on disk.
  final bool stateCached;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnisetteStatus &&
          other.packageVersion == packageVersion &&
          other.stateCached == stateCached &&
          other.provider == provider &&
          _sameStrings(other.servers, servers);

  static bool _sameStrings(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(packageVersion, stateCached, provider, Object.hashAll(servers));

  @override
  String toString() => 'AnisetteStatus(packageVersion: $packageVersion, '
      'stateCached: $stateCached, provider: $provider, servers: $servers)';
}

/// Result of `apple-support`: the state of Apple's device stack on this machine.
///
/// [state] is a vocabulary rather than a flag because the remedy differs for each
/// value — nothing, an elevated service start, or a ~200 MB install — and a screen
/// that cannot tell "stopped" from "never installed" offers the wrong button. A
/// value this build does not know is treated as "no opinion": [isRunning] is false
/// and so is [blocksDevices], so a newer engine can add one without a screen
/// blocking work over a word it cannot read.
class AppleSupportStatus {
  /// Creates an Apple-support status.
  const AppleSupportStatus({
    this.state,
    this.serviceName,
    this.serviceState,
    this.itunesInstalled = false,
    this.itunesVersion,
    this.detail,
  });

  /// Parses an `apple-support` payload.
  factory AppleSupportStatus.fromJson(Map<String, dynamic> json) =>
      AppleSupportStatus(
        state: jsonString(json, 'state'),
        serviceName: jsonString(json, 'service_name'),
        serviceState: jsonString(json, 'service_state'),
        itunesInstalled: jsonBool(json, 'itunes_installed'),
        itunesVersion: jsonString(json, 'itunes_version'),
        detail: jsonString(json, 'detail'),
      );

  /// The service is up and device I/O works.
  static const String running = 'running';

  /// The service is installed but not running; starting it needs elevation.
  static const String stopped = 'stopped';

  /// The service is not installed; iTunes has to be.
  static const String missing = 'missing';

  /// Not a Windows host, so there is no such service to have.
  static const String unsupported = 'unsupported';

  /// [running], [stopped], [missing] or [unsupported].
  final String? state;

  /// The Windows service that was looked for.
  final String? serviceName;

  /// Its raw Windows state (`RUNNING`, `STOPPED`, …); null when it is absent.
  final String? serviceState;

  /// Whether iTunes itself looks installed, which decides whether the fix is an
  /// install or a repair.
  final bool itunesInstalled;

  /// iTunes' registered version, when it is installed.
  final String? itunesVersion;

  /// One sentence, written by the engine to be shown verbatim.
  final String? detail;

  bool get isRunning => state == running;

  bool get isStopped => state == stopped;

  bool get isMissing => state == missing;

  bool get isUnsupported => state == unsupported;

  /// Whether this machine cannot reach an iPhone at all.
  ///
  /// True for both bad states, because usbmux brokers Wi-Fi as well as USB: with
  /// the service down there is no transport, not merely no cable.
  bool get blocksDevices => isStopped || isMissing;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppleSupportStatus &&
          other.state == state &&
          other.serviceName == serviceName &&
          other.serviceState == serviceState &&
          other.itunesInstalled == itunesInstalled &&
          other.itunesVersion == itunesVersion &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(
        state,
        serviceName,
        serviceState,
        itunesInstalled,
        itunesVersion,
        detail,
      );

  @override
  String toString() => 'AppleSupportStatus(state: $state, '
      'serviceState: $serviceState, itunesInstalled: $itunesInstalled, '
      'itunesVersion: $itunesVersion, detail: $detail)';
}

/// Result of `apple-support --download`: a verified installer waiting on disk.
///
/// The engine only reports one after Windows confirmed Apple signed it, so a
/// non-null [path] is the app's licence to run the file.
class ItunesDownload {
  /// Creates a download outcome.
  const ItunesDownload({
    this.path,
    this.bytes = 0,
    this.signer,
    this.signatureStatus,
  });

  /// Parses an `apple-support --download` payload.
  factory ItunesDownload.fromJson(Map<String, dynamic> json) => ItunesDownload(
        path: jsonString(json, 'path'),
        bytes: jsonInt(json, 'bytes'),
        signer: jsonString(json, 'signer'),
        signatureStatus: jsonString(json, 'signature_status'),
      );

  /// Where the verified installer is; null only from an unusable payload.
  final String? path;

  /// Its size on disk.
  final int bytes;

  /// The Authenticode subject Windows named, e.g. `CN=Apple Inc., O=Apple Inc., …`.
  final String? signer;

  /// Windows' verdict on the signature, which is always `Valid` here — anything
  /// else made the engine delete the file and raise instead.
  final String? signatureStatus;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ItunesDownload &&
          other.path == path &&
          other.bytes == bytes &&
          other.signer == signer &&
          other.signatureStatus == signatureStatus;

  @override
  int get hashCode => Object.hash(path, bytes, signer, signatureStatus);

  @override
  String toString() => 'ItunesDownload(path: $path, bytes: $bytes, '
      'signer: $signer, signatureStatus: $signatureStatus)';
}

/// Result of `apple-support --start-service`.
///
/// Declining the elevation prompt is a normal outcome, not a failure: [started]
/// is false, [wasDeclined] is true, and nothing was changed.
class AppleServiceStart {
  /// Creates a service-start outcome.
  const AppleServiceStart({
    this.started = false,
    this.reason,
    this.detail,
    this.status,
  });

  /// Parses an `apple-support --start-service` payload.
  factory AppleServiceStart.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? status = asJsonObject(json['status']);
    return AppleServiceStart(
      started: jsonBool(json, 'started'),
      reason: jsonString(json, 'reason'),
      detail: jsonString(json, 'detail'),
      status: status == null ? null : AppleSupportStatus.fromJson(status),
    );
  }

  /// The user declined the elevation prompt.
  static const String elevationDeclined = 'elevation_declined';

  /// Whether the service is running now.
  final bool started;

  /// `already_running`, `started`, `elevation_declined`, `did_not_start`, `failed`.
  final String? reason;

  /// One sentence describing the outcome, written to be shown verbatim.
  final String? detail;

  /// The status the engine re-read afterwards, so a caller never has to guess
  /// whether what it is showing survived the attempt.
  final AppleSupportStatus? status;

  bool get wasDeclined => reason == elevationDeclined;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppleServiceStart &&
          other.started == started &&
          other.reason == reason &&
          other.detail == detail &&
          other.status == status;

  @override
  int get hashCode => Object.hash(started, reason, detail, status);

  @override
  String toString() => 'AppleServiceStart(started: $started, reason: $reason, '
      'detail: $detail, status: $status)';
}

/// Result of `version`.
class EngineVersion {
  /// Creates an engine version.
  const EngineVersion({this.version});

  /// Parses a `version` payload.
  factory EngineVersion.fromJson(Map<String, dynamic> json) =>
      EngineVersion(version: jsonString(json, 'version'));

  /// The engine package version.
  final String? version;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is EngineVersion && other.version == version;

  @override
  int get hashCode => version.hashCode;

  @override
  String toString() => 'EngineVersion(version: $version)';
}

/// User-chosen sideload options.
///
/// Defaults mirror the web UI: extensions and device restrictions are removed,
/// file sharing is off, weak references are off. The signed-IPA pair defaults to
/// the engine's own behaviour, which is to delete the signed file it just
/// installed.
class SideloadOptions {
  /// Creates an option set, defaulting to the free-account-friendly choices.
  const SideloadOptions({
    this.udid,
    this.connection,
    this.bundleId,
    this.name,
    this.removeExtensions = true,
    this.removeDeviceRestrictions = true,
    this.enableFileSharing = false,
    this.weakDylibs = false,
    this.keepSigned = false,
    this.signedDirectory,
    this.dylibs = const <String>[],
  });

  /// The device to install to. Null leaves the choice to the engine, which
  /// refuses to guess when more than one device is connected.
  final String? udid;

  /// Transport to reach it by: `usb`, `wifi`, or null/`auto` to prefer USB and
  /// fall back. A forced transport is honoured rather than retried on the other.
  final String? connection;

  /// Override bundle identifier; blank or whitespace means automatic.
  final String? bundleId;

  /// Override display name; blank or whitespace keeps the app's own.
  final String? name;

  /// Remove app extensions and any watch app (a free-account requirement).
  final bool removeExtensions;

  /// Remove `UISupportedDevices` restrictions.
  final bool removeDeviceRestrictions;

  /// Enable Files app / iTunes file sharing.
  final bool enableFileSharing;

  /// Inject dylibs as `LC_LOAD_WEAK_DYLIB`; only meaningful with [dylibs].
  final bool weakDylibs;

  /// Keep the signed `.ipa` after installing instead of deleting it.
  final bool keepSigned;

  /// Where a kept `.ipa` is written; null (or blank) uses the engine's own
  /// default directory. Only meaningful with [keepSigned].
  final String? signedDirectory;

  /// Resolved dylib paths to inject. Read-only.
  final List<String> dylibs;

  /// Returns a copy with the given fields replaced.
  ///
  /// Passing null for [udid], [bundleId], [name] or [signedDirectory] keeps the
  /// current value; pass an empty string to clear one (blank and null behave
  /// identically in argv).
  SideloadOptions copyWith({
    String? udid,
    String? connection,
    String? bundleId,
    String? name,
    bool? removeExtensions,
    bool? removeDeviceRestrictions,
    bool? enableFileSharing,
    bool? weakDylibs,
    bool? keepSigned,
    String? signedDirectory,
    List<String>? dylibs,
  }) =>
      SideloadOptions(
        udid: udid ?? this.udid,
        connection: connection ?? this.connection,
        bundleId: bundleId ?? this.bundleId,
        name: name ?? this.name,
        removeExtensions: removeExtensions ?? this.removeExtensions,
        removeDeviceRestrictions:
            removeDeviceRestrictions ?? this.removeDeviceRestrictions,
        enableFileSharing: enableFileSharing ?? this.enableFileSharing,
        weakDylibs: weakDylibs ?? this.weakDylibs,
        keepSigned: keepSigned ?? this.keepSigned,
        signedDirectory: signedDirectory ?? this.signedDirectory,
        dylibs: dylibs ?? this.dylibs,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SideloadOptions &&
          other.udid == udid &&
          other.connection == connection &&
          other.bundleId == bundleId &&
          other.name == name &&
          other.removeExtensions == removeExtensions &&
          other.removeDeviceRestrictions == removeDeviceRestrictions &&
          other.enableFileSharing == enableFileSharing &&
          other.weakDylibs == weakDylibs &&
          other.keepSigned == keepSigned &&
          other.signedDirectory == signedDirectory &&
          _listEquals(other.dylibs, dylibs);

  @override
  int get hashCode => Object.hash(
        udid,
        connection,
        bundleId,
        name,
        removeExtensions,
        removeDeviceRestrictions,
        enableFileSharing,
        weakDylibs,
        keepSigned,
        signedDirectory,
        Object.hashAll(dylibs),
      );

  @override
  String toString() => 'SideloadOptions(udid: $udid, '
      'connection: $connection, '
      'bundleId: $bundleId, name: $name, '
      'removeExtensions: $removeExtensions, '
      'removeDeviceRestrictions: $removeDeviceRestrictions, '
      'enableFileSharing: $enableFileSharing, weakDylibs: $weakDylibs, '
      'keepSigned: $keepSigned, signedDirectory: $signedDirectory, '
      'dylibs: $dylibs)';
}

/// A parsed sideload progress event.
///
/// [percent] is null for the indeterminate provision/sign phases and a
/// monotonic 0-100 value during install (the engine computes it, including the
/// pinned final 100).
class SideloadProgress {
  /// Creates a progress event.
  const SideloadProgress({this.phase, this.percent, this.step, this.bundleId});

  /// `provision`, `sign`, `install`, ...
  final String? phase;

  /// 0-100 during install; null while indeterminate.
  final double? percent;

  /// The user-facing step label, e.g. `Contacting Apple...`.
  final String? step;

  /// The app being sideloaded, once known.
  final String? bundleId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SideloadProgress &&
          other.phase == phase &&
          other.percent == percent &&
          other.step == step &&
          other.bundleId == bundleId;

  @override
  int get hashCode => Object.hash(phase, percent, step, bundleId);

  @override
  String toString() => 'SideloadProgress(phase: $phase, percent: $percent, '
      'step: $step, bundleId: $bundleId)';
}

/// The one jailbreak iPASide offers to install: Dopamine.
///
/// Descriptive metadata the engine's catalog carries, so the UI names the tool, its
/// author and its project page without hardcoding them on the Dart side.
class JailbreakTool {
  /// Creates a tool descriptor.
  const JailbreakTool({
    this.id,
    this.name,
    this.kind,
    this.developer,
    this.projectUrl,
    this.knownVersion,
  });

  /// Parses a `tool` object from a `jailbreak` advise payload.
  factory JailbreakTool.fromJson(Map<String, dynamic> json) => JailbreakTool(
        id: jsonString(json, 'id'),
        name: jsonString(json, 'name'),
        kind: jsonString(json, 'kind'),
        developer: jsonString(json, 'developer'),
        projectUrl: jsonString(json, 'project_url'),
        knownVersion: jsonString(json, 'known_version'),
      );

  /// Stable identifier, e.g. `dopamine`.
  final String? id;

  /// Display name, e.g. `Dopamine`.
  final String? name;

  /// One-line kind, e.g. `Semi-untethered · rootless`.
  final String? kind;

  /// Who makes it, e.g. `opa334 (Lars Fröder)`.
  final String? developer;

  /// The project's home page.
  final String? projectUrl;

  /// The newest version the catalog knows of, for display only.
  final String? knownVersion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is JailbreakTool &&
          other.id == id &&
          other.name == name &&
          other.kind == kind &&
          other.developer == developer &&
          other.projectUrl == projectUrl &&
          other.knownVersion == knownVersion;

  @override
  int get hashCode =>
      Object.hash(id, name, kind, developer, projectUrl, knownVersion);

  @override
  String toString() => 'JailbreakTool(id: $id, name: $name)';
}

/// Whether a jailbreak fits the connected device, and why.
///
/// The engine resolves the device's chip from its `ProductType` and compares the
/// running iOS against the tool's support matrix; this is the parsed answer.
class JailbreakAdvice {
  /// Creates an advice snapshot.
  const JailbreakAdvice({
    required this.tool,
    this.productType,
    this.deviceName,
    this.chip,
    this.iosVersion,
    this.maxSupported,
    this.outcome,
    this.summary,
    this.canInstall = false,
  });

  /// Parses a `jailbreak` (advise) payload.
  factory JailbreakAdvice.fromJson(Map<String, dynamic> json) => JailbreakAdvice(
        tool: JailbreakTool.fromJson(jsonObject(json, 'tool')),
        productType: jsonString(json, 'product_type'),
        deviceName: jsonString(json, 'device_name'),
        chip: jsonString(json, 'chip'),
        iosVersion: jsonString(json, 'ios_version'),
        maxSupported: jsonString(json, 'max_supported'),
        outcome: jsonString(json, 'outcome'),
        summary: jsonString(json, 'summary'),
        canInstall: jsonBool(json, 'can_install'),
      );

  /// The tool this advice is about.
  final JailbreakTool tool;

  /// The device's model identifier, e.g. `iPhone12,1`.
  final String? productType;

  /// A marketing name when known, e.g. `iPhone 11`.
  final String? deviceName;

  /// The resolved chip family, e.g. `A13`.
  final String? chip;

  /// The device's running iOS version.
  final String? iosVersion;

  /// The newest iOS this chip is supported on, when applicable.
  final String? maxSupported;

  /// One of the engine's outcome constants: `supported`, `unsupported_version`,
  /// `no_jailbreak`, `older_unverified`, `unknown_device`.
  final String? outcome;

  /// One human-readable line describing the outcome.
  final String? summary;

  /// True only when the device can be installed to right now.
  final bool canInstall;

  /// Whether the device is fully supported.
  bool get isSupported => outcome == 'supported';

  /// Whether the chip has no public jailbreak at all (iPhone 16/17 families).
  bool get hasNoJailbreak => outcome == 'no_jailbreak';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is JailbreakAdvice &&
          other.tool == tool &&
          other.productType == productType &&
          other.deviceName == deviceName &&
          other.chip == chip &&
          other.iosVersion == iosVersion &&
          other.maxSupported == maxSupported &&
          other.outcome == outcome &&
          other.summary == summary &&
          other.canInstall == canInstall;

  @override
  int get hashCode => Object.hash(tool, productType, deviceName, chip,
      iosVersion, maxSupported, outcome, summary, canInstall);

  @override
  String toString() =>
      'JailbreakAdvice(outcome: $outcome, chip: $chip, canInstall: $canInstall)';
}

/// The outcome of installing a jailbreak (an ordinary sideload underneath).
class JailbreakInstallResult {
  /// Creates an install outcome.
  const JailbreakInstallResult({this.status, this.name, this.bundleId, this.version});

  /// Parses a `jailbreak --install` payload.
  factory JailbreakInstallResult.fromJson(Map<String, dynamic> json) =>
      JailbreakInstallResult(
        status: jsonString(json, 'status'),
        name: jsonString(json, 'name'),
        bundleId: jsonString(json, 'bundle_id'),
        version: jsonString(json, 'dopamine_version'),
      );

  /// `installed` on success.
  final String? status;

  /// Display name the tool was installed under.
  final String? name;

  /// Bundle identifier it was installed under.
  final String? bundleId;

  /// The Dopamine version that was installed, when it was downloaded.
  final String? version;

  /// Whether the install landed on the device.
  bool get isInstalled => status == 'installed';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is JailbreakInstallResult &&
          other.status == status &&
          other.name == name &&
          other.bundleId == bundleId &&
          other.version == version;

  @override
  int get hashCode => Object.hash(status, name, bundleId, version);

  @override
  String toString() =>
      'JailbreakInstallResult(status: $status, bundleId: $bundleId)';
}

// Base64 icons are hundreds of kilobytes; never let one into a log line.
String _describeIcon(String? icon) =>
    icon == null ? 'null' : '${icon.length} chars';

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
