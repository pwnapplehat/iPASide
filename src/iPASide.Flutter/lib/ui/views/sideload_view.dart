import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../viewmodels/apple_support_view_model.dart';
import '../../viewmodels/device_selection.dart';
import '../../viewmodels/sideload_view_model.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icon_image.dart';
import '../widgets/apple_support_banner.dart';
import '../widgets/buttons.dart';
import '../widgets/device_target.dart';
import '../widgets/expander.dart';
import '../widgets/inputs.dart';
import '../widgets/motion.dart';
import '../widgets/progress.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/surfaces.dart';

/// Sideload: choose an IPA, tune the options, run Provision → Sign → Install.
///
/// The view model is app-scoped rather than created here, so the session
/// survives navigating away and back.
class SideloadView extends StatefulWidget {
  const SideloadView({super.key});

  @override
  State<SideloadView> createState() => _SideloadViewState();
}

class _SideloadViewState extends State<SideloadView> {
  /// Held here rather than left to [SmoothScrollView] because the run scrolls
  /// the view itself; it still smooths the wheel. Built on the first dependency
  /// pass, which is where the reduced-motion flag becomes readable.
  SmoothScrollController? _scroll;
  SideloadViewModel? _vm;
  bool _wasShowingStepper = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scroll ??= SmoothScrollController(
      reducedMotion: UiOptions.reducedMotionOf(context),
    );
    final vm = context.read<SideloadViewModel>();
    if (!identical(vm, _vm)) {
      _vm?.removeListener(_onModelChanged);
      _vm = vm..addListener(_onModelChanged);
      _wasShowingStepper = vm.showStepper;
    }
  }

  @override
  void dispose() {
    _vm?.removeListener(_onModelChanged);
    _scroll?.dispose();
    super.dispose();
  }

  /// Follow the run: reveal the stepper when it appears, and the outcome when
  /// it lands.
  void _onModelChanged() {
    final showing = _vm?.showStepper ?? false;
    if (showing && !_wasShowingStepper) _revealBottom();
    if (showing && (_vm!.isSucceeded || _vm!.isFailed)) _revealBottom();
    _wasShowingStepper = showing;
  }

  void _revealBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final scroll = _scroll;
      if (scroll == null || !scroll.hasClients) return;
      scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 520),
        curve: Motion.curve,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SideloadViewModel>();
    final apple = context.watch<AppleSupportViewModel>();

    return SmoothScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(Space.s6, Space.s5, Space.s6, Space.s7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Entrance(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sideload an app', style: context.t.display),
                const SizedBox(height: Space.s1 + 2),
                Text(
                  'Choose an .ipa \u2014 iPASide signs it with your Apple ID and '
                  'installs it to your iPhone.',
                  style: context.t.bodyMuted,
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.s5),
          // Before the dropzone, not after the failure: without Apple's device
          // service there is no transport to any phone, so choosing an IPA and
          // pressing the button could only ever end in an error nobody can act on.
          if (apple.hasNotice) ...[
            Entrance(child: AppleSupportBanner(model: apple)),
            const SizedBox(height: Space.s5),
          ],
          if (vm.showDropzone)
            Entrance(
              index: 1,
              child: Dropzone(
                onTap: vm.choose,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      size: Sizes.iconXl,
                      color: context.palette.textMuted,
                    ),
                    const SizedBox(width: Space.s4 + 2),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Choose an .ipa file', style: context.t.semi(FontSizes.body + 0.5)),
                        const SizedBox(height: Space.s1),
                        Text('or drag & drop it here', style: context.t.smallMuted),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (vm.isInspecting)
            Entrance(
              index: 1,
              child: AppCard(
                child: Row(
                  children: [
                    const Spinner(),
                    const SizedBox(width: Space.s3),
                    Text(vm.inspectingText, style: context.t.body),
                  ],
                ),
              ),
            ),
          if (vm.hasInspectError) ...[
            const SizedBox(height: Space.s4),
            Entrance(
              index: 1,
              child: Alert(
                kind: AlertKind.danger,
                title: 'Could not read this IPA',
                message: vm.inspectError,
              ),
            ),
          ],
          if (vm.hasIpa) ...[
            Entrance(index: 1, child: _AppCard(vm: vm)),
            if (vm.isBlocked) ...[
              const SizedBox(height: Space.s4),
              const Entrance(
                index: 2,
                child: Alert(
                  kind: AlertKind.danger,
                  title: "Can't sideload this app",
                  message: "It's App Store-encrypted (FairPlay). Use a decrypted IPA.",
                ),
              ),
            ],
          ],
          if (vm.showSideloadArea) ...[
            const SizedBox(height: Space.s4),
            Entrance(index: 2, child: _AdvancedSection(vm: vm)),
            const SizedBox(height: Space.s4),
            // Directly above the button that acts on it: this is the last thing
            // read before an install, and the only screen where getting the
            // target wrong writes to the wrong phone.
            Entrance(
              index: 3,
              child: vm.exportOnly
                  ? const SizedBox.shrink()
                  : DeviceTargetBar(
                      selection: context.watch<DeviceSelection>(),
                    ),
            ),
            const SizedBox(height: Space.s4),
            Entrance(
              index: 4,
              child: AppButton(
                label: vm.actionLabel,
                icon: vm.exportOnly
                    ? Icons.ios_share_rounded
                    : Icons.download_rounded,
                tone: ButtonTone.primary,
                busy: vm.isRunning,
                // Held shut while Apple's service is down, with the banner above
                // saying why and offering the fix: an install cannot reach a phone
                // at all in that state, and letting it start would replace a fixable
                // explanation with a usbmux error.
                onPressed: vm.isRunning ||
                        (!vm.exportOnly && apple.blocksDevices)
                    ? null
                    : vm.sideload,
                tooltip: vm.exportOnly
                    ? (vm.isRunning ? 'An export is already running' : null)
                    : apple.blocksDevices
                        ? apple.usbBlockedReason
                        : vm.isRunning
                            ? 'A sideload is already running'
                            : null,
              ),
            ),
            if (vm.showStepper) ...[
              const SizedBox(height: Space.s5),
              AppCard(
                child: SideloadStepper(
                  activeIndex: vm.activeStepIndex,
                  stepText: vm.stepText,
                  percent: vm.percent,
                  isIndeterminate: vm.isProgressIndeterminate,
                  isComplete: vm.isInstallComplete,
                  hasError: vm.isFailed,
                ),
              ),
            ],
            if (vm.isSucceeded) ...[
              const SizedBox(height: Space.s4),
              Alert(
                kind: AlertKind.success,
                title: vm.successTitle,
                message: vm.exportMessage,
                body: vm.exportMessage == null ? _TrustHint() : null,
              ),
            ],
            if (vm.isUnexpected) ...[
              const SizedBox(height: Space.s4),
              const Alert(
                kind: AlertKind.warning,
                title: 'Unexpected response from the engine',
              ),
            ],
            if (vm.isFailed) ...[
              const SizedBox(height: Space.s4),
              Alert(
                kind: AlertKind.danger,
                title: vm.failureTitle,
                message: vm.failureMessage,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// "On your iPhone, open Settings ▸ General ▸ VPN & Device Management and tap
/// Trust to launch it." with the path and action emphasised.
class _TrustHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final strong = TextStyle(
      fontWeight: FontWeight.w600,
      color: context.palette.textPrimary,
    );
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(text: 'On your iPhone, open '),
          TextSpan(
            text: 'Settings \u25B8 General \u25B8 VPN & Device Management',
            style: strong,
          ),
          const TextSpan(text: ' and tap '),
          TextSpan(text: 'Trust', style: strong),
          const TextSpan(text: ' to launch it.'),
        ],
      ),
      style: context.t.small,
    );
  }
}

/// The selected app: icon, names, file, metadata chips and Change.
class _AppCard extends StatelessWidget {
  const _AppCard({required this.vm});

  final SideloadViewModel vm;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIconImage(bytes: vm.iconBytes),
                const SizedBox(width: Space.s4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(vm.displayName, style: context.t.title),
                      const SizedBox(height: 2),
                      Text(vm.bundleId, style: context.t.mono),
                      const SizedBox(height: 2),
                      Text(vm.fileName, style: context.t.faint),
                    ],
                  ),
                ),
                const SizedBox(width: Space.s3),
                AppButton(
                  label: 'Change',
                  compact: true,
                  // A run cannot be cancelled, so the selection is locked while
                  // one is in flight.
                  onPressed: vm.isRunning ? null : vm.change,
                  tooltip: vm.isRunning ? 'Wait for the current sideload to finish' : null,
                ),
              ],
            ),
            const SizedBox(height: Space.s4),
            Wrap(
              spacing: Space.s2 + 1,
              runSpacing: Space.s2 + 1,
              children: [
                MetaChip(vm.versionChip),
                MetaChip(vm.minOsChip),
                MetaChip(vm.frameworksChip),
                MetaChip(vm.extensionsChip),
              ],
            ),
          ],
        ),
      );
}

