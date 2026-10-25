import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/models.dart';

Map<String, dynamic> _decode(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

void main() {
  group('model parsing', () {
    test('DeviceInfo reads the PascalCase lockdown keys', () {
      final DeviceInfo info = DeviceInfo.fromJson(_decode(
        '{"DeviceName":"iPhone","ProductType":"iPhone10,2",'
        '"ProductVersion":"16.7.15","BuildVersion":"20H380",'
        '"UniqueDeviceID":"935cbbb9"}',
      ));

      expect(info.deviceName, 'iPhone');
      expect(info.productType, 'iPhone10,2');
      expect(info.productVersion, '16.7.15');
      expect(info.buildVersion, '20H380');
      expect(info.uniqueDeviceId, '935cbbb9');
    });

    test('DeviceInfo does not fuzzy-match casing', () {
      expect(DeviceInfo.fromJson(_decode('{"device_name":"iPhone"}')).deviceName,
          isNull);
    });

    test('IpaInspection defaults its lists and flag', () {
      final IpaInspection inspection =
          IpaInspection.fromJson(_decode('{"bundle_id":"com.a"}'));

      expect(inspection.bundleId, 'com.a');
      expect(inspection.frameworks, isEmpty);
      expect(inspection.extensions, isEmpty);
      expect(inspection.hasScInfo, isFalse);
    });

    test('IpaInspection tolerates wrongly-typed fields', () {
      final IpaInspection inspection = IpaInspection.fromJson(_decode(
        '{"bundle_id":42,"frameworks":"nope","has_sc_info":"true"}',
      ));

      expect(inspection.bundleId, isNull);
      expect(inspection.frameworks, isEmpty);
      expect(inspection.hasScInfo, isFalse);
    });

    test('InstallRecord widens an integer day count', () {
      final InstallRecord record = InstallRecord.fromJson(
        _decode('{"bundle_id":"com.a","days_left":7,"expired":false}'),
      );

      expect(record.daysLeft, 7.0);
      expect(record.expired, isFalse);
      expect(record.options, isNull);
    });

    test('InstallRecord parses nested options', () {
      final InstallRecord record = InstallRecord.fromJson(
        _decode('{"options":{"dylibs":["/a.dylib","/b.dylib"]}}'),
      );

      expect(record.options?.dylibs, <String>['/a.dylib', '/b.dylib']);
    });

    test('InstallRecord ignores a non-object options field', () {
      expect(
        InstallRecord.fromJson(_decode('{"options":"none"}')).options,
        isNull,
      );
    });

    test('RefreshSummary parses per-app entries and defaults to empty', () {
      expect(RefreshSummary.fromJson(_decode('{}')).refreshed, isEmpty);

      final RefreshSummary summary = RefreshSummary.fromJson(_decode(
        '{"refreshed":[{"bundle_id":"com.a","status":"error","error":"boom"}]}',
      ));

      expect(summary.refreshed.single.bundleId, 'com.a');
      expect(summary.refreshed.single.status, 'error');
      expect(summary.refreshed.single.error, 'boom');
    });

    test('DoctorReport parses its checks', () {
      final DoctorReport report = DoctorReport.fromJson(_decode(
        '{"overall":"warn","checks":[{"status":"warn","name":"n","detail":"d"}]}',
      ));

      expect(report.overall, 'warn');
      expect(
        report.checks.single,
        const DoctorCheck(status: 'warn', name: 'n', detail: 'd'),
      );
    });

    test('TweakDylib parses arches and its source deb', () {
      final TweakDylib dylib = TweakDylib.fromJson(_decode(
        '{"path":"/a.dylib","name":"a.dylib","arches":["arm64","arm64e"],'
        '"from_deb":"t.deb"}',
      ));

      expect(dylib.path, '/a.dylib');
      expect(dylib.arches, <String>['arm64', 'arm64e']);
      expect(dylib.fromDeb, 't.deb');
    });

    test('LoginResult exposes the two-factor state', () {
      expect(
        LoginResult.fromJson(_decode('{"status":"2fa_required","method":"sms"}'))
            .requiresTwoFactor,
        isTrue,
      );
      expect(
        LoginResult.fromJson(_decode('{"status":"authenticated"}'))
            .requiresTwoFactor,
        isFalse,
      );
    });

    test('LoginResult carries the engine notice when a text could not be sent', () {
      final LoginResult result = LoginResult.fromJson(_decode(
        '{"status":"2fa_required","method":"trusteddevice",'
        '"notice":"Apple would not text a verification code (HTTP 403)."}',
      ));

      expect(result.method, 'trusteddevice');
      expect(result.notice, 'Apple would not text a verification code (HTTP 403).');
      expect(
        LoginResult.fromJson(_decode('{"status":"2fa_required","method":"sms"}'))
            .notice,
        isNull,
      );
      expect(
        result,
        isNot(const LoginResult(status: '2fa_required', method: 'trusteddevice')),
      );
    });

    test('SignedIpaListing maps the totals and the files', () {
      final SignedIpaListing listing = SignedIpaListing.fromJson(_decode(
        '{"directory":"C:\\\\signed","count":2,"bytes":488636416,'
        '"files":[{"name":"a.ipa","bytes":244318208,'
        '"modified":"2026-07-25T12:00:00Z"},{"name":"b.ipa"}]}',
      ));

      expect(listing.directory, r'C:\signed');
      expect(listing.count, 2);
      expect(listing.bytes, 488636416);
      expect(listing.isEmpty, isFalse);
      expect(listing.files, hasLength(2));
      expect(listing.files.first.name, 'a.ipa');
      expect(listing.files.first.bytes, 244318208);
      expect(
        listing.files.first.modified,
        DateTime.utc(2026, 7, 25, 12),
        reason: 'the ISO 8601 string is parsed, not passed through',
      );
      expect(listing.files.last.bytes, 0);
      expect(listing.files.last.modified, isNull);
    });

    test('SignedIpaListing defaults an absent folder to empty', () {
      final SignedIpaListing listing = SignedIpaListing.fromJson(_decode('{}'));

      expect(listing.directory, isNull);
      expect(listing.count, 0);
      expect(listing.bytes, 0);
      expect(listing.files, isEmpty);
      expect(listing.isEmpty, isTrue);
    });

    test('SignedIpaListing tolerates wrongly-typed totals', () {
      final SignedIpaListing listing = SignedIpaListing.fromJson(_decode(
        '{"directory":7,"count":"two","bytes":null,"files":"nope"}',
      ));

      expect(listing.directory, isNull);
      expect(listing.count, 0);
      expect(listing.bytes, 0);
      expect(listing.files, isEmpty);
    });

    test('SignedIpaListing rounds a float byte total', () {
      // A Python division that stayed a float still has to land on a number.
      expect(
        SignedIpaListing.fromJson(_decode('{"bytes":1024.6,"count":1.0}')).bytes,
        1025,
      );
    });

    test('SignedIpaListing keeps the engine totals over the file list', () {
      // A listing that had to skip an unreadable entry still reports the folder.
      final SignedIpaListing listing = SignedIpaListing.fromJson(
        _decode('{"count":3,"bytes":300,"files":[{"name":"a.ipa"}]}'),
      );

      expect(listing.count, 3);
      expect(listing.files, hasLength(1));
    });

    test('SignedIpaCleanup maps what it removed', () {
      final SignedIpaCleanup cleanup = SignedIpaCleanup.fromJson(_decode(
        '{"directory":"C:\\\\signed","removed":3,"bytes_freed":732823552}',
      ));

      expect(cleanup.directory, r'C:\signed');
      expect(cleanup.removed, 3);
      expect(cleanup.bytesFreed, 732823552);
    });

    test('SignedIpaCleanup reads nothing removed as zero, not null', () {
      final SignedIpaCleanup cleanup = SignedIpaCleanup.fromJson(_decode('{}'));

      expect(cleanup.removed, 0);
      expect(cleanup.bytesFreed, 0);
      expect(cleanup.directory, isNull);
    });

    test('SignedIpaCleanup does not fuzzy-match the snake_case key', () {
      expect(
        SignedIpaCleanup.fromJson(_decode('{"bytesFreed":10}')).bytesFreed,
        0,
      );
    });

    test('AnisetteStatus and EngineVersion map their fields', () {
      expect(
        AnisetteStatus.fromJson(
          _decode('{"package_version":"1.2.4","state_cached":true}'),
        ),
        const AnisetteStatus(packageVersion: '1.2.4', stateCached: true),
      );
      expect(
        EngineVersion.fromJson(_decode('{"version":"0.1.0"}')),
        const EngineVersion(version: '0.1.0'),
      );
    });

    test('AnisetteStatus reads the provider and the services in order', () {
      final AnisetteStatus status = AnisetteStatus.fromJson(_decode(
        '{"provider":"remote","state_cached":true,"package_version":"1.2.4",'
        '"servers":["https://mac-ani.jkcoxson.com","https://new.ani.sidestore.io"]}',
      ));
      expect(status.provider, 'remote');
      expect(status.servers, <String>[
        'https://mac-ani.jkcoxson.com',
        'https://new.ani.sidestore.io',
      ]);
      expect(status.stateCached, isTrue);
    });

    test('AnisetteStatus from an older engine has no provider and no services', () {
      final AnisetteStatus status = AnisetteStatus.fromJson(
        _decode('{"package_version":"1.2.4","state_cached":false}'),
      );
      expect(status.provider, isNull);
      expect(status.servers, isEmpty);
    });

    test('AnisetteStatus ignores services that are not strings', () {
      final AnisetteStatus status = AnisetteStatus.fromJson(
        _decode('{"provider":"remote","servers":["https://a.example",7,null]}'),
      );
      expect(status.servers, <String>['https://a.example']);
    });

    test('AnisetteStatus equality includes the provider and the services', () {
      const AnisetteStatus a = AnisetteStatus(provider: 'remote', servers: <String>['x']);
      expect(a, const AnisetteStatus(provider: 'remote', servers: <String>['x']));
      expect(a == const AnisetteStatus(provider: 'local', servers: <String>['x']), isFalse);
      expect(a == const AnisetteStatus(provider: 'remote', servers: <String>['y']), isFalse);
      expect(a.hashCode, const AnisetteStatus(provider: 'remote', servers: <String>['x']).hashCode);
    });

    test('AppleSupportStatus maps its snake_case fields', () {
      final AppleSupportStatus status = AppleSupportStatus.fromJson(_decode(
        '{"state":"missing","service_name":"Apple Mobile Device Service",'
        '"service_state":null,"itunes_installed":true,'
        '"itunes_version":"12.13.10.3","detail":"not present"}',
      ));

      expect(status.state, AppleSupportStatus.missing);
      expect(status.serviceName, 'Apple Mobile Device Service');
      expect(status.serviceState, isNull);
      expect(status.itunesInstalled, isTrue);
      expect(status.itunesVersion, '12.13.10.3');
      expect(status.detail, 'not present');
      expect(status.blocksDevices, isTrue);
    });

    test('an AppleSupportStatus with no state has no opinion', () {
      // A payload this build cannot read must never block a working machine.
      const AppleSupportStatus empty = AppleSupportStatus();

      expect(empty.isRunning, isFalse);
      expect(empty.blocksDevices, isFalse);
      expect(AppleSupportStatus.fromJson(_decode('{}')), empty);
    });

    test('ItunesDownload maps the verified installer', () {
      expect(
        ItunesDownload.fromJson(_decode(
          '{"path":"C:\\\\dl\\\\iTunes64Setup.exe","bytes":208064480,'
          '"signer":"O=Apple Inc.","signature_status":"Valid"}',
        )),
        const ItunesDownload(
          path: r'C:\dl\iTunes64Setup.exe',
          bytes: 208064480,
          signer: 'O=Apple Inc.',
          signatureStatus: 'Valid',
        ),
      );
    });

    test('AppleServiceStart nests the status it read back', () {
      final AppleServiceStart result = AppleServiceStart.fromJson(_decode(
        '{"started":false,"reason":"elevation_declined","detail":"declined",'
        '"status":{"state":"stopped"}}',
      ));

      expect(result.started, isFalse);
      expect(result.wasDeclined, isTrue);
      expect(result.status, const AppleSupportStatus(state: 'stopped'));
    });

    test('AppleServiceStart ignores a non-object status field', () {
      expect(
        AppleServiceStart.fromJson(_decode('{"started":true,"status":"running"}'))
            .status,
        isNull,
      );
    });
  });

  group('value semantics', () {
    test('equal payloads compare equal and hash alike', () {
      final IpaInspection a = IpaInspection.fromJson(
        _decode('{"bundle_id":"com.a","frameworks":["F"]}'),
      );
      final IpaInspection b = IpaInspection.fromJson(
        _decode('{"bundle_id":"com.a","frameworks":["F"]}'),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a differing list element breaks equality', () {
      expect(
        const IpaInspection(frameworks: <String>['A']),
        isNot(const IpaInspection(frameworks: <String>['B'])),
      );
    });

    test('SideloadProgress compares by value', () {
      expect(
        const SideloadProgress(phase: 'install', percent: 10),
        const SideloadProgress(phase: 'install', percent: 10),
      );
      expect(
        const SideloadProgress(phase: 'install', percent: 10),
        isNot(const SideloadProgress(phase: 'install', percent: 11)),
      );
    });

    test('a signed listing compares by value, files included', () {
      const SignedIpaListing listing = SignedIpaListing(
        directory: r'C:\signed',
        count: 1,
        bytes: 10,
        files: <SignedIpaFile>[SignedIpaFile(name: 'a.ipa', bytes: 10)],
      );

      expect(
        listing,
        const SignedIpaListing(
          directory: r'C:\signed',
          count: 1,
          bytes: 10,
          files: <SignedIpaFile>[SignedIpaFile(name: 'a.ipa', bytes: 10)],
        ),
      );
      expect(
        listing.hashCode,
        const SignedIpaListing(
          directory: r'C:\signed',
          count: 1,
          bytes: 10,
          files: <SignedIpaFile>[SignedIpaFile(name: 'a.ipa', bytes: 10)],
        ).hashCode,
      );
      expect(
        listing,
        isNot(
          const SignedIpaListing(
            directory: r'C:\signed',
            count: 1,
            bytes: 10,
            files: <SignedIpaFile>[SignedIpaFile(name: 'b.ipa', bytes: 10)],
          ),
        ),
      );
    });

    test('a cleanup compares by value', () {
      expect(
        const SignedIpaCleanup(removed: 3, bytesFreed: 10),
        const SignedIpaCleanup(removed: 3, bytesFreed: 10),
      );
      expect(
        const SignedIpaCleanup(removed: 3, bytesFreed: 10),
        isNot(const SignedIpaCleanup(removed: 3, bytesFreed: 11)),
      );
    });

    test('a signed listing never inlines every file name in toString', () {
      final String text = const SignedIpaListing(
        count: 2,
        files: <SignedIpaFile>[
          SignedIpaFile(name: 'a.ipa'),
          SignedIpaFile(name: 'b.ipa'),
        ],
      ).toString();

      expect(text, contains('files: 2'));
      expect(text, isNot(contains('a.ipa')));
    });

    test('toString never inlines a base64 icon', () {
      final String text = const InstallRecord(
        bundleId: 'com.a',
        icon: 'AAAABBBBCCCC',
      ).toString();

      expect(text, contains('icon: 12 chars'));
      expect(text, isNot(contains('AAAABBBB')));
    });
  });

  group('SideloadOptions', () {
    test('defaults mirror the web UI', () {
      const SideloadOptions options = SideloadOptions();

      expect(options.removeExtensions, isTrue);
      expect(options.removeDeviceRestrictions, isTrue);
      expect(options.enableFileSharing, isFalse);
      expect(options.weakDylibs, isFalse);
      expect(options.dylibs, isEmpty);
      expect(options.bundleId, isNull);
      expect(options.name, isNull);
    });

    test('the signed IPA defaults to the engine behaviour', () {
      const SideloadOptions options = SideloadOptions();

      expect(options.keepSigned, isFalse);
      expect(options.signedDirectory, isNull);
    });

    test('copyWith replaces only what it is given', () {
      const SideloadOptions options = SideloadOptions(bundleId: 'com.a');
      final SideloadOptions updated = options.copyWith(
        removeExtensions: false,
        dylibs: <String>['/a.dylib'],
      );

      expect(updated.bundleId, 'com.a');
      expect(updated.removeExtensions, isFalse);
      expect(updated.removeDeviceRestrictions, isTrue);
      expect(updated.dylibs, <String>['/a.dylib']);
      expect(updated.keepSigned, isFalse);
      expect(options.dylibs, isEmpty, reason: 'the original is untouched');
    });

    test('copyWith carries the signed IPA pair', () {
      final SideloadOptions updated = const SideloadOptions().copyWith(
        keepSigned: true,
        signedDirectory: r'D:\signed',
      );

      expect(updated.keepSigned, isTrue);
      expect(updated.signedDirectory, r'D:\signed');
      expect(
        updated.copyWith(keepSigned: false).signedDirectory,
        r'D:\signed',
        reason: 'the folder outlives the flag that uses it',
      );
    });

    test('copyWith with no arguments is an equal copy', () {
      const SideloadOptions options = SideloadOptions(
        name: 'Example',
        enableFileSharing: true,
        keepSigned: true,
        signedDirectory: r'D:\signed',
      );

      expect(options.copyWith(), options);
    });

    test('the signed IPA pair takes part in equality', () {
      expect(
        const SideloadOptions(keepSigned: true),
        isNot(const SideloadOptions()),
      );
      expect(
        const SideloadOptions(signedDirectory: r'D:\a'),
        isNot(const SideloadOptions(signedDirectory: r'D:\b')),
      );
      expect(
        const SideloadOptions(keepSigned: true, signedDirectory: r'D:\a'),
        const SideloadOptions(keepSigned: true, signedDirectory: r'D:\a'),
      );
    });
  });

  group('pairing models', () {
    test('PairingStatus reads consumers and remote-pairing flags', () {
      final PairingStatus status = PairingStatus.fromJson(_decode(
        '{"source":"imported","has_lockdown":true,"has_rppairing":true,'
        '"consumers":[{"id":"escapeos","name":"EscapeOS",'
        '"bundle_id":"com.ipaside.escapeos.TEAM","needs_rppairing":true}]}',
      ));

      expect(status.hasPayload, isTrue);
      expect(status.hasRppairing, isTrue);
      expect(status.consumers, hasLength(1));
      expect(status.consumers.single.needsRppairing, isTrue);
      expect(status.consumers.single.label, 'EscapeOS');
    });

    test('PairingStatus degrades a missing payload to none', () {
      final PairingStatus status = PairingStatus.fromJson(_decode('{}'));

      expect(status.source, 'none');
      expect(status.hasPayload, isFalse);
      expect(status.consumers, isEmpty);
    });

    test('PairingDelivery.allPlaced is false when any write failed', () {
      final PairingDelivery delivery = PairingDelivery.fromJson(_decode(
        '{"placed":[{"name":"EscapeOS","placed":true},'
        '{"name":"SideStore","placed":false,"error":"busy"}]}',
      ));

      expect(delivery.allPlaced, isFalse);
      expect(delivery.placed.last.error, 'busy');
    });

    test('PairingCreate reads created and remote-pairing flags', () {
      final PairingCreate created = PairingCreate.fromJson(_decode(
        '{"created":true,"has_lockdown":true,"has_rppairing":true,'
        '"path":"C:\\\\iPASide\\\\pairing\\\\u.plist"}',
      ));

      expect(created.created, isTrue);
      expect(created.hasRppairing, isTrue);
      expect(created.path, contains('pairing'));
    });
  });
}
