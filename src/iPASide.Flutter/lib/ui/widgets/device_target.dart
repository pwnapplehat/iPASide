import 'package:flutter/material.dart';

import '../../viewmodels/device_selection.dart';
import '../theme/app_theme.dart';
import 'motion.dart';
import 'progress.dart';
import 'surfaces.dart';

/// The glyph for an iPhone, used everywhere a device is named so the same thing
/// always looks like the same thing.
const IconData kDeviceIcon = Icons.smartphone_rounded;

/// A device's name over its transports, e.g. `iOS_hAT's iPhone` / `USB/Network`.
///
/// The name is on its own line and ellipsised, because a device name is
/// user-chosen and can be any length; the transports never wrap, because they are
/// two short words from a closed set.
class DeviceTargetLabel extends StatelessWidget {
  const DeviceTargetLabel({
    super.key,
    required this.device,
    this.selected = false,
  });

  final DeviceTarget device;

  /// Emphasises the name, for the row that is the current target.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final String transports = device.transportText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          device.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: selected
              ? context.t.small.copyWith(fontWeight: FontWeight.w600)
              : context.t.small,
        ),
        if (transports.isNotEmpty)
          Text(transports, style: context.t.faint, maxLines: 1),
      ],
    );
  }
}

/// One device in a list of them: the glyph, its label, and a tick when it is the
/// current target.
class DeviceTargetRow extends StatelessWidget {
  const DeviceTargetRow({
    super.key,
    required this.device,
    required this.selected,
    this.onTap,
    this.trailing,
  });

  final DeviceTarget device;
  final bool selected;
  final VoidCallback? onTap;

  /// Replaces the tick, for a row that needs its own affordance.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Hoverable(
      onTap: onTap,
      pressScale: 1,
      selected: selected,
      builder: (bool hovered, bool pressed) => AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        padding: Pad.listItem,
        decoration: BoxDecoration(
          color: selected
              ? p.accentSubtle
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
              kDeviceIcon,
              size: Sizes.icon,
              color: selected ? p.accent : p.textSecondary,
            ),
            const SizedBox(width: Space.s2 + 2),
            Expanded(
              child: DeviceTargetLabel(device: device, selected: selected),
            ),
            if (trailing case final Widget widget) ...[
              const SizedBox(width: Space.s2),
              widget,
            ] else if (selected) ...[
              const SizedBox(width: Space.s2),
              Icon(Icons.check_rounded, size: Sizes.icon, color: p.accent),
            ],
          ],
        ),
      ),
    );
  }
}

/// The app-wide device target, as it appears in the sidebar footer.
///
/// It lives in the chrome rather than on a screen because the target applies to
/// every screen at once — Sideload installs to it, Apps lists it, Home describes
/// it — and a control repeated on four screens is four places for them to
/// disagree. It sits directly above the engine status because they answer the
/// same question: what is iPASide talking to.
///
/// With one device this is a label, not a control: there is no choice to offer.
/// With several it expands into the list, in place, so choosing never covers the
/// screen the user is working on.
class DeviceTargetPanel extends StatefulWidget {
  const DeviceTargetPanel({super.key, required this.selection});

  final DeviceSelection selection;

  @override
  State<DeviceTargetPanel> createState() => _DeviceTargetPanelState();
}

