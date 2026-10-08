import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../engine/engine.dart';
import '../../viewmodels/navigation_state.dart';
import '../../viewmodels/sign_in_view_model.dart';
import '../theme/app_theme.dart';
import '../widgets/buttons.dart';
import '../widgets/inputs.dart';
import '../widgets/motion.dart';
import '../widgets/progress.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/surfaces.dart';

/// Sign in: the credentials form, replaced by the 2FA code step when Apple
/// asks for one.
class SignInView extends StatelessWidget {
  const SignInView({super.key});

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) => SignInViewModel(
          engine: ctx.read<EngineApi>(),
          navigation: ctx.read<NavigationState>(),
        ),
        child: const _SignInBody(),
      );
}

class _SignInBody extends StatefulWidget {
  const _SignInBody();

  @override
  State<_SignInBody> createState() => _SignInBodyState();
}

class _SignInBodyState extends State<_SignInBody> {
  final FocusNode _codeFocus = FocusNode();
  bool _codeStepShown = false;

  @override
  void dispose() {
    _codeFocus.dispose();
    super.dispose();
  }

  /// Moves focus to the code field the first time the 2FA step appears, after
  /// the frame that inserts it — the field has to exist before it can take
  /// focus.
  void _focusCodeWhenShown(bool isCodeStep) {
    if (!isCodeStep || _codeStepShown) return;
    _codeStepShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _codeFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SignInViewModel>();
    _focusCodeWhenShown(vm.isCodeStep);

    return SmoothScrollView(
      padding: const EdgeInsets.fromLTRB(Space.s6, Space.s5, Space.s6, Space.s7),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Sizes.contentMax),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Entrance(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sign in to Apple ID', style: context.t.display),
                    const SizedBox(height: Space.s1),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Text(
                        'Used only to sign apps. Your password is sent only to '
                        'Apple \u2014 never stored or shared.',
                        style: context.t.bodyMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.s6),
              Entrance(
                index: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: Sizes.dialogMax),
                  child: AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (vm.isCodeStep)
                          _CodeStep(vm: vm, codeFocus: _codeFocus)
                        else
                          _CredentialsStep(vm: vm),
                        if (vm.hasMessage) ...[
                          const SizedBox(height: Space.s4),
                          _FormMessage(vm: vm),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CredentialsStep extends StatelessWidget {
  const _CredentialsStep({required this.vm});

  final SignInViewModel vm;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTextField(
            label: 'Apple ID email',
            hint: 'you@example.com',
            controller: vm.email,
            autofocus: true,
          ),
          const SizedBox(height: Space.s4),
          AppTextField(
            label: 'Password',
            controller: vm.password,
            obscure: true,
            onSubmitted: (_) => vm.submit(),
          ),
          const SizedBox(height: Space.s4),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: 'Sign in',
              tone: ButtonTone.primary,
              onPressed: vm.isBusy ? null : vm.submit,
            ),
          ),
        ],
      );
}

class _CodeStep extends StatelessWidget {
  const _CodeStep({required this.vm, required this.codeFocus});

  final SignInViewModel vm;
  final FocusNode codeFocus;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(vm.codeHint, style: context.t.bodyMuted),
          const SizedBox(height: Space.s4),
          AppTextField(
            label: '6-digit code',
            hint: '123456',
            controller: vm.code,
            focusNode: codeFocus,
            maxLength: 6,
            mono: true,
            onSubmitted: (_) => vm.verify(),
          ),
          const SizedBox(height: Space.s4),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: 'Verify',
              tone: ButtonTone.primary,
              onPressed: vm.isBusy ? null : vm.verify,
            ),
          ),
        ],
      );
}

class _FormMessage extends StatelessWidget {
  const _FormMessage({required this.vm});

  final SignInViewModel vm;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = switch (vm.messageTone) {
      SignInMessageTone.ok => p.success,
      SignInMessageTone.warn => p.warning,
      SignInMessageTone.fail => p.danger,
      SignInMessageTone.none || SignInMessageTone.busy => p.textPrimary,
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (vm.messageTone == SignInMessageTone.busy) ...[
          const Padding(
            padding: EdgeInsets.only(top: 3),
            child: Spinner(size: Sizes.spinnerSmall),
          ),
          const SizedBox(width: Space.s2),
        ],
        Expanded(
          child: SelectableText(
            vm.message,
            style: context.t.body.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
