// publish_gate.dart — P2.3 (design 02, step 2, section 4.5). RED STUBS: the
// tests in test/step2/p23_* pin this API; every member throws until the green
// commit.
import '../data/bundle_store.dart';

/// The serialised publish loop: (1) the freshness refresh (durable write),
/// (2) a best-effort warm, (3) the revision bump.
class PublishGate {
  PublishGate({
    required Future<void> Function() refreshFreshness,
    required Future<Map<String, int>> Function() servedRevisions,
    required Future<void> Function(Set<String> sources) warm,
    required void Function() bump,
    required void Function(String line) log,
    Duration warmBudget = const Duration(seconds: 2),
  });

  /// The standard wiring: [LocalDb.refreshComputeFreshness], the served
  /// revisions of [HomeWarmSet.resolve] and [store]`.warm`.
  factory PublishGate.standard({
    required BundleStore store,
    required void Function() bump,
    required void Function(String line) log,
    Duration warmBudget = const Duration(seconds: 2),
  }) => throw UnimplementedError('P2.3 PublishGate.standard');

  /// A day committed or the durable data changed.
  void request() => throw UnimplementedError('P2.3 PublishGate.request');

  /// Completes when no loop is running and none is pending.
  Future<void> get idle => throw UnimplementedError('P2.3 PublishGate.idle');

  /// Loop runs started so far (test readout).
  int get debugRuns => throw UnimplementedError('P2.3 PublishGate.debugRuns');

  /// Nothing runs or bumps after this.
  void dispose() => throw UnimplementedError('P2.3 PublishGate.dispose');
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
  static Future<HomeWarmSet> resolve({required String today}) =>
      throw UnimplementedError('P2.3 HomeWarmSet.resolve');
}

/// The warm after the first frame (4.5): fire-and-forget, 3 s timeout, at most
/// 6 payloads and 1 MB of source, never in a headless or background process.
class StartupWarm {
  StartupWarm({
    required Future<WarmResult> Function(List<BundleSource> sources, int maxSourceBytes) warm,
    required Future<HomeWarmSet> Function() resolve,
    required bool headless,
    Duration timeout = const Duration(seconds: 3),
    int maxPayloads = 6,
    int maxSourceBytes = 1024 * 1024,
  });

  /// The warm result, or null when skipped (headless, nothing to warm, timeout,
  /// failure). Never throws.
  Future<WarmResult?> run() => throw UnimplementedError('P2.3 StartupWarm.run');
}
