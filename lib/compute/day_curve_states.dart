// The three day-side curves that live in edge (`DerivationEngine.dayHrvCurve`,
// `dayRespCurve`, `_daytimeHrv`) as one resumable state carried in the day
// checkpoint, ported from the research prototypes
// (analytics-incr-research/tool/incremental/{hrv,resp}_incr.dart). Each is
// bit-identical to its batch function over what was folded.
//
// All three read the day's beats; two also read the accelerometer. The 1 Hz
// rows and the beats of one pass arrive together, but a beat can sit ahead of
// the accelerometer the caller has given so far, so beats are RELEASED to the
// two accelerometer curves only once every row of their second is in (the
// watermark). The HRV curve reads no accelerometer and takes every beat at once.
//
// The state does not depend on the sleep window. `daytimeHrv` keeps every
// quiet adjacent pair as it was formed (the second of each beat and the squared
// difference) and applies the window when it is READ, so the night that moves
// on most passes needs no refold. A pair is counted exactly when neither of its
// beats falls in the window, which is what the batch's "a beat in the window
// breaks the chain" comes to.
//
// Bytes are canonical: what is written is a function of the beats and rows
// folded, never of how they were chunked. Rings are written from their live
// head, and the seconds the accelerometer buffers keep only what a later beat
// can still read (see [_floorSec]).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart' show rsaRespRate;

import 'resume_bytes.dart';

const int _unset = -(1 << 60);

class DayCurveStates {
  /// [cut] is the family's quiet-second ENMO cut (g), 0.02 for gen4 / gen5.
  DayCurveStates({this.cut = 0.02});

  final double cut;

  // ── shared ────────────────────────────────────────────────────────────────
  int _watermark = _unset;

  /// Seconds below this are no longer buffered: a beat before it cannot be
  /// folded exactly any more (see [fold]'s result).
  int _floor = _unset;
  int? _lastBeatSec;
  bool _broken = false;
  final List<double> _pendTs = [], _pendRr = [];

  // ── HRV curve ─────────────────────────────────────────────────────────────
  List<double> _hTs = [], _hRr = [];
  int _hHead = 0;
  double _hLast = -1e18;
  final List<int> _hOutT = [];
  final List<double> _hOutV = [];

  // ── breathing curve ───────────────────────────────────────────────────────
  List<double> _rTs = [], _rRr = [];
  int _rHead = 0;
  int _rGated = 0;
  double _rLast = -1e18;
  final List<int> _rOutT = [];
  final List<double> _rOutV = [];
  final List<int> _rowSec = [];
  final List<int> _rowQuiet = [];

  // ── daytime HRV ───────────────────────────────────────────────────────────
  double? _prevQ;
  int _prevSec = 0;
  final Set<int> _quiet = {};
  final List<int> _pairSec = [], _pairBack = [];
  final List<double> _pairAbsD = [];