/// Advanced options: overrides, signing switches and injected tweaks.
class _AdvancedSection extends StatefulWidget {
  const _AdvancedSection({required this.vm});

  final SideloadViewModel vm;

  @override
  State<_AdvancedSection> createState() => _AdvancedSectionState();
}

class _AdvancedSectionState extends State<_AdvancedSection> {
  late final TextEditingController _bundleId =
      TextEditingController(text: widget.vm.bundleIdOverride);
  late final TextEditingController _name =
      TextEditingController(text: widget.vm.nameOverride);

  @override
  void didUpdateWidget(_AdvancedSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Choosing a different IPA clears the overrides in the model; mirror that
    // into the fields without disturbing an in-progress edit.
    if (_bundleId.text != widget.vm.bundleIdOverride && widget.vm.bundleIdOverride.isEmpty) {
      _bundleId.clear();
    }
    if (_name.text != widget.vm.nameOverride && widget.vm.nameOverride.isEmpty) {
      _name.clear();
    }
  }

  @override
  void dispose() {
    _bundleId.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;

    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: Space.s1, vertical: Space.s1),
      child: Expander(
        title: 'Advanced options',
        icon: Icons.tune_rounded,
        expanded: vm.advancedOpen,
        onToggle: (open) => vm.advancedOpen = open,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.s4, Space.s2, Space.s4, Space.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppTextField(
                      label: 'Bundle identifier',
                      hint: 'Automatic (team-scoped)',
                      controller: _bundleId,
                      onChanged: (value) => vm.bundleIdOverride = value,
                    ),
                  ),
                  const SizedBox(width: Space.s4),
                  Expanded(
                    child: AppTextField(
                      label: 'Display name',
                      hint: vm.namePlaceholder,
                      controller: _name,
                      onChanged: (value) => vm.nameOverride = value,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.s4),
              AppCheckbox(
                label: 'Remove all extensions',
                value: vm.removeExtensions,
                onChanged: (value) => vm.removeExtensions = value,
              ),
              if (!vm.removeExtensions && vm.availableExtensions.isNotEmpty) ...[
                const SizedBox(height: Space.s2),
                Text(
                  'Kept extensions stay in the IPA and are signed with this app\'s profile. '
                  'A free Apple ID can still refuse an extension.',
                  style: context.t.smallMuted,
                ),
                for (final String extension in vm.availableExtensions)
                  AppCheckbox(
                    label: 'Keep $extension',
                    value: vm.keepsExtension(extension),
                    onChanged: (value) => vm.setExtensionKept(extension, value),
                  ),
                AppCheckbox(
                  label: 'Own App ID for each kept extension',
                  value: vm.ownExtensionAppIds,
                  onChanged: (value) => vm.ownExtensionAppIds = value,
                ),
              ],
              AppCheckbox(
                label: 'Remove device restrictions',
                value: vm.removeDeviceRestrictions,
                onChanged: (value) => vm.removeDeviceRestrictions = value,
              ),
              AppCheckbox(
                label: 'Enable file sharing (Files app)',
                value: vm.enableFileSharing,
                onChanged: (value) => vm.enableFileSharing = value,
              ),
              const SizedBox(height: Space.s3),
              AppCheckbox(
                label: 'Export unsigned IPA only',
                value: vm.exportOnly,
                onChanged: (value) => vm.exportOnly = value,
              ),
              Text(
                'Applies these options and tweaks, then saves an unsigned .ipa. '
                'No Apple ID, device, or certificate. Sign and install it with another tool.',
                style: context.t.smallMuted,
              ),
              const SizedBox(height: Space.s4),
              Container(height: Sizes.hairline, color: context.palette.hairline),
              const SizedBox(height: Space.s4),
              Row(
                children: [
                  Text('Injected tweaks', style: context.t.semi(FontSizes.body)),
                  const SizedBox(width: Space.s2),
                  Text('(.deb / .dylib)', style: context.t.smallMuted),
                  const Spacer(),
                  AppButton(
                    label: 'Add tweak',
                    icon: Icons.add_rounded,
                    compact: true,
                    onPressed: vm.addTweaksFromPicker,
                  ),
                ],
              ),
              if (vm.hasTweaks) ...[
                const SizedBox(height: Space.s3),
                for (final row in vm.tweaks) _TweakRowTile(row: row, vm: vm),
                const SizedBox(height: Space.s2),
                AppCheckbox(
                  label: 'Inject as weak references',
                  value: vm.weakDylibs,
                  onChanged: (value) => vm.weakDylibs = value,
                ),
                AppCheckbox(
                  label: 'Use ElleKit instead of CydiaSubstrate',
                  value: vm.useEllekit,
                  onChanged: (value) => vm.useEllekit = value,
                ),
              ],
              const SizedBox(height: Space.s3),
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Drop '),
                    TextSpan(text: '.deb', style: context.t.mono),
                    const TextSpan(text: ' or '),
                    TextSpan(text: '.dylib', style: context.t.mono),
                    const TextSpan(
                      text: ' files here \u2014 dylibs are pulled out of .debs automatically.',
                    ),
                  ],
                ),
                style: context.t.smallMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TweakRowTile extends StatelessWidget {
  const _TweakRowTile({required this.row, required this.vm});

  final TweakRow row;
  final SideloadViewModel vm;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Space.s2),
        child: Container(
          padding: const EdgeInsets.fromLTRB(Space.s3, Space.s2, Space.s2, Space.s2),
          decoration: BoxDecoration(
            color: context.palette.bg2,
            borderRadius: Radii.rSmall,
            border: Border.all(color: context.palette.hairline),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  row.name,
                  style: context.t.small,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Space.s2),
              MetaChip(row.archText),
              if (row.hasSource) ...[
                const SizedBox(width: Space.s2),
                Text(row.fromDebText!, style: context.t.faint),
              ],
              const SizedBox(width: Space.s2),
              GhostIconButton(
                icon: Icons.close_rounded,
                tooltip: 'Remove',
                width: 26,
                height: 26,
                onPressed: () => vm.removeTweak(row),
              ),
            ],
          ),
        ),
      );
}
