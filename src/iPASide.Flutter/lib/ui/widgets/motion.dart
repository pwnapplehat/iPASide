import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// Carries UI-wide preferences down the tree. Reduced motion comes from the OS
/// (Windows "show animations"), so every animated widget can opt out at once.
class UiOptions extends InheritedWidget {
  const UiOptions({super.key, required this.reducedMotion, required super.child});

  final bool reducedMotion;

  static bool reducedMotionOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiOptions>()?.reducedMotion ?? false;

  @override
  bool updateShouldNotify(UiOptions oldWidget) => oldWidget.reducedMotion != reducedMotion;
}

/// Fade + rise entrance, optionally staggered behind earlier siblings.
///
/// Honours reduced motion by rendering the child immediately.
class Entrance extends StatefulWidget {
  const Entrance({
    super.key,
    required this.child,
    this.index = 0,
    this.delay,
    this.offset = 10,
  });

  final Widget child;

  /// Position in a group; multiplied by [Motion.stagger] for the delay.
  final int index;

  /// Explicit delay, overriding the [index]-derived stagger.
  final Duration? delay;

  /// Vertical travel in logical pixels.
  final double offset;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: Motion.entrance);
  late final Animation<double> _anim =
      CurvedAnimation(parent: _controller, curve: Motion.curve);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;

    if (UiOptions.reducedMotionOf(context)) {
      _controller.value = 1;
      return;
    }
    // Capped, so a page with many cards still settles promptly - see
    // Motion.staggerLimit.
    final delay = widget.delay ??
        Motion.stagger *
            (widget.index > Motion.staggerLimit
                ? Motion.staggerLimit
                : widget.index);
    if (delay == Duration.zero) {
      _controller.forward();
    } else {
      Future<void>.delayed(delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, child) {
        final v = _anim.value;
        // At rest, hand back the child untouched. Opacity composites its
        // subtree into an offscreen layer, and cards carry a gradient plus a
        // shadow: keeping the layer for the final frame and dropping it the
        // next makes the surface visibly shift colour.
        if (v >= 1) return child!;
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, widget.offset * (1 - v)),
            child: child,
          ),
        );
      },
      // Rasterise the card once and composite that, rather than redrawing its
      // gradient, shadow and text on every frame of the fade. Without this the
      // animation is doing real painting work each frame, which is what made it
      // stutter on the first pass through a screen - and Opacity skips painting
      // entirely at zero, so a card's first ever paint would otherwise land in
      // the middle of its own fade, at the worst possible moment.
      child: RepaintBoundary(child: widget.child),
    );
  }
}

/// Supplies hover and press state, plus a subtle press scale.
///
/// Colour changes are applied by the builder rather than tweened, which is what
/// keeps hover from flashing a bright frame on the way in.
///
/// This is also the one place the app's custom controls become accessible. A
/// bare [GestureDetector] is clickable with a mouse but invisible to a screen
/// reader's Tab key: it has no role and no focus node, so NVDA can only reach
/// the text inside it with object navigation. Everything interactive in this
/// app is built on this widget, so the semantics and the keyboard handling live
/// here rather than being repeated at each call site:
///
/// * one merged node per control, carrying its visible text as the label;
/// * a role — button by default, or checkbox / switch / selected option when
///   the caller passes the matching state;
/// * Enter and Space activation, the same as a native button;
/// * a focus node, so Tab and Shift+Tab walk the controls in reading order;
/// * keyboard focus reuses the hover treatment, so focus is visible.
class Hoverable extends StatefulWidget {
  const Hoverable({
    super.key,
    required this.builder,
    this.onTap,
    this.pressScale = 0.985,
    this.enabled = true,
    this.cursor = SystemMouseCursors.click,
    this.tooltip,
    this.semanticsLabel,
    this.isButton = true,
    this.checked,
    this.toggled,
    this.selected,
    this.expanded,
  });

  final Widget Function(bool hovered, bool pressed) builder;
  final VoidCallback? onTap;
  final double pressScale;
  final bool enabled;
  final MouseCursor cursor;

  /// Mouse tooltip. Kept out of semantics when [semanticsLabel] is null and the
  /// visible text already names the control.
  final String? tooltip;

  /// Label for a control whose text is not readable — an icon-only button.
  /// When set, the child's own text is excluded so it is not read twice.
  final String? semanticsLabel;

  /// Role. False for checkboxes, switches and option chips, which announce
  /// themselves by their state instead.
  final bool isButton;

  final bool? checked;
  final bool? toggled;
  final bool? selected;
  final bool? expanded;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  void _set({bool? hovered, bool? pressed, bool? focused}) {
    if (!mounted) return;
    setState(() {
      if (hovered != null) _hovered = hovered;
      if (pressed != null) _pressed = pressed;
      if (focused != null) _focused = focused;
    });
  }

  @override
  Widget build(BuildContext context) {
    final interactive = widget.enabled && (widget.onTap != null);
    final lit = interactive && (_hovered || _focused);
    Widget child = widget.builder(lit, interactive && _pressed);

    if (widget.pressScale != 1) {
      child = AnimatedScale(
        scale: interactive && _pressed ? widget.pressScale : 1.0,
        duration: Motion.fast,
        curve: Motion.curve,
        child: child,
      );
    }

    child = MouseRegion(
      cursor: interactive ? widget.cursor : MouseCursor.defer,
      onEnter: (_) => _set(hovered: true),
      onExit: (_) => _set(hovered: false, pressed: false),
      child: GestureDetector(
        onTapDown: interactive ? (_) => _set(pressed: true) : null,
        onTapUp: interactive ? (_) => _set(pressed: false) : null,
        onTapCancel: interactive ? () => _set(pressed: false) : null,
        onTap: interactive ? widget.onTap : null,
        child: child,
      ),
    );

    final tooltip = widget.tooltip;
    if (tooltip != null) {
      // Visual help only: the control's own node carries the label, so a screen
      // reader meets one control instead of a tooltip and a control.
      child = Tooltip(message: tooltip, excludeFromSemantics: true, child: child);
    }

    final label = widget.semanticsLabel;
    final hasState = widget.checked != null ||
        widget.toggled != null ||
        widget.selected != null ||
        widget.expanded != null;
    // Nothing to describe: a plain surface that only responds to hover.
    if (label == null && widget.onTap == null && !hasState) return child;

    if (label != null) child = ExcludeSemantics(child: child);

    final Widget semantics = Semantics(
      container: false,
      button: widget.isButton,
      enabled: interactive,
      // A disabled checkbox or switch still keeps focus, because the control
      // being disabled is usually the *result* of activating it ("busy") — and
      // dropping the focus node there sends the user's place in the form
      // somewhere else mid-action. A disabled button is not a Tab stop.
      focusable: interactive || hasState,
      label: label,
      tooltip: tooltip == label ? null : tooltip,
      // Declared here rather than left to the gesture recogniser, because an
      // explicit label excludes the child's own semantics — which is where the
      // recogniser's tap action would otherwise live.
      onTap: interactive ? widget.onTap : null,
      checked: widget.checked,
      toggled: widget.toggled,
      selected: widget.selected,
      expanded: widget.expanded,
      child: child,
    );

    // Nothing to focus and nothing to announce beyond the text itself.
    if (!interactive && !hasState) return MergeSemantics(child: semantics);

    return MergeSemantics(
      child: FocusableActionDetector(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent intent) {
              if (interactive) widget.onTap!();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (bool shown) => _set(focused: shown),
        child: semantics,
      ),
    );
  }
}
