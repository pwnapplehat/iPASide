import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../widgets/buttons.dart';

/// Raises confirm/alert dialogs without needing a [BuildContext] at the call
/// site, so view models can prompt the user directly.
///
/// Escape and a barrier tap dismiss (false); Enter confirms (true).
class DialogService {
  DialogService(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;

  Future<bool> confirm({
    required String title,
    required String message,
    String confirmLabel = 'OK',
    String cancelLabel = 'Cancel',
    bool danger = false,
  }) async {
    final result = await _show(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      danger: danger,
    );
    return result ?? false;
  }

  Future<void> alert({required String title, required String message}) => _show(
        title: title,
        message: message,
        confirmLabel: 'OK',
        cancelLabel: null,
        danger: false,
      );

  Future<bool?> _show({
    required String title,
    required String message,
    required String confirmLabel,
    required String? cancelLabel,
    required bool danger,
  }) {
    final context = navigatorKey.currentContext;
    if (context == null) return Future.value(null);

    return showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: context.palette.scrim,
      transitionDuration: Motion.base,
      pageBuilder: (_, _, _) => _DialogCard(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        danger: danger,
      ),
      transitionBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(parent: animation, curve: Motion.curve);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.97, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}

class _DialogCard extends StatelessWidget {
  const _DialogCard({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.danger,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String? cancelLabel;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: Sizes.dialogMin,
          maxWidth: Sizes.dialogMax,
        ),
        child: Material(
          color: Colors.transparent,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter): () =>
                  Navigator.of(context).pop(true),
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(context).pop(false),
            },
            child: Focus(
              autofocus: true,
              child: Semantics(
                // A dialog is its own screen for a screen reader: this is what
                // makes it announce the title on opening rather than leaving the
                // user to find the new content unheralded.
                scopesRoute: true,
                namesRoute: true,
                explicitChildNodes: true,
                label: title,
                child: Container(
                  padding: Pad.dialog,
                  decoration: BoxDecoration(
                    gradient: p.cardGradient,
                    borderRadius: Radii.rLarge,
                    border: Border.all(color: p.cardBorder),
                    boxShadow: p.liftShadow,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: context.t.title),
                      const SizedBox(height: Space.s3),
                      Text(message, style: context.t.bodyMuted),
                      const SizedBox(height: Space.s6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (cancelLabel != null) ...[
                            AppButton(
                              label: cancelLabel!,
                              onPressed: () => Navigator.of(context).pop(false),
                            ),
                            const SizedBox(width: Space.s2),
                          ],
                          AppButton(
                            label: confirmLabel,
                            tone: danger ? ButtonTone.danger : ButtonTone.primary,
                            onPressed: () => Navigator.of(context).pop(true),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
