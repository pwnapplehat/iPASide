import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import 'motion.dart';

/// Labelled text field. The label sits above the control, matching the
/// Avalonia form layout.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.obscure = false,
    this.maxLength,
    this.mono = false,
    this.autofocus = false,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.digitsOnly = false,
  });

  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final bool obscure;
  final int? maxLength;
  final bool mono;
  final bool autofocus;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool digitsOnly;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    OutlineInputBorder border(Color color, [double width = Sizes.hairline]) => OutlineInputBorder(
          borderRadius: Radii.rSmall,
          borderSide: BorderSide(color: color, width: width),
        );

    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      obscureText: obscure,
      obscuringCharacter: '\u2022',
      maxLength: maxLength,
      style: mono ? context.t.mono.copyWith(fontSize: FontSizes.body) : context.t.body,
      cursorColor: p.accent,
      inputFormatters: digitsOnly ? [FilteringTextInputFormatter.digitsOnly] : null,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        hintStyle: context.t.faint,
        filled: true,
        fillColor: p.inputBg,
        isDense: true,
        contentPadding: Pad.input,
        border: border(p.hairlineStrong),
        enabledBorder: border(p.hairlineStrong),
        focusedBorder: border(p.focusRing, 2),
      ),
    );

    if (label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The label is drawn above the field but belongs *to* the field: naming
        // the field is what lets a screen reader say what is being edited, and
        // leaving the text readable as well would read it twice.
        ExcludeSemantics(child: Text(label!, style: context.t.smallMuted)),
        const SizedBox(height: Space.s2 - 1),
        // Merged, not merely wrapped: an editable field is its own semantics
        // boundary, so a label on a parent node would be announced separately
        // from the field it names.
        MergeSemantics(child: Semantics(label: label, child: field)),
      ],
    );
  }
}

/// Checkbox with its label, as one click target.
class AppCheckbox extends StatelessWidget {
  const AppCheckbox({
    super.key,
    required this.label,
    required this.value,
    this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onChanged != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.s1 + 2),
      child: Hoverable(
        onTap: enabled ? () => onChanged!(!value) : null,
        pressScale: 1,
        // Announces as a checkbox with its state, not as a button; the visible
        // label is read as part of the same control.
        isButton: false,
        checked: value,
        builder: (hovered, _) => Row(
          children: [
            AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.curve,
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                gradient: value && enabled ? p.accentGradient : null,
                color: value
                    ? (enabled ? null : p.accentDisabled)
                    : p.inputBg,
                borderRadius: Radii.rTiny + const BorderRadius.all(Radius.circular(1)),
                border: Border.all(
                  color: value
                      ? Colors.transparent
                      : hovered
                          ? p.cardBorderHover
                          : p.hairlineStrong,
                ),
                boxShadow: value && enabled ? p.accentGlow : const [],
              ),
              child: AnimatedOpacity(
                opacity: value ? 1 : 0,
                duration: Motion.fast,
                child: Icon(Icons.check_rounded, size: 13, color: p.onAccent),
              ),
            ),
            const SizedBox(width: Space.s3 - 1),
            Expanded(
              child: Text(
                label,
                style: enabled
                    ? context.t.body
                    : context.t.body.copyWith(color: p.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Track-and-thumb switch used for the auto-refresh setting.
class AppToggle extends StatelessWidget {
  const AppToggle({
    super.key,
    required this.value,
    this.onChanged,
    this.label,
    this.semanticsLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Text drawn beside the switch. When the switch has no drawn label — a
  /// settings row puts the title to its left — use [semanticsLabel] instead.
  final String? label;

  /// Name read by a screen reader when [label] is null.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onChanged != null;

    final control = Hoverable(
      onTap: enabled ? () => onChanged!(!value) : null,
      pressScale: 1,
      isButton: false,
      toggled: value,
      semanticsLabel: label == null ? semanticsLabel : null,
      builder: (hovered, _) => AnimatedContainer(
        duration: Motion.base,
        curve: Motion.curve,
        width: 40,
        height: 22,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          gradient: value && enabled ? p.accentGradient : null,
          color: value
              ? (enabled ? null : p.accentDisabled)
              : (hovered ? p.surfaceHover : p.inputBg),
          borderRadius: Radii.rFull,
          border: Border.all(color: value ? Colors.transparent : p.hairlineStrong),
        ),
        child: AnimatedAlign(
          duration: Motion.base,
          curve: Motion.curve,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: value ? p.onAccent : p.textSecondary,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );

    if (label == null) return control;
    return Row(
      children: [
        control,
        const SizedBox(width: Space.s3),
        Expanded(
          child: Text(
            label!,
            style: enabled ? context.t.body : context.t.body.copyWith(color: p.textMuted),
          ),
        ),
      ],
    );
  }
}

/// A row of mutually-exclusive chips, for a setting with a handful of choices.
///
/// A toggle cannot express three options and a dropdown hides two of them behind
/// a click; with this many, showing them all is both clearer and fewer actions.
/// The visual language matches the device picker's chips deliberately, since both
/// are "pick exactly one of these".
class AppChoiceChips<T> extends StatelessWidget {
  /// Creates a chip row over [choices], marking [selected].
  const AppChoiceChips({
    super.key,
    required this.choices,
    required this.selected,
    required this.labelOf,
    required this.onSelect,
    this.groupLabel,
  });

  /// Every option, in the order shown.
  final List<T> choices;

  /// The option currently in force.
  final T selected;

  /// The chip caption for an option.
  final String Function(T choice) labelOf;

  /// Called with the option the user picked; not called for the current one.
  final ValueChanged<T> onSelect;

  /// What the choice is about, read before each caption — the settings row's
  /// title, so a screen reader hears "Connection: USB" rather than a bare
  /// "USB" out of context.
  final String? groupLabel;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: Space.s2,
        runSpacing: Space.s2,
        children: <Widget>[
          for (final T choice in choices)
            _Chip(
              label: labelOf(choice),
              selected: choice == selected,
              // The current choice stays focusable so a keyboard user can hear
              // which one it is; picking it again simply does nothing.
              onTap: () {
                if (choice != selected) onSelect(choice);
              },
              semanticsLabel: groupLabel == null
                  ? null
                  : '$groupLabel: ${labelOf(choice)}',
            ),
        ],
      );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    this.onTap,
    this.semanticsLabel,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Hoverable(
      onTap: onTap,
      pressScale: 0.98,
      selected: selected,
      semanticsLabel: semanticsLabel,
      builder: (bool hovered, bool pressed) => AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        padding: Pad.button,
        decoration: BoxDecoration(
          color: selected
              ? p.accentSubtle
              : hovered
                  ? p.surfaceHover
                  : p.bg1,
          borderRadius: Radii.rSmall,
          border: Border.all(
            color: selected
                ? p.accent
                : hovered
                    ? p.cardBorderHover
                    : p.hairlineStrong,
          ),
        ),
        child: Text(
          label,
          style: selected
              ? context.t.semi(FontSizes.small).copyWith(color: p.accent)
              : context.t.small,
        ),
      ),
    );
  }
}
