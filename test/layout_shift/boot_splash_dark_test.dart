// Flashbang rule: the cold-start cover is dark even for light-mode users.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/ui2/onboarding/splash.dart';

Widget _app({required bool ready, bool reduced = false}) => MaterialApp(
      theme: ThemeData(brightness: Brightness.light),
      builder: (c, child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: BootSplash(ready: ready, child: const SizedBox(key: Key('app'))),
    );

void main() {
  testWidgets('cover background is dark under a light theme', (t) async {
    await t.pumpWidget(_app(ready: false));
    final cover = t.widget<Material>(find.descendant(
        of: find.byType(AnimatedOpacity), matching: find.byType(Material)));
    final argb = cover.color!.toARGB32();
    expect(checkFirstPaint(0, argb, ShiftPolicy.standard), ShiftSeverity.none,
        reason: 'cover painted 0x${argb.toRadixString(16)}');
  });

  testWidgets('ready + reduced motion: cover is gone at once', (t) async {
    await t.pumpWidget(_app(ready: true, reduced: true));
    expect(find.byType(AnimatedOpacity), findsNothing);
    expect(find.byKey(const Key('app')), findsOneWidget);
  });
}
