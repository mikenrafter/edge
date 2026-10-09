// publish_gate.dart — P2.3 (design 02, step 2, section 4.5).
import 'dart:async';

import '../data/db.dart';
import '../data/bundle_store.dart';

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
  }) : _steps = steps,
       _warmBudget = warmBudget;

  final PublishGateSteps _steps;
  final Duration _warmBudget;
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
    _ensureRunning();
  }

  Future<void> publishAndWait() async {
    request();
    await idle;
  }

  void dispose() => _disposed = true;

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
      var requestSequence = _sequence;
      _runs++;
      await _refresh();
      if (_disposed) return;
      var refreshedForMovement = false;
      if (_sequence != requestSequence) {
        await _refresh();
        if (_disposed) return;
        requestSequence = _sequence;
        refreshedForMovement = true;
      }
      Map<String, int> before = const {};
      try {
        before = await _steps.servedRevisions();
        await _warmSet(before.keys.toSet());
      } catch (e) {
        _steps.log('[publish] warm failed: $e');
      }
      if (_disposed) return;

      // A later commit may have landed while freshness or warming was in
      // flight. Refresh again before warming its changed sources and publish
      // one coherent revision for the combined commits.
      if (_sequence != requestSequence) {
        if (!refreshedForMovement) await _refresh();
        if (_disposed) return;
        requestSequence = _sequence;
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
      _completedSequence = _sequence;
      _steps.bump();
      // Requests raised by the bump get their own trailing refresh.
    }
  }

  Future<void> _refresh() async {
    try {
      await _steps.refreshFreshness();
    } catch (e) {
      _steps.log('[publish] freshness refresh failed: $e');
    }
  }

  Future<void> _warmSet(Set<String> sources) async {
    if (sources.isEmpty) return;
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
  }) {
    return PublishGate(
      steps: LocalPublishGateSteps(store: store, effects: effects),
      warmBudget: warmBudget,
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
    final metas = await LocalDb.recentDayResultMetas(14);
    final days = metas.map((r) => r['date']?.toString()).whereType<String>().toSet();
    final bundles = <BundleSource>[];
    if (days.contains(today)) bundles.add(BundleSource.day(today));
    if (overnight != null && days.contains(overnight) && overnight != today) {
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
    try {
      final set = await _steps.resolve().timeout(_timeout);
      final sources = set.bundles.take(_maxPayloads).toList();
      if (sources.isEmpty) return null;
      return await _steps.warm(sources, _maxSourceBytes).timeout(_timeout);
    } catch (_) {
      return null;
    }
  }
}
