// CLAIM settling-height: pending and settled sections ease to natural size,
// including a fast read inside debounce; accessibility can disable the motion.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
      // why: only the changing inner boundary may tween; the card must flow.
      // CLAIM(settling-height-flow).
      expect(
        t.renderObject<RenderBox>(find.byType(SettingsAccordion)).size.height,
        initial + 100,
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  // why: animating only an ancestor's bounds leaves its second child jumping.
  // CLAIM(settling-height-flow); catches suppressing nested layout boundaries.
  for (final reduced in [false, true]) {
    testWidgets(
      'following row flows with nested growth and shrink, reduced=$reduced',
      (t) async {
        Widget page(double height) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SettlingHeight(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PendingContent(
                        pending: false,
                        child: SizedBox(height: height),
                      ),
                      const SizedBox(
                        key: ValueKey('following-row'),
                        height: 20,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        double top() =>
            t.getTopLeft(find.byKey(const ValueKey('following-row'))).dy;
        await t.pumpWidget(page(80));
        final start = top();
        await t.pumpWidget(page(180));
        expect(top(), reduced ? start + 100 : start);
        await t.pump(const Duration(milliseconds: 80));
        if (!reduced) {
          expect(top(), inExclusiveRange(start, start + 100));
          final root = t.renderObject<RenderBox>(
            find.byType(SettlingHeight).first,
          );
          expect(
            root.size.height,
            top() + 20,
            reason: 'ancestor follows the child with no second tween',
          );
        }
        await t.pump(const Duration(milliseconds: 170));
        expect(top(), start + 100);
        await t.pumpWidget(page(40));
        expect(top(), reduced ? start - 40 : start + 100);
        await t.pump(const Duration(milliseconds: 80));
        if (!reduced) expect(top(), inExclusiveRange(start - 40, start + 100));
        await t.pump(const Duration(milliseconds: 170));
        expect(top(), start - 40);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  // why: Sleep's frame wraps an accordion whose changing first section has
  // another visible row beneath it. CLAIM(settling-height-flow).
  testWidgets(
    'Sleep frame and accordion flow around the changing inner section',
    (t) async {
      Widget page(double height) => skHost(
        Scaffold(
          body: SingleChildScrollView(
            child: PendingContent(
              pending: false,
              child: SettingsAccordion(
                'Signals',
                id: 'sleep-flow-regression',
                initiallyExpanded: true,
                children: [
                  PendingContent(
                    pending: false,
                    child: SizedBox(height: height),
                  ),
                  const SizedBox(key: ValueKey('sleep-following'), height: 20),
                ],
              ),
            ),
          ),
        ),
      );
      double top() =>
          t.getTopLeft(find.byKey(const ValueKey('sleep-following'))).dy;
      await t.pumpWidget(page(80));
      final start = top();
      await t.pumpWidget(page(180));
      expect(top(), start);
      await t.pump(const Duration(milliseconds: 80));
      expect(top(), inExclusiveRange(start, start + 100));
      final animations = find
          .byWidgetPredicate((w) => w is SingleChildRenderObjectWidget)
          .evaluate()
          .map((e) => e.renderObject)
          .where((r) => r is RenderAnimatedSize || r is RenderSettlingHeight)
          .toSet();
      expect(
        animations
            .where(
              (r) => r is RenderAnimatedSize
                  ? r.isAnimating
                  : (r as RenderSettlingHeight).isAnimating,
            )
            .length,
        1,
        reason: 'only the changing boundary tweens, both ancestors flow',
      );
      await t.pump(const Duration(milliseconds: 170));
      expect(top(), start + 100);
      await t.pumpWidget(page(40));
      expect(top(), start + 100);
      await t.pump(const Duration(milliseconds: 80));
      expect(top(), inExclusiveRange(start - 40, start + 100));
      await t.pump(const Duration(milliseconds: 170));
      expect(top(), start - 40);
      await t.pumpWidget(const SizedBox());
    },
  );
  // why: descendant motion must not suppress a separate parent-owned change.
  // CLAIM(settling-height-independent). 80+20 -> 180+120 is a 200dp change.
  for (final reduced in [false, true]) {
    for (final staggered in [false, true]) {
      testWidgets(
        'independent parent growth and shrink, staggered=$staggered reduced=$reduced',
        (t) async {
          Widget page(double inner, double other) => MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SettlingHeight(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SettlingHeight(child: SizedBox(height: inner)),
                            SizedBox(height: other),
                          ],
                        ),
                      ),
                      const SizedBox(key: ValueKey('after-card'), height: 20),
                    ],
                  ),
                ),
              ),
            ),
          );
          double top() =>
              t.getTopLeft(find.byKey(const ValueKey('after-card'))).dy;
          await t.pumpWidget(page(80, 20));
          expect(top(), 100);
          for (final growing in [true, false]) {
            final initial = growing ? 100.0 : 300.0;
            final end = growing ? 300.0 : 100.0;
            final inner = growing ? 180.0 : 80.0;
            final other = growing ? 120.0 : 20.0;
            if (staggered) {
              await t.pumpWidget(page(inner, growing ? 20 : 120));
              await t.pump(const Duration(milliseconds: 80));
            }
            final before = top();
            await t.pumpWidget(page(inner, other));
            expect(
              top(),
              reduced ? end : before,
              reason:
                  'parent change begins at its current height even during child motion',
            );
            await t.pump(const Duration(milliseconds: 80));
            if (!reduced) {
              expect(
                top(),
                inExclusiveRange(
                  initial < end ? initial : end,
                  initial < end ? end : initial,
                ),
                reason:
                    'the independent change must have a real intermediate frame',
              );
            }
            await t.pump(const Duration(milliseconds: 170));
            expect(top(), end);
          }
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }
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
