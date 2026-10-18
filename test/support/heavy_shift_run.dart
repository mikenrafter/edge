// Real-time layout-shift + load-time capture against a real database.
//
// GATED like heavy_db_fixture.dart (LAYOUT_SHIFT_HEAVY=1). Unlike ShiftRun,
// which stamps frames with fake-time offsets, this one lets the screen's real
// database and isolate work run (WidgetTester.runAsync) and stamps every frame
// with a monotonic Stopwatch.
//
// Clock note: no DateTime.now here. Stopwatch is monotonic elapsed time and is
// the accepted exception for these gated heavy tests. The fake clock is kept
// in step with the Stopwatch (each pump advances it by the real time that
// passed) so the screen's own timers and animations behave as on a device.
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'as_of_recalc_fakes.dart';
import 'heavy_db_fixture.dart';
import 'layout_shift_probe.dart';
import 'shift_run.dart';
import 'timed_repository.dart';

const _quietMs = 750;
const _capMs = 20000;
const _stepMs = 16;

class HeavyResult {
  HeavyResult(this.report, this.settleMs, this.capped, this.frames);
  final ShiftReport report;

  /// Ms from open to the last visible change (the 'load' finding's time).
  final int? settleMs;
  final bool capped;
  final int frames;
}

bool _changed(Frame a, Frame b) {
  if (a.elements.length != b.elements.length) return true;
  final before = {for (final e in a.elements) e.id: e};
  for (final e in b.elements) {
    final o = before[e.id];
    if (o == null ||
        o.rect.left != e.rect.left ||
        o.rect.top != e.rect.top ||
        o.rect.width != e.rect.width ||
        o.rect.height != e.rect.height ||
        o.colorArgb != e.colorArgb) {
      return true;
    }
  }
  return false;
}

/// Pumps [screen] and captures until it has been unchanged for 750 ms, or
/// 20 s (cap: unsettled, so the scorer charges the full load cost).
Future<HeavyResult> measureOpen(WidgetTester t, Widget screen) async {
  final probe = ShiftProbe(trackUnkeyed: true, visibleOnly: shiftViewport);
  final sw = Stopwatch()..start();
  await t.pumpWidget(screen);
  var fakeAt = 0;
  var now = sw.elapsedMilliseconds;
  await t.pump(Duration(milliseconds: now));
  fakeAt = now;
  var prev = probe.capture(t, atMs: now);
  probe.interactions.add(const Interaction(0, 'screen-open'));
  var lastChange = now;
  var lastCapture = now;
  var capped = false;
  while (true) {
    // Spin, don't sleep: the screen's continuations after each `await` run on
    // the fake-async microtask queue, which only a pump flushes. A 16 ms sleep
    // per spin added ~one frame of latency to EVERY await in the screen's load
    // (a 4-await repository call read as 70 ms instead of ~5). So: yield one
    // real event-loop turn (lets the database / isolate replies in), pump to
    // flush, and only run the (costly) tree capture every [_stepMs].
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    now = sw.elapsedMilliseconds;
    await t.pump(Duration(milliseconds: now - fakeAt));
    fakeAt = now;
    if (now - lastCapture < _stepMs) continue;
    lastCapture = now;
    final f = probe.capture(t, atMs: now);
    // A static spinner is NOT settled: the screen is still loading, it just
    // has nothing moving yet. Quiet counts only once no progress indicator
    // is on screen.
    if (_changed(prev, f) ||
        find.byWidgetPredicate((w) => w is ProgressIndicator).evaluate().isNotEmpty) {
      lastChange = now;
    }
    prev = f;
    if (now - lastChange >= _quietMs) break;
    if (now >= _capMs) {
      capped = true;
      // Still not quiet at the cap: end on a frame that differs from the one
      // before it, which is how the scorer spells "unsettled".
      probe.frames.add(Frame(now + 1, [
        ...f.elements,
        const ElementSnapshot(id: '~cap-unsettled', rect: ShiftRect(0, 0, 1, 1)),
      ]));
      break;
    }
  }
  final report = layoutScore(probe.scenario(shiftViewport), ShiftPolicy.standard);
  final load = report.findings.where((x) => x.rule == 'load');
  return HeavyResult(report, load.isEmpty ? null : load.first.atMs, capped,
      probe.frames.length);
}

/// Warm timings of the LocalDb queries the screens lean on (after the screen
/// ran, so the page cache is hot; first = cold-ish run after the screen).
Future<String> dbHotCalls(WidgetTester t) async {
  final out = StringBuffer('  LocalDb call | run1 ms | run2 ms | rows\n');
  Future<void> one(String name, Future<Object?> Function() f) async {
    final sw = Stopwatch()..start();
    final a = await f();
    final t1 = sw.elapsedMilliseconds;
    sw.reset();
    await f();
    final t2 = sw.elapsedMilliseconds;
    final n = a is Iterable ? a.length : '-';
    out.writeln('  $name | $t1 | $t2 | $n');
  }

  await t.runAsync(() async {
    await one('importedDates', LocalDb.importedDates);
    await one("metricSeries('sleep')", () => LocalDb.metricSeries('sleep'));
    await one("metricSeries('worn_min')", () => LocalDb.metricSeries('worn_min'));
    await one('metricSeriesVersions', LocalDb.metricSeriesVersions);
    await one('recentDayResultsMeta(60)', () => LocalDb.recentDayResultsMeta(60));
    await one('recentDayResults(60)', () => LocalDb.recentDayResults(60));
    await one('dayResultDayIdsDesc', LocalDb.dayResultDayIdsDesc);
    // What getToday's freshness refresh is made of (it runs whenever the
    // stored 'today' row names another day).
    await one('rawStats', LocalDb.rawStats);
    await one('recentDayResultMetas(30)', () => LocalDb.recentDayResultMetas(30));
    await one('refreshComputeFreshness', LocalDb.refreshComputeFreshness);
    // The floor for any Isolate.run hop (sleepWindows, BundleStore.read).
    await one('Isolate.run(noop)', () => Isolate.run(() => 1));
  });
  return out.toString();
}

