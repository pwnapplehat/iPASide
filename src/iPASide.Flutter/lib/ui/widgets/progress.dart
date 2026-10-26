import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Rotating arc. Hand-painted rather than [CircularProgressIndicator] so the
/// stroke and sweep stay fixed regardless of Material's own defaults.
class Spinner extends StatefulWidget {
  const Spinner({super.key, this.size = Sizes.spinner, this.color, this.strokeWidth = 2.2});

  final double size;
  final Color? color;
  final double strokeWidth;

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: Motion.spin)..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
        turns: _controller,
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _ArcPainter(
            color: widget.color ?? context.palette.accent,
            strokeWidth: widget.strokeWidth,
          ),
        ),
      );
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final rect = Offset(strokeWidth / 2, strokeWidth / 2) &
        Size(size.width - strokeWidth, size.height - strokeWidth);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 1.55, false, paint);
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) =>
      old.color != color || old.strokeWidth != strokeWidth;
}

/// Spinner plus label: what a card, a list or a section shows while it waits on
/// the engine.
///
/// Shared rather than rebuilt per screen — it had been hand-rolled four times
/// with two different gaps and the size written out as a bare number, so the same
/// wait looked slightly different depending on which screen you were on.
class LoadingLine extends StatelessWidget {
  const LoadingLine({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Spinner(size: Sizes.spinnerSmall),
          const SizedBox(width: Space.s2 + 2),
          Expanded(
            child: Text(
              label,
              style: context.t.bodyMuted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
}

/// Accent progress bar. Determinate animates its width; indeterminate sweeps a
/// segment left to right.
class AppProgressBar extends StatefulWidget {
  const AppProgressBar({
    super.key,
    this.value = 0,
    this.indeterminate = false,
    this.tone,
    this.height = Sizes.progressBar,
  });

  /// 0–100, matching the engine's percentages.
  final double value;
  final bool indeterminate;

  /// Overrides the accent gradient (used for the failed state).
  final Color? tone;
  final double height;

  @override
  State<AppProgressBar> createState() => _AppProgressBarState();
}

class _AppProgressBarState extends State<AppProgressBar> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    if (widget.indeterminate) _sweep.repeat();
  }

  @override
  void didUpdateWidget(AppProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.indeterminate && !_sweep.isAnimating) {
      _sweep.repeat();
    } else if (!widget.indeterminate && _sweep.isAnimating) {
      _sweep.stop();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final fill = widget.tone == null
        ? p.accentGradient
        : LinearGradient(colors: [widget.tone!, widget.tone!]);

    return ClipRRect(
      borderRadius: Radii.rFull,
      child: Container(
        height: widget.height,
        decoration: BoxDecoration(color: p.inputBg, borderRadius: Radii.rFull),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            if (widget.indeterminate) {
              // Travel from fully off-screen left to fully off-screen right so
              // the loop restarts out of sight. Aligning the segment inside the
              // track instead parks it against the right edge and then snaps it
              // back, which reads as a stutter every cycle.
              final segmentWidth = width * 0.35;
              final travel = width + segmentWidth;
              return SizedBox.expand(
                child: AnimatedBuilder(
                  animation: _sweep,
                  builder: (_, _) => Stack(
                    children: [
                      Positioned(
                        left: -segmentWidth + _sweep.value * travel,
                        top: 0,
                        bottom: 0,
                        width: segmentWidth,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: fill,
                            borderRadius: Radii.rFull,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
            return Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: Motion.base,
                curve: Motion.curve,
                width: width * (widget.value.clamp(0, 100) / 100),
                decoration: BoxDecoration(
                  gradient: fill,
                  borderRadius: Radii.rFull,
                  boxShadow: widget.tone == null ? p.accentGlow : const [],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Provision → Sign → Install progress, mirroring the Avalonia `StepperControl`.
///
/// Connectors stretch to fill the card (the Avalonia version used a fixed 24px
/// connector); everything else — dot states, percent suppression while
/// indeterminate, spinner hiding on completion or error — matches it.
class SideloadStepper extends StatelessWidget {
  const SideloadStepper({
    super.key,
    this.steps = defaultSteps,
    this.activeIndex = 0,
    this.stepText,
    this.percent = 0,
    this.isIndeterminate = true,
    this.isComplete = false,
    this.hasError = false,
  });

  static const List<String> defaultSteps = ['Provision', 'Sign', 'Install'];

  final List<String> steps;
  final int activeIndex;
  final String? stepText;
  final double percent;
  final bool isIndeterminate;
  final bool isComplete;
  final bool hasError;

  bool _isDone(int i) => isComplete || i < activeIndex;
  bool _isActive(int i) => !isComplete && i == activeIndex;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final showPercent = isComplete || !isIndeterminate;
    final shownPercent = isComplete ? 100.0 : percent.clamp(0, 100);
    final textColor = hasError
        ? p.danger
        : isComplete
            ? p.success
            : p.textPrimary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              _StepMarker(
                label: steps[i],
                done: _isDone(i),
                active: _isActive(i),
                hasError: hasError && _isActive(i),
              ),
              if (i < steps.length - 1) _Connector(filled: _isDone(i + 1) || _isDone(i)),
            ],
          ],
        ),
        const SizedBox(height: Space.s5),
        Row(
          children: [
            if (!isComplete && !hasError)
              Spinner(size: Sizes.spinner - 1, color: p.accent)
            else
              Icon(
                hasError ? Icons.error_outline_rounded : Icons.check_circle_rounded,
                size: Sizes.icon + 1,
                color: hasError ? p.danger : p.success,
              ),
            const SizedBox(width: Space.s3),
            Expanded(
              // The run reports itself as it goes; without a live region a
              // screen-reader user has to hunt for the current step after every
              // press, and an install looks like it did nothing.
              child: Semantics(
                liveRegion: true,
                child: AnimatedSwitcher(
                  duration: Motion.base,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [...previous, ?current],
                  ),
                  child: Text(
                    stepText ?? '',
                    key: ValueKey(stepText),
                    style: context.t.body.copyWith(color: textColor),
                  ),
                ),
              ),
            ),
            if (showPercent) ...[
              const SizedBox(width: Space.s3),
              Text(
                '${shownPercent.round()}%',
                style: context.t.semi(FontSizes.small).copyWith(color: textColor),
              ),
            ],
          ],
        ),
        const SizedBox(height: Space.s3),
        AppProgressBar(
          value: shownPercent.toDouble(),
          indeterminate: !isComplete && !hasError && isIndeterminate,
          tone: hasError ? p.danger : null,
        ),
      ],
    );
  }
}

class _StepMarker extends StatelessWidget {
  const _StepMarker({
    required this.label,
    required this.done,
    required this.active,
    required this.hasError,
  });

  final String label;
  final bool done;
  final bool active;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final lit = done || active;
    final ring = hasError
        ? p.danger
        : lit
            ? p.accent
            : p.hairlineStrong;

    final state = hasError && active
        ? 'failed'
        : done
            ? 'done'
            : active
                ? 'in progress'
                : 'pending';

    return Semantics(
      // The dot encodes the state in colour and a tick; without this a screen
      // reader hears three step names and cannot tell which one is running.
      label: '$label, $state',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: Motion.base,
              curve: Motion.curve,
              width: Sizes.stepDot + (lit ? 6 : 4),
              height: Sizes.stepDot + (lit ? 6 : 4),
              decoration: BoxDecoration(
                color: done ? (hasError ? p.danger : p.accent) : (active ? p.accentSubtle : null),
                shape: BoxShape.circle,
                border: Border.all(color: ring, width: Sizes.strokeStepDot),
                boxShadow: active && !hasError ? p.accentGlow : const [],
              ),
              child: done
                  ? Icon(Icons.check_rounded, size: 11, color: p.onAccent)
                  : null,
            ),
            const SizedBox(width: Space.s2),
            AnimatedDefaultTextStyle(
              duration: Motion.base,
              style: lit
                  ? context.t.semi(FontSizes.small)
                  : context.t.smallMuted,
              child: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}

class _Connector extends StatelessWidget {
  const _Connector({required this.filled});

  final bool filled;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.s3),
        child: Stack(
          children: [
            Container(height: Sizes.stepConnectorThickness, color: p.hairlineStrong),
            AnimatedFractionallySizedBox(
              duration: const Duration(milliseconds: 420),
              curve: Motion.curve,
              widthFactor: filled ? 1 : 0,
              child: Container(
                height: Sizes.stepConnectorThickness,
                decoration: BoxDecoration(gradient: p.accentGradient),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