class _DeviceTargetPanelState extends State<DeviceTargetPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final DeviceSelection selection = widget.selection;

    // A choice that no longer exists cannot stay open.
    final bool open = _open && selection.hasChoice;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, selection, open),
          if (open)
            for (final DeviceTarget device in selection.devices)
              DeviceTargetRow(
                device: device,
                selected: device.udid == selection.selectedUdid,
                onTap: () {
                  selection.select(device.udid);
                  setState(() => _open = false);
                },
              ),
        ],
      ),
    );
  }

  Widget _header(
    BuildContext context,
    DeviceSelection selection,
    bool open,
  ) {
    // The first enumeration is the only one worth a spinner: a later refresh
    // still has the previous list to show, and blanking it would look like the
    // device had gone.
    if (!selection.hasLoaded && selection.isLoading) {
      return _line(
        context,
        child: Row(
          children: [
            const Spinner(size: Sizes.spinnerSmall),
            const SizedBox(width: Space.s2 + 2),
            Expanded(
              child: Text(
                'Looking for devices\u2026',
                style: context.t.smallMuted,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    final DeviceTarget? selected = selection.selected;
    if (selected == null) {
      return _line(
        context,
        tooltip: selection.error,
        child: Row(
          children: [
            Icon(
              kDeviceIcon,
              size: Sizes.icon,
              color: context.palette.textMuted,
            ),
            const SizedBox(width: Space.s2 + 2),
            Expanded(
              child: Text(
                selection.hasError ? "Couldn't list devices" : 'No device',
                style: context.t.smallMuted,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    if (!selection.hasChoice) {
      return _line(
        context,
        tooltip: selected.udid,
        child: Row(
          children: [
            Icon(
              kDeviceIcon,
              size: Sizes.icon,
              color: context.palette.textSecondary,
            ),
            const SizedBox(width: Space.s2 + 2),
            Expanded(child: DeviceTargetLabel(device: selected)),
          ],
        ),
      );
    }

    return DeviceTargetRow(
      device: selected,
      selected: false,
      onTap: () => setState(() => _open = !_open),
      trailing: Row(
        children: [
          Text('${selection.devices.length}', style: context.t.faint),
          const SizedBox(width: Space.s1),
          AnimatedRotation(
            turns: open ? 0.5 : 0,
            duration: Motion.fast,
            curve: Motion.curve,
            child: Icon(
              Icons.expand_more_rounded,
              size: Sizes.icon,
              color: context.palette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// A non-interactive header line, padded to match [DeviceTargetRow] so the
  /// panel does not shift when the number of devices changes.
  Widget _line(
    BuildContext context, {
    required Widget child,
    String? tooltip,
  }) {
    final Widget line = Padding(padding: Pad.listItem, child: child);
    return tooltip == null || tooltip.isEmpty
        ? line
        : Tooltip(message: tooltip, child: line);
  }
}

/// The install target, on the Sideload screen.
///
/// The sidebar already carries the app-wide target, but this is the one screen
/// where getting it wrong writes to the wrong phone, so it is stated again in
/// front of the button that does it — and when there is a choice, made here
/// rather than sending the user to the sidebar mid-task.
class DeviceTargetBar extends StatelessWidget {
  const DeviceTargetBar({super.key, required this.selection});

  final DeviceSelection selection;

  @override
  Widget build(BuildContext context) {
    // Nothing is claimed before the first enumeration answers: "no iPhone
    // connected" would be a lie for the second it takes to find out.
    if (!selection.hasLoaded) return const SizedBox.shrink();

    final DeviceTarget? selected = selection.selected;
    if (selected == null) {
      return Alert(
        kind: AlertKind.warning,
        message: selection.hasError
            ? selection.error
            : 'No iPhone connected. Plug one in, unlock it, and tap Trust.',
      );
    }

    if (!selection.hasChoice) {
      return AppCard(
        padding: Pad.card,
        shadow: false,
        child: Row(
          children: [
            Icon(
              kDeviceIcon,
              size: Sizes.icon,
              color: context.palette.textSecondary,
            ),
            const SizedBox(width: Space.s3),
            Text('Installing to', style: context.t.smallMuted),
            const SizedBox(width: Space.s2),
            Expanded(
              child: Text(
                selected.label,
                style: context.t.semi(FontSizes.small),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (selected.transportText.isNotEmpty)
              MetaChip(selected.transportText),
          ],
        ),
      );
    }

    return AppCard(
      padding: Pad.card,
      shadow: false,
      // Accented, not plain: with two phones plugged in, which one is about to
      // receive the install is the single most important thing on this screen.
      borderColor: context.palette.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(kDeviceIcon, size: Sizes.icon, color: context.palette.accent),
              const SizedBox(width: Space.s3),
              Text(
                '${selection.devices.length} iPhones connected \u2014 '
                'choose which one to install to',
                style: context.t.semi(FontSizes.small),
              ),
            ],
          ),
          const SizedBox(height: Space.s3),
          Wrap(
            spacing: Space.s2,
            runSpacing: Space.s2,
            children: [
              for (final DeviceTarget device in selection.devices)
                _DeviceChoiceChip(
                  device: device,
                  selected: device.udid == selection.selectedUdid,
                  onTap: () => selection.select(device.udid),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One device as a picker chip: filled when it is the target, outlined when it is
/// the alternative.
class _DeviceChoiceChip extends StatelessWidget {
  const _DeviceChoiceChip({
    required this.device,
    required this.selected,
    required this.onTap,
  });

  final DeviceTarget device;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Hoverable(
      onTap: onTap,
      pressScale: 0.98,
      tooltip: device.udid,
      selected: selected,
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.check_circle_rounded : kDeviceIcon,
              size: Sizes.icon,
              color: selected ? p.accent : p.textSecondary,
            ),
            const SizedBox(width: Space.s2 + 2),
            DeviceTargetLabel(device: device, selected: selected),
          ],
        ),
      ),
    );
  }
}
