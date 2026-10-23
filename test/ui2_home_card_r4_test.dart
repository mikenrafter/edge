// RED tests: Home card round 4 (Sol r3 P2 + owner render review).
// The 44 pt reserved caption row left a visible empty band above the rings
// (dials 60 pt below the card top; the approved mock has them about 30 pt).
// CONTRACT (keys are ValueKey<String>):
//   home-since-line     the VISUAL caption row inside the card: 18 pt at scale
//                       1.0 (grows with the text scale), reserved whether or not
//                       the time is known or held. NOT a tap target.
//   home-since-target   held only: a transparent Pressable, 44 pt tall at scale
//                       1.0, Positioned(top: 0, left: 16, right: 16) in a Stack
//                       that wraps the gap above the card AND the card. It ends
//                       above the dials and starts below the control before it
//                       (the day bar). Row and target grow together with text.
// Tests tap its top and bottom edges; the dials keep their own taps.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/as_of_recalc_fakes.dart';
import 'support/last_result_db.dart';

final _now = DateTime(2026, 10, 4, 15);
const _db = 'home_card_r4_test.db';

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

HomeData _data() => HomeData(
      dayId: todayLabel(),
      readiness: const Metric(value: 80, confidence: .8, tier: MetricTier.high),
      sleepMin: const Metric(value: 450, confidence: .8, tier: MetricTier.high),
      sleepNeedMin: const Metric(value: 480, confidence: .8, tier: MetricTier.high),
      strain: const Metric(value: 5, confidence: .8, tier: MetricTier.high),
      overnightAt: _at(16, 8),
      activityAt: _at(16, 8),
      overnightDay: todayLabel(),
      activityDay: todayLabel(),
    );

dynamic _sched(AppState a) => (a as dynamic).debugDeriveScheduler;

Future<AppState> _home(WidgetTester t,
    {double w = 390, double scale = 1.0, bool known = true, bool held = false}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(w, 3200);
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  await t.runAsync(() => g1FreshDb(_db));
  final app = AppState.forTesting()
    ..repo = (_Repo()..through = known ? _at(16, 4) : null);
  addTearDown(app.dispose);
  if (held) {
    (app as dynamic).debugLastRecTs = _at(16, 10).millisecondsSinceEpoch ~/ 1000;
    _sched(app).setOffloadActive(true);
    addTearDown(() => _sched(app).setOffloadActive(false));
  }
  await t.pumpWidget(perfApp(app, HomeScreen(data: _data(), hour: 9, now: _now)));
  await settle(t, n: 6);
  return app;
}

final _card = find.byKey(const ValueKey('card:rings'));
final _line = find.byKey(const ValueKey('home-since-line'));
final _target = find.byKey(const ValueKey('home-since-target'));
final _dials = find.descendant(
    of: _card,
    matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Dial'));

/// Whether a tap at [p] reaches [f]'s render object.
bool _hits(WidgetTester t, Offset p, Finder f) {
  final r = HitTestResult();
  t.binding.hitTestInView(r, p, t.view.viewId);
  final ro = t.renderObject(f);
  return r.path.any((e) => e.target == ro);
}

Future<void> _settleDb(WidgetTester t) async {
  var answered = false;
  LocalDb.instance.then((db) => db.rawQuery('SELECT 1')).then((_) => answered = true,
      onError: (_) => answered = true);
  while (!answered) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDownAll(() => g1DropDb(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final w in [360.0, 390.0]) {
    testWidgets('dials sit about 30 pt below the card top @${w.toInt()} (known, unknown, held)',
        (t) async {
      for (final (known, held) in [(true, false), (false, false), (true, true)]) {
        await _home(t, w: w, known: known, held: held);
        final gap = t.getTopLeft(_dials.first).dy - t.getTopLeft(_card).dy;
        expect(gap, lessThanOrEqualTo(36), reason: 'known=$known held=$held');
        expect(gap, greaterThanOrEqualTo(24));
        expect(t.getSize(_line).height, 18, reason: 'the visual row is 18 pt');
        if (held) await _settleDb(t);
      }
    });
  }

  testWidgets('the row and the target grow together with the text scale', (t) async {
    await _home(t, held: true);
    final r1 = t.getSize(_line).height, t1 = t.getSize(_target).height;
    expect(t1, 44);
    await _settleDb(t);
    await _home(t, scale: 1.3, held: true);
    expect(t.getSize(_line).height, greaterThan(r1));
    expect(t.getSize(_target).height, greaterThan(t1));
    expect(t.getRect(_target).bottom,
        lessThanOrEqualTo(t.getTopLeft(_dials.first).dy), reason: 'ends above the dials');
    await _settleDb(t);
  });

  testWidgets('text scale 0.85: the target keeps 44 pt, ends above the dials, row stays 18 pt',
      (t) async {
    await _home(t, scale: 0.85, held: true);
    expect(t.getSize(_target).height, greaterThanOrEqualTo(44));
    expect(t.getSize(_line).height, 18, reason: 'the row never shrinks below 18');
    final dialTop = t.getTopLeft(_dials.first).dy;
    expect(t.getRect(_target).bottom, lessThanOrEqualTo(dialTop));
    expect(dialTop - t.getTopLeft(_card).dy, inInclusiveRange(24, 36));
    await _settleDb(t);
  });

  testWidgets('held: a 44 pt transparent target between the day bar and the dials',
      (t) async {
    await _home(t, held: true);
    final tr = t.getRect(_target), card = t.getRect(_card);
    expect(tr.left, card.left + 16);
    expect(tr.right, card.right - 16);
    expect(tr.top, lessThan(card.top), reason: 'starts in the gap above the card');
    expect(tr.top, greaterThanOrEqualTo(t.getRect(find.byKey(const ValueKey('card:daynav'))).bottom),
        reason: 'below the preceding control');
    expect(tr.bottom, lessThanOrEqualTo(t.getTopLeft(_dials.first).dy));
    await _settleDb(t);
  });

  testWidgets('tapping the top and bottom edges of the target opens the explanation',
      (t) async {
    await _home(t, held: true);
    final tr = t.getRect(_target);
    for (final y in [tr.top + 1, tr.bottom - 1]) {
      await t.tapAt(Offset(tr.center.dx, y));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Waiting for sync to finish'), findsOneWidget, reason: 'y=$y');
      await t.tap(find.text('OK'));
      await t.pump(const Duration(milliseconds: 400));
    }
    await _settleDb(t);
  });

  testWidgets('the dials keep their taps, including their top edge; the day bar too',
      (t) async {
    await _home(t, held: true);
    for (var i = 0; i < 3; i++) {
      final d = t.getRect(_dials.at(i));
      final p = Offset(d.center.dx, d.top + 1);
      expect(_hits(t, p, _target), isFalse, reason: 'dial $i top edge is not the target');
      expect(_hits(t, p, _dials.at(i)), isTrue, reason: 'dial $i top edge reaches the dial');
    }
    final bar = t.getRect(find.byKey(const ValueKey('card:daynav')));
    expect(_hits(t, bar.bottomCenter - const Offset(0, 1), _target), isFalse,
        reason: 'the day bar is not under the target');
    await _settleDb(t);
  });

  testWidgets('not held: no target at all', (t) async {
    await _home(t);
    expect(_target, findsNothing);
    expect(_line, findsOneWidget);
    expect(find.text('since 16:04'), findsOneWidget);
  });
}
