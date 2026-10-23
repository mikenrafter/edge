// RED tests: the Home overview card (rings Recovery / Strain / Sleep).
// Owner decisions 2026-10-22 (ui-feedback-2026-10-22.md: DECIDED 3 and 4, Mock
// review, and the older-calculation direction of 2026-10-23 01:59). Approved
// mocks: mockups/ui-2026-10-22/v2/home_after_{0,1,2}_pressing.png and
// v3/home_older_{only,with_recovery}.png.
//
// WHAT THE CARD DOES NOW (so what the green phase replaces)
//   * RingTrio ends in a help strip whose "Why? HRV · Resting heart rate ·
//     Breathing rate" row (or a bare "Why?") opens Recovery.
//   * Home prints "Updated 16:08 · recordings through 16:04 · Waiting for sync
//     to finish" in a row under the card (_homeAsOf -> AsOfHold -> AsOfLabel).
//   * The older-calculation state is only an asterisk on the strain number.
//
// PINNED CONTRACT (keys are ValueKey<String>; the green phase must provide them)
//   home-why:<recovery|strain|sleep>        a "why" panel, tappable. 0, 1 or 2,
//                                           ONLY for the most pressing rings.
//   home-why-icon:<kind>                    the 32 pt circle holding the RING'S
//                                           OWN icon (recovery batteryCharging,
//                                           strain zap, sleep moon), never info.
//   home-why-title:<kind> / -body:<kind>    bold title / one-or-two-line body.
//   home-older-row                          the older-calculation row (same
//                                           inset panel style, neutral colour).
//   home-older-row-icon                     its circle (LucideIcons.history).
//   home-since                              the "since hh:mm" caption, inside
//                                           the card (card:rings), top right.
//   home-since-progress                     the tiny progress arc, present only
//                                           while a sync is pending.
// The panels, the older row and the overlay live INSIDE card:rings. Opening a
// panel calls RingTrio.onOpen(kind); the older row calls onOpen(strain).
//
// "SINCE" TIME (assumption, TODO owner review): it is the day's
// recordings-through time (LocalRepository.dayRecordingsThrough), the figure the
// old line printed as "recordings through". Unknown -> no overlay. "Sync
// pending" is the old line's "Waiting for sync to finish": the derive scheduler
// holds for an offload AND newer recordings exist than the result covers.
//
// "PRESSING" -- there was NO existing notion on Home (grep: none). The nearest
// existing vocabulary is readinessBand() (tier 0 "Rest today", tier 1 "Take it
// easy") and the sleep ring's whole-percent-of-need. So this file specifies a
// pure function, pressingRings (stub below), with these thresholds.
//   TODO(owner review): every number here is a proposal.
//   severity 3: recovery tier 0 (< 26), or sleep < 70% of need
//   severity 2: recovery tier 1 (26..36), or sleep 70..84% of need
//   severity 1: strain above the top of today's strain target range
//   otherwise not pressing. A ring with no value, a provisional / in-progress
//   recovery, or a sleep with no scored night is NEVER pressing (never
//   fabricate). Order: severity descending, ties recovery, sleep, strain.
//   At most 2 are returned.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/as_of_recalc_fakes.dart';
import 'support/older_version_fixtures.dart';

final _now = DateTime(2026, 10, 4, 15);

Metric _m(num v, {int? older, String? reason}) => Metric(
    value: v,
    confidence: .8,
    tier: MetricTier.high,
    fromOlderVersion: older,
    olderVersionReason: reason);

HomeData _data({
  num? recovery = 80,
  num? sleep = 450, // minutes
  num need = 480,
  num? strain = 5.0,
  Map<String, dynamic>? target,
  int? olderStrain,
  String? olderReason,
  DateTime? computedAt,
}) =>
    HomeData(
      dayId: todayLabel(),
      readiness: recovery == null ? Metric.empty : _m(recovery),
      sleepMin: sleep == null ? Metric.empty : _m(sleep),
      sleepNeedMin: _m(need),
      strain: strain == null
          ? Metric.empty
          : _m(strain, older: olderStrain, reason: olderReason),
      strainTarget: target,
      overnightAt: computedAt,
      activityAt: computedAt,
      overnightDay: computedAt == null ? null : todayLabel(),
      activityDay: computedAt == null ? null : todayLabel(),
    );