  /// Folds beats ([rrMs] / [rrTsMs], epoch ms) and 1 Hz accelerometer rows
  /// ([accTs] seconds, [ax] / [ay] / [az] g). Every accelerometer row with
  /// `tsSec < watermarkSec` has been given by this call or an earlier one; a
  /// beat whose second is at or past it waits ([pending]).
  ///
  /// False when the state can no longer be trusted as a continuation: a beat
  /// older than the seconds it still buffers (the caller's beats are not in
  /// time order within the slack this state keeps). The state is then to be
  /// thrown away, and the next pass folds the day from its start.
  bool fold(
    List<double> rrMs,
    List<double> rrTsMs,
    List<int> accTs,
    List<double> ax,
    List<double> ay,
    List<double> az,
    int watermarkSec,
  ) {
    if (_broken) return false;
    // Nothing to remember until the first beat: the rows a beat can read are
    // those from its own second on, and a beat never arrives behind rows this
    // state was not given (see [continuesWith]). A day's beat-less stretch costs
    // no bytes, and a state that has seen nothing stays the empty state.
    if (untouched && rrMs.isEmpty) return true;
    for (var i = 0; i < accTs.length; i++) {
      final mx = ax[i], my = ay[i], mz = az[i];
      final magSq = mx * mx + my * my + mz * mz;
      var q = false;
      if (magSq > 0 && magSq <= 16.0) {
        final mag = math.sqrt(mx * mx + my * my + mz * mz);
        q = (mag - 1.0).abs() <= cut;
      }
      _rowSec.add(accTs[i]);
      _rowQuiet.add(q ? 1 : 0);
      if (q) _quiet.add(accTs[i]);
    }
    for (var i = 0; i < rrMs.length; i++) {
      if (rrTsMs[i] ~/ 1000 < _floor) {
        _broken = true;
        return false;
      }
    }
    _hrvFold(rrMs, rrTsMs);
    _pendRr.addAll(rrMs);
    _pendTs.addAll(rrTsMs);
    if (watermarkSec > _watermark) _watermark = watermarkSec;
    var used = 0;
    for (; used < _pendRr.length; used++) {
      final tSec = _pendTs[used] ~/ 1000;
      if (tSec >= _watermark) break; // a second the accelerometer has not closed
      _release(_pendRr[used], _pendTs[used], tSec);
    }
    if (used > 0) {
      _pendRr.removeRange(0, used);
      _pendTs.removeRange(0, used);
    }
    return true;
  }

  /// True until the first beat is folded.
  bool get untouched => _lastBeatSec == null && _pendRr.isEmpty;

  /// Whether [fold] of beats stamped [rrTsMs] with accelerometer rows [accTs]
  /// can continue this state exactly. An untouched state kept no rows, so the
  /// beats must not reach back before the first row given with them (a resume's
  /// first beats sit a few seconds behind its first row, and the rows of those
  /// seconds went with the pass before). A state that has seen beats keeps the
  /// rows a later beat can read, and [fold] itself refuses the rest.
  bool continuesWith(List<double> rrTsMs, List<int> accTs) {
    if (!untouched || rrTsMs.isEmpty) return true;
    return accTs.isNotEmpty && rrTsMs.first ~/ 1000 >= accTs.first;
  }

  /// Beats held back from the two accelerometer-dependent curves (breathing,
  /// daytime HRV): the trailing beats whose second is at or past the watermark
  /// (both curves hold the same ones back, so there is one count).
  int get pending => _pendRr.length;

  /// Equal to `DerivationEngine.dayHrvCurve` over EVERY beat folded (it reads
  /// no accelerometer, so nothing is held back).
  List<Map<String, num>> hrvCurve() => _curve(_hOutT, _hOutV);

  /// Equal to `DerivationEngine.dayRespCurve` over what was folded and not
  /// pending.
  List<Map<String, num>> respCurve() =>
      _rGated < 60 ? const [] : _curve(_rOutT, _rOutV);

  static List<Map<String, num>> _curve(List<int> t, List<double> v) => [
        for (var i = 0; i < t.length; i++) {'t': t[i], 'v': v[i]},
      ];

