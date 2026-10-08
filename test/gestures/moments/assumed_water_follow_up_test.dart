// Assumed water glasses in the marked-moment follow-up (RED).
//
//   * Pure: `MomentFollowUps.pendingAssumed(now)` is the assumed (not kept, not
//     removed) glasses, with the same gates as pending moments: empty while the
//     follow-up setting is off, nothing from before it was enabled, nothing
//     older than 7 local calendar days, oldest first.
//   * The screen lists them chronologically INTERSPERSED with the pending
//     moments, each clearly labelled as an assumed glass that adds to water
//     drunk, in the user's unit, with Keep (acknowledge, leaves the list) and
//     Remove (subtracts exactly that glass, leaves the list). A glass offers no
//     moment choices and no Skip.
//   * With the setting off nothing is listed, but glasses are still logged
//     and still counted as assumed (LocalDb.assumedWaterMl).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/water_units.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

final _now = DateTime(2026, 10, 7, 12, 0);
final _since = DateTime(2026, 10, 1);

AssumedGlass _g(String date, int atMin,
        {double ml = 250, AssumedState state = AssumedState.assumed}) =>
    AssumedGlass(date: date, atMin: atMin, ml: ml, state: state, loggedAtMs: 1);

const _a = PendingMoment(date: '2026-10-06', hhmm: '09:15');
const _b = PendingMoment(date: '2026-10-07', hhmm: '07:05');

MomentFollowUps _f({
  DateTime? since,
  List<AssumedGlass> assumed = const [],
  List<MarkedMoment> marked = const [],
}) =>
    MomentFollowUps(enabledSince: since, assumed: assumed, marked: marked);

class _Fake extends AssumedWaterWriter {
  final kept = <String>[];
  final removed = <String>[];
  bool fail = false;
  @override
  Future<void> keep(AssumedGlass g) async {
    if (fail) throw StateError('disk full');
    kept.add(g.key);
  }

  @override
  Future<void> remove(AssumedGlass g) async {
    if (fail) throw StateError('disk full');
    removed.add(g.key);
  }
}

Finder _glass(AssumedGlass g) => find.byKey(ValueKey('assumed-water:${g.key}'));
Finder _keep(AssumedGlass g) => find.byKey(ValueKey('assumed-keep:${g.key}'));
Finder _remove(AssumedGlass g) =>
    find.byKey(ValueKey('assumed-remove:${g.key}'));
Finder _moment(PendingMoment m) =>
    find.byKey(ValueKey('moment-follow-up:${m.key}'));

Future<_Fake> _pump(
  WidgetTester t, {
  List<PendingMoment> moments = const [],
  List<AssumedGlass> glasses = const [],
  UnitSystem? system,
}) async {
  final w = _Fake();
  t.view.physicalSize = const Size(390 * 3, 4000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  Widget screen = MomentFollowUpScreen(
    preloaded: moments,
    preloadedAssumed: glasses,
    assumedWriter: w,
    now: _now,
  );
  if (system != null) {
    screen = ChangeNotifierProvider<UnitsController>.value(
        value: UnitsController.seed(system), child: screen);
  }
  await t.pumpWidget(
      MaterialApp(theme: buildTheme(Brightness.light), home: screen));
  await t.pumpAndSettle();
  return w;
}

/// Press the review's Save and let it finish: Keep / Remove are queued until
/// then.
Future<void> _saveAll(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('review-save')));
  await t.pumpAndSettle();
}

