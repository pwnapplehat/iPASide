import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/services/update_planner.dart';

String _release({
  String? tag = 'v0.2.0',
  String? htmlUrl = 'https://github.com/pwnapplehat/iPASide/releases/tag/v0.2.0',
  List<Map<String, String>> assets = const <Map<String, String>>[],
}) =>
    jsonEncode(<String, Object?>{
      'tag_name': ?tag,
      'html_url': ?htmlUrl,
      'assets': assets,
    });

Map<String, String> _asset(String name) => <String, String>{
      'name': name,
      'browser_download_url': 'https://example.test/$name',
    };

void main() {
  group('AppVersion ordering', () {
    test('a two-digit patch number is newer, not older (1.2.10 vs 1.2.9)', () {
      // Compared as text, "1.2.10" sorts before "1.2.9" and nobody would be offered the update.
      final AppVersion nine = AppVersion.tryParse('1.2.9')!;
      final AppVersion ten = AppVersion.tryParse('v1.2.10')!;
      expect(ten > nine, isTrue);
      expect(nine < ten, isTrue);
      expect(ten.toString(), '1.2.10');
    });

    test('minor and major compare numerically too', () {
      expect(AppVersion.tryParse('1.10.0')! > AppVersion.tryParse('1.9.9')!, isTrue);
      expect(AppVersion.tryParse('10.0.0')! > AppVersion.tryParse('9.9.9')!, isTrue);
    });
  });

  group('AppVersion.tryParse', () {
    test('accepts plain, v-prefixed, pre-release and build-metadata forms', () {
      expect(AppVersion.tryParse('1.2.3').toString(), '1.2.3');
      expect(AppVersion.tryParse('v1.2.3').toString(), '1.2.3');
      expect(AppVersion.tryParse('V1.2.3').toString(), '1.2.3');
      expect(AppVersion.tryParse('1.2.3-rc1').toString(), '1.2.3');
      expect(AppVersion.tryParse('1.2.3+42').toString(), '1.2.3');
      expect(AppVersion.tryParse('  1.2.3  ').toString(), '1.2.3');
    });

    test('fills a missing patch and rejects anything under two parts', () {
      expect(AppVersion.tryParse('1.2').toString(), '1.2.0');
      expect(AppVersion.tryParse('1'), isNull);
      expect(AppVersion.tryParse('v1'), isNull);
    });

    test('rejects empty and non-numeric input', () {
      expect(AppVersion.tryParse(null), isNull);
      expect(AppVersion.tryParse(''), isNull);
      expect(AppVersion.tryParse('   '), isNull);
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse('1.x.3'), isNull);
    });

    test('orders by major, then minor, then patch', () {
      expect(AppVersion.tryParse('1.0.0')! < AppVersion.tryParse('1.0.1')!, isTrue);
      expect(AppVersion.tryParse('1.10.0')! > AppVersion.tryParse('1.9.9')!, isTrue);
      expect(AppVersion.tryParse('2.0.0')! > AppVersion.tryParse('1.99.99')!, isTrue);
      expect(AppVersion.tryParse('0.1.0')! <= AppVersion.tryParse('0.1.0')!, isTrue);
    });
  });

  group('UpdatePlanner.parseRelease', () {
    test('finds the installer and the checksum list', () {
      final info = UpdatePlanner.parseRelease(
        _release(assets: <Map<String, String>>[
          _asset('iPASide-Setup-0.2.0-x64.exe'),
          _asset('SHA256SUMS.txt'),
        ]),
      );

      expect(info.tag, 'v0.2.0');
      expect(
        info.htmlUrl,
        'https://github.com/pwnapplehat/iPASide/releases/tag/v0.2.0',
      );
      expect(info.setupName, 'iPASide-Setup-0.2.0-x64.exe');
      expect(info.setupUrl, endsWith('iPASide-Setup-0.2.0-x64.exe'));
      expect(info.sumsUrl, endsWith('SHA256SUMS.txt'));
    });

    test('tolerates a release with no html_url', () {
      final info = UpdatePlanner.parseRelease(
        _release(htmlUrl: null, assets: <Map<String, String>>[
          _asset('iPASide-Setup-0.2.0-x64.exe'),
        ]),
      );

      expect(info.htmlUrl, isNull);
      expect(info.setupName, 'iPASide-Setup-0.2.0-x64.exe');
    });

    test('ignores assets that are neither an installer nor the sums', () {
      final info = UpdatePlanner.parseRelease(
        _release(assets: <Map<String, String>>[
          _asset('release-notes.md'),
          _asset('iPASide-portable.zip'),
        ]),
      );

      expect(info.setupUrl, isNull);
      expect(info.sumsUrl, isNull);
    });

    test('an arm machine prefers the arm64 installer', () {
      final assets = <Map<String, String>>[
        _asset('iPASide-Setup-0.2.0-x64.exe'),
        _asset('iPASide-Setup-0.2.0-arm64-setup.exe'),
      ];

      expect(
        UpdatePlanner.parseRelease(_release(assets: assets), arch: 'arm64').setupName,
        contains('arm64'),
      );
      expect(
        UpdatePlanner.parseRelease(_release(assets: assets), arch: 'x64').setupName,
        'iPASide-Setup-0.2.0-x64.exe',
      );
    });

    test('an arm machine falls back to the only installer on offer', () {
      final info = UpdatePlanner.parseRelease(
        _release(assets: <Map<String, String>>[_asset('iPASide-Setup-0.2.0-x64.exe')]),
        arch: 'arm64',
      );
      expect(info.setupName, 'iPASide-Setup-0.2.0-x64.exe');
    });

    test('survives a missing tag, a missing assets array and malformed entries', () {
      expect(UpdatePlanner.parseRelease(_release(tag: null)).tag, isNull);
      expect(UpdatePlanner.parseRelease('{}').setupUrl, isNull);
      expect(UpdatePlanner.parseRelease('[]').tag, isNull);
      expect(
        UpdatePlanner.parseRelease(
          jsonEncode(<String, Object?>{
            'tag_name': 'v1.0.0',
            'assets': <Object?>[
              'not-an-object',
              <String, Object?>{'name': 'x.exe'}, // no url
            ],
          }),
        ).setupUrl,
        isNull,
      );
    });
  });

  group('UpdatePlanner.checksumMatches', () {
    const hash = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
    const other = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

    test('matches the two-space and binary-mode layouts', () {
      expect(
        UpdatePlanner.checksumMatches('$hash  setup.exe', 'setup.exe', hash),
        isTrue,
      );
      expect(
        UpdatePlanner.checksumMatches('$hash *setup.exe', 'setup.exe', hash),
        isTrue,
      );
    });

    test('is case-insensitive on both the hash and the name', () {
      expect(
        UpdatePlanner.checksumMatches(
          '${hash.toUpperCase()}  SETUP.EXE',
          'setup.exe',
          hash,
        ),
        isTrue,
      );
    });

    test('picks the right line out of many, ignoring blanks', () {
      final sums = '''
$other  other-app.exe

$hash  setup.exe
''';
      expect(UpdatePlanner.checksumMatches(sums, 'setup.exe', hash), isTrue);
    });

    test('a hash listed against a DIFFERENT filename does not vouch for this one', () {
      expect(
        UpdatePlanner.checksumMatches('$hash  something-else.exe', 'setup.exe', hash),
        isFalse,
      );
    });

    test('rejects a mismatched hash for the right filename', () {
      expect(
        UpdatePlanner.checksumMatches('$other  setup.exe', 'setup.exe', hash),
        isFalse,
      );
    });

    test('compares only the file name, not the path it was staged at', () {
      expect(
        UpdatePlanner.checksumMatches(
          '$hash  setup.exe',
          r'C:\Users\me\AppData\Local\iPASide\updates\setup.exe',
          hash,
        ),
        isTrue,
      );
    });

    test('refuses empty input rather than defaulting to a match', () {
      expect(UpdatePlanner.checksumMatches('', 'setup.exe', hash), isFalse);
      expect(UpdatePlanner.checksumMatches('$hash  setup.exe', '', hash), isFalse);
      expect(UpdatePlanner.checksumMatches('$hash  setup.exe', 'setup.exe', ''), isFalse);
    });

    test('ignores lines that are not "<hash> <name>"', () {
      expect(UpdatePlanner.checksumMatches('garbage', 'setup.exe', hash), isFalse);
      expect(UpdatePlanner.checksumMatches(hash, 'setup.exe', hash), isFalse);
    });
  });
}
