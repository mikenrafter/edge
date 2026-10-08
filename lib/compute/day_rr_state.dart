// The day's streaming RR half of the checkpoint: a `RrCorrector` plus an
// `IrregularScreenState` (analytics aa67997), folded as beats arrive instead of
// `correctRr` / `irregularBeatScreen` over every beat of the day on every pass.
//
// The corrector settles a beat's output once enough later beats exist; its
// unsettled window and the screen's running sums and open 5-minute window are
// what the blob carries (bounded, not the series). Both are plain JSON in
// analytics, and JSON doubles round-trip bit-exactly, so the blob holds that
// JSON text rather than a second hand-written layout for the same fields.

import 'dart:convert';
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart';

import 'resume_bytes.dart';

class DayRrState {
  DayRrState()
      : _corr = RrCorrector(),
        _irr = IrregularScreenState();

  DayRrState._(this._corr, this._irr, this._beats, this._lastTsMs);

  final RrCorrector _corr;
  final IrregularScreenState _irr;
  int _beats = 0;
  double? _lastTsMs;

  /// Beats folded so far.
  int get beats => _beats;

  /// The timestamp of the last beat folded (ms), null before the first. Beats
  /// that follow it are held no earlier than this (the substrate's
  /// non-decreasing beat axis), so a caller that reads only the tail needs it.
  double? get lastTsMs => _lastTsMs;

  /// Folds [rrMs] (ms) stamped [rrTsMs] (epoch ms), in stored order.
  void fold(List<double> rrMs, List<double> rrTsMs) {
    if (rrMs.isEmpty) return;
    final settled = _corr.fold(rrMs, tsMs: rrTsMs);
    _irr.fold(settled.nn, settled.nnTimes);
    _beats += rrMs.length;
    _lastTsMs = rrTsMs.last;
  }

  /// The day's 24/7 irregular-rhythm screen over every beat folded: equal to
  /// `irregularBeatScreen(correctRr(all).nn, ...)` as persisted. Does not
  /// change the state.
  Metric<IrregularRhythm> irregular24h() => irregular24hDetailed().metric;

  /// [irregular24h] and the evidence behind it (beat counts, the corrector's
  /// corrected / dropped, per-window counts incl. the open window): equal to
  /// `irregularBeatScreenDetailed(correctRr(all)...)`. `.toJson()` is the
  /// envelope persisted as `clinical.irregular_24h`.
  IrregularScreenResult irregular24hDetailed() {
    final s = _corr.snapshot();
    return _irr.evaluateDetailed(
      s.tailNn,
      s.tailNnTimes,
      artifactFraction: (1.0 - s.cleanFraction).clamp(0.0, 1.0),
      cleaning: RrCleaningCounts(
        raw: s.n,
        corrected: s.correctedCount,
        dropped: s.droppedCount,
      ),
    );
  }

  void write(ResumeWriter w) {
    w.i64(_beats);
    w.optF64(_lastTsMs);
    final text = utf8.encode(jsonEncode({'c': _corr.toJson(), 'i': _irr.toJson()}));
    w.i32(text.length);
    w.bytes(Uint8List.fromList(text), text.length);
  }

  static DayRrState read(ResumeReader r) {
    final beats = r.i64();
    final last = r.optF64();
    final text = r.bytes(r.count(1));
    try {
      final j = jsonDecode(utf8.decode(text)) as Map<String, dynamic>;
      final corr = RrCorrector.fromJson((j['c'] as Map).cast<String, dynamic>());
      final irr =
          IrregularScreenState.fromJson((j['i'] as Map).cast<String, dynamic>());
      if (beats < 0 || corr.toJson()['n'] != beats) {
        throw const FormatException('RR state: beat counts disagree');
      }
      return DayRrState._(corr, irr, beats, last);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('RR state unreadable: $e');
    }
  }
}