// Fixtures. 10 -> tier 0; 30 -> tier 1; 66% of 528 min is the mock's sleep.
HomeData get _healthy => _data();
HomeData get _lowRecovery => _data(recovery: 10);
HomeData get _rec2Sleep3 => _data(recovery: 30, sleep: 350, need: 528);
HomeData get _recAndSleep => _data(recovery: 10, sleep: 350, need: 528);
HomeData get _olderOnly =>
    _data(strain: 8.4, olderStrain: 104, olderReason: kReasonRaw);
HomeData get _olderAndRecovery => _data(
    recovery: 10, strain: 8.4, olderStrain: 104, olderReason: kReasonRaw);
HomeData get _olderAndTwo => _data(
    recovery: 10,
    sleep: 350,
    need: 528,
    strain: 8.4,
    olderStrain: 104,
    olderReason: kReasonRaw);

class _Repo extends HomeRepo {
  _Repo() : super(const {});
  DateTime? through;
  @override
  Future<DateTime?> dayRecordingsThrough(String day) async => through;
}

DateTime _at(int h, int m) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day, h, m);
}

void _surface(WidgetTester t, double w, {double scale = 1.0}) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(w, 3200);
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<AppState> _home(WidgetTester t, HomeData d,
    {double w = 390,
    double scale = 1.0,
    DateTime? through,
    bool syncPending = false}) async {
  _surface(t, w, scale: scale);
  final repo = _Repo()..through = through;
  final app = AppState.forTesting()..repo = repo;
  addTearDown(app.dispose);
  if (syncPending) {
    // Newer recordings than the result covers, derive held for an offload.
    (app as dynamic).debugLastRecTs = _at(16, 10).millisecondsSinceEpoch ~/ 1000;
    (app as dynamic).debugDeriveScheduler.setOffloadActive(true);
    addTearDown(() => (app as dynamic).debugDeriveScheduler.setOffloadActive(false));
  }
  await t.pumpWidget(perfApp(app, HomeScreen(data: d, hour: 9, now: _now)));
  await settle(t, n: 6);
  return app;
}

Future<void> _rings(WidgetTester t, HomeData d,
    {void Function(HomeRingKind)? onOpen, double w = 390}) async {
  _surface(t, w);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
        body: SingleChildScrollView(
            child: RingTrio(d: d, now: _now, onOpen: onOpen))),
  ));
  await t.pump();
}

Finder _why(String k) => find.byKey(ValueKey('home-why:$k'));
final _anyWhy = find.byWidgetPredicate((w) =>
    w.key is ValueKey<String> &&
    (w.key as ValueKey<String>).value.startsWith('home-why:'));
final _card = find.byKey(const ValueKey('card:rings'));
final _olderRow = find.byKey(const ValueKey('home-older-row'));
final _since = find.byKey(const ValueKey('home-since'));
final _sinceArc = find.byKey(const ValueKey('home-since-progress'));

List<String> _whyOrder(WidgetTester t) {
  final all = t.widgetList(_anyWhy).map((w) => (w.key as ValueKey<String>).value);
  return [
    for (final k in all) k.substring('home-why:'.length),
  ]..sort((a, b) =>
      t.getTopLeft(_why(a)).dy.compareTo(t.getTopLeft(_why(b)).dy));
}

Map<String, Offset> _ringPos(WidgetTester t) => {
      for (final l in ['RECOVERY', 'STRAIN', 'SLEEP'])
        l: t.getTopLeft(find.descendant(of: _card, matching: find.text(l)).first),
    };

