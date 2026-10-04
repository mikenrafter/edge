import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'support/incremental_activity_fixture.dart';

List<Map<String, num>> _curve(
  String kind,
  Substrate s, {
  DayCalculationState? state,
  ana.CalculationMode mode = ana.CalculationMode.forced,
}) => kind == 'hrv'
    ? DerivationEngine.dayHrvCurve(s, state: state, mode: mode)
    : DerivationEngine.dayRespCurve(s, state: state, mode: mode);

int _attempts(String kind) => kind == 'hrv'
    ? DerivationEngine.debugHrvAttempts
    : DerivationEngine.debugRespAttempts +
          DerivationEngine.debugRespGateRejects;

void main() {
  for (final kind in ['hrv', 'resp']) {
    for (final seed in [1, 42]) {
      for (final moving in [false, true]) {
        test(
          '$kind curve completed windows survive RR append seed=$seed moving=$moving',
          () {
            final full = incrementalActivity(
              seed: seed,
              seconds: 961,
              moving: moving,
              gaps: true,
            );
            final state = DayCalculationState();
            List<Map<String, num>> previous = [];
            var previousOracleAttempts = 0;
            for (final n in [60, 181, 301, 361, 601, full.length]) {
              final s = full.sliceIdx(0, n);
              final beforeOracle = _attempts(kind);
              final oracle = _curve(kind, s);
              final oracleAttempts = _attempts(kind) - beforeOracle;
              final beforeIncremental = _attempts(kind);
              final hitsBeforeAppend = state.hits;
              final actual = _curve(
                kind,
                s,
                state: state,
                mode: ana.CalculationMode.periodicAwake,
              );
              expect(actual, oracle);
              expect(
                _attempts(kind) - beforeIncremental,
                lessThanOrEqualTo(oracleAttempts - previousOracleAttempts),
                reason:
                    'only newly closed windows require estimator/gate attempts',
              );
              if (previousOracleAttempts > 0) {
                expect(
                  state.hits,
                  greaterThan(hitsBeforeAppend),
                  reason: 'completed windows are reused on append',
                );
              }
              previousOracleAttempts = oracleAttempts;
              if (previous.isNotEmpty) {
                expect(
                  actual.take(previous.length).toList(),
                  previous,
                  reason: 'new RR cannot revise an already closed window',
                );
              }
              previous = List.of(actual);
              expect(state.computations, greaterThan(0));
              final hits = state.hits;
              expect(
                _curve(
                  kind,
                  s,
                  state: state,
                  mode: ana.CalculationMode.periodicAwake,
                ),
                oracle,
              );
              expect(state.hits, greaterThan(hits));
            }
          },
        );
      }
    }
    test('$kind curve invalidates historic RR and timestamp replacements', () {
      final s = incrementalActivity(seconds: 601, moving: false);
      final state = DayCalculationState();
      expect(
        _curve(kind, s, state: state, mode: ana.CalculationMode.periodicAwake),
        _curve(kind, s),
      );
      s.rrMs[37] += 49;
      expect(
        _curve(kind, s, state: state, mode: ana.CalculationMode.periodicAwake),
        _curve(kind, s),
      );
      s.rrTsMs[37] += .125;
      expect(
        _curve(kind, s, state: state, mode: ana.CalculationMode.periodicAwake),
        _curve(kind, s),
      );
      final hits = state.hits;
      expect(
        _curve(kind, s, state: state, mode: ana.CalculationMode.periodicAwake),
        _curve(kind, s),
      );
      expect(state.hits, greaterThan(hits));
    });
    for (final mode in [
      ana.CalculationMode.sleep,
      ana.CalculationMode.heavy,
      ana.CalculationMode.forced,
    ]) {
      test('$kind curve $mode bypasses cached completed windows', () {
        final s = incrementalActivity(seconds: 361, moving: false);
        final state = DayCalculationState();
        _curve(kind, s, state: state, mode: ana.CalculationMode.periodicAwake);
        final hits = state.hits, work = state.computations;
        expect(_curve(kind, s, state: state, mode: mode), _curve(kind, s));
        expect(state.hits, hits);
        expect(state.computations, greaterThan(work));
      });
    }
  }
  test('resp curve cache snapshots motion and family gate dependencies', () {
    final s = incrementalActivity(seconds: 601, moving: false);
    final state = DayCalculationState();
    _curve('resp', s, state: state, mode: ana.CalculationMode.periodicAwake);
    s.az[90] = 1.2;
    expect(
      _curve('resp', s, state: state, mode: ana.CalculationMode.periodicAwake),
      _curve('resp', s),
    );
    final unknown = incrementalActivity(
      seconds: 601,
      moving: false,
      family: null,
    );
    expect(
      _curve(
        'resp',
        unknown,
        state: state,
        mode: ana.CalculationMode.periodicAwake,
      ),
      _curve('resp', unknown),
    );
    final hits = state.hits;
    _curve(
      'resp',
      unknown,
      state: state,
      mode: ana.CalculationMode.periodicAwake,
    );
    expect(state.hits, greaterThan(hits));
  });
}