  /// Equal to `DerivationEngine.daytimeHrv(sub, onsetSec, offsetSec)` over what
  /// was folded and not pending, under ANY window given at read time (the
  /// checkpoint does not depend on the sleep window).
  Map<String, dynamic> daytimeHrv({required int onsetSec, required int offsetSec}) {
    const binSec = 300;
    final hasWindow = offsetSec > onsetSec;
    bool inWindow(int s) => hasWindow && s >= onsetSec && s < offsetSec;
    final sums = <int, double>{};
    final counts = <int, int>{};
    for (var k = 0; k < _pairSec.length; k++) {
      final s = _pairSec[k];
      if (inWindow(s) || inWindow(s - _pairBack[k])) continue;
      final d2 = _pairAbsD[k] * _pairAbsD[k];
      final b = s ~/ binSec;
      sums[b] = (sums[b] ?? 0.0) + d2;
      counts[b] = (counts[b] ?? 0) + 1;
    }
    final timeline = <Map<String, dynamic>>[];
    final means = <double>[];
    final keys = sums.keys.toList()..sort();
    for (final b in keys) {
      final n = counts[b]!;
      if (n < 5) continue;
      final rmssd = math.sqrt(sums[b]! / n);
      timeline.add({
        't': b * binSec,
        'rmssd': (rmssd * 10).round() / 10.0,
        'n': n,
      });
      means.add(rmssd);
    }
    final mean = means.isEmpty
        ? null
        : means.reduce((a, c) => a + c) / means.length;
    return {
      'timeline': timeline,
      'mean_rmssd': mean == null ? null : (mean * 10).round() / 10.0,
      'n_buckets': timeline.length,
    };
  }

  // ── HRV curve: trailing 5-min RMSSD on gated RR, emitted every 60 s ────────

  void _hrvFold(List<double> rrMs, List<double> rrTsMs) {
    for (var q = 0; q < rrMs.length; q++) {
      final v = rrMs[q];
      if (!(v >= 300 && v <= 2000)) continue;
      _hTs.add(rrTsMs[q]);
      _hRr.add(v);
      final i = _hTs.length - 1;
      while (_hTs[i] - _hTs[_hHead] > 300000.0) {
        _hHead++;
      }
      if (i - _hHead >= 10 && _hTs[i] - _hLast > 60000) {
        double? value;
        var ssd = 0.0;
        var nd = 0;
        for (var k = _hHead + 1; k <= i; k++) {
          final d = _hRr[k] - _hRr[k - 1];
          if (d.abs() > 0.20 * _hRr[k - 1] || d.abs() > 200) continue;
          ssd += d * d;
          nd++;
        }
        if (nd >= 8) {
          final rmssd = math.sqrt(ssd / nd);
          value = rmssd <= 220 ? double.parse(rmssd.toStringAsFixed(1)) : null;
        }
        _hLast = _hTs[i];
        if (value != null) {
          _hOutT.add((_hTs[i] / 1000).round());
          _hOutV.add(value);
        }
      }
    }
    if (_hHead > 512) {
      _hTs = _hTs.sublist(_hHead);
      _hRr = _hRr.sublist(_hHead);
      _hHead = 0;
    }
  }

  // ── released beats: daytime HRV pairs and the breathing curve ──────────────

  void _release(double v, double ts, int tSec) {
    if (_lastBeatSec == null || tSec > _lastBeatSec!) _lastBeatSec = tSec;
    // Daytime HRV: the pair is formed window-free (the window is applied at
    // read). A beat qualifies when its second was still and its interval is
    // plausible; a pair is two adjacent qualifying beats within 200 ms.
    if (!_quiet.contains(tSec) || v < 300 || v > 2000) {
      _prevQ = null;
    } else {
      final p = _prevQ;
      if (p != null) {
        final d = v - p;
        if (d.abs() <= 200) {
          _pairSec.add(tSec);
          _pairBack.add(tSec - _prevSec);
          _pairAbsD.add(d.abs());
        }
      }
      _prevQ = v;
      _prevSec = tSec;
    }
    _respBeat(v, ts);
  }

  void _respBeat(double v, double t) {
    if (!(v >= 300 && v <= 2000)) return;
    final i = _rTs.length; // the index this beat takes
    var head = _rHead;
    while (head < i && t - _rTs[head] > 180000.0) {
      head++;
    }
    final attempt = (i - head >= 30) && (t - _rLast > 300000);
    _rTs.add(t);
    _rRr.add(v);
    _rGated++;
    _rHead = head;
    if (attempt) _respAttempt(i);
    if (_rHead > 256) {
      _rTs = _rTs.sublist(_rHead);
      _rRr = _rRr.sublist(_rHead);
      _rHead = 0;
    }
  }

