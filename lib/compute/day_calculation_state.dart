import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:openstrap_analytics/onehz.dart';

import 'day_activity_state.dart';
import 'day_resume_state.dart';
import 'day_rr_state.dart' show rrCheckpointBeatCount;
import 'minute_bills.dart';
import 'night_prsa.dart';
import 'night_resp_bins.dart';
import 'night_resume_part.dart';
import 'state_fingerprint.dart';
import '../util/heavy.dart';

typedef NightRr = ({
  List<double> nn,
  List<double> nnTimesMs,
  double cleanFraction,
  int droppedCount,
  int correctedCount,
});

/// The night's corrected RR in one batch call (what [DayCalculationState.nightRr]
/// reproduces incrementally). Heavy (it corrects every beat of the night); the
/// public name stays because the pipeline, the incremental path and the tests
/// share it.
@heavy
NightRr nightRrBatch(List<double> rrMs, List<double> rrTsMs) {
  final r = correctRr(rrMs, rrTsMs: rrTsMs);
  return (
    nn: r.nn,
    nnTimesMs: r.nnTimesMs,
    cleanFraction: r.cleanFraction,
    droppedCount: r.droppedCount,
    correctedCount: r.correctedCount,
  );
}

/// RAM-only calculation data copied into workers and published after persistence.
/// Callbacks passed to [evaluate] are evaluated synchronously, never retained.
///
/// The state is kept small on purpose: results and running sums stay, but the
/// inputs they came from do not. Cached calculations are matched on a
/// fingerprint of their dependencies ([dependencyFingerprint]) instead of a
/// copy, and the per-second summaries fingerprint the samples they folded in.
class DayCalculationState {
  final CalculationCache _cache = CalculationCache(maxEntries: 2048);
  IncrementalMinuteMetrics _minutes = IncrementalMinuteMetrics();

  /// Minutes the state above already held when it was read back from storage:
  /// not work this process did, so [processedMinutes] leaves them out.
  int _minutesBase = 0;
  // One per isolate half: the pipeline and the activity pass each read the day
  // with their own sleep bounds, so sharing one would rebuild on any mismatch.
  final Map<String, DayHrSummary> _hr = {};
  DayMotionSummary _motion = DayMotionSummary();
  StepCounterFold _steps = StepCounterFold();
  DayDynMinutes _dyn = DayDynMinutes();
  IncrementalEnmoSeries _enmo = IncrementalEnmoSeries();

  /// Valid samples the motion series above holds a copy of.
  int _enmoHeld = 0;

  /// The gravity reference of the last full motion calculation. Periodic awake
  /// passes reuse it; see [motionMinutes].
  double? _gRef;

  /// True when the per-second summaries were seeded from a stored checkpoint
  /// ([seedFrom]). Summaries are always reused only when the samples they
  /// folded are still the ones handed in (a fingerprint decides), so seeding
  /// lets them append in any mode, including a full pass in a fresh process,
  /// which has no earlier pass to carry them over.
  bool _seeded = false;

  /// Starts this (empty) state from a stored checkpoint's folded summaries.
  /// The state takes ownership of [resume]'s parts.
  ///
  /// Its priced minutes come too when the package accepts them; otherwise the
  /// first pass prices the day's minutes again, which gives the same figures.
  void seedFrom(DayResumeState resume) {
    _hr['pipeline'] = resume.hrPipeline;
    _hr['activity'] = resume.hrActivity;
    _motion = resume.motion;
    _steps = resume.steps;
    _dyn = resume.dyn;
    final minutes = resume.bills?.toMetrics();
    if (minutes != null) {
      _minutes = minutes;
      _minutesBase = minutes.processedMinutes;
    }
    seedNightJson(resume.nightJson);
    _seeded = true;
  }

  /// The wake minutes priced so far, those before epoch minute [beforeMinute],
  /// for the checkpoint; null when there are none to keep.
  MinuteBills? minuteBills({required int beforeMinute}) {
    final json = _minutes.toJson();
    return MinuteBills.fromMetricsJson(json, beforeMinute: beforeMinute);
  }

  bool _forceSummaries(CalculationMode mode) =>
      mode != CalculationMode.periodicAwake && !_seeded;

