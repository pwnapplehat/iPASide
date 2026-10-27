import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../viewmodels/device_selection.dart';
import '../theme/app_theme.dart';
import '../widgets/device_target.dart';
import '../widgets/motion.dart';
import '../widgets/surfaces.dart';
import 'nav_destination.dart';

/// Engine health shown in the sidebar footer.
enum EngineHealth { unknown, ready, offline }

/// Left navigation rail, with the device target and the engine status pinned to
/// the bottom.
///
/// The two footer lines answer the same question from either end — which phone is
/// this acting on, and is the engine behind it alive — so they sit together, below
/// a rule that marks them off from navigation. The device target is watched here
/// rather than passed down so that choosing a device repaints the sidebar and
/// nothing else.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.engineLabel,
    required this.health,
  });

  /// Null while a screen outside the sidebar (sign-in) is showing, which
  /// clears the selection exactly like the Avalonia build did.
  final NavKey? selected;
  final ValueChanged<NavKey> onSelect;
  final String engineLabel;
  final EngineHealth health;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Container(
      width: Sizes.sidebar,
      decoration: BoxDecoration(
        gradient: p.sidebarGradient,
        border: Border(right: BorderSide(color: p.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: Pad.sidebarList,
            // One group, so Tab walks the whole nav before it steps into the
            // page. Without it traversal follows reading order across the
            // window, which interleaves the rail with the screen beside it —
            // Tab from "LiveContainer" lands on a card, then back on
            // "Jailbreak".
            child: FocusTraversalGroup(
              child: Column(
                children: [
                  for (final destination in NavDestination.sidebar)
                    _SidebarItem(
                      destination: destination,
                      selected: destination.key == selected,
                      onTap: () => onSelect(destination.key),
                    ),
                ],
              ),
            ),
          ),
          const Spacer(),
          Container(height: Sizes.hairline, color: p.hairline),
          const SizedBox(height: Space.s2),
          DeviceTargetPanel(selection: context.watch<DeviceSelection>()),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.s5, Space.s2, Space.s5, Space.s5 - 2),
            child: Row(
              children: [
                StatusDot(
                  color: switch (health) {
                    EngineHealth.ready => p.success,
                    EngineHealth.offline => p.danger,
                    EngineHealth.unknown => p.textMuted,
                  },
                ),
                const SizedBox(width: Space.s2 + 1),
                Expanded(
                  child: Text(
                    engineLabel,
                    style: context.t.smallMuted,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final NavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Hoverable(
        onTap: onTap,
        pressScale: 1,
        // Current screen announced as selected rather than by colour alone.
        selected: selected,
        builder: (hovered, pressed) => AnimatedContainer(
          duration: Motion.fast,
          curve: Motion.curve,
          height: Sizes.sidebarItem,
          padding: Pad.listItem,
          decoration: BoxDecoration(
            color: selected
                ? p.accentSelection
                : pressed
                    ? p.surfacePressed
                    : hovered
                        ? p.surfaceHover
                        : Colors.transparent,
            borderRadius: Radii.rSmall,
          ),
          child: Row(
            children: [
              Icon(
                destination.icon,
                size: Sizes.icon,
                color: selected
                    ? p.accent
                    : hovered
                        ? p.textPrimary
                        : p.textSecondary,
              ),
              const SizedBox(width: Space.s3),
              Expanded(
                child: AnimatedDefaultTextStyle(
                  duration: Motion.fast,
                  style: context.t.body.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected || hovered ? p.textPrimary : p.textSecondary,
                  ),
                  child: Text(destination.label),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