  void _respAttempt(int i) {
    final loSec = (_rTs[_rHead] / 1000).floor();
    final hiSec = (_rTs[i] / 1000).ceil();
    var still = 0;
    for (var r = 0; r < _rowSec.length; r++) {
      if (_rowSec[r] >= loSec && _rowSec[r] < hiSec && _rowQuiet[r] == 1) still++;
    }
    final spanSec = hiSec - loSec;
    double? brpm;
    if (!(spanSec <= 0 || still < 0.9 * spanSec)) {
      final nn = _rRr.sublist(_rHead, i + 1);
      final t0 = _rTs[_rHead];
      final nnt = [for (var k = _rHead; k <= i; k++) _rTs[k] - t0];
      final est = rsaRespRate(nn, nnt, artifactFraction: 0.15);
      brpm = est.present ? est.value!.brpm : null;
    }
    _rLast = _rTs[i];
    if (brpm != null) {
      _rOutT.add((_rTs[i] / 1000).round());
      _rOutV.add(double.parse(brpm.toStringAsFixed(1)));
    }
  }

  // ── bytes ─────────────────────────────────────────────────────────────────

  /// The oldest second a later beat can still read, minus slack: the buffered
  /// accelerometer seconds below it are never needed again. Anchored on state
  /// (the last beat released, the first one waiting, the watermark), so it does
  /// not depend on how the day was chunked.
  int _floorSec() {
    var anchor = _watermark;
    final last = _lastBeatSec;
    if (last != null && last < anchor) anchor = last;
    if (_pendTs.isNotEmpty) {
      final first = _pendTs.first ~/ 1000;
      if (first < anchor) anchor = first;
    }
    return math.max(_floor, anchor - 300);
  }

  void write(ResumeWriter w) {
    final floor = _floorSec();
    w.f64(cut);
    w.i64(_watermark);
    w.i64(floor);
    w.optI64(_lastBeatSec);
    // HRV curve.
    _writeBeats(w, _hTs, _hRr, _hHead);
    w.f64(_hLast);
    _writeCurve(w, _hOutT, _hOutV);
    // Beats waiting for the accelerometer.
    _writeBeats(w, _pendTs, _pendRr, 0);
    // Breathing curve.
    _writeBeats(w, _rTs, _rRr, _rHead);
    w.i64(_rGated);
    w.f64(_rLast);
    _writeCurve(w, _rOutT, _rOutV);
    final rows = <int>[
      for (var i = 0; i < _rowSec.length; i++)
        if (_rowSec[i] >= floor) i,
    ];
    w.i32(rows.length);
    for (final i in rows) {
      w.i64(_rowSec[i]);
      w.u8(_rowQuiet[i]);
    }
    // Daytime HRV.
    w.optF64(_prevQ);
    w.i64(_prevSec);
    final quiet = [
      for (final s in _quiet)
        if (s >= floor) s,
    ]..sort();
    w.i32(quiet.length);
    for (final s in quiet) {
      w.i64(s);
    }
    final pairs = _packPairs();
    w.i32(_pairSec.length);
    w.i32(pairs.length);
    w.bytes(pairs, pairs.length);
  }

  static void _writeBeats(
      ResumeWriter w, List<double> ts, List<double> rr, int from) {
    w.i32(ts.length - from);
    for (var i = from; i < ts.length; i++) {
      w.f64(ts[i]);
    }
    for (var i = from; i < rr.length; i++) {
      w.f64(rr[i]);
    }
  }

  static void _writeCurve(ResumeWriter w, List<int> t, List<double> v) {
    w.i32(t.length);
    for (var i = 0; i < t.length; i++) {
      w.i64(t[i]);
      w.f64(v[i]);
    }
  }

