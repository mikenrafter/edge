// The artifact warmer (8AG-perf P3-B). After a derive pass that computed days,
// the slow screen reads (journal insights, weekday effect, the night's beats, a
// workout, the circadian rollup) are recomputed in the background and stored in
// `last_result` under their current input signature, so the next open finds them
// FRESH and shows them with no recompute and no "As of" label.
//
// ONE bounded serial warmer: keys run strictly one after another, passes queue
// behind each other (a second pass finds the first one's results fresh and
// skips them), and it never starts a key while a workout, breathing session or
// ECG capture is live or the derive scheduler holds. A hold drops the rest of
// the pass: skip, don't queue. [dispose] cancels it and discards an in-flight
// result.
//
// A failure is logged and stores nothing (an error is never cached, an older
// entry stays) and is not retried within the pass.
import 'dart:async';

import '../compute/calc_status.dart';
import '../compute/derivation_engine.dart' show rawRetentionDays;
import '../data/day_label.dart';
import '../data/db.dart';
import '../data/local_repository_impl.dart';
import '../ui2/last_result_cache.dart';

/// What the warmer warms and how.
abstract class ArtifactSource {
  /// The artifact keys that may need warming after a pass that changed
  /// [changedDays] (local day labels), in the order they should be warmed.
  Future<List<String>> candidateKeys(List<String> changedDays);

  /// The CURRENT signature of [key]; null = none can be given.
  Future<String?> signature(String key);

  /// The value to store for [key] (the same map the matching reader returns);
  /// null = nothing to store. Heavy math runs off the UI isolate inside this
  /// call. A throw is a failed warm.
  Future<Map<String, dynamic>?> compute(String key);
}

/// The real source: the repository's own signatures and producers, so a warmed
/// row and an on-open row are the same thing.
class RepoArtifactSource implements ArtifactSource {
  RepoArtifactSource(this.repo);
  final LocalRepositoryImpl repo;

  @override
  Future<List<String>> candidateKeys(List<String> changedDays) async {
    final keys = <String>{
      'journal_insights|90d',
      'weekday_effect',
      'circadian',
    };
    final days = await repo.availableDays(); // newest first
    if (days.isNotEmpty) keys.add('beats|${days.first}');
    for (final d in changedDays) {
      final lo = localDayStartSec(d), hi = localDayEndSec(d);
      if (lo == null || hi == null) continue;
      for (final id in await LocalDb.sessionIdsInRange(lo, hi - 1)) {
        keys.add('workout|$id');
      }
    }
    // The intraday calorie curve: every changed day that has raw, and every day
    // still inside the raw window that has raw but no curve yet (days derived
    // before P3 get theirs from the substrate while it lives).
    final now = DateTime.now();
    final recent = [
      for (var i = 0; i < rawRetentionDays; i++)
        dayLabelOf(DateTime(now.year, now.month, now.day - i)),
    ];
    final withRaw =
        await LocalDb.decodedDayFingerprints([...changedDays, ...recent]);
    for (final d in changedDays) {
      if (withRaw.containsKey(d)) keys.add('kcal_minutes|$d');
    }
    for (final d in recent) {
      if (withRaw.containsKey(d) &&
          await LocalDb.lastResult('kcal_minutes|$d') == null) {
        keys.add('kcal_minutes|$d');
      }
    }
    return keys.toList();
  }

  @override
  Future<String?> signature(String key) => repo.artifactSignature(key);

  @override
  Future<Map<String, dynamic>?> compute(String key) =>
      repo.computeArtifact(key);
}

class ArtifactWarmer {
  ArtifactWarmer({
    required this.source,
    LastResultCache? cache,
    bool Function()? hold,
    void Function(String message)? log,
  })  : _cache = cache ?? LastResultCache.instance,
        _hold = hold,
        _log = log;

  final ArtifactSource source;
  final LastResultCache _cache;
  final bool Function()? _hold;
  final void Function(String message)? _log;

  bool _disposed = false;

  // Passes run one after another: the tail of the previous one.
  Future<void> _tail = Future<void>.value();

  /// Completes when this warm has finished, been dropped (a hold) or been
  /// cancelled. Never throws.
  Future<void> warmAfterPass({required List<String> changedDays}) {
    if (_disposed || changedDays.isEmpty || _held()) return Future<void>.value();
    final days = [...changedDays];
    return _tail = _tail.then((_) => _warm(days));
  }

