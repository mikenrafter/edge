// RED tests: fix round on the Home card (Sol r1: 1 P1 + 5 P2).
//
//  P1  the "since" lookup (dayRecordingsThrough) throws ReadPaused during
//      import focus. It must NEVER block the main model: load it separately,
//      ReadPaused means "unknown" (overlay hidden), retry when focus ends.
//  P2a an older-version value is never pressing (no why panel for it).
//  P2b why-copy states evidence or nothing:
//        recovery, drivers present: the biggest drags with their numbers
//          "Biggest drag: HRV -1.8, Resting heart rate -1.2 (how far each sits from your usual)."
//        recovery, no drivers: "Recovery 22 of 100" (no "usual range" claim)
//        strain: "Strain 15.2, above today's target of 8–12."
//      (driver fields: label, detail "...=<oriented z>", contribution)
//  P2c the "since" caption is its own slim right-aligned line ABOVE the rings
//      (height reserved whether or not the time is known); never over a dial.
//  P2d the progress arc follows the scheduler (watch, not read).
//  P2e the arc condition is the OLD "Waiting for ..." condition: a hold AND
//      newer recordings than the result covers. Held + stale: the caption is
//      tappable, opens the old explanation, and its semantics carry the reason.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/read_paused.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/import_focus.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/as_of_recalc_fakes.dart';
import 'support/last_result_db.dart';
import 'support/older_version_fixtures.dart';
import 'support/read_paused_fakes.dart';

final _now = DateTime(2026, 10, 4, 15);
const _target = {'value': 10, 'low': 8, 'high': 12};

Metric _m(num v, {int? older, String? reason}) => Metric(
    value: v,
    confidence: .8,
    tier: MetricTier.high,
    fromOlderVersion: older,
    olderVersionReason: reason);

HomeData _data({
  num? recovery = 80,
  num sleep = 450,
  num strain = 5.0,
  Map<String, dynamic>? target,
  int? olderStrain,
  List<Map<String, dynamic>> drivers = const [],
  DateTime? computedAt,
}) =>
    HomeData(
      dayId: todayLabel(),
      readiness: recovery == null ? Metric.empty : _m(recovery),
      sleepMin: _m(sleep),
      sleepNeedMin: _m(480),
      strain: _m(strain, older: olderStrain, reason: olderStrain == null ? null : kReasonRaw),
      strainTarget: target,
      drivers: drivers,
      overnightAt: computedAt,
      activityAt: computedAt,
      overnightDay: computedAt == null ? null : todayLabel(),
      activityDay: computedAt == null ? null : todayLabel(),
    );

Map<String, dynamic> _drv(String label, double z, double c) => {
      'label': label,
      'detail': 'oriented robust-z (median+MAD)=$z',
      'contribution': c,
    };

DateTime _at(int h, int m) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day, h, m);
}

class _Repo extends HomeRepo {
  _Repo() : super(const {});
  DateTime? through;
  @override
  Future<DateTime?> dayRecordingsThrough(String day) async => through;
}

/// Like FocusRepo, but the since lookup is paused too, as in production.
class _PausedSinceRepo extends FocusRepo {
  DateTime? through;
  @override
  Future<DateTime?> dayRecordingsThrough(String day) async {
    if (ImportFocus.active.value) throw const ReadPaused('import');
    return through;
  }
}

void _surface(WidgetTester t, double w, double scale) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(w, 3200);
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<AppState> _home(WidgetTester t, HomeData d,
    {double w = 390, double scale = 1.0, DateTime? through, int? lastRecSec}) async {
  _surface(t, w, scale);
  final app = AppState.forTesting()..repo = (_Repo()..through = through);
  addTearDown(app.dispose);
  if (lastRecSec != null) (app as dynamic).debugLastRecTs = lastRecSec;
  await t.pumpWidget(perfApp(app, HomeScreen(data: d, hour: 9, now: _now)));
  await settle(t, n: 6);
  return app;
}

/// Lets the database reads a hold release started finish (same as
/// calc_staleness_screen_test): a read in flight at teardown leaves a timer.
Future<void> _settleDb(WidgetTester t) async {
  for (var round = 0; round < 2; round++) {
    var answered = false;
    LocalDb.instance.then((db) => db.rawQuery('SELECT 1')).then(
        (_) => answered = true,
        onError: (_) => answered = true);
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (!answered) {
      if (!DateTime.now().isBefore(end)) fail('database reads still in flight');
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump();
    }
  }
}