  int get computations => _cache.computations;
  int get hits => _cache.hits;
  int get processedMinutes => _minutes.processedMinutes - _minutesBase;
  int get processedMotionPoints => _enmo.processedPoints + _dyn.processedSamples;
  int get processedHrSamples =>
      _hr.values.fold(0, (n, h) => n + h.processedSamples);
  int get processedOrientationSamples => _motion.processedSamples;
  int get processedStepSamples => _steps.processedSamples;

  /// Samples of the day held in memory by this state, across every part.
  int get retainedSamples =>
      _hr.values.fold(0, (n, h) => n + h.retainedSamples) +
      _motion.retainedSamples +
      _dyn.retainedSamples +
      _enmoHeld;

  /// Drops the one part that keeps day samples, the motion series. The next
  /// pass rebuilds it from the day it is handed, which gives the same minutes
  /// an appended one does; every other part is already compact.
  void compact() {
    _enmo = IncrementalEnmoSeries();
    _enmoHeld = 0;
    // A kept state must not hold the last pass's sample lists alive.
    _digests.clear();
  }

  // ── Night RR correction, streamed ──────────────────────────────────────────
  // The night slice depends on the sleep window, so this part rides the
  // checkpoint as its own optional section (NightResumePart), never in the day
  // part. What the corrector folded is remembered as (start, count, running
  // fingerprint), not as a copy of the beats; see [nightFoldTag].
  RrCorrector? _nightCorrector;
  double _nightStart = 0;
  int _nightCount = 0, _nightFp = kNightFingerprintSeed;

  /// A part from a checkpoint as its encoded text (UTF-8 JSON of
  /// [NightResumePart.toJson]), adopted by the next [nightRr] call if its slice
  /// proves to extend it (else dropped). The UI isolate only moves these bytes;
  /// the worker that runs [nightRr] decodes them.
  Uint8List? _pendingNightJson;

  /// The night's state as of the last pass, already encoded by the worker that
  /// ran it ([exportNightJsonHeavy]); what the checkpoint embeds. Null when no
  /// beats are folded. Replaced by every pass that is given this state.
  Uint8List? exportedNightJson;

  /// Final output of the folded beats, in order. The corrector hands each part
  /// out once, so it is kept here.
  final List<double> _nightNn = [], _nightNnTimes = [];
  int _nightProcessed = 0, _nightRebuilds = 0;

  /// Beats pushed through a corrector so far (a rebuild counts its whole slice).
  int get processedNightBeats => _nightProcessed;

  /// Times a corrector was started from scratch, the first included.
  int get nightRebuilds => _nightRebuilds;

  /// (first beat time, count, fingerprint) of the beats folded; null when none.
  NightFoldTag? get nightFoldTag => _nightCount == 0
      ? null
      : (startTsMs: _nightStart, count: _nightCount, fingerprint: _nightFp);

  /// Input beats kept as copies for the extension check: none. The one
  /// (count, fingerprint) rule serves the RAM and the restored path.
  int get nightRetainedInputBeats => 0;

  /// The night's state for the checkpoint, deep-copied; null when no beats are
  /// folded. The public name is pinned by the checkpoint tests.
  @heavy
  NightResumePart? exportNight() {
    final corrector = _nightCorrector;
    final tag = nightFoldTag;
    if (corrector == null || tag == null) return null;
    final live = _hrvStream != null &&
        _respStream != null &&
        _spectralGen == _nightRebuilds;
    return NightResumePart.captureHeavy(
      tag: tag,
      corrector: corrector,
      nn: _nightNn,
      nnTimesMs: _nightNnTimes,
      hrv: live ? _hrvStream : null,
      resp: live ? _respStream : null,
      spectralFed: _spectralFed,
      cvhr: _cvhrStream != null && _cvhrGen == _nightRebuilds ? _cvhrStream : null,
      cvhrFed: _cvhrFed,
      respBins: _bins != null && _binsGen == _nightRebuilds ? _bins : null,
      respBinsFed: _binsFed,
      prsa: _prsa != null && _prsaGen == _nightRebuilds ? _prsa : null,
      prsaFed: _prsaFed,
    );
  }

