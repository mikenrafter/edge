// Measurement of one derive pass: how long the job waited, why, and where the
// time went per day. Pure Dart (no Flutter, no I/O) with an injected clock so
// the numbers are testable. Nothing here changes a metric; it only reports.

/// The three phases of one day's derivation.
enum DerivePhase { prepare, compute, persist }

/// Records one pass. The scheduler calls [enqueued] / [noteHolds] /
/// [noteSettle] while the job waits; the engine calls [startPass],
/// [addPhase] and [endPass].
class DerivePerf {
  /// [enabled] false makes every recording call a no-op (design 02 step 2,
  /// P2.0a: measuring must cost nothing when nobody reads it). RED STUB: the
  /// flag is stored and not yet honoured.
  DerivePerf({required int Function() nowMs, this.enabled = true})
      : _now = nowMs;

  final bool enabled;
  final int Function() _now;

  // What is known about the NEXT pass (queued, not yet started).
  int? _enqueuedAt;
  final List<String> _pendingHolds = [];

  // The pass that has started (running or finished).
  bool _started = false;
  int? _queueWaitMs;
  List<String> _holds = const [];
  int _startedAt = 0;
  int? _passMs;
  final Map<String, Map<DerivePhase, int>> _days = {};
  // Finer than the three phases: where inside a phase the time and the rows
  // went. Summed over every day of the pass (so with concurrent days a stage's
  // total can exceed the pass's wall time).
  final Map<String, int> _stages = {};
  final Map<String, int> _counts = {};

  /// The scheduler queued a job. The first call before a pass starts wins, so
  /// a second stored-data tick does not reset the wait.
  void enqueued() => _enqueuedAt ??= _now();

  /// Read the hold reasons off a `DeriveScheduler.snapshot()`.
  void noteHolds(Map<String, dynamic> schedulerSnapshot) {
    final s = schedulerSnapshot;
    if (s['offload_active'] == true) _hold('offload');
    if (s['manual_sync_hold'] == true) _hold('manual_sync_hold');
    if (s['workout_active'] == true && s['workout_hold_expired'] != true) {
      _hold('workout');
    }
    if (s['background'] == true) _hold('background');
  }

  /// The settle timer was armed: the job waits out a quiet window.
  void noteSettle() => _hold('settle');

  void _hold(String reason) {
    if (!_pendingHolds.contains(reason)) _pendingHolds.add(reason);
  }

  /// A pass begins: close the queue wait and start collecting phases.
  void startPass() {
    final at = _now();
    _started = true;
    _queueWaitMs = _enqueuedAt == null ? null : at - _enqueuedAt!;
    _holds = List.of(_pendingHolds);
    _enqueuedAt = null;
    _pendingHolds.clear();
    _startedAt = at;
    _passMs = null;
    _days.clear();
    _stages.clear();
    _counts.clear();
  }

  /// Accumulates per (day, phase): the same pair reported twice adds up.
  void addPhase(String day, DerivePhase phase, int ms) {
    final byPhase = _days.putIfAbsent(day, () => {});
    byPhase[phase] = (byPhase[phase] ?? 0) + ms;
  }

  /// Adds [ms] to the named stage of this pass.
  void addStage(String name, int ms) =>
      _stages[name] = (_stages[name] ?? 0) + ms;

  /// Adds [n] to a named counter of this pass (rows read, beats, bytes).
  void addCount(String name, int n) =>
      _counts[name] = (_counts[name] ?? 0) + n;

  /// Like [addCount], but [value] runs only when this instance is [enabled]:
  /// the way to book a count that is itself costly to measure (a node walk, a
  /// byte sum). RED STUB: does nothing.
  void addCountLazy(String name, int Function() value) {}

  /// Runs [body] and books its wall time to [name], also when it throws.
  Future<T> stage<T>(String name, Future<T> Function() body) async {
    final at = _now();
    try {
      return await body();
    } finally {
      addStage(name, _now() - at);
    }
  }

  void endPass() => _passMs = _now() - _startedAt;

  int _total(DerivePhase p) =>
      _days.values.fold(0, (a, d) => a + (d[p] ?? 0));
  int _max(DerivePhase p) => _days.values
      .fold(0, (a, d) => (d[p] ?? 0) > a ? (d[p] ?? 0) : a);