Color _fill(Widget w) =>
    ((w as Container).decoration! as BoxDecoration).color!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // ── 0. what "pressing" means (pure function, stubbed above) ───────────────
  group('pressingRings (thresholds are a proposal; see header)', () {
    test('healthy day: nothing is pressing', () {
      expect(pressingRings(_healthy, now: _now), isEmpty);
    });

    test('recovery: tier 0 and tier 1 are pressing, the boundary is 37', () {
      expect(pressingRings(_data(recovery: 10), now: _now),
          [HomeRingKind.recovery]);
      expect(pressingRings(_data(recovery: 36), now: _now),
          [HomeRingKind.recovery]);
      expect(pressingRings(_data(recovery: 37), now: _now), isEmpty);
    });

    test('sleep: under 85% of need is pressing (84 yes, 86 no)', () {
      expect(pressingRings(_data(sleep: 403, need: 480), now: _now),
          [HomeRingKind.sleep]);
      expect(pressingRings(_data(sleep: 413, need: 480), now: _now), isEmpty);
    });

    test('strain: only above the top of the target range', () {
      const t = {'value': 10, 'low': 8, 'high': 12};
      expect(pressingRings(_data(strain: 15, target: t), now: _now),
          [HomeRingKind.strain]);
      expect(pressingRings(_data(strain: 11, target: t), now: _now), isEmpty);
      // Low strain is not pressing, and with no target there is no range.
      expect(pressingRings(_data(strain: 0.0, target: t), now: _now), isEmpty);
      expect(pressingRings(_data(strain: 20), now: _now), isEmpty);
    });

    test('ordered by severity, ties recovery then sleep', () {
      // recovery 30 is severity 2, sleep at 66% is severity 3.
      expect(pressingRings(_rec2Sleep3, now: _now),
          [HomeRingKind.sleep, HomeRingKind.recovery]);
      // Both severity 3: recovery first.
      expect(pressingRings(_recAndSleep, now: _now),
          [HomeRingKind.recovery, HomeRingKind.sleep]);
    });

    test('at most 2, the least pressing is dropped', () {
      final d = _data(
          recovery: 10,
          sleep: 350,
          need: 528,
          strain: 15,
          target: const {'value': 10, 'low': 8, 'high': 12});
      expect(pressingRings(d, now: _now),
          [HomeRingKind.recovery, HomeRingKind.sleep]);
    });

    test('absent or provisional values are never pressing', () {
      expect(pressingRings(_data(recovery: null, sleep: null), now: _now),
          isEmpty);
      final provisional = HomeData(
          dayId: todayLabel(),
          readiness: _m(10),
          recoveryState: 'provisional');
      expect(pressingRings(provisional, now: _now), isEmpty);
      final sleeping = HomeData(
          dayId: todayLabel(),
          readiness: Metric.empty,
          recoveryState: 'night_in_progress');
      expect(pressingRings(sleeping, now: _now), isEmpty);
    });

    test('an older-version value does not make a ring pressing', () {
      expect(pressingRings(_olderOnly, now: _now), isEmpty);
    });
  });

  // ── 1. the why panels ─────────────────────────────────────────────────────
  group('why panels', () {
    testWidgets('the "Why?" explainer row is gone', (t) async {
      // Drivers present: today this prints "Why? HRV · Resting heart ...".
      final d = HomeData(
        dayId: todayLabel(),
        readiness: _m(80),
        sleepMin: _m(450),
        sleepNeedMin: _m(480),
        strain: _m(5),
        drivers: const [
          {'label': 'hrv'},
          {'label': 'rhr'},
          {'label': 'resp'},
        ],
      );
      await _rings(t, d);
      expect(find.textContaining('Why?'), findsNothing);
      expect(find.byIcon(LucideIcons.info), findsNothing);
      await _rings(t, _healthy); // and the bare "Why?" with no drivers
      expect(find.textContaining('Why?'), findsNothing);
    });

    testWidgets('0 pressing: no panel at all', (t) async {
      await _rings(t, _healthy);
      expect(_anyWhy, findsNothing);
    });

    testWidgets('1 pressing: exactly the recovery panel', (t) async {
      await _rings(t, _lowRecovery);
      expect(_anyWhy, findsOneWidget);
      expect(_why('recovery'), findsOneWidget);
      expect(find.text('Recovery is low'), findsOneWidget);
    });

    testWidgets('2 pressing: recovery then sleep, capped at 2 of 3', (t) async {
      final d = _data(
          recovery: 10,
          sleep: 350,
          need: 528,
          strain: 15,
          target: const {'value': 10, 'low': 8, 'high': 12});
      await _rings(t, d);
      expect(_whyOrder(t), ['recovery', 'sleep']);
      expect(_why('strain'), findsNothing);
      expect(find.text('Sleep is short of need'), findsOneWidget);
      // The mock's body, derived from the data: 5h 50m vs 8h 48m need.
      expect(find.text('5h 50m asleep, 2h 58m under your 8h 48m need.'),
          findsOneWidget);
    });

    testWidgets('ordered by pressingness, not by ring order', (t) async {
      await _rings(t, _rec2Sleep3);
      expect(_whyOrder(t), ['sleep', 'recovery']);
    });

    testWidgets('a pressing strain gets the strain panel', (t) async {
      await _rings(
          t,
          _data(
              strain: 15,
              target: const {'value': 10, 'low': 8, 'high': 12}));
      expect(_whyOrder(t), ['strain']);
    });

    testWidgets('inset style: the Overnight-signals inner panel', (t) async {
      await _rings(t, _lowRecovery);
      expect(_why('recovery'), findsOneWidget);
      final p = P.of(t.element(_why('recovery')));
      final box = find.descendant(
          of: _why('recovery'), matching: find.byType(Container));
      final insets = t.widgetList<Container>(box).where((c) {
        final dec = c.decoration;
        return dec is BoxDecoration &&
            dec.color == p.card2 &&
            dec.borderRadius == R.rMd;
      });
      expect(insets, isNotEmpty,
          reason: 'a Container filled card2 with the rMd radius');
    });

    testWidgets('icon: the ring\'s own, in a circle, never an (i)', (t) async {
      final d = _data(
          recovery: 10,
          sleep: 350,
          need: 528,
          strain: 15,
          target: const {'value': 10, 'low': 8, 'high': 12});
      // Show all three by asking each pair in turn.
      await _rings(t, d);
      expect(_whyOrder(t), ['recovery', 'sleep']);
      Finder iconIn(String k) => find.descendant(
          of: find.byKey(ValueKey('home-why-icon:$k')),
          matching: find.byType(Icon));
      expect(t.widget<Icon>(iconIn('recovery')).icon, LucideIcons.batteryCharging);
      expect(t.widget<Icon>(iconIn('sleep')).icon, LucideIcons.moon);
      final circle =
          t.widget<Container>(find.byKey(const ValueKey('home-why-icon:recovery')));
      expect((circle.decoration! as BoxDecoration).shape, BoxShape.circle);
      expect(find.descendant(of: _why('recovery'), matching: find.byIcon(LucideIcons.info)),
          findsNothing);

      await _rings(
          t,
          _data(
              strain: 15,
              target: const {'value': 10, 'low': 8, 'high': 12}));
      expect(t.widget<Icon>(iconIn('strain')).icon, LucideIcons.zap);
    });

    testWidgets('bold title, body of one or two lines, a chevron', (t) async {
      await _rings(t, _recAndSleep, w: 360);
      expect(_whyOrder(t), ['recovery', 'sleep']);
      for (final k in ['recovery', 'sleep']) {
        final title = t.widget<Text>(find.byKey(ValueKey('home-why-title:$k')));
        expect(title.style?.fontWeight?.index,
            greaterThanOrEqualTo(FontWeight.w600.index));
        final body = find.byKey(ValueKey('home-why-body:$k'));
        expect(t.widget<Text>(body).data, isNotEmpty);
        final rp = t.renderObject(body) as RenderParagraph;
        final fs = rp.text.style?.fontSize ?? 12;
        final lines = (rp.size.height / (fs * 1.45)).round();
        expect(lines, inInclusiveRange(1, 2), reason: '$k body lines');
        expect(
            find.descendant(
                of: _why(k), matching: find.byIcon(LucideIcons.chevronRight)),
            findsOneWidget);
      }
    });

    testWidgets('icon and chevron are vertically centred in the panel',
        (t) async {
      await _rings(t, _recAndSleep, w: 360);
      expect(_whyOrder(t), ['recovery', 'sleep']);
      for (final k in ['recovery', 'sleep']) {
        final mid = t.getCenter(_why(k)).dy;
        final icon = t.getCenter(find.byKey(ValueKey('home-why-icon:$k'))).dy;
        final chev = t.getCenter(find.descendant(
            of: _why(k), matching: find.byIcon(LucideIcons.chevronRight))).dy;
        expect((icon - mid).abs(), lessThan(1.0), reason: '$k icon');
        expect((chev - mid).abs(), lessThan(1.0), reason: '$k chevron');
      }
    });

    testWidgets('a panel opens its ring\'s detail', (t) async {
      final opened = <HomeRingKind>[];
      await _rings(t, _recAndSleep, onOpen: opened.add);
      expect(_anyWhy, findsNWidgets(2));
      await t.tap(_why('sleep'));
      await t.tap(_why('recovery'));
      expect(opened, [HomeRingKind.sleep, HomeRingKind.recovery]);
    });
  });

  // ── 2. the "since hh:mm" overlay ──────────────────────────────────────────
  group('since overlay', () {
    testWidgets('top right inside the card, a small caption', (t) async {
      await _home(t, _data(computedAt: _at(16, 8)), through: _at(16, 4));
      expect(find.text('since 16:04'), findsOneWidget);
      final card = t.getRect(_card);
      final s = t.getRect(_since);
      expect(card.contains(s.topLeft) && card.contains(s.bottomRight), isTrue,
          reason: 'inside card:rings');
      expect(s.center.dx, greaterThan(card.center.dx), reason: 'right half');
      // The caption sits in the card's first line (18 pt visual row, round 4).
      final line = t.getRect(find.byKey(const ValueKey('home-since-line')));
      expect(line.top - card.top, lessThan(28), reason: 'the line is the top of the card');
      expect(line.contains(s.center), isTrue, reason: 'caption inside the line');
      final style = t.widget<Text>(find.descendant(of: _since, matching: find.byType(Text)).first).style;
      expect(style?.fontSize ?? 99, lessThanOrEqualTo(12), reason: 'small caption');
    });

    testWidgets('no time known: no overlay (nothing made up)', (t) async {
      await _home(t, _data(computedAt: _at(16, 8)));
      expect(_since, findsNothing);
      expect(find.textContaining('since'), findsNothing);
    });

    testWidgets('a pending sync adds a tiny progress arc, otherwise none',
        (t) async {
      await _home(t, _data(computedAt: _at(16, 8)),
          through: _at(16, 4), syncPending: true);
      expect(_sinceArc, findsOneWidget);
      expect(t.getSize(_sinceArc).longestSide, lessThanOrEqualTo(12));
      expect(find.text('since 16:04'), findsOneWidget);
    });

    testWidgets('no pending sync: no arc', (t) async {
      await _home(t, _data(computedAt: _at(16, 8)), through: _at(16, 4));
      expect(_since, findsOneWidget);
      expect(_sinceArc, findsNothing);
    });

    testWidgets('"Updated ... recordings through ... Waiting for sync" is gone',
        (t) async {
      await _home(t, _data(computedAt: _at(16, 8)),
          through: _at(16, 4), syncPending: true);
      expect(find.textContaining('recordings through'), findsNothing);
      expect(find.textContaining('Waiting for sync'), findsNothing);
      expect(find.textContaining('Updated 16:08'), findsNothing);
      expect(find.byType(AsOfLabel), findsNothing);
    });

    testWidgets('adds no row: rings and the next card sit at the same y',
        (t) async {
      final detected = find.byKey(const ValueKey('card:detected'));
      await _home(t, _data(computedAt: _at(16, 8)));
      final without = _ringPos(t);
      final cardH = t.getSize(_card).height;
      final next = t.getTopLeft(detected).dy;

      await _home(t, _data(computedAt: _at(16, 8)),
          through: _at(16, 4), syncPending: true);
      expect(_ringPos(t), without, reason: 'rings do not move');
      expect(t.getSize(_card).height, cardH, reason: 'card does not grow');
      expect(t.getTopLeft(detected).dy, next, reason: 'no row under the card');
    });
  });

  // ── 3. the older-calculation row ──────────────────────────────────────────
  group('older-calculation row', () {
    testWidgets('same pressing style, neutral colour, history icon, text',
        (t) async {
      await _rings(t, _olderOnly);
      expect(_olderRow, findsOneWidget);
      expect(find.text('* Strain is from an older calculation'), findsOneWidget);
      expect(find.text('Version 104 · $kReasonSentence'), findsOneWidget);
      expect(find.descendant(of: _olderRow, matching: find.byIcon(LucideIcons.history)),
          findsOneWidget);
      expect(find.descendant(of: _olderRow, matching: find.byIcon(LucideIcons.chevronRight)),
          findsOneWidget);
      final p = P.of(t.element(_olderRow));
      final icon = t.widget<Icon>(find.descendant(
          of: _olderRow, matching: find.byIcon(LucideIcons.history)));
      expect(icon.color, p.ink2, reason: 'neutral, not a ring colour');
      final circle = t.widget<Container>(
          find.byKey(const ValueKey('home-older-row-icon')));
      expect(_fill(circle), p.ink3.withValues(alpha: .16));
      // Same inset panel as the whys.
      final insets = t.widgetList<Container>(find.descendant(
          of: _olderRow, matching: find.byType(Container))).where((c) {
        final dec = c.decoration;
        return dec is BoxDecoration &&
            dec.color == p.card2 &&
            dec.borderRadius == R.rMd;
      });
      expect(insets, isNotEmpty);
      // Icon and chevron centred.
      final mid = t.getCenter(_olderRow).dy;
      expect((t.getCenter(find.byKey(const ValueKey('home-older-row-icon'))).dy - mid).abs(),
          lessThan(1.0));
    });

    testWidgets('no older value: no row', (t) async {
      await _rings(t, _healthy);
      expect(_olderRow, findsNothing);
      expect(find.textContaining('older calculation'), findsNothing);
    });

    testWidgets('it opens something (tappable, not just an asterisk)',
        (t) async {
      final opened = <HomeRingKind>[];
      await _rings(t, _olderOnly, onOpen: opened.add);
      expect(_olderRow, findsOneWidget);
      await t.tap(_olderRow);
      expect(opened, [HomeRingKind.strain]);
    });

    testWidgets('always below the whys: max 2 whys + 1 older row', (t) async {
      await _rings(t, _olderAndTwo);
      expect(_whyOrder(t), ['recovery', 'sleep']);
      expect(_olderRow, findsOneWidget);
      final lastWhy = t.getBottomLeft(_why('sleep')).dy;
      expect(t.getTopLeft(_olderRow).dy, greaterThanOrEqualTo(lastWhy));
    });

    testWidgets('below a single why too', (t) async {
      await _rings(t, _olderAndRecovery);
      expect(_whyOrder(t), ['recovery']);
      expect(t.getTopLeft(_olderRow).dy,
          greaterThanOrEqualTo(t.getBottomLeft(_why('recovery')).dy));
    });

    testWidgets('the older status is spoken exactly once on the card',
        (t) async {
      final h = t.ensureSemantics();
      await _rings(t, _olderOnly);
      expect(_olderRow, findsOneWidget, reason: 'the row exists first');
      expect(spokenCount(t), 1, reason: 'row only, or mark only; never both');
      await _rings(t, _olderAndTwo);
      expect(_olderRow, findsOneWidget);
      expect(spokenCount(t), 1);
      await _rings(t, _healthy);
      expect(spokenCount(t), 0);
      h.dispose();
    });
  });

  // ── 4. layout: nothing reserved, rings never move, no overflow ────────────
  group('layout', () {
    final states = <String, HomeData Function()>{
      '0 panels': () => _healthy,
      '1 panel': () => _lowRecovery,
      '2 panels': () => _recAndSleep,
      'older row only': () => _olderOnly,
      '2 panels + older row': () => _olderAndTwo,
    };

    for (final w in [360.0, 390.0]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('ring positions identical across states @${w.toInt()} pt, x$scale',
            (t) async {
          Map<String, Offset>? base;
          for (final e in states.entries) {
            await _home(t, e.value(), w: w, scale: scale);
            expect(t.takeException(), isNull, reason: '${e.key}: overflow');
            final pos = _ringPos(t);
            base ??= pos;
            expect(pos, base, reason: e.key);
            // Panels only ADD below the rings.
            final ringsBottom = t
                .getRect(find.descendant(of: _card, matching: find.text('SLEEP')).first)
                .bottom;
            for (final f in [_anyWhy, _olderRow]) {
              for (var i = 0; i < f.evaluate().length; i++) {
                expect(t.getTopLeft(f.at(i)).dy, greaterThan(ringsBottom),
                    reason: '${e.key}: below the rings');
              }
            }
          }
        });

        testWidgets('0 panels reserves no empty space; each row costs its height @${w.toInt()} pt, x$scale',
            (t) async {
          await _home(t, _healthy, w: w, scale: scale);
          final h0 = t.getSize(_card).height;
          // The card ends right under the ring captions (its own padding).
          final texts = find.descendant(of: _card, matching: find.byType(Text));
          var lowest = 0.0;
          for (final e in texts.evaluate()) {
            lowest = [lowest, t.getRect(find.byWidget(e.widget)).bottom].reduce((a, b) => a > b ? a : b);
          }
          expect(t.getRect(_card).bottom - lowest, lessThanOrEqualTo(28),
              reason: 'no empty reserved strip under the rings');

          await _home(t, _lowRecovery, w: w, scale: scale);
          final h1 = t.getSize(_card).height;
          final p1 = t.getSize(_why('recovery')).height;
          expect(h1 - h0 - p1, inInclusiveRange(0, 16), reason: 'one panel + a gap');

          await _home(t, _recAndSleep, w: w, scale: scale);
          final h2 = t.getSize(_card).height;
          final p2 = t.getSize(_why('sleep')).height;
          expect(h2 - h1 - p2, inInclusiveRange(0, 16), reason: 'second panel + a gap');
          expect(t.takeException(), isNull);
        });
      }
    }
  });
}
