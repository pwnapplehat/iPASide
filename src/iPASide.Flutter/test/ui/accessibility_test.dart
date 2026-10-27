import 'dart:ui' show CheckedState, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/ui/theme/app_theme.dart';
import 'package:ipaside/ui/widgets/buttons.dart';
import 'package:ipaside/ui/widgets/expander.dart';
import 'package:ipaside/ui/widgets/inputs.dart';
import 'package:ipaside/ui/widgets/progress.dart';

/// Every control in this app is custom-painted on top of `Hoverable`, which is
/// where the role, label and focus node come from. These tests pin that down:
/// a control a mouse can press but Tab cannot reach (or a screen reader cannot
/// name) is the bug, and it would otherwise return silently.

Widget _app(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(body: Center(child: child)),
    );

SemanticsData _data(WidgetTester tester, Finder finder) =>
    tester.getSemantics(finder).getSemanticsData();

bool _on(Tristate value) => value == Tristate.isTrue;

bool _off(Tristate value) => value == Tristate.isFalse;

Iterable<SemanticsNode> _nodes(SemanticsNode root) sync* {
  yield root;
  final List<SemanticsNode> children = <SemanticsNode>[];
  root.visitChildren((SemanticsNode child) {
    children.add(child);
    return true;
  });
  for (final SemanticsNode child in children) {
    yield* _nodes(child);
  }
}

