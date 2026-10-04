import 'package:openstrap_analytics/onehz.dart' as ana;

import 'hr_max.dart';
import 'substrate.dart' show accelPlausible;

bool _same(double a, double b) => a == b || (a.isNaN && b.isNaN);

/// True when `[on, off)` is a sleep window and [t] falls inside it. Every
/// wake-side reader in the engine and the pipeline excludes exactly this.
bool _inSleep(int t, int on, int off) => off > on && t >= on && t < off;

/// Exact append-only summaries of a day's 1 Hz heart rate.
///
/// Each figure is a running sum, count or extreme taken in sample order, so it
/// is bit-identical to the batch reader it replaces: the batch means add in the
/// same order, and the smoothed extremes see the same windows in the same
/// order. Any change to an already-summarised sample, the sleep window or the
/// age (which moves the plausibility ceiling) rebuilds from the start.
class DayHrSummary {
  final List<int> _ts = [], _hr = [];
  int _sleepOn = 0, _sleepOff = 0;
  int? _age;
  int _processed = 0;

  // Valid (hr > 0) samples over the whole day.
  double _validSum = 0;
  int _validCount = 0;
  double? _validMax, _validMin;

  // Smoothed extremes over valid samples that pass the physiological reject.
  final List<int> _window = [];
  int _kept = 0;
  int? _plainMax, _plainMin, _medMax, _medMin;

  // Wake-side figures (outside the sleep window).
  final Map<int, double> _minuteSum = {};
  final Map<int, int> _minuteCount = {};
  double _wakeSum = 0;
  int _wakeCount = 0;

  /// The odd smoothing window `_smoothedExtremeHrAt` uses.
  static const _w = kHrSmoothWindow % 2 == 1 ? kHrSmoothWindow : kHrSmoothWindow + 1;

  /// Samples folded in since construction, including rebuilds (work counter).
  int get processedSamples => _processed;

  void sync(
    List<int> ts,
    List<int> hr, {
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required int? age,
    bool force = false,
  }) {
    final n = ts.length < hr.length ? ts.length : hr.length;
    var append = !force &&
        n >= _ts.length &&
        sleepOnsetSec == _sleepOn &&
        sleepOffsetSec == _sleepOff &&
        age == _age;
    for (var i = 0; append && i < _ts.length; i++) {
      if (ts[i] != _ts[i] || hr[i] != _hr[i]) append = false;
    }
    if (!append) _reset(sleepOnsetSec, sleepOffsetSec, age);
    final ceil = hrCeilingForAge(age);
    for (var i = _ts.length; i < n; i++) {
      final t = ts[i], h = hr[i];
      _ts.add(t);
      _hr.add(h);
      _processed++;
      if (!_inSleep(t, _sleepOn, _sleepOff) && h > 0) {
        final m = t ~/ 60;
        _minuteSum[m] = (_minuteSum[m] ?? 0) + h.toDouble();
        _minuteCount[m] = (_minuteCount[m] ?? 0) + 1;
        _wakeSum += h.toDouble();
        _wakeCount++;
      }
      if (h <= 0) continue;
      final v = h.toDouble();
      _validSum += v;
      _validCount++;
      if (_validMax == null || v > _validMax!) _validMax = v;
      if (_validMin == null || v < _validMin!) _validMin = v;
      // `smoothedMaxHr` takes `round()` of the valid doubles; ints round-trip.
      if (h < kHrFloorBpm || h > ceil) continue;
      if (_plainMax == null || h > _plainMax!) _plainMax = h;
      if (_plainMin == null || h < _plainMin!) _plainMin = h;
      _kept++;
      _window.add(h);
      if (_window.length > _w) _window.removeAt(0);
      if (_window.length < _w) continue;
      final med = (List<int>.of(_window)..sort())[_w ~/ 2];
      if (_medMax == null || med > _medMax!) _medMax = med;
      if (_medMin == null || med < _medMin!) _medMin = med;
    }
  }

  void _reset(int on, int off, int? age) {
    _ts.clear();
    _hr.clear();
    _sleepOn = on;
    _sleepOff = off;
    _age = age;
    _validSum = 0;
    _validCount = 0;
    _validMax = _validMin = null;
    _window.clear();
    _kept = 0;
    _plainMax = _plainMin = _medMax = _medMin = null;
    _minuteSum.clear();
    _minuteCount.clear();
    _wakeSum = 0;
    _wakeCount = 0;
  }

  /// `{max, min, avg}` over the day's valid HR, as the engine and pipeline
  /// publish it; null when there is no valid HR.
  Map<String, int?>? hrStats() {
    if (_validCount == 0) return null;
    final full = _kept >= _w;
    return {
      'max': (full ? _medMax : _plainMax) ?? _validMax!.round(),
      'min': (full ? _medMin : _plainMin) ?? _validMin!.round(),
      'avg': (_validSum / _validCount).round(),
    };
  }

