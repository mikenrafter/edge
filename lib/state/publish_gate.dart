// publish_gate.dart — P2.3 (design 02, step 2, section 4.5).
import 'dart:async';

import 'package:clock/clock.dart';

import '../data/db.dart';
import '../data/bundle_store.dart';
import '../data/json_payload_lane.dart';
import '../compute/derivation_engine.dart' show kAlgoVersion;

abstract interface class PublishGateSteps {
  Future<void> refreshFreshness();
  Future<Map<String, int>> servedRevisions();
  Future<void> warm(Set<String> sources);
  void bump();
  void log(String line);
}

abstract interface class PublishGateEffects {
  void publishBump();
  void publishLog(String line);
}

final class LocalPublishGateSteps implements PublishGateSteps {
  LocalPublishGateSteps({required BundleStore store, required PublishGateEffects effects})
      : _store = store,
        _effects = effects;

  final BundleStore _store;
  final PublishGateEffects _effects;

  @override
  Future<void> refreshFreshness() => LocalDb.refreshComputeFreshness();

  Future<HomeWarmSet> _homeSet() =>
      HomeWarmSet.resolve(today: LocalDb.localDayLabelNow());

  @override
  Future<Map<String, int>> servedRevisions() async {
    final set = await _homeSet();
    final out = <String, int>{};
    for (final source in set.bundles) {
      final rev = await _store.sourceRevision(source);
      if (rev != null) out['${source.kind}|${source.k1}'] = rev;
    }
    return out;
  }

  @override
  Future<void> warm(Set<String> ids) async {
    final set = await _homeSet();
    final sources = [
      for (final source in set.bundles)
        if (ids.contains('${source.kind}|${source.k1}')) source,
    ];
    await _store.warm(sources);
    final jsonRows = <({String key, int? revision, Object? text})>[];
    final rows = await LocalDb.sleepWindowRows(14);
    jsonRows.addAll([
      for (final row in rows) (
        key: 'window|${row['day_id']}',
        revision: (row['rev'] as num?)?.toInt(),
        text: row['window_json'],
      ),
    ]);
    if (set.wakeDay != null) {
      final row = await LocalDb.wakeDayFeatures(set.wakeDay!, kAlgoVersion);
      if (row != null) {
        jsonRows.add((
          key: 'wake|${set.wakeDay}|${row['algo_version']}',
          revision: (row['rev'] as num?)?.toInt(),
          text: row['payload_json'],
        ));
      }
    }
    await JsonPayloadLane.shared.warm(jsonRows);
  }

  @override
  void bump() => _effects.publishBump();

  @override
  void log(String line) => _effects.publishLog(line);
}

/// The serialised publish loop: (1) the freshness refresh (durable write),
/// (2) a best-effort warm, (3) the revision bump.
class PublishGate {
  PublishGate({
    required PublishGateSteps steps,
    Duration warmBudget = const Duration(seconds: 2),
    Duration retryDelay = const Duration(seconds: 1),
  }) : _steps = steps,
       _warmBudget = warmBudget,
       _retryDelay = retryDelay;

  final PublishGateSteps _steps;
  final Duration _warmBudget;
  final Duration _retryDelay;

  /// A sequence whose freshness refresh failed is retried this many times (the
  /// bump still happens on every attempt) and then given up: the next request
  /// starts afresh, but nothing loops on its own.
  static const int _maxRetries = 1;
  int _retries = 0;
  Timer? _retryTimer;
  Completer<void>? _retryWake;
  int _sequence = 0;
  int _runs = 0;
  bool _disposed = false;
  Future<void>? _running;

  Future<void> get idle async {
    while (true) {
      final run = _running;
      if (run == null) return;
      await run;
    }
  }

  int get debugRuns => _runs;

  void request() {
    if (_disposed) return;
    _sequence++;
    _wakeRetry(); // a new request is itself the retry
    _ensureRunning();
  }

  /// Request a publish and wait for it. A run already in flight finishes
  /// first, so this caller always gets a run (and a bump) of its own that
  /// starts after the call: the end-of-pass and import publishes are never
  /// absorbed by a per-day run that began earlier.
  Future<void> publishAndWait() async {
    await idle;
    request();
    await idle;
  }

  void dispose() {
    _disposed = true;
    _wakeRetry();
  }