  Map<String, Object?> summary() => {
        'queue_wait_ms': _started ? _queueWaitMs : null,
        'holds': List<String>.of(_started ? _holds : _pendingHolds),
        'days': _days.length,
        'prepare_ms': _total(DerivePhase.prepare),
        'compute_ms': _total(DerivePhase.compute),
        'persist_ms': _total(DerivePhase.persist),
        'prepare_max_ms': _max(DerivePhase.prepare),
        'compute_max_ms': _max(DerivePhase.compute),
        'persist_max_ms': _max(DerivePhase.persist),
        'pass_ms': _passMs,
        'stages': Map<String, int>.of(_stages),
        'counts': Map<String, int>.of(_counts),
      };

  /// One `[perf] derive …` line carrying the numbers.
  String logLine() {
    final s = summary();
    final holds = (s['holds'] as List).join(',');
    return '[perf] derive wait=${s['queue_wait_ms'] ?? '-'}ms '
        'holds=${holds.isEmpty ? '-' : holds} days=${s['days']} '
        'prepare=${s['prepare_ms']}ms(max ${s['prepare_max_ms']}) '
        'compute=${s['compute_ms']}ms(max ${s['compute_max_ms']}) '
        'persist=${s['persist_ms']}ms(max ${s['persist_max_ms']}) '
        'pass=${s['pass_ms'] ?? '-'}ms'
        '${_kv(_stages, 'stages', 'ms')}${_kv(_counts, 'counts', '')}';
  }

  static String _kv(Map<String, int> m, String label, String unit) => m.isEmpty
      ? ''
      : ' $label=${m.entries.map((e) => '${e.key}:${e.value}$unit').join(',')}';

  /// One `[perf] mem …` log line: the process's resident size next to what the
  /// derivation engine retains between passes, so a device log shows whether
  /// background passes grow or shrink the footprint.
  static String memLine({
    required int rssBytes,
    required int states,
    required int retainedSamples,
    required int cacheComputations,
    required int cacheHits,
  }) =>
      'rss=${(rssBytes / (1024 * 1024)).toStringAsFixed(1)}MB '
      'dayStates=$states retainedSamples=$retainedSamples '
      'cacheComputed=$cacheComputations cacheHits=$cacheHits';

  /// The Settings > Developer "Last calculation" text. Only what was
  /// measured; nothing measured is an em dash, never a zero.
  static String describe(Map<String, Object?>? summary) {
    final s = summary;
    if (s == null) return '—';
    final parts = <String>[];
    final wait = (s['queue_wait_ms'] as num?)?.toInt();
    if (wait != null) {
      final holds = (s['holds'] as List?)?.cast<String>() ?? const <String>[];
      parts.add('Waited ${_span(wait)}'
          '${holds.isEmpty ? '' : ' (${holds.join(', ')})'}');
    }
    final days = (s['days'] as num?)?.toInt() ?? 0;
    if (days > 0) parts.add('$days ${days == 1 ? 'day' : 'days'}');
    final total = (s['pass_ms'] as num?)?.toInt();
    if (total != null) parts.add('${_span(total)} total');
    return parts.isEmpty ? '—' : parts.join(', ');
  }

  static String _span(int ms) => ms < 1000 ? '$ms ms' : '${ms ~/ 1000} s';
}

/// "First usable render": the time from a revision bump to the first commit
/// that consumed it.
class RenderLatency {
  RenderLatency({required int Function() nowMs}) : _now = nowMs;

  final int Function() _now;
  int? _bumpedAt;

  /// The earliest unconsumed bump is the one timed.
  void revisionBumped() => _bumpedAt ??= _now();

  /// Milliseconds since that bump, then cleared; null when none is pending.
  int? committed() {
    final at = _bumpedAt;
    if (at == null) return null;
    _bumpedAt = null;
    return _now() - at;
  }
}

/// The perf instance of reads that happen outside a derive pass (the repository
/// read seam, `LastResultCache`). Null = disabled: the readers record nothing
/// and measure nothing. Tests and a diagnostics switch set it; production
/// leaves it null until the owner's device trace needs it (design 02 step 2,
/// P2.0a). RED STUB: nothing reads it yet.
abstract final class ReadPerf {
  static DerivePerf? sink;
}

/// Number of values in a decoded JSON graph: every map, every list and every
/// scalar (including null) counts once; map keys do not. The root counts.
/// `{'a': [1, 2], 'b': null}` is 5. RED STUB: returns 0.
int payloadNodeCount(Object? decoded) => 0;

/// Estimated bytes the rows carry as sqflite hands them over: a `num` is 8, a
/// `String` its UTF-8 length, a `Uint8List` its length, null and anything else
/// 0; map keys are not counted. RED STUB: returns 0.
int rowsByteEstimate(Iterable<Map<String, Object?>> rows) => 0;