  /// Per-minute mean wake HR, keyed by epoch minute, in minute order.
  ({List<int> keys, List<double> hr}) wakeMinutes() {
    final keys = _minuteSum.keys.toList()..sort();
    return (
      keys: keys,
      hr: [for (final k in keys) _minuteSum[k]! / _minuteCount[k]!],
    );
  }

  /// Day-side input of `hrDip`: valid wake samples, as count and sum.
  ({int count, double sum}) get wakeHr => (count: _wakeCount, sum: _wakeSum);
}

/// Exact append-only summaries of a day's 1 Hz orientation and record
/// presence: wake active minutes, the 5-minute activity curve, and wear runs.
///
/// Each second's contribution reads only that second and the one before it, so
/// appending folds in new seconds. Any change to an already-summarised sample,
/// or to the sleep window, rebuilds from the start.
class DayMotionSummary {
  final List<int> _ts = [];
  final List<double> _ax = [], _ay = [], _az = [];
  int _sleepOn = 0, _sleepOff = 0;
  int _processed = 0;

  double _prevAngle = 0;
  bool _prevPresent = false;
  final Map<int, int> _wakeTot = {}, _wakeMove = {};
  final Map<int, int> _curveTot = {}, _curveMove = {};

  final List<List<int>> _closedRuns = [];
  int _runStart = 0, _prevTs = 0;

  static const _moveDeg = 5.0;
  static const _activeFrac = 0.20;
  static const _bucketSec = 300;
  static const _offGapSec = 120;

  int get processedSamples => _processed;
  int get length => _ts.length;

  void sync(
    List<int> ts,
    List<double> ax,
    List<double> ay,
    List<double> az, {
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    bool force = false,
  }) {
    final n = ts.length;
    var append = !force &&
        n >= _ts.length &&
        sleepOnsetSec == _sleepOn &&
        sleepOffsetSec == _sleepOff;
    for (var i = 0; append && i < _ts.length; i++) {
      if (ts[i] != _ts[i] ||
          !_same(ax[i], _ax[i]) ||
          !_same(ay[i], _ay[i]) ||
          !_same(az[i], _az[i])) {
        append = false;
      }
    }
    if (!append) _reset(sleepOnsetSec, sleepOffsetSec);
    for (var i = _ts.length; i < n; i++) {
      final t = ts[i];
      final angle = ana.zAngle(ax[i], ay[i], az[i]);
      final present = accelPlausible(ax[i], ay[i], az[i]);
      if (i == 0) {
        _runStart = t;
      } else {
        if (t - _prevTs > _offGapSec) {
          _closedRuns.add([_runStart, _prevTs + 1]);
          _runStart = t;
        }
        if (present && _prevPresent) {
          final moved = (angle - _prevAngle).abs() > _moveDeg;
          final b = t ~/ _bucketSec;
          _curveTot[b] = (_curveTot[b] ?? 0) + 1;
          if (moved) _curveMove[b] = (_curveMove[b] ?? 0) + 1;
          if (!_inSleep(t, _sleepOn, _sleepOff)) {
            final m = t ~/ 60;
            _wakeTot[m] = (_wakeTot[m] ?? 0) + 1;
            if (moved) _wakeMove[m] = (_wakeMove[m] ?? 0) + 1;
          }
        }
      }
      _prevTs = t;
      _prevAngle = angle;
      _prevPresent = present;
      _ts.add(t);
      _ax.add(ax[i]);
      _ay.add(ay[i]);
      _az.add(az[i]);
      _processed++;
    }
  }

  void _reset(int on, int off) {
    _ts.clear();
    _ax.clear();
    _ay.clear();
    _az.clear();
    _sleepOn = on;
    _sleepOff = off;
    _prevAngle = 0;
    _prevPresent = false;
    _wakeTot.clear();
    _wakeMove.clear();
    _curveTot.clear();
    _curveMove.clear();
    _closedRuns.clear();
    _runStart = _prevTs = 0;
  }

  /// Wake minutes with at least 20 % of their seconds moving ≥ 5°; null when
  /// under a minute of data or no second carried a gravity vector.
  int? activeMinutes() {
    if (_ts.length < 60 || _wakeTot.isEmpty) return null;
    var active = 0;
    _wakeTot.forEach((m, tot) {
      if (tot > 0 && (_wakeMove[m] ?? 0) / tot >= _activeFrac) active++;
    });
    return active;
  }

  /// Per-5-minute movement fraction over the whole day.
  List<Map<String, dynamic>> activityCurve() {
    if (_ts.length < 60) return const [];
    final keys = _curveTot.keys.toList()..sort();
    return [
      for (final b in keys)
        {
          't': b * _bucketSec,
          'v': double.parse(
            ((_curveMove[b] ?? 0) / _curveTot[b]!).toStringAsFixed(3),
          ),
        },
    ];
  }

  /// Contiguous record-presence runs as `[start, end)`; empty with no data.
  List<List<int>> wearRuns() => _ts.isEmpty
      ? const []
      : [
          for (final r in _closedRuns) [r[0], r[1]],
          [_runStart, _prevTs + 1],
        ];
}