  /// [exportNight] as the encoded text the checkpoint stores, built in the
  /// worker so the UI isolate never serialises the night.
  @heavy
  Uint8List? exportNightJsonHeavy() {
    final part = exportNight();
    return part == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(part.toJson())));
  }

  /// Arms the encoded part (null clears); the next [nightRr] call adopts it
  /// only when its slice starts at the part's first beat, holds at least its
  /// count of beats and those hash to its fingerprint. An adopted part is
  /// neither a rebuild nor a spectral restart. Nothing is parsed here: damage
  /// shows up at adoption and the night is rebuilt.
  void seedNightJson(Uint8List? json) => _pendingNightJson = json;

  /// [seedNightJson] for a part held as an object (tests). Production never has
  /// one on the UI isolate.
  @visibleForTesting
  void seedNight(NightResumePart? part) => seedNightJson(part == null
      ? null
      : Uint8List.fromList(utf8.encode(jsonEncode(part.toJson()))));

  void _resetNight() {
    _nightCorrector = null;
    _nightStart = 0;
    _nightCount = 0;
    _nightFp = kNightFingerprintSeed;
    _nightNn.clear();
    _nightNnTimes.clear();
    _tailNn = const [];
    _tailNnTimes = const [];
    _hrvStream = null;
    _respStream = null;
    _spectralFed = 0;
    _cvhrStream = null;
    _cvhrFed = 0;
    _bins = null;
    _binsFed = 0;
    _prsa = null;
    _prsaFed = 0;
  }

  /// Takes over the encoded [json] as this (empty) state's fold. False leaves
  /// it empty: the bytes are damaged, or the slice does not extend them.
  @heavy
  bool _adoptHeavy(Uint8List json, List<double> rrMs, List<double> rrTsMs) {
    final NightResumePart part;
    try {
      part = NightResumePart.fromJson(
          (jsonDecode(utf8.decode(json)) as Map).cast<String, dynamic>());
    } catch (_) {
      return false; // damaged: the night rebuilds, never wrong output
    }
    final tag = part.tag;
    final n = rrMs.length;
    if (tag.count == 0 ||
        n < tag.count ||
        rrTsMs.length != n ||
        rrTsMs[0] != tag.startTsMs ||
        nightBeatsFingerprint(rrMs, rrTsMs, tag.count) != tag.fingerprint) {
      return false;
    }
    try {
      final corrector = part.buildCorrectorHeavy();
      // The tag must describe what the corrector folded.
      if (rrCheckpointBeatCount(corrector.toJson()) != tag.count) {
        throw const FormatException('night part: tag disagrees with corrector');
      }
      final hrv = part.buildHrvHeavy(), resp = part.buildRespHeavy();
      final cvhr = part.buildCvhrHeavy();
      final bins = part.buildRespBinsHeavy(), prsa = part.buildPrsaHeavy();
      _nightCorrector = corrector;
      _nightStart = tag.startTsMs;
      _nightCount = tag.count;
      _nightFp = tag.fingerprint;
      _nightNn.addAll(part.nn);
      _nightNnTimes.addAll(part.nnTimesMs);
      _hrvStream = hrv;
      _respStream = resp;
      _spectralFed = part.spectralFed;
      // The streams belong to this generation, so they continue.
      _spectralGen = _nightRebuilds;
      _cvhrStream = cvhr;
      _cvhrFed = part.cvhrFed;
      _cvhrGen = _nightRebuilds;
      _bins = bins;
      _binsFed = part.respBinsFed;
      _binsGen = _nightRebuilds;
      _prsa = prsa;
      _prsaFed = part.prsaFed;
      _prsaGen = _nightRebuilds;
      return true;
    } on FormatException {
      _resetNight();
      return false;
    }
  }

  /// The corrected night for this slice: `correctRr(rrMs, rrTsMs: rrTsMs)`, bit
  /// for bit, folding only the beats past those already folded. A slice that
  /// does not extend them (moved start, any earlier beat or timestamp changed,
  /// shorter, empty) starts over.
  ///
  /// Cost: proving the extension hashes the folded beats again, O(folded) of
  /// integer work per call (the correction itself stays O(new)). A prefix cannot
  /// be proven unchanged without reading it.
  @heavy
  NightRr nightRr(List<double> rrMs, List<double> rrTsMs) {
    _batchNight = null;
    NightRr batch() => _batchNight = nightRrBatch(rrMs, rrTsMs);

    final n = rrMs.length;
    final pending = _pendingNightJson;
    _pendingNightJson = null;
    if (pending != null && _nightCorrector == null && n > 0) {
      _adoptHeavy(pending, rrMs, rrTsMs);
    }
    var held = _nightCount;
    var extends_ = n >= held && rrTsMs.length == n;
    if (extends_ && held > 0) {
      extends_ = rrTsMs[0] == _nightStart &&
          _countProof() &&
          nightBeatsFingerprint(rrMs, rrTsMs, held) == _nightFp;
    }
    if (!extends_) {
      // A non-empty slice counts below, as the fresh corrector it gets.
      if (n == 0 && _nightCorrector != null) _nightRebuilds++;
      _resetNight();
      held = 0;
    }
    if (n == 0 || rrTsMs.length != n) return batch();
    final fresh = _nightCorrector == null;
    final corrector = _nightCorrector ??= RrCorrector();
    if (fresh) _nightRebuilds++;
    if (n > held) {
      final addRr = held == 0 ? rrMs : rrMs.sublist(held);
      final addTs = held == 0 ? rrTsMs : rrTsMs.sublist(held);
      final RrSettled settled;
      try {
        settled = corrector.fold(addRr, tsMs: addTs);
      } on ArgumentError {
        // A non-finite beat: the corrector refuses it before changing anything,
        // but this state no longer matches it. Let the batch path decide.
        _resetNight();
        return batch();
      }
      _nightProcessed += addRr.length;
      if (held == 0) _nightStart = rrTsMs[0];
      _nightFp = nightBeatsFingerprintFrom(_nightFp, rrMs, rrTsMs, held, n);
      _nightCount = n;
      _nightNn.addAll(settled.nn);
      _nightNnTimes.addAll(settled.nnTimes);
    }
    final snap = corrector.snapshot();
    _tailNn = snap.tailNn;
    _tailNnTimes = snap.tailNnTimes;
    return (
      nn: [..._nightNn, ...snap.tailNn],
      nnTimesMs: [..._nightNnTimes, ...snap.tailNnTimes],
      cleanFraction: snap.cleanFraction,
      droppedCount: snap.droppedCount,
      correctedCount: snap.correctedCount,
    );
  }

  bool _countProof() {
    _prefixProofs++;
    return true;
  }

  /// The last [nightRr] result when it came from the batch path (the night was
  /// reset, so every stream is empty); null when it came from the fold. The
  /// night getters then answer with their batch functions over it, so a pass
  /// is never scored on beats the streams do not hold. RAM-only.
  NightRr? _batchNight;

  // ── Night spectral metrics, streamed ───────────────────────────────────────
  // An HrvFreqStream and an RsaRespStream fed only the corrector's settled
  // beats; each ask snapshots them with the provisional tail of the last
  // nightRr call. Restarted (lazily) whenever nightRr rebuilds. RAM-only.
  List<double> _tailNn = const [], _tailNnTimes = const [];
  HrvFreqStream? _hrvStream;
  RsaRespStream? _respStream;
  int _spectralFed = 0, _spectralFolded = 0, _spectralRestarts = 0;
  int _spectralGen = -1;

  /// Settled beats folded into the spectral streams (a restart counts again).
  int get nightSpectralFolded => _spectralFolded;

  /// Times the spectral streams were started from scratch, the first included.
  int get nightSpectralRestarts => _spectralRestarts;

  @heavy
  void _syncSpectralHeavy() {
    if (_hrvStream == null || _respStream == null || _spectralGen != _nightRebuilds) {
      _hrvStream = HrvFreqStream();
      _respStream = RsaRespStream();
      _spectralFed = 0;
      _spectralGen = _nightRebuilds;
      _spectralRestarts++;
    }
    if (_spectralFed < _nightNn.length) {
      final nn = _nightNn.sublist(_spectralFed);
      final ts = _nightNnTimes.sublist(_spectralFed);
      _hrvStream!.fold(nn, ts);
      _respStream!.fold(nn, ts);
      _spectralFolded += nn.length;
      _spectralFed = _nightNn.length;
    }
  }

  /// `hrvFreq` of the last [nightRr] slice, bit for bit, without re-running
  /// Welch over the settled beats.
  @heavy
  Metric<HrvFreq> nightHrvFreq(double artifactFraction) {
    final b = _batchNight;
    if (b != null) {
      return hrvFreq(b.nn, b.nnTimesMs, artifactFraction: artifactFraction);
    }
    _syncSpectralHeavy();
    return _hrvStream!.snapshot(
      tailNnMs: _tailNn,
      tailNnTimesMs: _tailNnTimes,
      artifactFraction: artifactFraction,
    );
  }

  /// `rsaRespRate` of the last [nightRr] slice, bit for bit.
  @heavy
  Metric<RespEstimate> nightResp(double artifactFraction) {
    final b = _batchNight;
    if (b != null) {
      return rsaRespRate(b.nn, b.nnTimesMs, artifactFraction: artifactFraction);
    }
    _syncSpectralHeavy();
    return _respStream!.snapshot(
      tailNnMs: _tailNn,
      tailNnTimesMs: _tailNnTimes,
      artifactFraction: artifactFraction,
    );
  }

  // ── Night CVHR, streamed ───────────────────────────────────────────────────
  // A CvhrStream fed the same settled beats, with its own feed count (it is
  // asked only on nights past the 60-beat gate). Restarted when nightRr
  // rebuilds; rides the night part of the checkpoint.
  CvhrStream? _cvhrStream;
  int _cvhrFed = 0, _cvhrFolded = 0, _cvhrRestarts = 0;
  int _cvhrGen = -1;

  /// Settled beats folded into the CVHR stream (a restart counts again).
  int get nightCvhrFolded => _cvhrFolded;

  /// Times the CVHR stream was started from scratch, the first included.
  int get nightCvhrRestarts => _cvhrRestarts;

  /// `cvhrApneaScreen` of the last [nightRr] slice, bit for bit, without
  /// re-scoring the settled beats.
  @heavy
  Metric<CvhrResult> nightCvhr(double artifactFraction) {
    final b = _batchNight;
    if (b != null) {
      return cvhrApneaScreen(b.nn, b.nnTimesMs,
          artifactFraction: artifactFraction);
    }
    if (_cvhrStream == null || _cvhrGen != _nightRebuilds) {
      _cvhrStream = CvhrStream();
      _cvhrFed = 0;
      _cvhrGen = _nightRebuilds;
      _cvhrRestarts++;
    }
    if (_cvhrFed < _nightNn.length) {
      final nn = _nightNn.sublist(_cvhrFed);
      _cvhrStream!.fold(nn, _nightNnTimes.sublist(_cvhrFed));
      _cvhrFolded += nn.length;
      _cvhrFed = _nightNn.length;
    }
    return _cvhrStream!.snapshot(
      tailNnMs: _tailNn,
      tailNnTimesMs: _tailNnTimes,
      artifactFraction: artifactFraction,
    );
  }

  // ── Night 30-min RSA bins and PRSA, streamed ──────────────────────────────
  // Same rules as CVHR: fed only settled beats (own feed counts), restarted
  // when nightRr rebuilds, ride the night part of the checkpoint. DC and AC
  // share one feed count.
  NightRespBins? _bins;
  int _binsFed = 0, _binsFolded = 0, _binsRestarts = 0;
  int _binsGen = -1;
  NightPrsa? _prsa;
  int _prsaFed = 0, _prsaFolded = 0, _prsaRestarts = 0;
  int _prsaGen = -1;

  /// Settled beats folded into the RSA bins (a restart counts again).
  int get nightBinsFolded => _binsFolded;

  /// Times the RSA bins were started from scratch, the first included.
  int get nightBinsRestarts => _binsRestarts;

  /// Settled beats folded into the PRSA sums (a restart counts again).
  int get nightPrsaFolded => _prsaFolded;

  /// Times the PRSA sums were started from scratch, the first included.
  int get nightPrsaRestarts => _prsaRestarts;

  /// [respPerWindowHeavy] of the last [nightRr] slice, bit for bit, scoring
  /// each closed 30-min bin once.
  @heavy
  List<double> nightRespWindows() {
    final b = _batchNight;
    if (b != null) return respPerWindowHeavy(b.nn, b.nnTimesMs);
    if (_bins == null || _binsGen != _nightRebuilds) {
      _bins = NightRespBins();
      _binsFed = 0;
      _binsGen = _nightRebuilds;
      _binsRestarts++;
    }
    if (_binsFed < _nightNn.length) {
      final nn = _nightNn.sublist(_binsFed);
      _bins!.foldHeavy(nn, _nightNnTimes.sublist(_binsFed));
      _binsFolded += nn.length;
      _binsFed = _nightNn.length;
    }
    return _bins!.snapshotHeavy(_tailNn, _tailNnTimes);
  }

  @heavy
  NightPrsa _syncPrsaHeavy() {
    if (_prsa == null || _prsaGen != _nightRebuilds) {
      _prsa = NightPrsa.emptyHeavy();
      _prsaFed = 0;
      _prsaGen = _nightRebuilds;
      _prsaRestarts++;
    }
    if (_prsaFed < _nightNn.length) {
      final nn = _nightNn.sublist(_prsaFed);
      _prsa!.foldHeavy(nn);
      _prsaFolded += nn.length;
      _prsaFed = _nightNn.length;
    }
    return _prsa!;
  }

  /// `decelerationCapacity` of the last [nightRr] slice, bit for bit.
  @heavy
  Metric<PrsaResult> nightPrsaDc() {
    final b = _batchNight;
    if (b != null) return decelerationCapacity(b.nn);
    return _syncPrsaHeavy().dcHeavy(_tailNn);
  }

  /// `accelerationCapacity` of the last [nightRr] slice, bit for bit.
  @heavy
  Metric<PrsaResult> nightPrsaAc() {
    final b = _batchNight;
    if (b != null) return accelerationCapacity(b.nn);
    return _syncPrsaHeavy().acHeavy(_tailNn);
  }

  /// Per-key reuse and cost, collected only when [debugStats] is set (for the
  /// cache benchmark). Keys of per-window entries are collapsed to their prefix.
  Map<String, ({int hits, int misses, int micros})>? debugStats;

  /// Digests of the long lists named by this pass's memo dependencies, by list
  /// identity: each is walked once however many memos read it. Cleared by
  /// [beginPass]; a state used without it digests per call, as before.
  final ListDigestCache _digests = ListDigestCache();
  int _prefixProofs = 0;

  /// Full-list digests computed, plus night-prefix proofs hashed (work counter).
  int get nightListHashes => _digests.computed + _prefixProofs;

  /// Starts a derive pass: lists may have changed since the last one.
  void beginPass() => _digests.clear();

  /// Ends a derive pass: drops the digests so a state kept between passes (the
  /// engine keeps up to three days) does not hold their sample lists alive.
  void endPass() => _digests.clear();

  T evaluate<T>(
    String key,
    Object? dependencies,
    T Function() calculate,
    CalculationMode mode,
  ) {
    final stats = debugStats;
    if (stats == null) {
      return _cache.evaluate(
        key,
        dependencyFingerprint(dependencies, cache: _digests),
        calculate,
        full: mode != CalculationMode.periodicAwake,
      );
    }
    final before = _cache.hits;
    final watch = Stopwatch()..start();
    final result = _cache.evaluate(
      key,
      dependencyFingerprint(dependencies, cache: _digests),
      calculate,
      full: mode != CalculationMode.periodicAwake,
    );
    final name = key.replaceFirst(RegExp(r'_-?[\d.]+$'), '_*');
    final hit = _cache.hits > before;
    final old = stats[name] ?? (hits: 0, misses: 0, micros: 0);
    stats[name] = (
      hits: old.hits + (hit ? 1 : 0),
      misses: old.misses + (hit ? 0 : 1),
      micros: old.micros + watch.elapsedMicroseconds,
    );
    return result;
  }

  MinuteMetrics minutes(
    List<int> keys,
    List<double> hr, {
    List<double?>? cadence,
    double? restingHr,
    double? maxHr,
    required Sex sex,
    WorkoutUserProfile? profile,
    int dayMinutes = 1440,
    required CalculationMode mode,
  }) => _minutes.sync(
    keys,
    hr,
    cadenceSpm: cadence,
    restingHr: restingHr,
    maxHr: maxHr,
    sex: sex,
    profile: profile,
    dayMinutes: dayMinutes,
    quietHrr: quietWakingHrr,
    // A state read back from storage trusts the minutes it holds only as far as
    // the sync can prove them (it compares every minute's HR and cadence and
    // the anchors), so it never reprices what has not changed.
    force: _forceSummaries(mode),
    includeMinuteSeries: false,
  );

  /// Times [calculate] under [name] in [debugStats], when collecting.
  T timed<T>(String name, T Function() calculate) {
    final stats = debugStats;
    if (stats == null) return calculate();
    final watch = Stopwatch()..start();
    final result = calculate();
    final old = stats[name] ?? (hits: 0, misses: 0, micros: 0);
    stats[name] = (
      hits: old.hits,
      misses: old.misses + 1,
      micros: old.micros + watch.elapsedMicroseconds,
    );
    return result;
  }

  /// The day's heart-rate summary for [slot], brought up to date with
  /// [ts]/[hr].
  DayHrSummary hrSummary(
    String slot,
    List<int> ts,
    List<int> hr, {
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required int? age,
    required CalculationMode mode,
  }) => timed('hr_summary_$slot', () {
    final summary = _hr[slot] ??= DayHrSummary();
    summary.sync(
      ts,
      hr,
      sleepOnsetSec: sleepOnsetSec,
      sleepOffsetSec: sleepOffsetSec,
      age: age,
      force: _forceSummaries(mode),
    );
    return summary;
  });

  /// The day's orientation/presence summary, brought up to date.
  DayMotionSummary motionSummary(
    List<int> ts,
    List<double> ax,
    List<double> ay,
    List<double> az, {
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required CalculationMode mode,
  }) => timed('motion_summary', () {
    _motion.sync(
      ts,
      ax,
      ay,
      az,
      sleepOnsetSec: sleepOnsetSec,
      sleepOffsetSec: sleepOffsetSec,
      force: _forceSummaries(mode),
    );
    return _motion;
  });

  /// Per-minute motion over the whole calendar day from the folded per-minute
  /// buckets ([DayDynMinutes]): the day's seconds are folded in once and only
  /// new ones afterwards, in any mode, with no `AccelSample` copy of the day.
  /// Every field the app reads is the batch value (`enmoSeries`); `enmo`, `mad`
  /// and `meanMag` are NaN, not computed.
  List<MotionMinute> dynMinutes(
    List<int> ts,
    List<int> hr,
    List<double> ax,
    List<double> ay,
    List<double> az,
    CalculationMode mode,
  ) => timed('motion_minutes', () {
    _dyn.sync(ts, hr, ax, ay, az, force: _forceSummaries(mode));
    return _dyn.minutes();
  });

  /// The strap's own credited steps for the day (see [StepCounterFold]); null
  /// when the strap has no counter. Same figure `hardwareStepsFromCounter`
  /// gives over the same seconds.
  int? bandSteps(
    List<int> ts,
    List<int> counter, {
    required int? modulus,
    required CalculationMode mode,
  }) => timed('step_fold', () {
    _steps.sync(ts, counter, modulus: modulus, force: _forceSummaries(mode));
    return _steps.steps;
  });

  /// Per-minute motion over the whole calendar day (`expectedMinutes` 1440).
  ///
  /// A full mode calibrates the gravity reference exactly as
  /// `enmoSeries(samples)` does, so its result is the batch result. A periodic
  /// awake pass keeps the last full pass's reference and appends: every field
  /// except [MotionMinute.enmo] is still the batch value (they do not depend on
  /// the reference), and `enmo` is the batch value at that reference. Nothing
  /// in the app reads `enmo`. With no earlier full pass, awake runs as full.
  List<MotionMinute> motionMinutes(
    List<AccelSample> samples,
    CalculationMode mode,
  ) => timed('motion_minutes', () {
    final full = mode != CalculationMode.periodicAwake || _gRef == null;
    var g = _gRef;
    if (full) {
      final valid = samples.where((s) => s.valid).toList()
        ..sort((a, b) => a.tsMs.compareTo(b.tsMs));
      if (valid.isEmpty) return const <MotionMinute>[];
      g = calibrateGRef([
        for (final s in valid) math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z),
      ]);
      _gRef = g;
    }
    final result =
        _enmo.sync(samples, gRef: g, expectedMinutes: 1440, force: full);
    _enmoHeld = samples.where((s) => s.valid).length;
    return result.minutes;
  });
}