void main() {
  group('pendingAssumed (pure)', () {
    test('only glasses still waiting, oldest first', () {
      final f = _f(since: _since, assumed: [
        _g('2026-10-07', 600),
        _g('2026-10-06', 480),
        _g('2026-10-06', 720, state: AssumedState.kept),
        _g('2026-10-06', 840, state: AssumedState.removed),
      ]);
      expect([for (final g in f.pendingAssumed(_now)) g.key],
          ['2026-10-06 08:00', '2026-10-07 10:00']);
    });

    test('setting off: nothing is pending, whatever was logged', () {
      final f = _f(since: null, assumed: [_g('2026-10-07', 600)]);
      expect(f.pendingAssumed(_now), isEmpty);
    });

    test('nothing from before the setting was enabled', () {
      final f = _f(since: DateTime(2026, 10, 7, 9, 0), assumed: [
        _g('2026-10-07', 8 * 60),
        _g('2026-10-07', 10 * 60),
      ]);
      expect([for (final g in f.pendingAssumed(_now)) g.hhmm], ['10:00']);
    });

    test('nothing older than 7 local calendar days', () {
      final f = _f(since: DateTime(2026, 9, 1), assumed: [
        _g('2026-09-29', 600),
        _g('2026-09-30', 11 * 60),
        _g('2026-09-30', 13 * 60),
      ]);
      // now = 12:00 on the 7th; cutoff = 12:00 on the 30th.
      expect([for (final g in f.pendingAssumed(_now)) g.key],
          ['2026-09-30 13:00']);
    });

    test('a pending glass does not make a moment pending, nor the reverse', () {
      final f = _f(
          since: _since,
          assumed: [_g('2026-10-06', 600)],
          marked: [(date: '2026-10-06', hhmm: '10:00')]);
      expect(f.pending(_now), hasLength(1));
      expect(f.pendingAssumed(_now), hasLength(1));
    });
  });

  group('from the database', () {
    final created = <String>[];
    var n = 0;
    Future<String> path(String name) async =>
        p.join(await databaseFactory.getDatabasesPath(), name);

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });
    tearDownAll(() async {
      await LocalDb.close();
      for (final c in created) {
        await databaseFactory.deleteDatabase(await path(c));
      }
    });
    setUp(() async {
      final name = 'openstrap_assumed_follow_${n++}.db';
      created.add(name);
      await LocalDb.close();
      await databaseFactory.deleteDatabase(await path(name));
      LocalDb.lastRebuild = null;
      LocalDb.dbName = name;
      await LocalDb.instance;
      await LocalDb.putJournal('2026-10-06', '["moment 09:15"]', '');
    });

    test('load() carries the assumed glasses; only unreviewed ones are '
        'pending', () async {
      for (final m in [480, 600, 720]) {
        await LocalDb.logAssumedWater(
            date: '2026-10-06', atMin: m, ml: 250, loggedAtMs: 1);
      }
      final gs = await LocalDb.assumedWater(date: '2026-10-06');
      await LocalDb.keepAssumedWater(gs[0]);
      await LocalDb.removeAssumedWater(gs[1]);
      final f = await MomentFollowUps.load(enabledSince: _since);
      expect([for (final g in f.pendingAssumed(_now)) g.hhmm], ['12:00']);
      expect(f.pending(_now), hasLength(1), reason: 'the 09:15 moment');
    });

    test('setting off: glasses were still logged and still count as assumed '
        'water, but nothing is pending', () async {
      await LocalDb.logAssumedWater(
          date: '2026-10-06', atMin: 600, ml: 250, loggedAtMs: 1);
      final f = await MomentFollowUps.load(enabledSince: null);
      expect(f.pendingAssumed(_now), isEmpty);
      expect(await LocalDb.assumedWaterMl('2026-10-06'), 250);
      expect(
          (await LocalDb.journalMetricsForDay('2026-10-06'))['water_ml']!.value,
          250);
    });

    test('the real writer: keep leaves the total, remove takes the glass back',
        () async {
      await LocalDb.logAssumedWater(
          date: '2026-10-06', atMin: 600, ml: 250, loggedAtMs: 1);
      await LocalDb.logAssumedWater(
          date: '2026-10-06', atMin: 720, ml: 250, loggedAtMs: 1);
      final gs = await LocalDb.assumedWater(date: '2026-10-06');
      const w = AssumedWaterWriter();
      await w.keep(gs[0]);
      await w.remove(gs[1]);
      final total =
          (await LocalDb.journalMetricsForDay('2026-10-06'))['water_ml']!.value;
      expect(total, 250);
      final f = await MomentFollowUps.load(enabledSince: _since);
      expect(f.pendingAssumed(_now), isEmpty);
    });
  });

  group('the screen', () {
    final g1 = _g('2026-10-06', 12 * 60);
    final g2 = _g('2026-10-07', 8 * 60);

    testWidgets('assumed glasses are interspersed chronologically with '
        'pending moments', (t) async {
      // Passed out of order on purpose: the screen orders by time.
      await _pump(t, moments: [_b, _a], glasses: [g2, g1]);
      final order = [_moment(_a), _glass(g1), _moment(_b), _glass(g2)];
      for (final f in order) {
        expect(f, findsOneWidget);
      }
      final ys = [for (final f in order) t.getTopLeft(f).dy];
      expect(ys, orderedEquals([...ys]..sort()),
          reason: '09:15 moment, 12:00 glass, 07:05 moment, 08:00 glass');
      expect(ys.toSet(), hasLength(4));
    });

    testWidgets('a glass is clearly an ASSUMED glass that adds to water '
        'drunk, with its time and amount', (t) async {
      await _pump(t, glasses: [g1]);
      final row = _glass(g1);
      expect(
          find.descendant(
              of: row,
              matching: find.textContaining(
                  RegExp('assumed glass', caseSensitive: false))),
          findsOneWidget);
      expect(
          find.descendant(
              of: row,
              matching: find.textContaining(
                  RegExp('water', caseSensitive: false))),
          findsWidgets);
      expect(find.descendant(of: row, matching: find.textContaining('250 ml')),
          findsOneWidget);
      expect(find.descendant(of: row, matching: find.textContaining('12:00')),
          findsOneWidget);
      expect(
          find.descendant(
              of: row, matching: find.textContaining('2026-10-06')),
          findsOneWidget);
    });

    testWidgets('the amount is in the user\'s units', (t) async {
      final cup = _g('2026-10-06', 600,
          ml: WaterUnits.stepMl(UnitSystem.imperial));
      await _pump(t, glasses: [cup], system: UnitSystem.imperial);
      expect(
          find.descendant(
              of: _glass(cup), matching: find.textContaining('8 fl oz')),
          findsOneWidget);
      expect(find.textContaining(' ml'), findsNothing);
    });

    testWidgets('a glass offers Keep and Remove, and no moment choices or '
        'Skip', (t) async {
      await _pump(t, moments: [_a], glasses: [g1]);
      expect(_keep(g1), findsOneWidget);
      expect(_remove(g1), findsOneWidget);
      expect(
          find.descendant(
              of: _glass(g1),
              matching: find.byWidgetPredicate((w) =>
                  w.key is ValueKey<String> &&
                  (w.key as ValueKey<String>).value.startsWith('moment-'))),
          findsNothing);
    });

    testWidgets('Keep acknowledges: the writer is asked, the row leaves, the '
        'rest stays', (t) async {
      final w = await _pump(t, moments: [_a], glasses: [g1, g2]);
      await t.tap(_keep(g1));
      await t.pumpAndSettle();
      expect(w.kept, isEmpty, reason: 'queued, not applied');
      expect(_glass(g1), findsOneWidget, reason: 'the row stays until Save');
      await _saveAll(t);
      expect(w.kept, [g1.key]);
      expect(w.removed, isEmpty);
      expect(_glass(g1), findsNothing);
      expect(_glass(g2), findsOneWidget);
      expect(_moment(_a), findsOneWidget);
    });

    testWidgets('Remove: the writer is asked to subtract that glass, the row '
        'leaves', (t) async {
      final w = await _pump(t, moments: [_a], glasses: [g1, g2]);
      await t.tap(_remove(g2));
      await t.pumpAndSettle();
      expect(w.removed, isEmpty, reason: 'queued, not applied');
      expect(_glass(g2), findsOneWidget);
      await _saveAll(t);
      expect(w.removed, [g2.key]);
      expect(w.kept, isEmpty);
      expect(_glass(g2), findsNothing);
      expect(_glass(g1), findsOneWidget);
    });

    testWidgets('a failed write on Save keeps the row, says so on it, and '
        'keeps the decision queued', (t) async {
      final w = await _pump(t, glasses: [g1]);
      w.fail = true;
      await t.tap(_remove(g1));
      await t.pumpAndSettle();
      await _saveAll(t);
      expect(_glass(g1), findsOneWidget);
      expect(find.byKey(ValueKey('assumed-save-failed:${g1.key}')),
          findsOneWidget);
      expect(find.byKey(ValueKey('assumed-pending:${g1.key}')), findsOneWidget);
    });

    testWidgets('only glasses: the screen is not the empty state', (t) async {
      await _pump(t, glasses: [g1]);
      expect(find.byKey(const ValueKey('moment-follow-up-empty')),
          findsNothing);
      expect(_glass(g1), findsOneWidget);
    });

    testWidgets('answering the last item shows the empty state', (t) async {
      await _pump(t, glasses: [g1]);
      await t.tap(_keep(g1));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('moment-follow-up-empty')),
          findsNothing, reason: 'queued only');
      await _saveAll(t);
      expect(find.byKey(const ValueKey('moment-follow-up-empty')),
          findsOneWidget);
    });
  });
}
