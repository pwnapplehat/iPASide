import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/engine.dart';
import '../../viewmodels/live_container_view_model.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icon_image.dart';
import '../widgets/buttons.dart';
import '../widgets/motion.dart';
import '../widgets/progress.dart';
import '../widgets/smooth_scroll.dart';
import '../widgets/surfaces.dart';

/// LiveContainer: run more than three sideloaded apps by running them inside one.
class LiveContainerView extends StatefulWidget {
  const LiveContainerView({super.key});

  @override
  State<LiveContainerView> createState() => _LiveContainerViewState();
}

class _LiveContainerViewState extends State<LiveContainerView> {
  @override
  void initState() {
    super.initState();
    // The model is app-scoped, so it may already hold a status - or a run in
    // flight - from an earlier visit. Refreshing on arrival keeps what is drawn
    // true to the device without disturbing either.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<LiveContainerViewModel>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final LiveContainerViewModel vm = context.watch<LiveContainerViewModel>();

    return SmoothScrollView(
      padding: Pad.page,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Sizes.contentMax),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Entrance(child: _Header()),
              const SizedBox(height: Space.s5),
              Entrance(index: 1, child: _StatusCard(vm: vm)),
              if (vm.showStepper) ...<Widget>[
                const SizedBox(height: Space.s5),
                Entrance(index: 2, child: _RunCard(vm: vm)),
              ],
              if (vm.isInstalled) ...<Widget>[
                const SizedBox(height: Space.s5),
                Entrance(index: 3, child: _GuestApps(vm: vm)),
              ],
              if (vm.hasSideStore) ...<Widget>[
                const SizedBox(height: Space.s5),
                Entrance(index: 4, child: _SideStoreCard(vm: vm)),
              ],
              const SizedBox(height: Space.s5),
              const Entrance(index: 5, child: _ExplainerCard()),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('LiveContainer', style: context.t.display),
          const SizedBox(height: Space.s1),
          Text(
            'Run more than three sideloaded apps, by running them inside one.',
            style: context.t.bodyMuted,
          ),
        ],
      );
}

/// What the device says, and the button that changes it.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.vm});

  final LiveContainerViewModel vm;

  @override
  Widget build(BuildContext context) {
    if (vm.error != null) {
      return Alert(
        kind: AlertKind.danger,
        title: "Couldn't read your iPhone",
        message: vm.error!,
      );
    }

    final bool checking = vm.isLoading && vm.status == null;
    return StatusCard(
      label: 'STATUS',
      footer: _Action(vm: vm),
      // The icon is a bundled asset with no dependency on the device, so it is drawn
      // from the first frame - during the initial check, and whether or not
      // LiveContainer is installed. It is the same app either way, and seeing it is most
      // useful before you have it. Only the text beside it waits on the phone.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const AppIconImage.asset('assets/brand/livecontainer.png'),
          const SizedBox(width: Space.s4),
          Expanded(
            child: checking
                ? const LoadingLine(label: 'Checking your iPhone\u2026')
                : _StatusBody(vm: vm),
          ),
        ],
      ),
    );
  }
}

class _StatusBody extends StatelessWidget {
  const _StatusBody({required this.vm});

  final LiveContainerViewModel vm;

  @override
  Widget build(BuildContext context) {
    if (!vm.isInstalled) {
      return Row(
        children: <Widget>[
          const Pill(label: 'Not installed', kind: PillKind.neutral),
          const SizedBox(width: Space.s3),
          Expanded(
            child: Text(
              'iPASide will fetch the latest release, sign it, and set it up.',
              style: context.t.bodyMuted,
            ),
          ),
        ],
      );
    }

    final String version = vm.status?.version ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Pill(
              label: vm.needsLaunch ? 'Open it once' : 'Ready',
              kind: vm.needsLaunch ? PillKind.warn : PillKind.ok,
            ),
            const SizedBox(width: Space.s3),
            Text(
              version.isEmpty ? 'Installed' : 'Version $version',
              style: context.t.bodyMuted,
            ),
          ],
        ),
        const SizedBox(height: Space.s3),
        Text(
          vm.needsLaunch
              ? 'Open LiveContainer on your iPhone once. It imports the signing '
                  'certificate itself, and JIT-less mode is then ready.'
              : 'Set up and signing on device. Add apps to it from LiveContainer '
                  'itself, and they will not count against your three slots.',
          style: context.t.bodyMuted,
        ),
      ],
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.vm});

  final LiveContainerViewModel vm;

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          AppButton(
            label: vm.isInstalled ? 'Reinstall' : 'Install LiveContainer',
            icon: vm.isInstalled ? Icons.refresh_rounded : Icons.download_rounded,
            tone: vm.isInstalled ? ButtonTone.soft : ButtonTone.primary,
            busy: vm.isRunning,
            onPressed: vm.isRunning ? null : vm.setUp,
          ),
          const SizedBox(width: Space.s3),
          AppButton(
            label: 'Refresh',
            icon: Icons.sync_rounded,
            compact: true,
            busy: vm.isLoading,
            onPressed: vm.isRunning || vm.isLoading ? null : vm.load,
          ),
        ],
      );
}

