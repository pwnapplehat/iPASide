import 'package:flutter/widgets.dart';

import '../engine/engine.dart';
import '../ui/shell/nav_destination.dart';
import 'base_view_model.dart';
import 'navigation_state.dart';

/// Tone of the single form message shown under the sign-in actions.
enum SignInMessageTone {
  /// Neutral: the message renders in the primary text colour.
  none,

  /// A round-trip is running; the view pairs the message with a spinner.
  busy,

  /// The sign-in succeeded.
  ok,

  /// Validation, or a response that was neither 2FA nor success.
  warn,

  /// The engine reported a failure.
  fail,
}

/// Apple ID sign-in: email + password, then a 6-digit code step when Apple
/// asks for one.
///
/// A `2fa_required` response switches the form to [isCodeStep] with the
/// sms / trusted-device hint; success shows a confirmation for
/// [successNavigateDelay] and then lands on Home.
///
/// The password is read out of [password] only at the moment of the call and
/// handed to [EngineApi.login], which sends it through per-request env. It
/// never reaches argv, a message, or a log line.
class SignInViewModel extends BaseViewModel {
  /// Creates the view model for one visit to the sign-in screen.
  SignInViewModel({required this._engine, required this._navigation});

  /// How long "Signed in." stays on screen before Home replaces the form.
  static const Duration successNavigateDelay = Duration(milliseconds: 700);

  static final RegExp _codePattern = RegExp(r'^\d{6}$');

  final EngineApi _engine;
  final NavigationState _navigation;

  /// Apple ID address; bound to the step-one email field.
  final TextEditingController email = TextEditingController();

  /// Apple ID password; bound to the masked step-one field.
  final TextEditingController password = TextEditingController();

  /// Verification code; bound to the step-two field.
  final TextEditingController code = TextEditingController();

  bool _isCodeStep = false;
  String _codeHint = '';
  bool _isBusy = false;
  String _message = '';
  SignInMessageTone _messageTone = SignInMessageTone.none;

  /// True once the 2FA code step has replaced the credentials form.
  bool get isCodeStep => _isCodeStep;

  /// The code step's hint sentence, naming where the code was sent.
  String get codeHint => _codeHint;

  /// True while a login round-trip is running; the active submit is disabled.
  bool get isBusy => _isBusy;

  /// The single line shown under the actions; empty when there is none.
  String get message => _message;

  bool get hasMessage => _message.isNotEmpty;

  SignInMessageTone get messageTone => _messageTone;

  /// Step one: submits the credentials.
  ///
  /// Apple either completes the sign-in or asks for a verification code, in
  /// which case the form moves on to [verify].
  Future<void> submit() async {
    // The Avalonia command refused re-entry while it was running.
    if (_isBusy) return;

    if (email.text.isEmpty || password.text.isEmpty) {
      _setMessage('Enter your Apple ID and password.', SignInMessageTone.warn);
      return;
    }

    _isBusy = true;
    _setMessage('Signing in\u2026', SignInMessageTone.busy);
    try {
      final result = await _engine.login(email.text, password.text);
      if (result.requiresTwoFactor) {
        final channel = result.method == 'sms' ? 'phone' : 'device';
        _codeHint = result.notice ??
            'A verification code was sent to your trusted $channel. '
                'Enter it to finish.';
        _isCodeStep = true;
        _setMessage('', SignInMessageTone.none);
      } else {
        await _completeSignIn();
      }
    } on EngineShutdownException {
      _setMessage('', SignInMessageTone.none); // the app is closing
    } catch (error) {
      _setMessage(BaseViewModel.errorText(error), SignInMessageTone.fail);
    } finally {
      _isBusy = false;
      notify();
    }
  }

  /// Step two: submits the verification code alongside the credentials.
  Future<void> verify() async {
    if (_isBusy) return;

    if (!_codePattern.hasMatch(code.text)) {
      _setMessage('Enter the 6-digit code.', SignInMessageTone.warn);
      return;
    }

    _isBusy = true;
    _setMessage('Verifying\u2026', SignInMessageTone.busy);
    try {
      final result = await _engine.login(
        email.text,
        password.text,
        code: code.text,
      );
      if (result.status == 'authenticated') {
        await _completeSignIn();
      } else {
        _setMessage('Unexpected response.', SignInMessageTone.warn);
      }
    } on EngineShutdownException {
      _setMessage('', SignInMessageTone.none);
    } catch (error) {
      _setMessage(BaseViewModel.errorText(error), SignInMessageTone.fail);
    } finally {
      _isBusy = false;
      notify();
    }
  }

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> _completeSignIn() async {
    _setMessage('Signed in.', SignInMessageTone.ok);
    await Future<void>.delayed(successNavigateDelay);
    _navigation.navigateTo(NavKey.home);
  }

  void _setMessage(String text, SignInMessageTone tone) {
    _message = text;
    _messageTone = tone;
    notify();
  }
}
