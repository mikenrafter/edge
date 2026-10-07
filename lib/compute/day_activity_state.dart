import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart' as ana;

import 'growable_bytes.dart';
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
/// order. Any change to an already-summarised sample or the age (which moves
/// the plausibility ceiling) rebuilds from the start.
///
/// The sleep window is NOT part of what is folded. The whole-day figures do not
/// read it, and the wake-side ones (per-minute mean HR, wake count and sum) are
/// read from the day's valid seconds, kept as one byte of second-in-minute and
/// one of bpm each, under whatever window the reader names ([wakeMinutesFor],
/// [wakeHrFor]). So the window can move on every pass, and the folded state,
/// and the bytes it is stored as, are the same. [sync] and [appendTail] only
/// record the window the argument-less readers use.
///
/// The day's raw samples are not kept beyond that. A 128-bit fingerprint of the
/// folded prefix tells the next pass whether that prefix is still what the
/// caller holds.
class DayHrSummary {
  final PrefixFingerprint _prefix = PrefixFingerprint();
  int _n = 0;

  /// The window the argument-less readers use; not part of the state.
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

  // Every valid (hr > 0) second, in fold order, as runs of one epoch minute:
  // run r is [_runLen[r]] seconds of minute [_runMin[r]], their second within
  // the minute (biased by 64, so a pre-epoch time still fits a byte) in [_secs]
  // and their bpm in [_bpm] (255 = look in [_bigBpm], by position).
  final List<int> _runMin = [], _runLen = [];
  final GrowableBytes _secs = GrowableBytes(), _bpm = GrowableBytes();
  final Map<int, int> _bigBpm = {};

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
    var append = !force && n >= _n && age == _age;
    if (append) {
      final seen = PrefixFingerprint();
      for (var i = 0; i < _n; i++) {
        seen.addInt(ts[i]);
        seen.addInt(hr[i]);
      }
      append = seen.matches(_prefix);
    }
    if (!append) _reset(age);
    _sleepOn = sleepOnsetSec;
    _sleepOff = sleepOffsetSec;
    _fold(ts, hr, _n, n);
  }

  /// Samples folded so far (the day's rows before the resume point).
  int get length => _n;

  /// Folds [ts]/[hr], the samples that come right after the ones already
  /// folded, without looking back at them: a caller that resumed this summary
  /// from storage has already shown (by the revisions of the rows it folded)
  /// that the prefix is unchanged. False, folding nothing, when the age differs
  /// from the one this summary was folded under; the window never does.
  bool appendTail(
    List<int> ts,
    List<int> hr, {
    int sleepOnsetSec = 0,
    int sleepOffsetSec = 0,
    required int? age,
  }) {
    if (_n > 0 && age != _age) return false;
    if (_n == 0) _reset(age);
    _sleepOn = sleepOnsetSec;
    _sleepOff = sleepOffsetSec;
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
      if (h <= 0) continue;
      _keepSecond(t, h);
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

  /// Records valid second [t] with [h] bpm.
  void _keepSecond(int t, int h) {
    final m = (t / 60).floor();
    if (_runMin.isEmpty || _runMin.last != m) {
      _runMin.add(m);
      _runLen.add(0);
    }
    _runLen[_runLen.length - 1]++;
    _secs.add(t - m * 60 + _secBias);
    if (h < 255) {
      _bpm.add(h);
    } else {
      _bigBpm[_bpm.length] = h;
      _bpm.add(255);
    }
  }

  static const _secBias = 64;

  void _reset(int? age) {
    _prefix.clear();
    _n = 0;
    _age = age;
    _validSum = 0;
    _validCount = 0;
    _validMax = _validMin = null;
    _window.clear();
    _kept = 0;
    _plainMax = _plainMin = _medMax = _medMin = null;
    _runMin.clear();
    _runLen.clear();
    _secs.clear();
    _bpm.clear();
    _bigBpm.clear();
  }

  /// The state, for the resume blob. [processedSamples] is a work counter and
  /// starts again from 0 when the state is read back.
  void write(ResumeWriter w) {
    final (a, b) = _prefix.words;
    w.i64(a);
    w.i64(b);
    w.i64(_n);
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
    w.i32(_runMin.length);
    for (var i = 0; i < _runMin.length; i++) {
      w.i64(_runMin[i]);
      w.i32(_runLen[i]);
    }
    w.i32(_secs.length);
    w.bytes(_secs.view, _secs.length);
    w.bytes(_bpm.view, _bpm.length);
    final big = _bigBpm.keys.toList()..sort();
    w.i32(big.length);
    for (final k in big) {
      w.i32(k);
      w.i64(_bigBpm[k]!);
    }
  }

  /// Reads what [write] wrote; throws [FormatException] on anything else.
  static DayHrSummary read(ResumeReader r) {
    final s = DayHrSummary();
    s._prefix.copyFrom(PrefixFingerprint.fromWords(r.i64(), r.i64()));
    s._n = r.i64();
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
    final runs = r.count(12);
    var held = 0;
    for (var i = 0; i < runs; i++) {
      s._runMin.add(r.i64());
      final len = r.i32();
      if (len < 1) throw const FormatException('resume state: bad run');
      s._runLen.add(len);
      held += len;
    }
    final secs = r.i32();
    if (secs != held || r.remaining < 2 * secs) {
      throw const FormatException('resume state: bad seconds');
    }
    s._secs.addAll(r.bytes(secs));
    s._bpm.addAll(r.bytes(secs));
    final big = r.count(12);
    for (var i = 0; i < big; i++) {
      final k = r.i32();
      if (k < 0 || k >= secs || s._bpm[k] != 255) {
        throw const FormatException('resume state: bad bpm');
      }
      s._bigBpm[k] = r.i64();
    }
    if (s._n < 0 || s._validCount < 0 || s._kept < 0 || held > s._n) {
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

  /// Per-minute mean wake HR, keyed by epoch minute, in minute order, under
  /// the window of the last [sync] or [appendTail].
  ({List<int> keys, List<double> hr}) wakeMinutes() =>
      wakeMinutesFor(sleepOnsetSec: _sleepOn, sleepOffsetSec: _sleepOff);

  /// Day-side input of `hrDip`: valid wake samples, as count and sum, under
  /// the window of the last [sync] or [appendTail].
  ({int count, double sum}) get wakeHr =>
      wakeHrFor(sleepOnsetSec: _sleepOn, sleepOffsetSec: _sleepOff);

  /// Calls [each] with the minute and bpm of every valid second outside the
  /// window `[on, off)`, in fold order.
  void _eachWake(int on, int off, void Function(int minute, int bpm) each) {
    var at = 0;
    for (var r = 0; r < _runMin.length; r++) {
      final m = _runMin[r], len = _runLen[r];
      for (var j = at; j < at + len; j++) {
        if (_inSleep(m * 60 + _secs[j] - _secBias, on, off)) continue;
        final v = _bpm[j];
        each(m, v == 255 ? _bigBpm[j]! : v);
      }
      at += len;
    }
  }

  /// [wakeMinutes] for the window `[sleepOnsetSec, sleepOffsetSec)`, read from
  /// the window-free state, so moving the window between passes never refolds
  /// the day. Whole bpm are added as integers and divided once, as the batch
  /// reader does.
  ({List<int> keys, List<double> hr}) wakeMinutesFor({
    required int sleepOnsetSec,
    required int sleepOffsetSec,
  }) {
    final sum = <int, int>{}, count = <int, int>{};
    _eachWake(sleepOnsetSec, sleepOffsetSec, (m, v) {
      sum[m] = (sum[m] ?? 0) + v;
      count[m] = (count[m] ?? 0) + 1;
    });
    final keys = sum.keys.toList()..sort();
    return (keys: keys, hr: [for (final k in keys) sum[k]! / count[k]!]);
  }

  /// [wakeHr] for the window `[sleepOnsetSec, sleepOffsetSec)`.
  ({int count, double sum}) wakeHrFor({
    required int sleepOnsetSec,
    required int sleepOffsetSec,
  }) {
    var sum = 0, count = 0;
    _eachWake(sleepOnsetSec, sleepOffsetSec, (_, v) {
      sum += v;
      count++;
    });
    return (count: count, sum: sum.toDouble());
  }
}

/// Exact append-only summaries of a day's 1 Hz orientation and record
/// presence: wake active minutes, the 5-minute activity curve, and wear runs.
///
/// Each second's contribution reads only that second and the one before it, so
/// appending folds in new seconds. Any change to an already-summarised sample
/// rebuilds from the start. As in [DayHrSummary], a fingerprint of the folded
/// prefix stands in for a copy of the samples, and the sleep window is not
/// part of the state: every second that counted (a gravity vector now and one
/// second before) is kept as its second in the minute and whether it moved,
/// and [activeMinutesFor] reads them under the window it is given.
class DayMotionSummary {
  final PrefixFingerprint _prefix = PrefixFingerprint();
  int _n = 0;

  /// The window the argument-less reader uses; not part of the state.
  int _sleepOn = 0, _sleepOff = 0;
  int _processed = 0;

  double _prevAngle = 0;
  bool _prevPresent = false;
  final Map<int, int> _curveTot = {}, _curveMove = {};

  // Counted seconds in fold order, as runs of one epoch minute: run r is
  // [_runLen[r]] seconds of minute [_runMin[r]]; a second is stored as
  // `(second in minute + 64) << 1 | moved`.
  final List<int> _runMin = [], _runLen = [];
  final GrowableBytes _counted = GrowableBytes();

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
    var append = !force && n >= _n;
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
    if (!append) _reset();
    _sleepOn = sleepOnsetSec;
    _sleepOff = sleepOffsetSec;
    _fold(ts, ax, ay, az, _n, n);
  }

  /// Folds the samples that come right after the ones already folded, without
  /// looking back at them; see [DayHrSummary.appendTail]. Always true: the
  /// window is not part of what was folded.
  bool appendTail(
    List<int> ts,
    List<double> ax,
    List<double> ay,
    List<double> az, {
    int sleepOnsetSec = 0,
    int sleepOffsetSec = 0,
  }) {
    if (_n == 0) _reset();
    _sleepOn = sleepOnsetSec;
    _sleepOff = sleepOffsetSec;
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
          final m = (t / 60).floor();
          if (_runMin.isEmpty || _runMin.last != m) {
            _runMin.add(m);
            _runLen.add(0);
          }
          _runLen[_runLen.length - 1]++;
          _counted.add((t - m * 60 + _secBias) << 1 | (moved ? 1 : 0));
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

  static const _secBias = 64;

  void _reset() {
    _prefix.clear();
    _n = 0;
    _prevAngle = 0;
    _prevPresent = false;
    _runMin.clear();
    _runLen.clear();
    _counted.clear();
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
    w.f64(_prevAngle);
    w.bool_(_prevPresent);
    w.i32(_runMin.length);
    for (var i = 0; i < _runMin.length; i++) {
      w.i64(_runMin[i]);
      w.i32(_runLen[i]);
    }
    w.i32(_counted.length);
    w.bytes(_counted.view, _counted.length);
    for (final m in [_curveTot, _curveMove]) {
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
    s._prevAngle = r.f64();
    s._prevPresent = r.bool_();
    final minutes = r.count(12);
    var held = 0;
    for (var i = 0; i < minutes; i++) {
      s._runMin.add(r.i64());
      final len = r.i32();
      if (len < 1) throw const FormatException('resume state: bad run');
      s._runLen.add(len);
      held += len;
    }
    final counted = r.i32();
    if (counted != held || r.remaining < counted) {
      throw const FormatException('resume state: bad seconds');
    }
    s._counted.addAll(r.bytes(counted));
    for (final m in [s._curveTot, s._curveMove]) {
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
    if (s._n < 0 || held > s._n) {
      throw const FormatException('resume state: bad count');
    }
    return s;
  }

  /// Wake minutes with at least 20 % of their seconds moving ≥ 5°; null when
  /// under a minute of data or no second carried a gravity vector. Wake is
  /// outside the window of the last [sync] or [appendTail].
  int? activeMinutes() =>
      activeMinutesFor(sleepOnsetSec: _sleepOn, sleepOffsetSec: _sleepOff);

  /// [activeMinutes] for the window `[sleepOnsetSec, sleepOffsetSec)`, read
  /// from the window-free state.
  int? activeMinutesFor({
    required int sleepOnsetSec,
    required int sleepOffsetSec,
  }) {
    if (_n < 60) return null;
    final tot = <int, int>{}, move = <int, int>{};
    var at = 0;
    for (var r = 0; r < _runMin.length; r++) {
      final m = _runMin[r], len = _runLen[r];
      for (var j = at; j < at + len; j++) {
        final v = _counted[j];
        if (_inSleep(m * 60 + (v >> 1) - _secBias, sleepOnsetSec, sleepOffsetSec)) {
          continue;
        }
        tot[m] = (tot[m] ?? 0) + 1;
        if (v & 1 == 1) move[m] = (move[m] ?? 0) + 1;
      }
      at += len;
    }
    if (tot.isEmpty) return null;
    var active = 0;
    tot.forEach((m, t) {
      if ((move[m] ?? 0) / t >= _activeFrac) active++;
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

/// The day's per-minute motion buckets, folded second by second: for each
/// minute, how many valid seconds fed it and the sum of their gravity-removed
/// vector magnitude (`dynAmp` is the mean). Window-free: a valid second is one
/// with a heart rate and a real gravity vector, nothing about sleep.
///
/// The arithmetic is `enmoSeries`' for `dyn`, operation for operation: the
/// per-axis running sums over the trailing 15 s of valid seconds (add the new
/// second, then drop the ones 15 s or more behind it, never the new one), the
/// mean taken over what is in that window, the minute's sum added in second
/// order. Carrying the three sums and the (at most a few dozen) seconds of the
/// window across a resume therefore gives the batch's bits.
///
/// Nothing is derived from a gravity reference (`calibrateGRef` reads the whole
/// day and only fed `enmo`, which no reader in the app uses), so [minutes] sets
/// `enmo`, `mad` and `meanMag` to NaN, "not computed", rather than a number
/// they are not. Samples must come in ascending time, as the substrate holds
/// them.
class DayDynMinutes {
  final PrefixFingerprint _prefix = PrefixFingerprint();
  int _n = 0;
  int _processed = 0;

  double _sx = 0, _sy = 0, _sz = 0;
  final List<int> _qt = [];
  final List<double> _qx = [], _qy = [], _qz = [];
  final Map<int, int> _count = {};
  final Map<int, double> _dynSum = {};

  static const _windowSec = 15;

  int get processedSamples => _processed;
  int get length => _n;

  /// Seconds of the day held in memory: the trailing window.
  int get retainedSamples => _qt.length;

  /// Brings the buckets up to date with the day's [ts]/[hr]/[ax]/[ay]/[az]; as
  /// [DayMotionSummary.sync], rebuilding unless the folded prefix is still the
  /// one passed.
  void sync(
    List<int> ts,
    List<int> hr,
    List<double> ax,
    List<double> ay,
    List<double> az, {
    bool force = false,
  }) {
    final n = ts.length;
    var append = !force && n >= _n;
    if (append) {
      final seen = PrefixFingerprint();
      for (var i = 0; i < _n; i++) {
        _hash(seen, ts[i], hr[i], ax[i], ay[i], az[i]);
      }
      append = seen.matches(_prefix);
    }
    if (!append) _reset();
    _fold(ts, hr, ax, ay, az, _n, n);
  }

  /// Folds the samples right after the ones already folded, without looking
  /// back at them; see [DayHrSummary.appendTail].
  void appendTail(
    List<int> ts,
    List<int> hr,
    List<double> ax,
    List<double> ay,
    List<double> az,
  ) {
    if (_n == 0) _reset();
    _fold(ts, hr, ax, ay, az, 0, ts.length);
  }

  static void _hash(
    PrefixFingerprint f,
    int t,
    int h,
    double x,
    double y,
    double z,
  ) {
    f.addInt(t);
    f.addInt(h > 0 ? 1 : 0);
    f.addDouble(x);
    f.addDouble(y);
    f.addDouble(z);
  }

  void _fold(
    List<int> ts,
    List<int> hr,
    List<double> ax,
    List<double> ay,
    List<double> az,
    int from,
    int to,
  ) {
    for (var i = from; i < to; i++) {
      final t = ts[i], x = ax[i], y = ay[i], z = az[i];
      _hash(_prefix, t, hr[i], x, y, z);
      _n++;
      _processed++;
      if (hr[i] <= 0 || !accelPlausible(x, y, z)) continue;
      _sx += x;
      _sy += y;
      _sz += z;
      _qt.add(t);
      _qx.add(x);
      _qy.add(y);
      _qz.add(z);
      while (_qt.length > 1 && t - _qt[0] >= _windowSec) {
        _sx -= _qx[0];
        _sy -= _qy[0];
        _sz -= _qz[0];
        _qt.removeAt(0);
        _qx.removeAt(0);
        _qy.removeAt(0);
        _qz.removeAt(0);
      }
      final w = _qt.length;
      final dx = x - _sx / w, dy = y - _sy / w, dz = z - _sz / w;
      final dyn = math.sqrt(dx * dx + dy * dy + dz * dz);
      final k = (t * 1000.0 / 60000).floor();
      _count[k] = (_count[k] ?? 0) + 1;
      _dynSum[k] = (_dynSum[k] ?? 0.0) + dyn;
    }
  }

  void _reset() {
    _prefix.clear();
    _n = 0;
    _sx = _sy = _sz = 0;
    _qt.clear();
    _qx.clear();
    _qy.clear();
    _qz.clear();
    _count.clear();
    _dynSum.clear();
  }

  /// One row per minute that had a valid second, in minute order: what
  /// `enmoSeries(...).minutes` holds for the fields the app reads (`tsMinStartMs`,
  /// `nSamples`, `dynAmp`).
  List<ana.MotionMinute> minutes() {
    final keys = _count.keys.toList()..sort();
    return [
      for (final k in keys)
        ana.MotionMinute(k * 60000.0, _count[k]!, double.nan, double.nan,
            double.nan, _dynSum[k]! / _count[k]!),
    ];
  }

  void write(ResumeWriter w) {
    final (a, b) = _prefix.words;
    w.i64(a);
    w.i64(b);
    w.i64(_n);
    w.f64(_sx);
    w.f64(_sy);
    w.f64(_sz);
    w.i32(_qt.length);
    for (var i = 0; i < _qt.length; i++) {
      w.i64(_qt[i]);
      w.f64(_qx[i]);
      w.f64(_qy[i]);
      w.f64(_qz[i]);
    }
    final keys = _count.keys.toList()..sort();
    w.i32(keys.length);
    for (final k in keys) {
      w.i64(k);
      w.i32(_count[k]!);
      w.f64(_dynSum[k]!);
    }
  }

  static DayDynMinutes read(ResumeReader r) {
    final s = DayDynMinutes();
    s._prefix.copyFrom(PrefixFingerprint.fromWords(r.i64(), r.i64()));
    s._n = r.i64();
    s._sx = r.f64();
    s._sy = r.f64();
    s._sz = r.f64();
    final window = r.count(32);
    for (var i = 0; i < window; i++) {
      s._qt.add(r.i64());
      s._qx.add(r.f64());
      s._qy.add(r.f64());
      s._qz.add(r.f64());
    }
    final minutes = r.count(20);
    for (var i = 0; i < minutes; i++) {
      final k = r.i64();
      final c = r.i32();
      if (c < 1) throw const FormatException('resume state: bad count');
      s._count[k] = c;
      s._dynSum[k] = r.f64();
    }
    if (s._n < 0) throw const FormatException('resume state: bad count');
    return s;
  }
}
