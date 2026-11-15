// WHY: pending templates must preserve geometry without exposing invented
// readings, actions or accessible values. Reverting the pointer/semantics
// guards, collapsing a pending list, or hiding retained data fails these tests.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

void main() {
  testWidgets('pending content keeps its card size and disables actions', (
    t,
  ) async {
    var taps = 0;
    Widget page(bool pending) => MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: PendingContent(
          pending: pending,
          child: SizedBox(
            key: const ValueKey('card'),
            width: 300,
            height: 180,
            child: TextButton(
              onPressed: () => taps++,
              child: const Text('Stored value'),
            ),
          ),
        ),
      ),
    );
    final semantics = t.ensureSemantics();
    try {
      await t.pumpWidget(page(true));
      final before = t.getRect(find.byKey(const ValueKey('card')));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.bySemanticsLabel('Stored value'), findsNothing);
      await t.tap(find.byType(TextButton), warnIfMissed: false);
      expect(taps, 0);
      await t.pumpWidget(page(false));
      expect(t.getRect(find.byKey(const ValueKey('card'))), before);
      expect(find.bySemanticsLabel('Stored value'), findsOneWidget);
      await t.tap(find.byType(TextButton));
      expect(taps, 1);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a retained value survives refresh and missing data settles', (
    t,
  ) async {
    Widget page({required bool pending, String? value, bool failed = false}) =>
        MaterialApp(
          home: AsyncSection<String>(
            pending: pending,
            value: value,
            failed: failed,
            pendingBuilder: (_) => const SizedBox(height: 100),
            builder: (_, value) => Text(value),
            emptyBuilder: (_) => const Text('No recorded data'),
            failureBuilder: (_) => const Text('Try again'),
          ),
        );
    await t.pumpWidget(page(pending: true, value: 'Stored result'));
    expect(find.text('Stored result'), findsOneWidget);
    expect(find.byType(PendingContent), findsNothing);
    await t.pumpWidget(page(pending: false));
    expect(find.text('No recorded data'), findsOneWidget);
    await t.pumpWidget(page(pending: false, failed: true));
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('unknown list counts keep the following section in place', (
    t,
  ) async {
    Widget page(List<String>? items) => MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: Column(
          children: [
            AsyncListSection<String>(
              items: items,
              itemBuilder: (_, value) => Text(value),
              emptyBuilder: (_) => const Text('No entries'),
            ),
            const Text('Next section', key: ValueKey('next')),
          ],
        ),
      ),
    );
    await t.pumpWidget(page(null));
    final before = t.getRect(find.byKey(const ValueKey('next')));
    await t.pumpWidget(page(['One', 'Two', 'Three', 'Four']));
    expect(t.getRect(find.byKey(const ValueKey('next'))), before);
    expect(find.text('Four'), findsOneWidget);
    await t.pumpWidget(page([]));
    expect(t.getRect(find.byKey(const ValueKey('next'))), before);
    expect(find.text('No entries'), findsOneWidget);
  });
  testWidgets('pending rows fit a constrained viewport', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: 80,
              child: AsyncListSection<String>(
                items: null,
                itemBuilder: (_, value) => Text(value),
                emptyBuilder: (_) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
    expect(t.takeException(), isNull);
  });
}
