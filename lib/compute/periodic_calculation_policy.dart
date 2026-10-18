import 'dart:async';

import 'package:openstrap_analytics/onehz.dart' show CalculationMode;

import '../wake/natural_wake.dart';
import '../wake/wake_orchestrator.dart' show WakeSamples;
import '../wake/wake_settings.dart' show kNaturalWarmupMinutes;
import 'calculation_policy.dart';

/// Gathers the evidence [selectCalculationMode] needs for one derive pass:
/// the phone's charging state and a causal-stager observation of the last
/// [_kLookback] of band samples.
///
/// Fails closed. A thrown or timed-out input, or a call that overlaps one
/// still in flight, selects a full run. The stager checkpoint advances only
/// on an observation that completed in time, so a late answer is dropped.
class PeriodicCalculationPolicy {
  PeriodicCalculationPolicy({
    required Future<bool?> Function() phoneCharging,
    required Future<WakeSamples> Function(DateTime from, DateTime to)
    loadSamples,
    NaturalStageObserver observer = const IsolateNaturalStageObserver(),
    DateTime Function()? now,
    Duration timeout = const Duration(seconds: 8),
  }) : _phoneCharging = phoneCharging,
       _loadSamples = loadSamples,
       _observer = observer,
       _now = now ?? DateTime.now,
       _timeout = timeout;

  /// The stager's warm-up plus one minute for the newest epoch still closing.
  static const _kLookback = Duration(minutes: kNaturalWarmupMinutes + 1);

  final Future<bool?> Function() _phoneCharging;
  final Future<WakeSamples> Function(DateTime, DateTime) _loadSamples;
  final NaturalStageObserver _observer;
  final DateTime Function() _now;
  final Duration _timeout;

  Map<String, Object?>? _checkpoint;
  bool _busy = false;

  Future<CalculationMode> select({
    required bool heavy,
    required bool forced,
  }) async {
    if (heavy) return CalculationMode.heavy;
    if (forced) return CalculationMode.forced;
    if (_busy) return CalculationMode.sleep;
    _busy = true;
    try {
      return await _observe();
    } catch (_) {
      return CalculationMode.sleep;
    } finally {
      _busy = false;
    }
  }

  Future<CalculationMode> _observe() async {
    final charging = await Future.sync(_phoneCharging).timeout(_timeout);
    if (charging != false) return CalculationMode.sleep;
    final to = _now();
    final samples = await Future.sync(
      () => _loadSamples(to.subtract(_kLookback), to),
    ).timeout(_timeout);
    final result = await Future.sync(
      () => _observer.observe(
        NaturalObserveRequest(
          nowMs: to.millisecondsSinceEpoch.toDouble(),
          hr: samples.hr,
          accel: samples.accel,
          rr: samples.rr,
          priorState: _checkpoint,
        ),
      ),
    ).timeout(_timeout);
    _checkpoint = result.nextState;
    return selectCalculationMode(
      heavy: false,
      forced: false,
      phoneCharging: charging,
      observation: result.observation,
      nowMs: _now().millisecondsSinceEpoch.toDouble(),
    );
  }
}
