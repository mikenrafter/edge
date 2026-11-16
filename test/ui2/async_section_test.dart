// WHY: pending templates must preserve geometry without exposing invented
// readings, actions or accessible values. Reverting the pointer/semantics
// guards, collapsing a pending list, or hiding retained data fails these tests.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

class _Content implements AsyncSectionContent<String> {
  const _Content();
  @override Widget loaded(BuildContext context, String value) => Text(value);
  @override Widget pending(BuildContext context) => const SizedBox(height: 100);
  @override Widget empty(BuildContext context) => const Text('No recorded data');
  @override Widget failed(BuildContext context) => const Text('Try again');
}

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
            content: const _Content(),
          ),
        );
    await t.pumpWidget(page(pending: true, value: 'Stored result'));
    expect(find.text('Stored result'), findsOneWidget);
    // The shared owner stays mounted to announce user-started settlement;
    // retained data must still be readable and interactive, never pending.
    expect(find.byWidgetPredicate((w) => w is PendingContent && w.pending), findsNothing);
    await t.pumpWidget(page(pending: false));
    expect(find.text('No recorded data'), findsOneWidget);
    await t.pumpWidget(page(pending: false, failed: true));
    expect(find.text('Try again'), findsOneWidget);
  });

  // WHY: a short or empty list must not leave the pilot's empty viewport,
  // and accordion content must not acquire another scrollable.
  testWidgets('settled lists fit their content and never scroll internally', (t) async {
    Widget page(List<String>? items) => MaterialApp(home: Scaffold(body:
      SingleChildScrollView(child: AsyncListSection<String>(memoryKey: 'test-settled-list', items: items,
        itemBuilder: (_, value) => Text(value),
        emptyBuilder: (_) => const Text('No entries')))));
    await t.pumpWidget(page(['One', 'Two', 'Three', 'Four']));
    expect(find.byType(Scrollable), findsOneWidget);
    expect(find.text('Four'), findsOneWidget);
    await t.pumpWidget(page([]));
    expect(find.byType(Scrollable), findsOneWidget);
    expect(find.text('No entries'), findsOneWidget);
    expect(find.byType(PendingRows), findsNothing);
  });

  // CLAIM remembered-list: an unknown list reuses its settled size instead
  // of reserving the generic three-row template on every revisit.
  testWidgets('async list remembers short content and empty content stays natural', (t) async {
    Widget page(List<String>? items) => MaterialApp(home: Scaffold(body:
      SingleChildScrollView(child: SizedBox(width:200,child: AsyncListSection<String>(
        memoryKey:'short-list',key:const ValueKey('short-list'), items:items,
        itemBuilder:(_, value)=>SizedBox(height:42,child:Text(value)),
        emptyBuilder:(_)=>const SizedBox(height:14))))));
    await t.pumpWidget(page(['One']));await t.pump();
    expect(t.getSize(find.byType(AsyncListSection<String>)).height,42);
    await t.pumpWidget(page(null));
    expect(t.getSize(find.byType(AsyncListSection<String>)).height,42);
    await t.pumpWidget(page([]));await t.pump(const Duration(milliseconds:250));
    expect(t.getSize(find.byType(AsyncListSection<String>)).height,14);
    await t.pumpWidget(const SizedBox());
  });

  // WHY: bounded parents (Track editor/startup) must not stretch row skeletons
  // into an empty full-screen card. The known rows determine their own height.
  testWidgets('pending rows fit their contents inside a bounded centre', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: Center(
      child: PendingRows(count: 5, rowHeight: 64)))));
    expect(t.getSize(find.byType(PendingRows)).height, 320);
  });

  // WHY: fast reads must never flash placeholders. Slow reads fade in after
  // 200 ms and pulse only value, with identical hue and saturation.
  // Proves CLAIM(pending-debounce). Changing 200 to 0 or removing fade fails.
  testWidgets('placeholder waits 200ms then fades with value-only pulse', (t) async {
    Widget page(bool pending) => MaterialApp(home: PendingContent(
      pending: pending, child: const Text('Stored value')));
    PendingTone tone() => t.widget<PendingTone>(find.byType(PendingTone));
    await t.pumpWidget(page(true));
    await t.pump(const Duration(milliseconds: 199));
    expect(tone().fade, 0);
    await t.pump(const Duration(milliseconds: 1));
    expect(tone().fade, 0);
    await t.pump(const Duration(milliseconds: 125));
    expect(tone().fade, closeTo(.5, .02));
    await t.pump(const Duration(milliseconds: 125));
    expect(tone().fade, 1);
    final context = t.element(find.text('Stored value'));
    const source = Color(0xff568aba);
    final pulsed = PendingTone.colorOf(context, source);
    // Equal RGB ratios preserve HSV hue and saturation. HSVColor.fromColor
    // quantizes via integer channels, so it is not an oracle for this pulse.
    expect(pulsed.r / source.r, closeTo(pulsed.g / source.g, 1e-6));
    expect(pulsed.g / source.g, closeTo(pulsed.b / source.b, 1e-6));
    expect(pulsed.b, lessThan(source.b));
    expect(pulsed.a, source.a);
    await t.pumpWidget(page(false));
    await t.pumpWidget(page(true));
    await t.pump(const Duration(milliseconds: 100));
    await t.pumpWidget(page(false));
    await t.pump(const Duration(milliseconds: 500));
    expect(tone().fade, 1, reason: 'a completed fast read cancels placeholder paint and reveals the new data');
    await t.pumpWidget(const SizedBox());
  });
}