/// Synthetic ingest shaped like a sync commit (DrainController.commit is one
/// transaction per chunk): each round is ONE transaction of five 10k-row
/// replaces, held open across the statements.
/// Reads on the writer's handle wait for the whole transaction; reads on the
/// read connection wait for one statement at most.
Future<void> startIngestTxnWriter(AppState app) async {
  var stop = false;
  addTearDown(() => stop = true);
  final db = await LocalDb.instance;
  unawaited(() async {
    try {
      while (!stop) {
        await db.transaction((t) async {
          for (var i = 0; i < 5; i++) {
            await t.execute('INSERT OR REPLACE INTO decoded_onehz '
                'SELECT * FROM decoded_onehz WHERE rec_ts IN '
                '(SELECT rec_ts FROM decoded_onehz LIMIT 10000)');
          }
        });
      }
    } catch (_) {
      // the database closed under the last statement
    }
  }());
}

class HeavyCase {
  const HeavyCase(this.label, this.build, {this.prepare, this.after});
  final String label;
  final Widget Function() build;

  /// Runs inside runAsync before the screen opens (settings, prefs).
  final Future<void> Function(AppState app)? prepare;

  /// Extra standalone timing after the measured open (runs in runAsync); the
  /// repository's call log is cleared first and printed after.
  final Future<void> Function(TimedRepository repo)? after;
}

/// Declares, for each variant (export as-is, weeks: 5), one test per case.
/// The database is opened once per variant in setUpAll (an open started under
/// fake time never completes).
void heavyScreen(String screen, List<HeavyCase> cases) {
  final skip = heavySkipReason();
  for (final weeks in const [0, 5]) {
    final variant = weeks == 0 ? 'export as-is' : 'weeks: $weeks';
    group('$screen [$variant]', () {
      late HeavyDb db;
      setUpAll(() async {
        TestWidgetsFlutterBinding.ensureInitialized();
        // The app is in the foreground while the screen is open: reads may
        // use the read connection.
        await LocalDb.setForeground(true);
        db = await openHeavyDb(weeks: weeks, name: 'ls_heavy_${screen}_w$weeks.db');
        debugPrint('[heavy] $screen [$variant] ${db.describe()}');
      });
      tearDownAll(() => db.dispose());
      setUp(() => SharedPreferences.setMockInitialValues({}));

      for (final c in cases) {
        testWidgets(c.label, (t) async {
          phoneSurface(t);
          final log = CallLog();
          final app = AppState.forTesting()
            ..repo = TimedRepository(log,
                getProfileMap: () => const <String, dynamic>{'age': 22, 'sex': 'male'});
          addTearDown(app.dispose);
          if (c.prepare != null) await t.runAsync(() => c.prepare!(app));
          log.reset();
          final r = await measureOpen(t, perfApp(app, c.build()));
          final calls = log.table();
          final seq = log.timeline();
          final hot = await dbHotCalls(t);
          var afterLog = '';
          if (c.after != null) {
            log.reset();
            final sw = Stopwatch()..start();
            await t.runAsync(() => c.after!(app.repo as TimedRepository));
            afterLog = '  standalone follow-up call took ${sw.elapsedMilliseconds} ms; '
                'repository calls inside it:\n${log.table()}';
          }
          final b = StringBuffer('[heavy] ${c.label} [$variant] ${db.describe()}\n');
          b.writeln('  settle ${r.settleMs} ms${r.capped ? ' (CAPPED at 20 s: unsettled)' : ''}; '
              '${r.frames} frames');
          b.write(formatShiftReport('${c.label} [$variant]', r.report, r.frames));
          for (final f in r.report.findings.where((f) => f.rule == 'load')) {
            b.writeln('  load: ${f.score.toStringAsFixed(4)} ${f.severity.name} '
                'at ${f.atMs} ms');
          }
          b.writeln('  repository calls, top 10 by total ms (inclusive):');
          b.write(calls);
          b.writeln('  call sequence (first 40):');
          b.write(seq);
          b.write(hot);
          b.write(afterLog);
          debugPrint(b.toString());
          printOnFailure(b.toString());
          expect(r.report.errors, isEmpty,
              reason: '${c.label} [$variant] has error-level findings');
        }, timeout: const Timeout(Duration(minutes: 4)), skip: skip != null);
      }
    }, skip: skip);
  }
}
