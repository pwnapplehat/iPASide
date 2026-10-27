import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../engine/engine.dart';
import '../../services/startup_query.dart';
import '../../viewmodels/drop_router.dart';
import '../../viewmodels/navigation_state.dart';
import '../../viewmodels/sideload_view_model.dart';
import '../../viewmodels/theme_controller.dart';
import '../../viewmodels/update_view_model.dart';
import '../theme/app_theme.dart';
import '../views/account_view.dart';
import '../views/apps_view.dart';
import '../views/diagnostics_view.dart';
import '../views/home_view.dart';
import '../views/jailbreak_view.dart';
import '../views/library_view.dart';
import '../views/live_container_view.dart';
import '../views/settings_view.dart';
import '../views/sideload_view.dart';
import '../views/sign_in_view.dart';
import '../widgets/update_banner.dart';
import 'drop_veil.dart';
import 'nav_destination.dart';
import 'sidebar.dart';
import 'title_bar.dart';

/// The window: title bar, sidebar, the active screen, and the drop overlay.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.startup});

  /// Harness overrides from `IPASIDE_STARTUP_QUERY`.
  final StartupOptions startup;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  String _engineLabel = 'engine';
  EngineHealth _health = EngineHealth.unknown;

  @override
  void initState() {
    super.initState();
    _loadEngineStatus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyStartupOptions());
  }

  Future<void> _loadEngineStatus() async {
    try {
      final result = await context.read<EngineApi>().version();
      if (!mounted) return;
      final version = result.version;
      setState(() {
        _engineLabel = (version == null || version.isEmpty)
            ? 'engine ready'
            : 'engine $version';
        _health = EngineHealth.ready;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _engineLabel = 'engine offline';
        _health = EngineHealth.offline;
      });
    }
  }

  /// Applies the startup query: open a screen, preload an IPA and tweaks, and
  /// expand the Advanced section.
  Future<void> _applyStartupOptions() async {
    final startup = widget.startup;
    final navigation = context.read<NavigationState>();
    final sideload = context.read<SideloadViewModel>();

    final requested = NavKey.fromWireName(startup.view);
    if (requested != null) navigation.navigateTo(requested);

    if (startup.advancedOpen) sideload.openAdvanced();

    final ipa = startup.ipaPath;
    if (ipa == null) return;

    navigation.navigateTo(NavKey.sideload);
    await sideload.loadIpa(ipa);
    if (startup.tweakPaths.isNotEmpty) {
      await sideload.addTweaks(startup.tweakPaths);
    }
  }

  static Widget _pageFor(NavKey key) => switch (key) {
    NavKey.home => const HomeView(),
    NavKey.signIn => const SignInView(),
    NavKey.sideload => const SideloadView(),
    NavKey.library => const LibraryView(),
    NavKey.apps => const AppsView(),
    NavKey.liveContainer => const LiveContainerView(),
    NavKey.jailbreak => const JailbreakView(),
    NavKey.account => const AccountView(),
    NavKey.diagnostics => const DiagnosticsView(),
    NavKey.settings => const SettingsView(),
  };

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final navigation = context.watch<NavigationState>();
    final drop = context.watch<DropRouter>();
    final theme = context.watch<ThemeController>();
    final updates = context.watch<UpdateViewModel>();
    final platformBrightness = MediaQuery.platformBrightnessOf(context);

    return DropTarget(
      onDragEntered: (_) => drop.onDragEnter(),
      onDragExited: (_) => drop.onDragLeave(),
      onDragDone: (details) =>
          drop.onDrop([for (final f in details.files) f.path]),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.appGradient),
        // Material supplies the text and ink defaults every descendant relies
        // on; without it Flutter falls back to its debug underline style.
        child: Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              Column(
                children: [
                  TitleBar(
                    isDark: theme.isDark(platformBrightness),
                    onToggleTheme: () => theme.toggle(platformBrightness),
                  ),
                  if (updates.showBanner)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Space.s3,
                        0,
                        Space.s3,
                        Space.s2,
                      ),
                      child: UpdateBanner(model: updates),
                    ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Sidebar(
                          selected: navigation.sidebarSelection,
                          onSelect: navigation.navigateTo,
                          engineLabel: _engineLabel,
                          health: _health,
                        ),
                        Expanded(
                          // The staggered card entrances *are* the transition;
                          // the page itself is swapped outright.
                          //
                          // It used to fade the whole page in over Motion.page
                          // as well, which flickered. A page-wide fade needs one
                          // offscreen layer holding every card's gradient and
                          // shadow, and it finished (260ms) long before the
                          // stagger did (up to ~900ms on Home) - so the layer
                          // was torn down mid-animation and the entire screen
                          // shifted at once, on every tab switch. Entrance
                          // documents the same hazard for a single card; this is
                          // that, one level up. One opacity layer per card,
                          // retired the moment it reaches rest, and none over
                          // the page.
                          child: FocusTraversalGroup(
                            // The screen is its own group, so Tab visits the
                            // whole nav rail and then the whole page rather
                            // than bouncing between them by position.
                            child: KeyedSubtree(
                              // The epoch remounts the screen even when the
                              // destination is unchanged, so re-navigating
                              // reloads it the way the previous build did.
                              key: ValueKey(
                                '${navigation.current.wireName}#${navigation.epoch}',
                              ),
                              child: _pageFor(navigation.current),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              DropVeil(
                visible: drop.isVeilVisible,
                text: drop.veilText,
                isReject: drop.isReject,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