  /// `second delta | gap back to the previous beat | |d|`, each pair a few bytes:
  /// zigzag varints for the two seconds, one byte for a whole-millisecond |d|
  /// (at most 200), 255 then a float for anything else.
  Uint8List _packPairs() {
    final out = BytesBuilder(copy: false);
    final f = ByteData(8);
    void varint(int v) {
      var z = (v << 1) ^ (v >> 63); // zigzag
      while (z >= 0x80 || z < 0) {
        out.addByte((z & 0x7f) | 0x80);
        z = z >>> 7;
      }
      out.addByte(z);
    }

    var prev = 0;
    for (var k = 0; k < _pairSec.length; k++) {
      varint(_pairSec[k] - prev);
      prev = _pairSec[k];
      varint(_pairBack[k]);
      final d = _pairAbsD[k];
      if (d <= 254 && d == d.truncateToDouble()) {
        out.addByte(d.toInt());
      } else {
        out.addByte(255);
        f.setFloat64(0, d);
        out.add(f.buffer.asUint8List(0, 8));
      }
    }
    return out.takeBytes();
  }

  static DayCurveStates read(ResumeReader r) {
    final s = DayCurveStates(cut: r.f64());
    s._watermark = r.i64();
    s._floor = r.i64();
    s._lastBeatSec = r.optI64();
    _readBeats(r, (ts, rr) {
      s._hTs = ts;
      s._hRr = rr;
    });
    s._hLast = r.f64();
    _readCurve(r, s._hOutT, s._hOutV);
    _readBeats(r, (ts, rr) {
      s._pendTs.addAll(ts);
      s._pendRr.addAll(rr);
    });
    _readBeats(r, (ts, rr) {
      s._rTs = ts;
      s._rRr = rr;
    });
    s._rGated = r.i64();
    s._rLast = r.f64();
    _readCurve(r, s._rOutT, s._rOutV);
    final rows = r.count(9);
    for (var i = 0; i < rows; i++) {
      s._rowSec.add(r.i64());
      s._rowQuiet.add(r.u8());
    }
    s._prevQ = r.optF64();
    s._prevSec = r.i64();
    final quiet = r.count(8);
    for (var i = 0; i < quiet; i++) {
      s._quiet.add(r.i64());
    }
    final nPairs = r.count(3);
    s._unpackPairs(r.bytes(r.count(1)), nPairs);
    return s;
  }

  static void _readBeats(
      ResumeReader r, void Function(List<double> ts, List<double> rr) put) {
    final n = r.count(16);
    final ts = <double>[for (var i = 0; i < n; i++) r.f64()];
    final rr = <double>[for (var i = 0; i < n; i++) r.f64()];
    put(ts, rr);
  }

  static void _readCurve(ResumeReader r, List<int> t, List<double> v) {
    final n = r.count(16);
    for (var i = 0; i < n; i++) {
      t.add(r.i64());
      v.add(r.f64());
    }
  }

  void _unpackPairs(Uint8List b, int n) {
    final d = ByteData.sublistView(b);
    var at = 0;
    int varint() {
      var shift = 0, z = 0;
      while (true) {
        if (at >= b.length || shift > 63) {
          throw const FormatException('resume state: bad pair varint');
        }
        final byte = b[at++];
        z |= (byte & 0x7f) << shift;
        if (byte < 0x80) break;
        shift += 7;
      }
      return (z >>> 1) ^ -(z & 1);
    }

    var sec = 0;
    for (var k = 0; k < n; k++) {
      sec += varint();
      _pairSec.add(sec);
      _pairBack.add(varint());
      if (at >= b.length) throw const FormatException('resume state truncated');
      final tag = b[at++];
      if (tag == 255) {
        if (at + 8 > b.length) throw const FormatException('resume state truncated');
        _pairAbsD.add(d.getFloat64(at));
        at += 8;
      } else {
        _pairAbsD.add(tag.toDouble());
      }
    }
    if (at != b.length) throw const FormatException('resume state: pair bytes left');
  }
}
