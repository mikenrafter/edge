// Home's greeting with a long name: never a name cut off mid-word. Too long at
// 28 pt it is set at 22 pt on the same line; too long even then (320 pt) the
// greeting shows alone. Real fonts, so widths are real.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/bundled_fonts.dart';

Future<void> _pump(WidgetTester t, double width) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(width, 400);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: const Scaffold(
      body: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: ScreenTitle('Good afternoon, Alexandra',
            shortTitle: 'Good afternoon',
            avatar: SizedBox(width: 40, height: 40)),
      ),
    ),
  ));
  await t.pump();
}

void main() {
  setUpAll(loadFonts);

  testWidgets('320 pt: the greeting alone, not a truncated name', (t) async {
    await _pump(t, 320);
    expect(find.text('Good afternoon'), findsOneWidget);
    expect(find.text('Good afternoon, Alexandra'), findsNothing);
  });

  testWidgets('390 pt: the full title, set smaller to fit', (t) async {
    await _pump(t, 390);
    final w = t.widget<Text>(find.text('Good afternoon, Alexandra'));
    expect(w.style!.fontSize, 22);
  });

  testWidgets('a title that fits keeps the title size', (t) async {
    await _pump(t, 600);
    final w = t.widget<Text>(find.text('Good afternoon, Alexandra'));
    expect(w.style!.fontSize, 28);
  });

  testWidgets('the slot is the same height either way', (t) async {
    await _pump(t, 320);
    final short = t.getSize(find.byKey(const ValueKey('shared:title'))).height;
    await _pump(t, 390);
    final full = t.getSize(find.byKey(const ValueKey('shared:title'))).height;
    expect(short, full);
  });
}
