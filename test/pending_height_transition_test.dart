// CLAIM settling-height: pending and settled sections ease to natural size,
// including a fast read inside debounce; accessibility can disable the motion.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'support/skeleton_fixture.dart';

void main() {
  for (final fast in [true, false]) {
    testWidgets(
      'height settles smoothly when data lands ${fast ? 'before' : 'after'} debounce',
      (t) async {
        Widget page(bool pending, double height) => MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                child: PendingContent(
                  pending: pending,
                  child: SizedBox(height: height),
                ),
              ),
            ),
          ),
        );
        await t.pumpWidget(page(true, 100));
        await t.pump(Duration(milliseconds: fast ? 50 : 400));
        await t.pumpWidget(page(false, 180));
        expect(
          t.getSize(find.byType(PendingContent)).height,
          100,
          reason: 'landing starts at the reserved height rather than jumping',
        );
        await t.pump(const Duration(milliseconds: 80));
        expect(
          t.getSize(find.byType(PendingContent)).height,
          inExclusiveRange(100, 180),
        );
        await t.pump(const Duration(milliseconds: 200));
        expect(t.getSize(find.byType(PendingContent)).height, 180);
        await t.pumpWidget(page(false, 60));
        expect(t.getSize(find.byType(PendingContent)).height, 180);
        await t.pump(const Duration(milliseconds: 250));
        expect(t.getSize(find.byType(PendingContent)).height, 60);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'an expanded accordion animates changing content without scrolling',
    (t) async {
      Widget page(double height) => skHost(
        Scaffold(
          body: SingleChildScrollView(
            child: SettingsAccordion(
              'Signals',
              id: 'polish-height-signals',
              children: [
                PendingContent(pending: false, child: SizedBox(height: height)),
              ],
            ),
          ),
        ),
      );
      await t.pumpWidget(page(80));
      final initial = t.getSize(find.byType(SettingsAccordion)).height;
      await t.pumpWidget(page(180));
      expect(t.getSize(find.byType(SettingsAccordion)).height, initial);
      await t.pump(const Duration(milliseconds: 80));
      expect(
        t.getSize(find.byType(SettingsAccordion)).height,
        inExclusiveRange(initial, initial + 100),
      );
      await t.pump(const Duration(milliseconds: 200));
      expect(t.getSize(find.byType(SettingsAccordion)).height, initial + 100);
      expect(find.byType(Scrollable), findsOneWidget);
      expect(
        find.byType(AnimatedSize),
        findsOneWidget,
        reason: 'nested pending sections share the accordion envelope',
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('reduced motion settles to natural height immediately', (
    t,
  ) async {
    Widget page(bool pending, double height) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: PendingContent(
              pending: pending,
              child: SizedBox(width: 200, height: height),
            ),
          ),
        ),
      ),
    );
    await t.pumpWidget(page(true, 100));
    await t.pumpWidget(page(false, 180));
    expect(t.getSize(find.byType(PendingContent)).height, 180);
    await t.pumpWidget(const SizedBox());
  });
}
