import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/ui/shell/app_dialogs.dart';
import 'package:ipaside/ui/theme/app_theme.dart';
import 'package:ipaside/ui/widgets/inputs.dart';

/// Dialogs bind Enter to "confirm" and Escape to "cancel" on the dialog itself. Every button is a
/// focusable control that activates on Enter and Space, so the two have to agree: a button the
/// user has Tabbed to must do what it says, once, and the dialog's own shortcut must not fire on
/// top of it.

final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

Future<void> _pumpHome(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        navigatorKey: _navigatorKey,
        theme: buildAppTheme(Brightness.dark),
        home: const Scaffold(body: Center(child: Text('home page'))),
      ),
    );

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Enter on the open dialog confirms, once', (tester) async {
    await _pumpHome(tester);
    bool? result;
    DialogService(_navigatorKey)
        .confirm(title: 'Remove app?', message: 'm', confirmLabel: 'Remove')
        .then((bool v) => result = v);
    await tester.pumpAndSettle();
    expect(find.text('Remove app?'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.enter);

    expect(result, isTrue);
    expect(find.text('Remove app?'), findsNothing);
    expect(find.text('home page'), findsOneWidget, reason: 'one pop only');
  });

  testWidgets('Escape cancels', (tester) async {
    await _pumpHome(tester);
    bool? result;
    DialogService(_navigatorKey)
        .confirm(title: 'Remove app?', message: 'm')
        .then((bool v) => result = v);
    await tester.pumpAndSettle();

    await _key(tester, LogicalKeyboardKey.escape);

    expect(result, isFalse);
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('Tab to Cancel and press Enter: it cancels instead of confirming',
      (tester) async {
    await _pumpHome(tester);
    bool? result;
    DialogService(_navigatorKey)
        .confirm(
          title: 'Remove app?',
          message: 'm',
          confirmLabel: 'Remove',
          cancelLabel: 'Keep',
        )
        .then((bool v) => result = v);
    await tester.pumpAndSettle();

    await _key(tester, LogicalKeyboardKey.tab); // first control: Keep
    await _key(tester, LogicalKeyboardKey.enter);

    expect(result, isFalse, reason: 'a focused Cancel must cancel');
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('Tab to Cancel and press Space cancels', (tester) async {
    await _pumpHome(tester);
    bool? result;
    DialogService(_navigatorKey)
        .confirm(
          title: 'Remove app?',
          message: 'm',
          confirmLabel: 'Remove',
          cancelLabel: 'Keep',
        )
        .then((bool v) => result = v);
    await tester.pumpAndSettle();

    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.space);

    expect(result, isFalse);
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('Tab twice to the confirm button and press Enter: confirms exactly once',
      (tester) async {
    await _pumpHome(tester);
    bool? result;
    var completions = 0;
    DialogService(_navigatorKey)
        .confirm(
          title: 'Remove app?',
          message: 'm',
          confirmLabel: 'Remove',
          cancelLabel: 'Keep',
        )
        .then((bool v) {
      result = v;
      completions++;
    });
    await tester.pumpAndSettle();

    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.enter);

    expect(result, isTrue);
    expect(completions, 1);
    expect(find.text('home page'), findsOneWidget,
        reason: 'a double pop would take the page too');
  });

  testWidgets('an alert closes on Enter from its only button', (tester) async {
    await _pumpHome(tester);
    var closed = false;
    DialogService(_navigatorKey)
        .alert(title: 'Heads up', message: 'm')
        .then((_) => closed = true);
    await tester.pumpAndSettle();

    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.enter);

    expect(closed, isTrue);
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('a space typed into a text field types a space and presses nothing',
      (tester) async {
    var pressed = 0;
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: Column(
            children: [
              AppCheckbox(
                label: 'Remove extensions',
                value: false,
                onChanged: (_) => pressed++,
              ),
              SizedBox(
                width: 320,
                child: AppTextField(label: 'Apple ID email', controller: controller),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'a b');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(controller.text, startsWith('a b'));
    expect(pressed, 0, reason: 'Space belongs to the field that has focus');
  });
}
