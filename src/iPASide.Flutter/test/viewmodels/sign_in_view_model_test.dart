import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine_api.dart';
import 'package:ipaside/engine/engine_client.dart';
import 'package:ipaside/engine/engine_exception.dart';
import 'package:ipaside/ui/shell/nav_destination.dart';
import 'package:ipaside/viewmodels/navigation_state.dart';
import 'package:ipaside/viewmodels/sign_in_view_model.dart';

/// A transport stand-in: records what the facade asked for and replays a
/// canned result, optionally parked until the test releases [gate].
class _FakeRunner with EngineCommandRunner {
  EngineResult result = const EngineResult(
    ok: true,
    data: <String, dynamic>{'status': 'authenticated'},
  );

  /// Thrown instead of returning [result] when set.
  Object? failure;

  /// Holds the call open so the test can observe the in-flight state.
  Completer<void>? gate;

  final List<List<String>> calls = <List<String>>[];
  final List<Map<String, String>?> envs = <Map<String, String>?>[];

  List<String> get lastArgs => calls.last;
  Map<String, String>? get lastEnv => envs.last;

  @override
  Future<EngineResult> run(
    List<String> args, {
    void Function(String line)? onProgress,
    Map<String, String>? env,
  }) async {
    calls.add(args);
    envs.add(env);

    final Completer<void>? parked = gate;
    if (parked != null) {
      await parked.future;
    }
    final Object? error = failure;
    if (error != null) {
      throw error;
    }
    return result;
  }
}

