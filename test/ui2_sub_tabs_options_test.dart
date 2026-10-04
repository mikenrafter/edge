// SubTabs options the Alarm day tabs use: per-tab keys and screen-reader labels,
// "muted" (drawn off but still tappable, unlike `disabled`) and `dense` (seven
// short labels fit a 360 pt phone).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

Future<void> _pump(WidgetTester t, Widget w, {double width = 360}) async {
  t.view.physicalSize = Size(width, 400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(S.x4), child: w),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('itemKeys put a key on each tab', (t) async {
    await _pump(
      t,
      SubTabs(
        _days,
        0,
        (_) {},
        itemKeys: [for (var i = 0; i < 7; i++) ValueKey('d$i')],
        dense: true,
      ),
    );
    // The test font is wider than the app's, so the last tabs may sit past the
    // edge; the first is always built.
    expect(find.byKey(const ValueKey('d0')), findsOneWidget);
    expect(find.byKey(const ValueKey('d1')), findsOneWidget);
  });

  testWidgets('semanticLabels name each tab for a screen reader', (t) async {
    final h = t.ensureSemantics();
    await _pump(
      t,
      SubTabs(
        _days,
        0,
        (_) {},
        semanticLabels: [for (final d in _days) 'Edit $d'],
        dense: true,
      ),
    );
    expect(find.bySemanticsLabel(RegExp('Edit Tue')), findsOneWidget);
    h.dispose();
  });

  testWidgets('a muted tab is drawn off but still taps', (t) async {
    final taps = <int>[];
    await _pump(
      t,
      SubTabs(
        _days,
        0,
        taps.add,
        muted: const {2},
        itemKeys: [for (var i = 0; i < 7; i++) ValueKey('d$i')],
        dense: true,
      ),
    );
    Color? fill(int i) {
      final box = t.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(ValueKey('d$i')),
          matching: find.byType(AnimatedContainer),
        ),
      );
      return (box.decoration as BoxDecoration?)?.color;
    }

    final p = P.of(t.element(find.byType(SubTabs)));
    expect(fill(2), p.card2, reason: 'the off look, like a disabled tab');
    expect(fill(3), isNot(p.card2));
    await t.tap(find.byKey(const ValueKey('d2')));
    expect(taps, [2]);
  });

  testWidgets('dense never overflows: a wider font scrolls, every tab is '
      'reachable', (t) async {
    final taps = <int>[];
    await _pump(t, SubTabs(_days, 0, taps.add, dense: true));
    expect(t.takeException(), isNull);
    await t.ensureVisible(find.text('Sun'));
    await t.pumpAndSettle();
    await t.tap(find.text('Sun'));
    expect(taps, [6]);
    expect(t.takeException(), isNull);
  });

  testWidgets('dense tabs are narrower than the default ones', (t) async {
    await _pump(t, SubTabs(const ['Mon', 'Tue'], 0, (_) {}));
    final wide = t.getRect(find.text('Tue')).left;
    await _pump(t, SubTabs(const ['Mon', 'Tue'], 0, (_) {}, dense: true));
    expect(t.getRect(find.text('Tue')).left, lessThan(wide));
  });
}