/// The stepper, and whatever the finished run has to say.
class _RunCard extends StatelessWidget {
  const _RunCard({required this.vm});

  final LiveContainerViewModel vm;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppCard(
            child: SideloadStepper(
              steps: LiveContainerViewModel.schedule.steps,
              activeIndex: vm.progress.activeIndex,
              stepText: vm.progress.stepText,
              percent: vm.progress.percent,
              isIndeterminate: vm.progress.isIndeterminate,
              isComplete: vm.isSucceeded,
              hasError: vm.isFailed,
            ),
          ),
          if (vm.isFailed) ...<Widget>[
            const SizedBox(height: Space.s4),
            Alert(
              kind: AlertKind.danger,
              title: "LiveContainer wasn't set up",
              message: vm.failureMessage!,
            ),
          ],
          if (vm.isSucceeded) ...<Widget>[
            const SizedBox(height: Space.s4),
            // Installed is not the same as finished here: the certificate import
            // happens inside LiveContainer, on its next launch. Saying "done"
            // without saying that would leave JIT-less mode quietly unavailable.
            Alert(
              kind: vm.manualInstructions != null
                  ? AlertKind.warning
                  : AlertKind.success,
              title: 'Installed LiveContainer${_version(vm)}',
              message: vm.manualInstructions ??
                  'Open it on your iPhone once to finish. It imports the signing '
                      'certificate itself, then it can sign apps on device.',
            ),
          ],
        ],
      );

  static String _version(LiveContainerViewModel vm) {
    final String? version = vm.result?.version;
    return version == null || version.isEmpty ? '' : ' $version';
  }
}

/// The apps running inside LiveContainer - the point of the whole screen.
class _GuestApps extends StatelessWidget {
  const _GuestApps({required this.vm});

  final LiveContainerViewModel vm;

