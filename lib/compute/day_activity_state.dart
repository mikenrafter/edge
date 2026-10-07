import 'package:openstrap_analytics/onehz.dart' as ana;

import 'hr_max.dart';
import 'resume_bytes.dart';
import 'state_fingerprint.dart';
import 'substrate.dart' show accelPlausible;

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
///
/// The samples themselves are not kept. A 128-bit fingerprint of the folded
/// prefix tells the next pass whether that prefix is still what the caller
/// holds, so the summary stays a few thousand numbers however long the day is.
class DayHrSummary {
  final PrefixFingerprint _prefix = PrefixFingerprint();
  int _n = 0;
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

  /// Samples held in memory: the smoothing window, nothing of the day itself.
  int get retainedSamples => _window.length;

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
        n >= _n &&
        sleepOnsetSec == _sleepOn &&
        sleepOffsetSec == _sleepOff &&
        age == _age;
    if (append) {
      final seen = PrefixFingerprint();
      for (var i = 0; i < _n; i++) {
        seen.addInt(ts[i]);
        seen.addInt(hr[i]);
      }
      append = seen.matches(_prefix);
    }
    if (!append) _reset(sleepOnsetSec, sleepOffsetSec, age);
    _fold(ts, hr, _n, n);
  }

  /// Samples folded so far (the day's rows before the resume point).
  int get length => _n;

  /// Folds [ts]/[hr], the samples that come right after the ones already
  /// folded, without looking back at them: a caller that resumed this summary
  /// from storage has already shown (by the revisions of the rows it folded)
  /// that the prefix is unchanged. False, folding nothing, when the sleep
  /// window or age differ from the ones this summary was folded under.
  bool appendTail(
    List<int> ts,
    List<int> hr, {
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required int? age,
  }) {
    if (_n > 0 &&
        (sleepOnsetSec != _sleepOn ||
            sleepOffsetSec != _sleepOff ||
            age != _age)) {
      return false;
    }
    if (_n == 0) _reset(sleepOnsetSec, sleepOffsetSec, age);
    _fold(ts, hr, 0, ts.length < hr.length ? ts.length : hr.length);
    return true;
  }

  void _fold(List<int> ts, List<int> hr, int from, int to) {
    final ceil = hrCeilingForAge(_age);
    for (var i = from; i < to; i++) {
      final t = ts[i], h = hr[i];
      _prefix.addInt(t);
      _prefix.addInt(h);
      _n++;
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
    _prefix.clear();
    _n = 0;
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

  /// The state, for the resume blob. [processedSamples] is a work counter and
  /// starts again from 0 when the state is read back.
  void write(ResumeWriter w) {
    final (a, b) = _prefix.words;
    w.i64(a);
    w.i64(b);
    w.i64(_n);
    w.i64(_sleepOn);
    w.i64(_sleepOff);
    w.optI64(_age);
    w.f64(_validSum);
    w.i64(_validCount);
    w.optF64(_validMax);
    w.optF64(_validMin);
    w.i32(_window.length);
    for (final v in _window) {
      w.i64(v);
    }
    w.i64(_kept);
    w.optI64(_plainMax);
    w.optI64(_plainMin);
    w.optI64(_medMax);
    w.optI64(_medMin);
    final keys = _minuteSum.keys.toList()..sort();
    w.i32(keys.length);
    for (final k in keys) {
      w.i64(k);
      w.f64(_minuteSum[k]!);
      w.i64(_minuteCount[k]!);
    }
    w.f64(_wakeSum);
    w.i64(_wakeCount);
  }

  /// Reads what [write] wrote; throws [FormatException] on anything else.
  static DayHrSummary read(ResumeReader r) {
    final s = DayHrSummary();
    s._prefix.copyFrom(PrefixFingerprint.fromWords(r.i64(), r.i64()));
    s._n = r.i64();
    s._sleepOn = r.i64();
    s._sleepOff = r.i64();
    s._age = r.optI64();
    s._validSum = r.f64();
    s._validCount = r.i64();
    s._validMax = r.optF64();
    s._validMin = r.optF64();
    final window = r.count(8);
    if (window > _w) throw const FormatException('resume state: bad window');
    for (var i = 0; i < window; i++) {
      s._window.add(r.i64());
    }
    s._kept = r.i64();
    s._plainMax = r.optI64();
    s._plainMin = r.optI64();
    s._medMax = r.optI64();
    s._medMin = r.optI64();
    final minutes = r.count(24);
    for (var i = 0; i < minutes; i++) {
      final k = r.i64();
      s._minuteSum[k] = r.f64();
      s._minuteCount[k] = r.i64();
    }
    s._wakeSum = r.f64();
    s._wakeCount = r.i64();
    if (s._n < 0 || s._validCount < 0 || s._kept < 0 || s._wakeCount < 0) {
      throw const FormatException('resume state: bad count');
    }
    return s;
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
/// or to the sleep window, rebuilds from the start. As in [DayHrSummary], a
/// fingerprint of the folded prefix stands in for a copy of the samples.
class DayMotionSummary {
  final PrefixFingerprint _prefix = PrefixFingerprint();
  int _n = 0;
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
  int get length => _n;

  /// Samples held in memory: none, only running sums.
  int get retainedSamples => 0;

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
        n >= _n &&
        sleepOnsetSec == _sleepOn &&
        sleepOffsetSec == _sleepOff;
    if (append) {
      final seen = PrefixFingerprint();
      for (var i = 0; i < _n; i++) {
        seen.addInt(ts[i]);
        seen.addDouble(ax[i]);
        seen.addDouble(ay[i]);
        seen.addDouble(az[i]);
      }
      append = seen.matches(_prefix);
    }
    if (!append) _reset(sleepOnsetSec, sleepOffsetSec);
    _fold(ts, ax, ay, az, _n, n);
  }

  /// Folds the samples that come right after the ones already folded, without
  /// looking back at them; see [DayHrSummary.appendTail]. False, folding
  /// nothing, when the sleep window differs from the one folded under.
  bool appendTail(
    List<int> ts,
    List<double> ax,
    List<double> ay,
    List<double> az, {
    required int sleepOnsetSec,
    required int sleepOffsetSec,
  }) {
    if (_n > 0 && (sleepOnsetSec != _sleepOn || sleepOffsetSec != _sleepOff)) {
      return false;
    }
    if (_n == 0) _reset(sleepOnsetSec, sleepOffsetSec);
    _fold(ts, ax, ay, az, 0, ts.length);
    return true;
  }

  void _fold(
    List<int> ts,
    List<double> ax,
    List<double> ay,
    List<double> az,
    int from,
    int to,
  ) {
    for (var i = from; i < to; i++) {
      final t = ts[i];
      final angle = ana.zAngle(ax[i], ay[i], az[i]);
      final present = accelPlausible(ax[i], ay[i], az[i]);
      // `_n` is the day's own sample index (it counts the samples folded
      // before this one), which is what "the first sample" means here.
      if (_n == 0) {
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
      _prefix.addInt(t);
      _prefix.addDouble(ax[i]);
      _prefix.addDouble(ay[i]);
      _prefix.addDouble(az[i]);
      _n++;
      _processed++;
    }
  }

  void _reset(int on, int off) {
    _prefix.clear();
    _n = 0;
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

  void write(ResumeWriter w) {
    final (a, b) = _prefix.words;
    w.i64(a);
    w.i64(b);
    w.i64(_n);
    w.i64(_sleepOn);
    w.i64(_sleepOff);
    w.f64(_prevAngle);
    w.bool_(_prevPresent);
    for (final m in [_wakeTot, _wakeMove, _curveTot, _curveMove]) {
      final keys = m.keys.toList()..sort();
      w.i32(keys.length);
      for (final k in keys) {
        w.i64(k);
        w.i64(m[k]!);
      }
    }
    w.i32(_closedRuns.length);
    for (final r in _closedRuns) {
      w.i64(r[0]);
      w.i64(r[1]);
    }
    w.i64(_runStart);
    w.i64(_prevTs);
  }

  static DayMotionSummary read(ResumeReader r) {
    final s = DayMotionSummary();
    s._prefix.copyFrom(PrefixFingerprint.fromWords(r.i64(), r.i64()));
    s._n = r.i64();
    s._sleepOn = r.i64();
    s._sleepOff = r.i64();
    s._prevAngle = r.f64();
    s._prevPresent = r.bool_();
    for (final m in [s._wakeTot, s._wakeMove, s._curveTot, s._curveMove]) {
      final n = r.count(16);
      for (var i = 0; i < n; i++) {
        m[r.i64()] = r.i64();
      }
    }
    final runs = r.count(16);
    for (var i = 0; i < runs; i++) {
      s._closedRuns.add([r.i64(), r.i64()]);
    }
    s._runStart = r.i64();
    s._prevTs = r.i64();
    if (s._n < 0) throw const FormatException('resume state: bad count');
    return s;
  }

  /// Wake minutes with at least 20 % of their seconds moving ≥ 5°; null when
  /// under a minute of data or no second carried a gravity vector.
  int? activeMinutes() {
    if (_n < 60 || _wakeTot.isEmpty) return null;
    var active = 0;
    _wakeTot.forEach((m, tot) {
      if (tot > 0 && (_wakeMove[m] ?? 0) / tot >= _activeFrac) active++;
    });
    return active;
  }

  /// Per-5-minute movement fraction over the whole day.
  List<Map<String, dynamic>> activityCurve() {
    if (_n < 60) return const [];
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
  List<List<int>> wearRuns() => _n == 0
      ? const []
      : [
          for (final r in _closedRuns) [r[0], r[1]],
          [_runStart, _prevTs + 1],
        ];
}

/// The band's own step counter folded second by second: the previous reading,
/// when it was taken, and the credited total. Identical to
/// `hardwareStepsFromCounter` over the same seconds (that function is this fold
/// run once over a whole day), so a day folded in pieces, or resumed from the
/// stored triple, gives the same total.
///
/// Counter wrap and reset are handled exactly as there: a negative delta is
/// re-read modulo [modulus], and a delta over the plausibility budget (which is
/// what a reset looks like) is dropped, never invented.
class StepCounterFold {
  final PrefixFingerprint _prefix = PrefixFingerprint();
  int _n = 0;
  int? _modulus;
  int? _prev, _prevTs;
  int _total = 0;
  bool _seen = false;
  int _processed = 0;

  static const _maxStepsPerSecond = 5;
  static const _minGapSecForBudget = 60;
  static const _maxGapSecForBudget = 3600;

  int get processedSamples => _processed;
  int get length => _n;

  /// The credited steps, or null when the strap has no counter (no modulus) or
  /// no second carried a reading: absent, never 0.
  int? get steps {
    final m = _modulus;
    if (m == null || m <= 0) return null;
    return _seen ? _total : null;
  }

  /// Brings the fold up to date with the day's [ts] and [counter] (`-1` = no
  /// reading that second). Rebuilds from the start unless the samples folded
  /// before are still the ones passed and [modulus] is unchanged.
  void sync(
    List<int> ts,
    List<int> counter, {
    required int? modulus,
    bool force = false,
  }) {
    final n = ts.length;
    var append = !force && n >= _n && modulus == _modulus;
    if (append) {
      final seen = PrefixFingerprint();
      for (var i = 0; i < _n; i++) {
        seen.addInt(ts[i]);
        seen.addInt(i < counter.length ? counter[i] : -1);
      }
      append = seen.matches(_prefix);
    }
    if (!append) _reset(modulus);
    _fold(ts, counter, _n, n);
  }

  /// Folds the samples right after the ones already folded, without looking
  /// back at them; see [DayHrSummary.appendTail]. False, folding nothing, when
  /// [modulus] differs from the one folded under.
  bool appendTail(List<int> ts, List<int> counter, {required int? modulus}) {
    if (_n > 0 && modulus != _modulus) return false;
    if (_n == 0) _reset(modulus);
    _fold(ts, counter, 0, ts.length);
    return true;
  }

  void _reset(int? modulus) {
    _prefix.clear();
    _n = 0;
    _modulus = modulus;
    _prev = _prevTs = null;
    _total = 0;
    _seen = false;
  }

  void _fold(List<int> ts, List<int> counter, int from, int to) {
    final wrap = _modulus;
    final live = wrap != null && wrap > 0;
    for (var i = from; i < to; i++) {
      final t = ts[i];
      final c = i < counter.length ? counter[i] : -1;
      _prefix.addInt(t);
      _prefix.addInt(c);
      _n++;
      _processed++;
      if (!live || c < 0) continue;
      _seen = true;
      final prev = _prev, prevTs = _prevTs;
      if (prev != null && prevTs != null && t > prevTs) {
        final gap = t - prevTs;
        final budget =
            gap.clamp(_minGapSecForBudget, _maxGapSecForBudget) *
            _maxStepsPerSecond;
        var delta = c - prev;
        if (delta < 0) delta += wrap; // wrap candidate; a reset overshoots below
        if (delta > 0 && delta <= budget) _total += delta;
      }
      _prev = c;
      _prevTs = t;
    }
  }

  void write(ResumeWriter w) {
    final (a, b) = _prefix.words;
    w.i64(a);
    w.i64(b);
    w.i64(_n);
    w.optI64(_modulus);
    w.optI64(_prev);
    w.optI64(_prevTs);
    w.i64(_total);
    w.bool_(_seen);
  }

  static StepCounterFold read(ResumeReader r) {
    final s = StepCounterFold();
    s._prefix.copyFrom(PrefixFingerprint.fromWords(r.i64(), r.i64()));
    s._n = r.i64();
    s._modulus = r.optI64();
    s._prev = r.optI64();
    s._prevTs = r.optI64();
    s._total = r.i64();
    s._seen = r.bool_();
    if (s._n < 0) throw const FormatException('resume state: bad count');
    return s;
  }
}
