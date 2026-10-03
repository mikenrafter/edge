// Structural replacement for SCREEN goldens. A screen that is not a showcase
// is protected by what it must contain and by not overflowing, not by pixels.
//
// Each screen is pumped at two phone sizes and once more at 2x text on the
// small phone, then scrolled to the bottom so rows below the fold are laid
// out too. The 2x pass is the check the retired 2x goldens made: large text is
// where cards overflow. `takeException` catches RenderFlex overflow because
// the framework reports it as a FlutterError.
//
// What the screen must contain is checked once on a viewport tall enough to
// build every row, because a lazy list builds only what is on screen.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _viewports = <(String, Size, double)>[
  ('360x640', Size(360, 640), 1.0),
  ('390x844', Size(390, 844), 1.0),
  ('360x640 at 2x text', Size(360, 640), 2.0),
];

Future<void> _pump(
  WidgetTester tester,
  Widget screen,
  Size size,
  double scale,
  bool scrolls,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data:
            MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: scrolls
          ? Scaffold(body: SingleChildScrollView(child: screen))
          : screen,
    ),
  );
  // A busy spinner never settles. Two bounded pumps allow layout and font
  // completion while keeping animation deterministic.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Registers the structural tests for [screen]. [present] states what the
/// screen must show, with plain finders.
void screenStructure(
  String name,
  Widget screen,
  void Function() present, {
  bool scrolls = false,
}) {
  testWidgets('$name content', (tester) async {
    await _pump(tester, screen, const Size(390, 6000), 1.0, scrolls);
    expect(tester.takeException(), isNull, reason: '$name threw');
    present();
  });
  for (final (label, size, scale) in _viewports) {
    testWidgets('$name no overflow $label', (tester) async {
      await _pump(tester, screen, size, scale, scrolls);
      expect(tester.takeException(), isNull,
          reason: '$name overflowed or threw at $label');
      final scrollable = find.byType(Scrollable);
      if (scrollable.evaluate().isEmpty) return;
      final position = tester.state<ScrollableState>(scrollable.first).position;
      while (position.pixels < position.maxScrollExtent) {
        position.jumpTo(math.min(
            position.pixels + size.height * 0.8, position.maxScrollExtent));
        await tester.pump();
        expect(tester.takeException(), isNull,
            reason: '$name overflowed at $label, ${position.pixels} px down');
      }
    });
  }
}
