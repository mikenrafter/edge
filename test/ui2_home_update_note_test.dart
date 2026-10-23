// RED: Home must keep the shared recovery update note ("Updated 8:12 AM · 62 → 58").
// It used to live in the help strip the Home card removed; a changed number
// must be explained (honesty). The same line text Readiness detail and Health
// print (recoveryUpdatedLine) now shows as a NEUTRAL row in the pressing style:
//   key home-update-note       the row (inset card2/rMd panel, tappable)
//   key home-update-note-icon  circle, ink3 @ .16, LucideIcons.refreshCw
//   title = the shared line, chevron, icon and chevron centred.
// ORDER: why panels (max 2), then the update note, then the older row.
// Shown whenever the shared line is non-empty. Taps open recovery. Spoken once.
// Adds nothing above the rings: dials and labels sit where they did.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/clock_format.dart' show formatClockOf;
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/older_version_fixtures.dart';

final _at = DateTime(2026, 10, 8, 8, 12).millisecondsSinceEpoch;
final _line = 'Updated ${formatClockOf(DateTime.fromMillisecondsSinceEpoch(_at))} · 62 → 58';
final _row = find.byKey(const ValueKey('home-update-note'));
final _dials = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Dial');

Metric _m(num v, {int? older}) => Metric(
    value: v, confidence: .8, tier: MetricTier.high,
    fromOlderVersion: older, olderVersionReason: older == null ? null : kReasonRaw);

HomeData _d({num recovery = 58, bool update = true, bool twoWhys = false, bool older = false}) =>
    HomeData(
      dayId: '2026-10-08',
      recoveryState: 'final',
      readiness: _m(recovery),
      sleepMin: _m(twoWhys ? 350 : 450),
      sleepNeedMin: _m(twoWhys ? 528 : 480),
      strain: _m(older ? 8.4 : 5, older: older ? 104 : null),
      readinessUpdate: update ? {'from': 62, 'to': 58, 'at': _at} : null,
    );

Future<void> _pump(WidgetTester t, HomeData d, {void Function(HomeRingKind)? onOpen, double w = 390}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(w, 3000);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
        body: SingleChildScrollView(
            child: RingTrio(d: d, now: DateTime(2026, 10, 8, 15), onOpen: onOpen))),
  ));
  await t.pump();
}

void main() {
  testWidgets('the row carries the shared line, once, tappable to recovery', (t) async {
    final opened = <HomeRingKind>[];
    await _pump(t, _d(), onOpen: opened.add);
    expect(_row, findsOneWidget);
    expect(find.text(_line), findsOneWidget);
    await t.tap(_row);
    expect(opened, [HomeRingKind.recovery]);
  });

  testWidgets('no update, no row', (t) async {
    await _pump(t, _d(update: false));
    expect(_row, findsNothing);
    expect(find.textContaining('Updated'), findsNothing);
  });

  testWidgets('neutral pressing style: inset panel, refresh icon, chevron, centred', (t) async {
    await _pump(t, _d());
    final p = P.of(t.element(_row));
    expect(find.descendant(of: _row, matching: find.byIcon(LucideIcons.refreshCw)), findsOneWidget);
    expect(find.descendant(of: _row, matching: find.byIcon(LucideIcons.chevronRight)), findsOneWidget);
    final icon = t.widget<Icon>(find.descendant(of: _row, matching: find.byIcon(LucideIcons.refreshCw)));
    expect(icon.color, p.ink2);
    final circle = t.widget<Container>(find.byKey(const ValueKey('home-update-note-icon')));
    expect(((circle.decoration! as BoxDecoration).color), p.ink3.withValues(alpha: .16));
    expect((circle.decoration! as BoxDecoration).shape, BoxShape.circle);
    final insets = t.widgetList<Container>(find.descendant(of: _row, matching: find.byType(Container))).where((c) {
      final d = c.decoration;
      return d is BoxDecoration && d.color == p.card2 && d.borderRadius == R.rMd;
    });
    expect(insets, isNotEmpty);
    final mid = t.getCenter(_row).dy;
    expect((t.getCenter(find.byKey(const ValueKey('home-update-note-icon'))).dy - mid).abs(), lessThan(1));
    expect((t.getCenter(find.descendant(of: _row, matching: find.byIcon(LucideIcons.chevronRight))).dy - mid).abs(), lessThan(1));
  });

  testWidgets('order: whys, then the update note, then the older row', (t) async {
    await _pump(t, _d(recovery: 10, twoWhys: true, older: true));
    final why = [for (final k in ['recovery', 'sleep']) t.getTopLeft(find.byKey(ValueKey('home-why:$k'))).dy];
    final note = t.getTopLeft(_row).dy;
    final older = t.getTopLeft(find.byKey(const ValueKey('home-older-row'))).dy;
    expect(why[0] < why[1], isTrue);
    expect(why[1] < note, isTrue, reason: 'note below the whys');
    expect(note < older, isTrue, reason: 'older row last');
  });

  testWidgets('spoken once', (t) async {
    final h = t.ensureSemantics();
    await _pump(t, _d());
    expect(spokenCount(t, RegExp('Updated .* 62 → 58')), 1);
    h.dispose();
  });

  testWidgets('adds nothing above the rings: dials and labels do not move', (t) async {
    await _pump(t, _d(update: false));
    final before = [for (var i = 0; i < 3; i++) t.getRect(_dials.at(i))];
    await _pump(t, _d());
    expect([for (var i = 0; i < 3; i++) t.getRect(_dials.at(i))], before);
  });
}
