// 8AG-perf P1/P1b: wiring that is a statement about where code lives, in the
// repo's usual source-grep style. Every check here fails today on behaviour
// (the symbol or call is not in the file yet), not on a missing import.
//
// Symbol names assumed: DerivePerf / DerivePhase (lib/compute/derive_perf.dart),
// RevisionCoalescer, RecalcState, `onScopeDays`, `onCrossDay`,
// `last_pass_perf`, `[perf] derive`, `[perf] home render`, TickerMode,
// 'Last calculation', docs/perf.md.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

String _body(String src, String signature, {int span = 9000}) {
  final at = src.indexOf(signature);
  expect(at, greaterThanOrEqualTo(0), reason: '$signature has moved');
  return src.substring(at, (at + span).clamp(0, src.length));
}

void main() {
  final engine = _read('lib/compute/derivation_engine.dart');
  final app = _read('lib/state/app_state.dart');

  group('engine', () {
    test('run() and runDays() report the scope\'s days', () {
      final run = _body(engine, 'Future<int> run(', span: 1200);
      expect(run, contains('onScopeDays'));
      expect(run, contains('onCrossDay'));
      expect(run, contains('onScope'), reason: 'onScope is kept');
      expect(_body(engine, 'Future<int> runDays(', span: 800),
          contains('onScopeDays'));
      expect(_body(engine, 'Future<int> rescanRecent(', span: 800),
          contains('onScopeDays'));
    });

    test('the pass is measured and published on snapshot()', () {
      expect(engine, contains('DerivePerf('));
      expect(engine, contains("'last_pass_perf'"));
      expect(engine, contains('[perf] derive'));
      expect(engine, contains('DerivePhase.prepare'));
      expect(engine, contains('DerivePhase.compute'));
      expect(engine, contains('DerivePhase.persist'));
    });

    test('the cross-day / baseline step brackets crossDay', () {
      final run = _body(engine, 'Future<int> run(', span: 14000);
      final on = run.indexOf('onCrossDay?.call(true)');
      final off = run.indexOf('onCrossDay?.call(false)');
      final step = run.indexOf('_runCrossDay(profile)');
      expect(on, greaterThan(0));
      expect(on, lessThan(step));
      expect(off, greaterThan(step));
    });

    test('no kAlgoVersion bump: nothing here changes a metric output', () {
      expect(engine, contains('const int kAlgoVersion = 100;'));
    });
  });

  group('AppState', () {
    test('owns recalc as a ValueNotifier and clears it in finally', () {
      expect(app, contains('ValueListenable<RecalcState> get recalc'));
      expect(app, contains('ValueNotifier<RecalcState>'));
      final drain = _body(app, 'Future<void> _afterDrain(', span: 9000);
      expect(drain, contains('onScopeDays'));
      expect(drain, contains('onCrossDay'));
      final fin = drain.lastIndexOf('} finally {');
      expect(fin, greaterThan(0));
      expect(drain.substring(fin), contains('RecalcState.idle'),
          reason: 'cleared on success, failure and cancel (AGENTS 4.3)');
    });

    test('each committed day is published through the coalescer', () {
      final drain = _body(app, 'Future<void> _afterDrain(', span: 5000);
      expect(app, contains('RevisionCoalescer('));
      final done = drain.indexOf('onDayDone:');
      expect(done, greaterThan(0));
      expect(drain.substring(done, done + 1400), contains('request()'));
      expect(drain, contains('bumpInsights()'),
          reason: 'the end-of-pass bump stays');
    });

    test('lastHomeRenderMs exists and is nullable', () {
      expect(app, contains('int? lastHomeRenderMs'));
      expect(app, contains('[perf] home render'));
    });
  });

  group('UI', () {
    test('AppShell parks hidden tabs under TickerMode(enabled: false)', () {
      final shell = _read('lib/ui2/app_shell.dart');
      expect(shell, contains('TickerMode('));
      expect(shell, contains('enabled:'));
    });

    test('RevisionReload defers on TickerMode and drops the old ponytail', () {
      final rev = _read('lib/ui2/revision.dart');
      expect(rev, contains('TickerMode.valuesOf(context)'),
          reason: 'registers the dependency (TickerMode.of is deprecated)');
      expect(rev, isNot(contains('a parked tab re-reads too')));
    });

    test('Home measures bump -> first commit', () {
      final home = _read('lib/ui2/screens/home_screen.dart');
      expect(home, contains('RenderLatency'));
      expect(home, contains('recordHomeRender'));
    });

    test('every as-of screen listens to recalc without a DB re-read', () {
      for (final f in const [
        'home_screen',
        'sleep_detail',
        'metric_detail',
        'wellness_screen',
        'beats',
      ]) {
        final src = _read('lib/ui2/screens/$f.dart');
        expect(src, contains('recalc'), reason: '$f never reads AppState.recalc');
        expect(src, contains('AsOfLabel'), reason: '$f never shows the label');
        expect(src, contains('asOfFor('), reason: '$f decides on its own');
      }
    });

    test('Readiness and Circadian detail screens carry the label too', () {
      for (final f in const ['readiness_detail', 'circadian_detail']) {
        final src = _read('lib/ui2/screens/$f.dart');
        expect(src, contains('AsOfLabel'), reason: f);
        expect(src, contains('asOfFor('), reason: f);
      }
    });

    test('Health (Last night / Today / Trends) carries the label', () {
      final src = _read('lib/ui2/screens/health_screen.dart');
      expect(src, contains('AsOfLabel'));
      expect(src, contains('asOfFor('));
    });

    test('Settings > Developer has a read-only "Last calculation" row', () {
      final s = _read('lib/ui2/profile/settings.dart');
      expect(s, contains('Last calculation'));
      expect(s, contains('last_pass_perf'));
      expect(s, contains('DerivePerf.describe'));
    });
  });

  test('the docs exist', () {
    expect(File('docs/perf.md').existsSync(), isTrue);
    expect(_read('test/phase8/CONTRACTS.md'), contains('8AG P1/P1b'));
    expect(
        _read('docs/superpowers/plans/2026-10-03-next-queue-perf-power-explorer.md'),
        contains('### 8AG-perf P1'));
  });
}
