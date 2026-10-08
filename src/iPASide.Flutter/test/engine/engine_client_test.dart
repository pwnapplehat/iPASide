import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine_client.dart';
import 'package:ipaside/engine/engine_exception.dart';
import 'package:ipaside/engine/engine_locator.dart';
import 'package:ipaside/platform/child_process_reaper.dart';

/// Records the pids the client hands over, so lifecycle wiring is observable.
class _RecordingReaper implements ChildProcessReaper {
  final List<int> adopted = <int>[];

  @override
  void adopt(int pid) => adopted.add(pid);
}

void main() {
  group('EngineClient.encodeRequest', () {
    test('omits env when there is none', () {
      expect(
        EngineClient.encodeRequest(1, <String>['devices'], null),
        '{"id":1,"args":["devices"]}',
      );
    });

    test('omits env when it is empty', () {
      expect(
        EngineClient.encodeRequest(
          2,
          <String>['version'],
          const <String, String>{},
        ),
        '{"id":2,"args":["version"]}',
      );
    });

    test('carries a per-request env', () {
      expect(
        EngineClient.encodeRequest(
          3,
          <String>['login', '--email', 'a@b.c'],
          const <String, String>{'IPASIDE_APPLE_PASSWORD': 'pw'},
        ),
        '{"id":3,"args":["login","--email","a@b.c"],'
        '"env":{"IPASIDE_APPLE_PASSWORD":"pw"}}',
      );
    });

    test('never appends --json; the engine does that itself', () {
      expect(
        EngineClient.encodeRequest(4, <String>['doctor'], null),
        isNot(contains('--json')),
      );
    });

    test('escapes so one request stays on one line', () {
      final String line = EngineClient.encodeRequest(
        5,
        <String>['sideload', 'C:\\ipa\\Trüs "App"\n.ipa'],
        null,
      );

      expect(line, isNot(contains('\n')));
      final Map<String, dynamic> decoded =
          jsonDecode(line) as Map<String, dynamic>;
      expect(
        (decoded['args'] as List<dynamic>).last,
        'C:\\ipa\\Trüs "App"\n.ipa',
      );
    });
  });

  group('isUnsolicitedEngineEvent', () {
    test('only type event is unsolicited', () {
      expect(
        isUnsolicitedEngineEvent(<String, dynamic>{
          'type': 'event',
          'name': 'devices',
        }),
        isTrue,
      );
      expect(
        isUnsolicitedEngineEvent(<String, dynamic>{
          'id': 1,
          'type': 'result',
          'ok': true,
        }),
        isFalse,
      );
      expect(
        isUnsolicitedEngineEvent(<String, dynamic>{
          'id': 1,
          'type': 'progress',
          'line': 'signing',
        }),
        isFalse,
      );
    });
  });

  group('EngineClient lifecycle', () {
    late Directory root;
    late _RecordingReaper reaper;

    setUp(() {
      // An empty base directory with no checkout above it resolves to bare
      // `python`, which is never launched by these tests.
      root = Directory.systemTemp.createTempSync('ipaside_client_');
      reaper = _RecordingReaper();
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    EngineClient newClient() => EngineClient(
          locator: EngineLocator(
            environment: const <String, String>{},
            baseDirectory: root.path,
          ),
          reaper: reaper,
          log: (String _) {},
        );

    test('resolves its launch spec up front without starting anything', () {
      final EngineClient client = newClient();

      expect(
        client.launchSpec.prefixArgs,
        <String>['-E', '-u', '-X', 'utf8', '-m', 'ipaside_engine'],
      );
      expect(client.enginePid, isNull);
      expect(client.isDisposed, isFalse);
      expect(reaper.adopted, isEmpty);
    });

    test('the teardown ceiling stays inside a close nobody notices', () {
      // The engine acknowledges the shutdown frame and exits in ~70ms, so this
      // ceiling is only ever paid by an engine that has wedged - and the job
      // object reaps that one when we exit. Both stages can time out, so the
      // worst case is twice this.
      expect(
        EngineClient.shutdownTimeout,
        lessThanOrEqualTo(const Duration(seconds: 1)),
      );
    });

    test('dispose is idempotent and safe before any start', () async {
      final EngineClient client = newClient();

      await client.dispose();
      await client.dispose();

      expect(client.isDisposed, isTrue);
      expect(client.enginePid, isNull);
      expect(reaper.adopted, isEmpty);
    });

    test('rejects calls made after disposal', () async {
      final EngineClient client = newClient();
      await client.dispose();

      await expectLater(
        client.run(<String>['version']),
        throwsA(isA<EngineDisposedException>()),
      );
    });

    test('prewarm after disposal is a no-op', () async {
      final EngineClient client = newClient();
      await client.dispose();

      client.prewarm();
      await Future<void>.delayed(Duration.zero);

      expect(reaper.adopted, isEmpty);
      expect(client.enginePid, isNull);
    });
  });

  group('describeEngineExit', () {
    test('keeps the headline and adds the exit code', () {
      expect(
        describeEngineExit(headline: 'engine exited unexpectedly', exitCode: 1),
        'engine exited unexpectedly (exit 1, 0x00000001)\n'
        'The engine printed nothing before it stopped. '
        'Sign in once more and send this whole message.',
      );
    });

    test('formats a Windows fail-fast code and keeps the last stderr lines', () {
      final String text = describeEngineExit(
        headline: 'engine exited unexpectedly',
        exitCode: -1073740791,
        stderrLines: <String>[
          'IPASIDE_APPLE_PASSWORD=secret',
          'Fatal Python error: Windows fatal exception: code 0xc0000409',
        ],
      );

      expect(text, contains('0xC0000409'));
      expect(text, contains('IPASIDE_APPLE_PASSWORD=(redacted)'));
      expect(text, isNot(contains('secret')));
      expect(text, contains('Windows fatal exception'));
    });

    test('says when the pipe closed but the process had not exited', () {
      expect(
        describeEngineExit(
          headline: 'engine exited unexpectedly',
          stillRunning: true,
          stderrLines: <String>['  boom  '],
        ),
        'engine exited unexpectedly (output closed while the process was still running)\n'
        'boom',
      );
    });
  });
}