dynamic _sched(AppState a) => (a as dynamic).debugDeriveScheduler;
int _sec(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

Future<void> _rings(WidgetTester t, HomeData d, {double w = 390}) async {
  _surface(t, w, 1.0);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
        body: SingleChildScrollView(child: RingTrio(d: d, now: _now))),
  ));
  await t.pump();
}

final _card = find.byKey(const ValueKey('card:rings'));
final _since = find.byKey(const ValueKey('home-since'));
final _arc = find.byKey(const ValueKey('home-since-progress'));
final _dials = find.descendant(
    of: _card,
    matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Dial'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    resetFocus();
  });
  tearDown(resetFocus);

  // ── P1 ────────────────────────────────────────────────────────────────────
  group('P1: the since lookup never blocks the main model', () {
    Future<_PausedSinceRepo> open(WidgetTester t) async {
      _surface(t, 390, 1.0);
      final repo = _PausedSinceRepo()..through = _at(16, 4);
      final app = AppState.forTesting()..repo = repo;
      addTearDown(app.dispose);
      await t.pumpWidget(perfApp(app, const HomeScreen(hour: 9)));
      await settle(t, n: 20);
      return repo;
    }

    testWidgets('during focus: today from the published model, overlay absent, nothing thrown',
        (t) async {
      startFocus();
      await open(t);
      expect(find.text('77'), findsOneWidget, reason: 'published readiness');
      expect(_since, findsNothing);
      expect(find.textContaining('could not be read'), findsNothing);
      expect(t.takeException(), isNull, reason: 'no uncaught ReadPaused');
    });

    testWidgets('when focus ends the lookup is retried and the overlay appears',
        (t) async {
      startFocus();
      await open(t);
      expect(_since, findsNothing);
      endFocus();
      await settle(t, n: 20);
      expect(find.text('since 16:04'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  // ── P2a ───────────────────────────────────────────────────────────────────
  group('P2a: older values are never pressing', () {
    test('an older strain above target is not pressing', () {
      expect(pressingRings(_data(strain: 15, target: _target, olderStrain: 104), now: _now),
          isEmpty);
    });

    testWidgets('only the older row shows, no why panel', (t) async {
      await _rings(t, _data(strain: 15, target: _target, olderStrain: 104));
      expect(find.byKey(const ValueKey('home-older-row')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-why:strain')), findsNothing);
    });
  });

  // ── P2b ───────────────────────────────────────────────────────────────────
  group('P2b: why-copy states evidence or nothing', () {
    Finder body(String k) => find.byKey(ValueKey('home-why-body:$k'));

    testWidgets('recovery with drivers: the biggest drags, with their numbers',
        (t) async {
      await _rings(
          t,
          _data(recovery: 22, drivers: [
            _drv('hrv', -1.8, -.8),
            _drv('rhr', -1.2, -.4),
            _drv('resp', .5, .1),
          ]));
      expect(t.widget<Text>(body('recovery')).data,
          'Biggest drag: HRV -1.8, Resting heart rate -1.2 (how far each sits from your usual).');
    });

    testWidgets('recovery, one drag: just that one', (t) async {
      await _rings(
          t, _data(recovery: 22, drivers: [_drv('hrv', -1.8, -.8), _drv('rhr', .4, .1)]));
      expect(t.widget<Text>(body('recovery')).data,
          'Biggest drag: HRV -1.8 (how far each sits from your usual).');
    });

    testWidgets('recovery, no drivers (or none below baseline): plain fact, no usual-range claim',
        (t) async {
      await _rings(t, _data(recovery: 22));
      expect(t.widget<Text>(body('recovery')).data, 'Recovery 22 of 100');
      await _rings(t, _data(recovery: 22, drivers: [_drv('hrv', .6, .2)]));
      expect(t.widget<Text>(body('recovery')).data, 'Recovery 22 of 100');
      expect(find.textContaining('usual'), findsNothing);
    });

    testWidgets('strain: the number and the target range', (t) async {
      await _rings(t, _data(strain: 15.2, target: _target));
      expect(t.widget<Text>(body('strain')).data,
          'Strain 15.2, above today’s target of 8–12.');
    });
  });

  // ── P2c ───────────────────────────────────────────────────────────────────
  group('P2c: the since caption has its own line above the rings', () {
    for (final w in [360.0, 390.0]) {
      for (final s in [1.0, 1.3]) {
        testWidgets('no overlap with any dial; line reserved @${w.toInt()} x$s',
            (t) async {
          await _home(t, _data(computedAt: _at(16, 8)), w: w, scale: s);
          final without = t.getTopLeft(_dials.first);
          final cardH = t.getSize(_card).height;
          await _home(t, _data(computedAt: _at(16, 8)),
              w: w, scale: s, through: _at(16, 4));
          expect(_since, findsOneWidget);
          final cap = t.getRect(_since);
          expect(_dials, findsNWidgets(3));
          for (var i = 0; i < 3; i++) {
            expect(cap.overlaps(t.getRect(_dials.at(i))), isFalse,
                reason: 'caption vs dial $i');
            expect(cap.bottom, lessThanOrEqualTo(t.getTopLeft(_dials.at(i)).dy),
                reason: 'the line sits above the rings');
          }
          expect(t.getTopLeft(_dials.first), without,
              reason: 'the line was already reserved');
          expect(t.getSize(_card).height, cardH);
          expect(t.getRect(_since).right, lessThanOrEqualTo(t.getRect(_card).right));
          expect(t.takeException(), isNull);
        });
      }
    }
  });

  // ── P2d / P2e ─────────────────────────────────────────────────────────────
  group('progress arc and the old hold semantics', () {
    setUp(() async {
      await g1FreshDb('home_card_fix_test.db');
    });
    tearDownAll(() => g1DropDb('home_card_fix_test.db'));
    final ctx = (computedAt: _at(16, 8), through: _at(16, 4));

    Future<AppState> open(WidgetTester t, {required DateTime newest}) =>
        _home(t, _data(computedAt: ctx.computedAt),
            through: ctx.through, lastRecSec: _sec(newest));

    testWidgets('toggling offload shows and hides the arc with no other rebuild',
        (t) async {
      final app = await open(t, newest: _at(16, 10));
      expect(_arc, findsNothing);
      _sched(app).setOffloadActive(true);
      await t.pump();
      expect(_arc, findsOneWidget);
      _sched(app).setOffloadActive(false);
      await t.pump();
      expect(_arc, findsNothing);
      await _settleDb(t);
    });

    testWidgets('current results (nothing newer): a hold shows no arc',
        (t) async {
      final app = await open(t, newest: _at(16, 4));
      _sched(app).setOffloadActive(true);
      await t.pump();
      expect(_since, findsOneWidget);
      expect(_arc, findsNothing);
      _sched(app).setOffloadActive(false);
      await t.pump();
      await _settleDb(t);
    });

    testWidgets('held and stale: arc, tappable, the old explanation, spoken',
        (t) async {
      final h = t.ensureSemantics();
      final app = await open(t, newest: _at(16, 10));
      _sched(app).setOffloadActive(true);
      await t.pump();
      const why = 'Updated 16:08 · recordings through 16:04 · Waiting for sync to finish';
      expect(_arc, findsOneWidget);
      // Round 4: the tap target is the held-only wrapper target, not the caption.
      expect(t.getSemantics(find.byKey(const ValueKey('home-since-target'))).label,
          contains('Waiting for sync to finish'));
      expect(find.text(why), findsNothing, reason: 'not on the card itself');
      await t.tap(_since);
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text(why), findsOneWidget);
      _sched(app).setOffloadActive(false);
      await t.pump();
      await _settleDb(t);
      h.dispose();
    });

    testWidgets('a workout hold explains itself too', (t) async {
      final app = await open(t, newest: _at(16, 10));
      _sched(app).setWorkoutActive(true);
      await t.pump();
      expect(_arc, findsOneWidget);
      await t.tap(_since);
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Paused during workout'), findsOneWidget);
      _sched(app).setWorkoutActive(false);
      await t.pump();
      await _settleDb(t);
    });

    testWidgets('not held: caption is plain, not a button', (t) async {
      final h = t.ensureSemantics();
      await open(t, newest: _at(16, 10));
      expect(_arc, findsNothing);
      expect(find.descendant(of: _since, matching: find.byType(Pressable)), findsNothing);
      h.dispose();
    });
  });
}