/// Drains the microtask queue so awaited engine calls have settled.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeRunner runner;
  late NavigationState navigation;
  late SignInViewModel viewModel;

  setUp(() {
    runner = _FakeRunner();
    navigation = NavigationState()..navigateTo(NavKey.signIn);
    viewModel = SignInViewModel(
      engine: EngineApi(runner),
      navigation: navigation,
    );
  });

  tearDown(() {
    if (!viewModel.isDisposed) viewModel.dispose();
  });

  void enterCredentials() {
    viewModel.email.text = 'user@example.com';
    viewModel.password.text = 'sup3r-s3cret';
  }

  /// Runs step one against a `2fa_required` response so the code step is live.
  Future<void> reachCodeStep({String? method = 'sms', String? notice}) async {
    runner.result = EngineResult(
      ok: true,
      data: <String, dynamic>{
        'status': '2fa_required',
        'method': ?method,
        'notice': ?notice,
      },
    );
    enterCredentials();
    await viewModel.submit();
    runner.result = const EngineResult(
      ok: true,
      data: <String, dynamic>{'status': 'authenticated'},
    );
  }

  group('SignInViewModel initial state', () {
    test('opens on the credentials step with no message', () {
      expect(viewModel.isCodeStep, isFalse);
      expect(viewModel.isBusy, isFalse);
      expect(viewModel.hasMessage, isFalse);
      expect(viewModel.message, isEmpty);
      expect(viewModel.messageTone, SignInMessageTone.none);
      expect(viewModel.codeHint, isEmpty);
    });
  });

  group('SignInViewModel validation', () {
    test('blank credentials are rejected before the engine is called', () async {
      await viewModel.submit();

      expect(viewModel.message, 'Enter your Apple ID and password.');
      expect(viewModel.messageTone, SignInMessageTone.warn);
      expect(runner.calls, isEmpty);
    });

    test('an email without a password is rejected', () async {
      viewModel.email.text = 'user@example.com';

      await viewModel.submit();

      expect(viewModel.message, 'Enter your Apple ID and password.');
      expect(viewModel.messageTone, SignInMessageTone.warn);
      expect(runner.calls, isEmpty);
    });

    test('a password without an email is rejected', () async {
      viewModel.password.text = 'sup3r-s3cret';

      await viewModel.submit();

      expect(viewModel.message, 'Enter your Apple ID and password.');
      expect(viewModel.messageTone, SignInMessageTone.warn);
      expect(runner.calls, isEmpty);
    });

    test('anything but six digits is rejected before the engine is called', () async {
      await reachCodeStep();
      final int callsAfterSubmit = runner.calls.length;

      for (final String code in <String>[
        '',
        '1',
        '12345',
        '1234567',
        'abcdef',
        '12 456',
        ' 123456',
        '123456 ',
        '12.456',
      ]) {
        viewModel.code.text = code;

        await viewModel.verify();

        expect(
          viewModel.message,
          'Enter the 6-digit code.',
          reason: 'rejected "$code"',
        );
        expect(viewModel.messageTone, SignInMessageTone.warn);
        expect(runner.calls, hasLength(callsAfterSubmit));
      }
    });
  });

  group('SignInViewModel step one', () {
    test('sends the password through env, never argv', () async {
      enterCredentials();

      await viewModel.submit();

      expect(runner.lastArgs, <String>['login', '--email', 'user@example.com']);
      expect(runner.lastArgs, isNot(contains('sup3r-s3cret')));
      expect(
        runner.lastEnv,
        <String, String>{'IPASIDE_APPLE_PASSWORD': 'sup3r-s3cret'},
      );
    });

    test('shows the busy message while the round-trip runs', () async {
      runner.gate = Completer<void>();
      enterCredentials();

      final Future<void> pending = viewModel.submit();
      await _settle();

      expect(viewModel.isBusy, isTrue);
      expect(viewModel.message, 'Signing in\u2026');
      expect(viewModel.messageTone, SignInMessageTone.busy);

      runner.gate!.complete();
      await pending;

      expect(viewModel.isBusy, isFalse);
    });

    test('a second submit is ignored while one is in flight', () async {
      runner.gate = Completer<void>();
      enterCredentials();

      final Future<void> pending = viewModel.submit();
      await _settle();
      await viewModel.submit();

      expect(runner.calls, hasLength(1));

      runner.gate!.complete();
      await pending;
    });

    test('an authenticated response signs in without a code step', () async {
      enterCredentials();

      await viewModel.submit();

      expect(viewModel.isCodeStep, isFalse);
      expect(viewModel.message, 'Signed in.');
      expect(viewModel.messageTone, SignInMessageTone.ok);
      expect(navigation.current, NavKey.home);
    });

    test('the confirmation is shown before Home replaces the form', () async {
      enterCredentials();

      unawaited(viewModel.submit());
      await _settle();

      expect(viewModel.message, 'Signed in.');
      expect(viewModel.messageTone, SignInMessageTone.ok);
      expect(navigation.current, NavKey.signIn);

      await Future<void>.delayed(
        SignInViewModel.successNavigateDelay + const Duration(milliseconds: 100),
      );

      expect(navigation.current, NavKey.home);
    });
  });

  group('SignInViewModel two-factor step', () {
    test('an sms code names the trusted phone', () async {
      await reachCodeStep();

      expect(viewModel.isCodeStep, isTrue);
      expect(
        viewModel.codeHint,
        'A verification code was sent to your trusted phone. '
        'Enter it to finish.',
      );
      expect(viewModel.hasMessage, isFalse);
      expect(viewModel.messageTone, SignInMessageTone.none);
      expect(navigation.current, NavKey.signIn);
    });

    test('any other delivery method names the trusted device', () async {
      await reachCodeStep(method: 'trusteddevice');

      expect(
        viewModel.codeHint,
        'A verification code was sent to your trusted device. '
        'Enter it to finish.',
      );
    });

    test('the engine notice replaces the usual line when no text could be sent',
        () async {
      await reachCodeStep(
        method: 'trusteddevice',
        notice: 'Apple would not text a verification code (HTTP 403). '
            'If a code appeared on one of your Apple devices, enter it to finish.',
      );

      expect(viewModel.isCodeStep, isTrue);
      expect(
        viewModel.codeHint,
        'Apple would not text a verification code (HTTP 403). '
        'If a code appeared on one of your Apple devices, enter it to finish.',
      );
      expect(viewModel.codeHint, isNot(contains('was sent to your trusted')));
    });

    test('a missing delivery method names the trusted device', () async {
      await reachCodeStep(method: null);

      expect(
        viewModel.codeHint,
        'A verification code was sent to your trusted device. '
        'Enter it to finish.',
      );
    });

    test('the code is verified alongside the credentials', () async {
      await reachCodeStep();
      viewModel.code.text = '123456';

      await viewModel.verify();

      expect(runner.lastArgs, <String>[
        'login',
        '--email',
        'user@example.com',
        '--code',
        '123456',
      ]);
      expect(runner.lastArgs, isNot(contains('sup3r-s3cret')));
      expect(
        runner.lastEnv,
        <String, String>{'IPASIDE_APPLE_PASSWORD': 'sup3r-s3cret'},
      );
      expect(viewModel.message, 'Signed in.');
      expect(viewModel.messageTone, SignInMessageTone.ok);
      expect(navigation.current, NavKey.home);
    });

    test('shows the verifying message while the round-trip runs', () async {
      await reachCodeStep();
      viewModel.code.text = '123456';
      runner.gate = Completer<void>();

      final Future<void> pending = viewModel.verify();
      await _settle();

      expect(viewModel.isBusy, isTrue);
      expect(viewModel.message, 'Verifying\u2026');
      expect(viewModel.messageTone, SignInMessageTone.busy);

      runner.gate!.complete();
      await pending;
    });

    test('a status other than authenticated is an unexpected response', () async {
      await reachCodeStep();
      viewModel.code.text = '123456';
      runner.result = const EngineResult(
        ok: true,
        data: <String, dynamic>{'status': '2fa_required'},
      );

      await viewModel.verify();

      expect(viewModel.message, 'Unexpected response.');
      expect(viewModel.messageTone, SignInMessageTone.warn);
      expect(navigation.current, NavKey.signIn);
    });
  });

  group('SignInViewModel failures', () {
    test('an engine failure is shown cleaned', () async {
      runner.result = const EngineResult(
        ok: false,
        data: <String, dynamic>{
          'status': 'error',
          'error': 'Login failed: invalid password',
        },
        error: 'Engine exited with code 1.',
      );
      enterCredentials();

      await viewModel.submit();

      expect(viewModel.message, 'invalid password');
      expect(viewModel.messageTone, SignInMessageTone.fail);
      expect(viewModel.isBusy, isFalse);
      expect(navigation.current, NavKey.signIn);
    });

    test('a verify failure is shown cleaned', () async {
      await reachCodeStep();
      viewModel.code.text = '123456';
      runner.result = const EngineResult(ok: false, error: 'invalid code');

      await viewModel.verify();

      expect(viewModel.message, 'invalid code');
      expect(viewModel.messageTone, SignInMessageTone.fail);
    });

    test('a shutdown during sign-in leaves no message behind', () async {
      runner.failure = EngineShutdownException();
      enterCredentials();

      await viewModel.submit();

      expect(viewModel.hasMessage, isFalse);
      expect(viewModel.messageTone, SignInMessageTone.none);
      expect(viewModel.isBusy, isFalse);
    });

    test('a shutdown during verification leaves no message behind', () async {
      await reachCodeStep();
      viewModel.code.text = '123456';
      runner.failure = EngineShutdownException();

      await viewModel.verify();

      expect(viewModel.hasMessage, isFalse);
      expect(viewModel.messageTone, SignInMessageTone.none);
    });

    test('a completion after disposal notifies nobody', () async {
      runner.gate = Completer<void>();
      enterCredentials();

      final Future<void> pending = viewModel.submit();
      await _settle();
      viewModel.dispose();
      runner.gate!.complete();

      await expectLater(pending, completes);
    });
  });
}