  Future<void> _sleepBeforeRetry() {
    final wake = _retryWake = Completer<void>();
    _retryTimer = Timer(_retryDelay, _wakeRetry);
    return wake.future;
  }

  void _wakeRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final wake = _retryWake;
    _retryWake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _ensureRunning() {
    if (_disposed || _running != null) return;
    final run = _drain();
    _running = run;
    unawaited(run.whenComplete(() {
      if (identical(_running, run)) _running = null;
      if (!_disposed && _sequence > _completedSequence) _ensureRunning();
    }));
  }

  int _completedSequence = 0;

  Future<void> _drain() async {
    while (!_disposed && _completedSequence < _sequence) {
      // Only the sequence captured BEFORE a refresh is acknowledged by the bump
      // that follows it: a request that arrives later (during the second
      // refresh, the warm or the revalidation warm) is newer than the freshness
      // that run wrote, and gets a trailing run of its own.
      var captured = _sequence;
      _runs++;
      // Whether the LAST refresh of this run wrote: a failed one leaves the
      // freshness older than `captured`, and the sequence must not be
      // acknowledged on its behalf.
      var refreshed = await _refresh();
      if (_disposed) return;
      if (_sequence != captured) {
        // A commit landed during the refresh: the freshness may predate it.
        captured = _sequence;
        refreshed = await _refresh();
        if (_disposed) return;
      }
      // Only a request made while the warm runs folds into this run; one that
      // arrived during the refreshes above is behind `captured` and gets the
      // trailing run.
      final warmStart = _sequence;
      Map<String, int> before = const {};
      try {
        before = await _steps.servedRevisions();
        await _warmSet(before.keys.toSet());
      } catch (e) {
        _steps.log('[publish] warm failed: $e');
      }
      if (_disposed) return;

      if (_sequence != warmStart) {
        // A commit landed during the warm: refresh again, then warm only the
        // sources whose revision changed.
        captured = _sequence;
        refreshed = await _refresh();
        if (_disposed) return;
        try {
          final after = await _steps.servedRevisions();
          final changed = <String>{
            for (final e in after.entries)
              if (before[e.key] != e.value) e.key,
          };
          if (changed.isNotEmpty) await _warmSet(changed);
        } catch (e) {
          _steps.log('[publish] revalidation warm failed: $e');
        }
      }
      if (_disposed) return;
      // A failed refresh still bumps (4.5: nothing may suppress the bump), but
      // the sequence stays pending and is retried once after a short delay;
      // when the retries are spent it is acknowledged so the loop ends.
      final retry = !refreshed && _retries < _maxRetries;
      if (!retry) {
        _completedSequence = captured;
        _retries = 0;
      }
      _steps.bump();
      // Anything requested after `captured` (including from the bump itself)
      // is still ahead of `_completedSequence`: the loop runs it next.
      if (retry) {
        _retries++;
        // A request made since `captured` (or by the bump) is the retry.
        if (_sequence == captured) await _sleepBeforeRetry();
        if (_disposed) return;
      }
    }
  }

  /// True when the freshness was written.
  Future<bool> _refresh() async {
    try {
      await _steps.refreshFreshness();
      return true;
    } catch (e) {
      _steps.log('[publish] freshness refresh failed: $e');
      return false;
    }
  }

  Future<void> _warmSet(Set<String> sources) async {
    try {
      await _steps.warm(sources).timeout(_warmBudget);
    } catch (e) {
      _steps.log('[publish] warm failed: $e');
    }
  }

  /// The standard wiring: [LocalDb.refreshComputeFreshness], the served
  /// revisions of [HomeWarmSet.resolve] and [store]`.warm`.
  factory PublishGate.standard({
    required BundleStore store,
    required PublishGateEffects effects,
    Duration warmBudget = const Duration(seconds: 2),
    Duration retryDelay = const Duration(seconds: 1),
  }) {
    return PublishGate(
      steps: LocalPublishGateSteps(store: store, effects: effects),
      warmBudget: warmBudget,
      retryDelay: retryDelay,
    );
  }

  /// A day committed or the durable data changed.
  // implemented above

  /// Completes when no loop is running and none is pending.
  // implemented above

  /// Loop runs started so far (test readout).
  // implemented above

