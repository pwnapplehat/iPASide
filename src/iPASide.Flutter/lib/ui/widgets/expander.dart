import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'motion.dart';

/// Collapsible section with a rotating chevron — used for "Advanced options".
class Expander extends StatelessWidget {
  const Expander({
    super.key,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
    this.icon,
  });

  final String title;
  final bool expanded;
  final ValueChanged<bool> onToggle;
  final Widget child;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Hoverable(
          onTap: () => onToggle(!expanded),
          pressScale: 1,
          // Says whether the section is open, not just that it is clickable.
          expanded: expanded,
          builder: (hovered, _) => AnimatedContainer(
            duration: Motion.fast,
            curve: Motion.curve,
            padding: Pad.expanderHeader,
            decoration: BoxDecoration(
              color: hovered ? p.surfaceHover : Colors.transparent,
              borderRadius: Radii.rMedium,
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: Sizes.icon, color: p.textSecondary),
                  const SizedBox(width: Space.s2 + 1),
                ],
                Expanded(child: Text(title, style: context.t.semi(FontSizes.body + 0.5))),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: Motion.base,
                  curve: Motion.curve,
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: Sizes.iconLarge,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
        ClipRect(
          child: AnimatedAlign(
            alignment: Alignment.topCenter,
            heightFactor: expanded ? 1 : 0,
            duration: Motion.page,
            curve: Motion.curve,
            child: AnimatedOpacity(
              opacity: expanded ? 1 : 0,
              duration: Motion.base,
              // A collapsed section is zero-height but still in the tree, so
              // without this its controls stay Tab stops and stay readable —
              // a screen reader would walk into a panel nobody can see.
              child: ExcludeFocus(
                excluding: !expanded,
                child: ExcludeSemantics(excluding: !expanded, child: child),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