  // Keys asked for through [warmKeys] that have not finished: a key asked for
  // again meanwhile joins the first ask instead of computing twice.
  final Map<String, Future<bool>> _requested = {};
  final Set<String> _pendingKeys = <String>{};

  /// Warms exactly [keys] on demand (a screen with nothing stored for one),
  /// through the same serial queue, hold rule and per-key rules as a pass.
  /// Completes when they have finished, been skipped (fresh, or no signature),
  /// dropped (held, disposed) or failed; never throws. True when something new
  /// was stored. Held, an automatic warm is dropped, not queued; a screen's own
  /// request ([keepIfHeld]) is kept and runs when its owner calls
  /// [warmPending] after the hold may have ended.
  Future<bool> warmKeys(List<String> keys, {bool keepIfHeld = false}) async {
    if (_disposed) return false;
    if (_held()) {
      if (keepIfHeld) _pendingKeys.addAll(keys);
      return false;
    }
    final asks = <Future<bool>>[];
    for (final key in {...keys}) {
      final inFlight = _requested[key];
      if (inFlight != null) {
        asks.add(inFlight);
        continue;
      }
      final done = _tail.then((_) async {
        if (_stop) return false;
        return _warmKey(key);
      });
      _tail = done.then((_) {});
      final ask = _requested[key] = done;
      unawaited(ask.whenComplete(() => _requested.remove(key)));
      asks.add(ask);
    }
    final stored = await Future.wait(asks);
    return stored.any((b) => b);
  }

  /// Retries the screen requests held earlier. While a hold is on it does
  /// nothing and keeps them, so nothing computes early.
  Future<bool> warmPending() async {
    if (_disposed || _held() || _pendingKeys.isEmpty) return false;
    final keys = _pendingKeys.toList();
    _pendingKeys.clear();
    return warmKeys(keys, keepIfHeld: true);
  }

  /// Cancels: no further key starts, an in-flight compute's result is
  /// discarded, and later passes return at once.
  void dispose() {
    _disposed = true;
    _pendingKeys.clear();
  }

  // A hold that cannot be read counts as held: the safe answer is to wait.
  bool _held() {
    try {
      return _hold?.call() ?? false;
    } catch (_) {
      return true;
    }
  }

  void _say(String m) {
    try {
      _log?.call(m);
    } catch (_) {}
  }

  bool get _stop => _disposed || _held();

  Future<void> _warm(List<String> days) async {
    try {
      if (_stop) return;
      final keys = await source.candidateKeys(days);
      for (final key in keys) {
        if (_stop) return; // the rest is dropped, not queued
        await _warmKey(key);
      }
    } catch (e) {
      _say('artifact warm failed: $e');
    }
  }

  /// True when this call stored a new result.
  Future<bool> _warmKey(String key) async {
    try {
      // Asked BEFORE the compute, so a result whose inputs move while it runs is
      // stored under the older signature and reads stale next time.
      final sig = await source.signature(key);
      if (sig == null) return false; // nothing to key freshness on
      final stored = await _cache.read<Map>(key);
      if (stored != null && stored.sig == sig) return false; // fresh
      // Only a key that really computes is shown (fresh and unsigned ones
      // returned above); closed whether the compute returns, throws or is
      // discarded.
      final value =
          await CalcStatus.instance.run(_label(key), () => source.compute(key));
      if (_disposed || value == null) return false;
      _cache.put<Map<String, dynamic>>(key, value, sig: sig);
      await _cache.flush();
      return true;
    } catch (e) {
      _say('artifact warm $key failed: $e');
      return false;
    }
  }

  // The status line's words for a key; an unknown key still gets honest ones.
  static String _label(String key) {
    final kind = key.split('|').first;
    return switch (kind) {
      'journal_insights' => 'Preparing journal insights',
      'weekday_effect' => 'Preparing weekday effect',
      'circadian' => 'Preparing Circadian',
      'beats' => 'Preparing Beats',
      'workout' => 'Preparing workout',
      'kcal_minutes' => 'Preparing calorie curve',
      _ => 'Preparing results',
    };
  }
}