  /// Nothing runs or bumps after this.
  // implemented above
}

/// What a publish warms: Home's real inputs (4.5).
final class HomeWarmSet {
  const HomeWarmSet({
    required this.bundles,
    required this.wakeDay,
    required this.windowDays,
  });

  /// Payload sources, in this order and without repeats: the today bundle, the
  /// latest-with-sleep (night) bundle, the `crossday` baseline.
  final List<BundleSource> bundles;

  /// The `wake_day_features` row's day, or null when none exists.
  final String? wakeDay;

  /// The days whose `window_json` back `sleepWindows(days: 14)`.
  final List<String> windowDays;

  /// Resolved from meta rows and the freshness row only: no payload is read.
  static Future<HomeWarmSet> resolve({required String today}) async {
    final overnight = await LocalDb.computeFreshnessStringField(
      'today',
      r'$.overnight_day',
    );
    final bundles = <BundleSource>[];
    if (await LocalDb.dayResultMeta(today) != null) {
      bundles.add(BundleSource.day(today));
    }
    // The freshness row's selected night is resolved by its own key: it may be
    // older than the newest rows (the freshness scan reads 30), and getToday
    // reads exactly that day.
    if (overnight != null &&
        overnight != today &&
        await LocalDb.dayResultMeta(overnight) != null) {
      bundles.add(BundleSource.day(overnight));
    }
    if (await LocalDb.baselineMeta('crossday') != null) {
      bundles.add(const BundleSource.baseline('crossday'));
    }
    final wake = await LocalDb.wakeDayFeaturesMeta(today);
    final windows = await LocalDb.sleepWindowRows(14);
    return HomeWarmSet(
      bundles: bundles,
      wakeDay: wake == null ? null : today,
      windowDays: [
        for (final row in windows)
          if (row['day_id'] is String) row['day_id'] as String,
      ],
    );
  }
}

/// The warm after the first frame (4.5): fire-and-forget, 3 s timeout, at most
/// 6 payloads and 1 MB of source, never in a headless or background process.
abstract interface class StartupWarmSteps {
  Future<WarmResult> warm(List<BundleSource> sources, int maxSourceBytes);
  Future<HomeWarmSet> resolve();
}

final class LocalStartupWarmSteps implements StartupWarmSteps {
  LocalStartupWarmSteps({required BundleStore store}) : _store = store;

  final BundleStore _store;

  @override
  Future<WarmResult> warm(List<BundleSource> sources, int maxSourceBytes) =>
      _store.warm(sources, maxSourceBytes: maxSourceBytes);

  @override
  Future<HomeWarmSet> resolve() =>
      HomeWarmSet.resolve(today: LocalDb.localDayLabelNow());
}

class StartupWarm {
  StartupWarm({
    required StartupWarmSteps steps,
    required bool headless,
    Duration timeout = const Duration(seconds: 3),
    int maxPayloads = 6,
    int maxSourceBytes = 1024 * 1024,
  }) : _steps = steps,
       _headless = headless,
       _timeout = timeout,
       _maxPayloads = maxPayloads,
       _maxSourceBytes = maxSourceBytes;

  final StartupWarmSteps _steps;
  final bool _headless;
  final Duration _timeout;
  final int _maxPayloads;
  final int _maxSourceBytes;

  /// The warm result, or null when skipped (headless, nothing to warm, timeout,
  /// failure). Never throws.
  Future<WarmResult?> run() async {
    if (_headless) return null;
    // One deadline for both stages: a slow resolution leaves the warm only
    // what remains of the 3 s, not a fresh 3 s of its own. `Future.timeout`
    // abandons the work but does not cancel it, so the continuation checks the
    // deadline itself (on a monotonic watch) before it starts the warm.
    final watch = clock.stopwatch()..start();
    try {
      return await _resolveAndWarm(watch).timeout(_timeout);
    } catch (_) {
      return null;
    }
  }

  Future<WarmResult?> _resolveAndWarm(Stopwatch watch) async {
    final set = await _steps.resolve();
    if (watch.elapsed >= _timeout) return null; // run() has already answered null
    final sources = set.bundles.take(_maxPayloads).toList();
    if (sources.isEmpty) return null;
    return _steps.warm(sources, _maxSourceBytes);
  }
}
