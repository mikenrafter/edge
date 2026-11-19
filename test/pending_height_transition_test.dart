import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';

void main() {
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
}