  @override
  Widget build(BuildContext context) {
    final List<GuestApp> guests = vm.guests;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(child: SectionLabel('APPS INSIDE LIVECONTAINER')),
              AppButton(
                label: 'Add an app',
                icon: Icons.add_rounded,
                tone: ButtonTone.primary,
                compact: true,
                busy: vm.isAdding,
                onPressed: vm.isGuestBusy ? null : vm.addGuest,
              ),
            ],
          ),
          const SizedBox(height: Space.s2),
          Text(
            guests.isEmpty
                ? 'Nothing yet. An app added here is not installed on your phone, so it '
                    'uses none of your three slots.'
                : '${guests.length} app${guests.length == 1 ? '' : 's'}, using none of '
                    'your three app slots.',
            style: context.t.bodyMuted,
          ),
          if (vm.guestProgress != null) ...<Widget>[
            const SizedBox(height: Space.s4),
            LoadingLine(label: vm.guestProgress!),
          ],
          if (vm.guestNotice != null) ...<Widget>[
            const SizedBox(height: Space.s4),
            Alert(
              kind: AlertKind.info,
              message: vm.guestNotice!,
              trailing: AppButton(
                label: 'Dismiss',
                compact: true,
                onPressed: vm.dismissGuestNotice,
              ),
            ),
          ],
          for (final GuestApp guest in guests) ...<Widget>[
            const SizedBox(height: Space.s3),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    guest.bundleId ?? '',
                    style: context.t.semi(FontSizes.body),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: Space.s4),
                AppButton(
                  label: 'Remove',
                  tone: ButtonTone.danger,
                  compact: true,
                  busy: vm.isRemoving(guest.bundleId),
                  onPressed: vm.isGuestBusy ? null : () => vm.removeGuest(guest),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The SideStore build's own state: whether the phone can refresh without a PC.
class _SideStoreCard extends StatelessWidget {
  const _SideStoreCard({required this.vm});

  final LiveContainerViewModel vm;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(child: SectionLabel('ON-DEVICE REFRESH')),
                Pill(
                  label: vm.isPaired ? 'Paired' : 'Not paired',
                  kind: vm.isPaired ? PillKind.ok : PillKind.warn,
                ),
              ],
            ),
            const SizedBox(height: Space.s2),
            Text(
              vm.isPaired
                  ? 'This build carries SideStore, and it has this PC\u2019s pairing '
                      'file, so it can re-sign apps on the phone itself.'
                  : 'This build carries SideStore but has no pairing file yet, so it '
                      'cannot re-sign anything. Reinstall to deliver one.',
              style: context.t.bodyMuted,
            ),
            const SizedBox(height: Space.s4),
            // The steps SideStore needs that iPASide cannot do for it, said plainly rather
            // than left for the user to hit as errors. Sign-in comes first: the baked
            // certificate is reused during sign-in, it does not replace it.
            const _Point(
              icon: Icons.person_outline,
              title: 'Sign in once, with the same Apple ID',
              body: 'Open SideStore inside LiveContainer and sign in with the same '
                  'Apple ID iPASide uses. iPASide has already baked its certificate in, '
                  'so SideStore reuses that identity instead of replacing it \u2014 no '
                  'extra certificate is spent. A different Apple ID makes SideStore mint '
                  'its own, and a second LiveContainer along with it.',
            ),
            const SizedBox(height: Space.s4),
            const _Point(
              icon: Icons.vpn_lock_outlined,
              title: 'It needs a local tunnel',
              body: 'SideStore reaches your phone over the network, so a local device '
                  'VPN such as StosVPN or LocalDevVPN has to be connected before a '
                  'refresh will start.',
            ),
            const SizedBox(height: Space.s4),
            const _Point(
              icon: Icons.shortcut_outlined,
              title: 'And a Shortcut named TurnOffData',
              body: 'When SideStore finishes it runs an iOS Shortcut with exactly that '
                  'name, to drop the tunnel. Without one, the Shortcuts app opens with '
                  'an error \u2014 the refresh still worked. Create a Shortcut called '
                  'TurnOffData containing a disconnect-VPN action to silence it. '
                  'Shortcuts cannot be created from a PC.',
            ),
          ],
        ),
      );
}

/// Why this exists, in the terms someone hitting the three-app wall would ask it.
class _ExplainerCard extends StatelessWidget {
  const _ExplainerCard();

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SectionLabel('How it helps'),
            const SizedBox(height: Space.s3),
            _Point(
              icon: Icons.layers_outlined,
              title: 'Past the three-app limit',
              body: 'Your iPhone allows three apps signed by a free Apple ID at '
                  'once. Apps run inside LiveContainer are not installed '
                  'separately, so they do not use a slot.',
            ),
            const SizedBox(height: Space.s4),
            _Point(
              icon: Icons.verified_user_outlined,
              title: 'It signs on device',
              body: 'iPASide hands LiveContainer the same certificate it signs '
                  'with, so LiveContainer can sign the apps you add to it '
                  'without a PC.',
            ),
            const SizedBox(height: Space.s4),
            _Point(
              icon: Icons.event_repeat_outlined,
              title: 'Refreshed like anything else',
              body: 'LiveContainer is tracked in your Library and re-signed '
                  'before its seven days are up, certificate included.',
            ),
          ],
        ),
      );
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: Sizes.iconLarge, color: p.accent),
        const SizedBox(width: Space.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: context.t.semi(FontSizes.body)),
              const SizedBox(height: Space.s1),
              Text(body, style: context.t.bodyMuted),
            ],
          ),
        ),
      ],
    );
  }
}