void main() {
  testWidgets('buttons are named, focusable and pressable from the keyboard',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    var taps = 0;

    await tester.pumpWidget(
      _app(AppButton(label: 'Sideload to iPhone', onPressed: () => taps++)),
    );

    final SemanticsData data = _data(tester, find.byType(AppButton));
    expect(data.label, 'Sideload to iPhone');
    expect(data.flagsCollection.isButton, isTrue);
    expect(_on(data.flagsCollection.isEnabled), isTrue);
    expect(data.flagsCollection.isFocused, isNot(Tristate.none));
    expect(data.hasAction(SemanticsAction.tap), isTrue);

    // One Tab reaches the only focusable control; Enter presses it.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1);

    // Space too, the way every native button behaves.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(taps, 2);

    handle.dispose();
  });

  testWidgets('a disabled button is still named, but not focusable',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();

    await tester.pumpWidget(_app(const AppButton(label: 'Place in all apps')));

    final SemanticsData data = _data(tester, find.byType(AppButton));
    expect(data.label, 'Place in all apps');
    expect(data.flagsCollection.isButton, isTrue);
    expect(_off(data.flagsCollection.isEnabled), isTrue);
    expect(data.flagsCollection.isFocused, Tristate.none);
    expect(data.hasAction(SemanticsAction.tap), isFalse);

    handle.dispose();
  });

  testWidgets('icon-only buttons take their name from the tooltip',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(GhostIconButton(
        icon: Icons.close_rounded,
        tooltip: 'Close',
        onPressed: () {},
      )),
    );

    final SemanticsData data = _data(tester, find.byType(GhostIconButton));
    expect(data.label, 'Close');
    expect(data.flagsCollection.isButton, isTrue);
    expect(
      find.bySemanticsLabel('Close'),
      findsOneWidget,
      reason: 'the tooltip must not become a second node',
    );

    handle.dispose();
  });

  testWidgets('checkboxes announce state and toggle from Space', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    var value = false;

    await tester.pumpWidget(
      _app(StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => AppCheckbox(
          label: 'Remove app extensions',
          value: value,
          onChanged: (bool next) => setState(() => value = next),
        ),
      )),
    );

    var data = _data(tester, find.bySemanticsLabel('Remove app extensions'));
    expect(data.label, 'Remove app extensions');
    expect(data.flagsCollection.isChecked, isNot(CheckedState.none));
    expect(data.flagsCollection.isChecked, CheckedState.isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(value, isTrue);
    data = _data(tester, find.bySemanticsLabel('Remove app extensions'));
    expect(data.flagsCollection.isChecked, CheckedState.isTrue);

    handle.dispose();
  });

  testWidgets('toggles announce state and their row title', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    var value = false;

    await tester.pumpWidget(
      _app(StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => AppToggle(
          value: value,
          semanticsLabel: 'Enable daily background auto-refresh',
          onChanged: (bool next) => setState(() => value = next),
        ),
      )),
    );

    var data = _data(tester, find.byType(AppToggle));
    expect(data.label, 'Enable daily background auto-refresh');
    expect(data.flagsCollection.isToggled, isNot(Tristate.none));
    expect(_off(data.flagsCollection.isToggled), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(value, isTrue);
    data = _data(tester, find.byType(AppToggle));
    expect(_on(data.flagsCollection.isToggled), isTrue);

    handle.dispose();
  });

  testWidgets('option chips say what they choose and which is current',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(AppChoiceChips<String>(
        choices: const <String>['USB', 'Network', 'Auto'],
        selected: 'USB',
        labelOf: (String choice) => choice,
        onSelect: (_) {},
        groupLabel: 'Connection',
      )),
    );

    final SemanticsData other =
        _data(tester, find.bySemanticsLabel('Connection: Network'));
    expect(other.flagsCollection.isButton, isTrue);
    expect(_off(other.flagsCollection.isSelected), isTrue);

    final SemanticsData current =
        _data(tester, find.bySemanticsLabel('Connection: USB'));
    expect(_on(current.flagsCollection.isSelected), isTrue);

    handle.dispose();
  });

  testWidgets('text fields carry the label drawn above them', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(const SizedBox(
        width: 320,
        child: AppTextField(label: 'Apple ID email', hint: 'you@example.com'),
      )),
    );

    final SemanticsData data = _data(tester, find.byType(TextField));
    // The hint is part of the field's own label in Flutter, so it may follow.
    expect(data.label, startsWith('Apple ID email'));
    expect(data.flagsCollection.isTextField, isTrue);

    handle.dispose();
  });

  testWidgets('a collapsed expander hides its contents from AT and Tab',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(Expander(
        title: 'Advanced options',
        expanded: false,
        onToggle: (_) {},
        child: AppButton(label: 'Add tweak', onPressed: () {}),
      )),
    );

    // The header is the control; the Expander itself is the section around it.
    final Finder header = find.bySemanticsLabel('Advanced options');
    final SemanticsData data = _data(tester, header);
    expect(data.label, 'Advanced options');
    expect(data.flagsCollection.isExpanded, isNot(Tristate.none));
    expect(_off(data.flagsCollection.isExpanded), isTrue);
    expect(
      find.bySemanticsLabel('Add tweak'),
      findsNothing,
      reason: 'the panel is zero-height, so nothing in it may be read',
    );

    handle.dispose();
  });

  testWidgets('progress steps say which one is running', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(const SideloadStepper(activeIndex: 1, stepText: 'Signing')),
    );

    expect(find.bySemanticsLabel('Provision, done'), findsOneWidget);
    expect(find.bySemanticsLabel('Sign, in progress'), findsOneWidget);
    expect(find.bySemanticsLabel('Install, pending'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('no control in a composed screen is left unnamed or role-less',
      (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();

    // One of each control the app uses, laid out the way a real screen does.
    await tester.pumpWidget(
      _app(SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AppButton(label: 'Refresh', onPressed: () {}),
            GhostIconButton(
              icon: Icons.remove,
              tooltip: 'Minimize',
              onPressed: () {},
            ),
            AppCheckbox(
              label: 'Enable file sharing',
              value: true,
              onChanged: (_) {},
            ),
            AppToggle(
              value: true,
              semanticsLabel: 'Keep the signed IPA',
              onChanged: (_) {},
            ),
            ActionTile(
              icon: Icons.library_books,
              title: 'Library',
              subtitle: 'Your sideloaded apps.',
              onTap: () {},
            ),
            AppChoiceChips<String>(
              choices: const <String>['USB', 'Auto'],
              selected: 'USB',
              labelOf: (String choice) => choice,
              onSelect: (_) {},
              groupLabel: 'Connection',
            ),
          ],
        ),
      )),
    );

    // The screen's root node: everything the user can reach hangs below it.
    final SemanticsNode root = tester.getSemantics(find.byType(Scaffold));
    final List<String> unlabelled = <String>[];
    final List<String> roleless = <String>[];

    for (final SemanticsNode node in _nodes(root)) {
      final SemanticsData data = node.getSemanticsData();
      // Nodes merged into an ancestor are not what a screen reader meets; their
      // label and flags are reported on the ancestor instead.
      if (node.isMergedIntoParent) continue;
      if (!data.hasAction(SemanticsAction.tap)) continue;
      if (data.label.trim().isEmpty) unlabelled.add(node.toStringDeep());
      final bool hasRole = data.flagsCollection.isButton ||
          data.flagsCollection.isChecked != CheckedState.none ||
          data.flagsCollection.isToggled != Tristate.none ||
          data.flagsCollection.isTextField;
      if (!hasRole) roleless.add(node.toStringDeep());
    }

    expect(unlabelled, isEmpty, reason: 'tappable nodes with no name');
    expect(roleless, isEmpty, reason: 'tappable nodes with no role');

    handle.dispose();
  });
}
