import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'motion.dart';
import 'progress.dart';

enum ButtonTone {
  /// Accent gradient with a glow — one per screen.
  primary,

  /// Neutral surface with a hairline border.
  soft,

  /// Destructive action; danger text and border.
  danger,
}

/// The app's button. Tone selects the treatment; [busy] swaps the icon for a
/// spinner and blocks input.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.tone = ButtonTone.soft,
    this.busy = false,
    this.compact = false,
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final ButtonTone tone;
  final bool busy;
  final bool compact;
  final String? tooltip;

  bool get _enabled => onPressed != null && !busy;

  @override
  Widget build(BuildContext context) {
    return Hoverable(
      onTap: onPressed,
      enabled: _enabled,
      pressScale: 0.97,
      tooltip: tooltip,
      // Named even when it is disabled or busy, where it has no action and would
      // otherwise be an anonymous piece of text.
      semanticsLabel: label,
      builder: (hovered, pressed) => switch (tone) {
        ButtonTone.primary => _primary(context, hovered, pressed),
        ButtonTone.soft => _outlined(context, hovered, pressed, danger: false),
        ButtonTone.danger => _outlined(context, hovered, pressed, danger: true),
      },
    );
  }

  EdgeInsets get _padding => compact ? Pad.buttonSmall : Pad.button;

  Widget _primary(BuildContext context, bool hovered, bool pressed) {
    final p = context.palette;
    return AnimatedContainer(
      duration: Motion.base,
      curve: Motion.curve,
      transform: Matrix4.translationValues(0, hovered ? -1 : 0, 0),
      padding: _padding,
      decoration: BoxDecoration(
        gradient: _enabled ? (hovered ? p.accentGradientHover : p.accentGradient) : null,
        color: _enabled ? null : p.accentDisabled,
        borderRadius: Radii.rSmall,
        boxShadow: _enabled && !pressed ? p.accentGlow : const [],
      ),
      child: _content(context, p.onAccent, p.onAccent),
    );
  }

  Widget _outlined(BuildContext context, bool hovered, bool pressed, {required bool danger}) {
    final p = context.palette;
    final fg = danger
        ? (_enabled ? p.danger : p.dangerDisabled)
        : (_enabled ? p.textPrimary : p.textMuted);
    final border = danger
        ? (hovered ? p.danger : p.hairlineStrong)
        : (hovered ? p.cardBorderHover : p.hairlineStrong);

    return AnimatedContainer(
      duration: Motion.fast,
      curve: Motion.curve,
      padding: _padding,
      decoration: BoxDecoration(
        color: pressed
            ? p.surfacePressed
            : hovered
                ? p.surfaceHover
                : p.bg1,
        borderRadius: Radii.rSmall,
        border: Border.all(color: border),
      ),
      child: _content(context, fg, danger ? p.danger : p.textSecondary),
    );
  }

  Widget _content(BuildContext context, Color labelColor, Color iconColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy) ...[
          Spinner(size: Sizes.spinnerSmall, color: iconColor),
          const SizedBox(width: Space.s2),
        ] else if (icon != null) ...[
          Icon(icon, size: Sizes.icon, color: iconColor),
          const SizedBox(width: Space.s2),
        ],
        Text(
          label,
          style: context.t.small.copyWith(
            fontSize: compact ? FontSizes.small : FontSizes.body,
            fontWeight: FontWeight.w600,
            color: labelColor,
          ),
        ),
      ],
    );
  }
}

/// Borderless icon button used for window controls and row actions.
class GhostIconButton extends StatelessWidget {
  const GhostIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.danger = false,
    this.busy = false,
    this.width = Sizes.iconButton,
    this.height = Sizes.iconButton,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  /// Fills with danger colour on hover — used for the window close button.
  final bool danger;
  final bool busy;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hoverable(
      onTap: onPressed,
      enabled: onPressed != null && !busy,
      pressScale: 1,
      tooltip: tooltip,
      // No text to read, so the tooltip is the only name this control has.
      semanticsLabel: tooltip,
      builder: (hovered, pressed) {
        final bg = !hovered
            ? Colors.transparent
            : danger
                ? (pressed ? p.dangerPressed : p.danger)
                : (pressed ? p.surfacePressed : p.surfaceHover);
        final fg = hovered && danger ? p.onAccent : p.textSecondary;

        return AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.curve,
          width: width,
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: bg, borderRadius: Radii.rSmall),
          child: busy
              ? Spinner(size: Sizes.spinnerSmall, color: fg)
              : Icon(icon, size: Sizes.icon, color: fg),
        );
      },
    );
  }
}

/// Large quick-action tile: icon at the top, title and description at the bottom.
///
/// The three tiles on Home are stretched to a common height, and their
/// descriptions are different lengths — so with everything top-aligned the
/// shorter ones leave a hole below the text. Sending the text block to the bottom
/// puts every title on the same baseline instead, and the icons on the one above
/// it, which is what makes the row read as a set. [MainAxisAlignment.spaceBetween]
/// rather than a [Spacer] so a tile is still safe at its natural height.
class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hoverable(
      onTap: onTap,
      pressScale: 0.99,
      builder: (hovered, _) => AnimatedContainer(
        duration: Motion.base,
        curve: Motion.curve,
        transform: Matrix4.translationValues(0, hovered ? -4 : 0, 0),
        padding: Pad.cardLarge,
        decoration: BoxDecoration(
          gradient: hovered ? p.cardHoverGradient : p.cardGradient,
          borderRadius: Radii.rLarge,
          border: Border.all(color: hovered ? p.cardBorderHover : p.cardBorder),
          boxShadow: hovered ? p.liftShadow : p.cardShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s3),
              child: Icon(icon, size: Sizes.iconLarge, color: p.accent),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.t.semi(FontSizes.body + 0.5)),
                const SizedBox(height: Space.s1),
                Text(subtitle, style: context.t.smallMuted),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
