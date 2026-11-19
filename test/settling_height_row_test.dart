import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Section, Surface;
import 'package:openstrap_edge/ui2/skeleton/settling_height.dart';

void main() {
  // why: round-3 summed siblings that contribute their maximum height, causing
  // overshoot and a second tween. CLAIM(settling-height-layout-contribution).
  // catches: summing all descendants, or tweening their motion again above Row.
  for (final shape in ['fixed taller sibling', 'two siblings', 'Home glance']) {
    for (final reduced in [false, true]) {
      testWidgets('$shape settles without overshoot, reduced=$reduced', (
        t,
      ) async {
        Widget page(double height) {
          final home = shape == 'Home glance';
          final row = Row(
            crossAxisAlignment: home
                ? CrossAxisAlignment.stretch
                : CrossAxisAlignment.start,
            children: [
              Expanded(
                child: home
                    ? Surface(child: SettlingHeight(child: SizedBox(height: height)))
                    : SettlingHeight(child: SizedBox(height: height)),
              ),
              Expanded(
                child: home
                    ? Surface(child: SettlingHeight(child: SizedBox(height: height)))
                    : shape == 'fixed taller sibling'
                    ? const SizedBox(height: 300)
                    : SettlingHeight(child: SizedBox(height: height)),
              ),
            ],
          );
          return MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 300,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Matches Home's Section -> IntrinsicHeight -> stretched
                        // Row -> Expanded(Surface), including real card padding.
                        if (home)
                          Section('At a glance', SettlingHeight(child: IntrinsicHeight(child: row)))
                        else
                          SettlingHeight(child: row),
                        const SizedBox(key: ValueKey('after-row'), height: 20),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        double top() =>
            t.getTopLeft(find.byKey(const ValueKey('after-row'))).dy;
        await t.pumpWidget(page(80));
        final initial = top();
        // The fixed 300dp sibling masks both changes. Otherwise max(80,80)
        // becomes max(180,180), a 100dp change; title/padding stay constant.
        final grown = initial + (shape == 'fixed taller sibling' ? 0 : 100);
        for (final growing in [true, false]) {
          final start = growing ? initial : grown;
          final end = growing ? grown : initial;
          await t.pumpWidget(page(growing ? 180 : 80));
          expect(top(), reduced ? end : start, reason: 'landing frame');
          var previous = top();
          // Include intermediate frames and exactly 250ms, then check stability.
          for (final millis in [...List.filled(15, 16), 10, 250]) {
            await t.pump(Duration(milliseconds: millis));
            final current = top();
            expect(
              current,
              inInclusiveRange(initial, grown),
              reason: 'no overshoot on growth or shrink',
            );
            expect(
              growing ? current >= previous : current <= previous,
              isTrue,
              reason: 'following row must not reverse direction',
            );
            if (reduced || millis == 10 || millis == 250) {
              expect(
                current,
                closeTo(end, 0.001),
                reason: 'settled by 250ms and remains settled',
              );
            }
            previous = current;
          }
        }
        await t.pumpWidget(const SizedBox());
      });
    }
  }
}
