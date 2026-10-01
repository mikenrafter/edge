// gesture_dispatcher.dart — turns a live band event into the user's chosen
// actions, with the guards that keep each one safe. Wired ONLY into the
// foreground/live event path (AppState), never the headless drain
// (background_sync persists events but must not dispatch them).
//
// A double-tap can map to SEVERAL actions. For each one, in enum order and one
// at a time, [handle] decides:
//  • Recency — a tap that reached the phone long after it happened (drained from
//    the band's flash, or held back by a dropped link) is "stale". A stale tap is
//    replayed ONLY for an action that opts in (`supportsHistoricalReplay` and the
//    user's replay switch: today just Mark moment, which stamps the tap's own
//    time). Everything else — native actions, water, workouts — is skipped, so a
//    sync catch-up never plays music for a tap from this morning. A stale skip
//    takes no claim, so turning replay on later still works.
//  • Once-ever — a tap with a believable strap clock is one occurrence, named by
//    StrapEvent.identity. Each (occurrence, action) pair is claimed in the
//    persistent notif_fired ledger before it runs, so a re-send, a reconnect or an
//    app restart can't run it twice. A failed action gives its claim back.
//  • Receipt debounce — an unset or wild RTC makes every tap share one identity,
//    so a persistent claim would lock the feature out forever. For those the only
//    guard is a 2 s in-memory window on RECEIPT time.
// One action failing never stops the next, and nothing escapes as an unhandled
// async error: [handle] always completes with a list of outcomes.
//
// No wall clock is read here: recency and the debounce both use the event's own
// `receivedAt`, which keeps this deterministic under test.
//
// Claim growth: one `gesture:<identity>:<action>` row per tap per action in
// notif_fired. LocalDb.pruneNotifFired (run whenever a notification fires)
// drops them after 90 days.

import 'device_action.dart';
import 'gesture_settings.dart';
import 'strap_event.dart';
import '../data/db.dart';
import '../platform/device_actions.dart';

enum GestureStatus { ran, skippedStale, skippedDuplicate, failed }

class GestureOutcome {
  const GestureOutcome({
    required this.action,
    required this.status,
    required this.timeSource,
    this.error,
  });

  final DeviceAction action;
  final GestureStatus status;

  /// Where the EVENT's time came from; the same on every outcome of one tap.
  final EventTimeSource timeSource;

  /// Non-null iff [status] is [GestureStatus.failed].
  final Object? error;
}

typedef GestureHandler = Future<void> Function(StrapEvent event);

class GestureDispatcher {
  final GestureSettings settings;
  final void Function(String line)? log;

  /// In-app action handlers (supplied by AppState). Native actions go to the
  /// platform channel instead.
  final GestureHandler? onMarkMoment;
  final GestureHandler? onWorkoutToggle;
  final GestureHandler? onLogWater;

  final Future<bool> Function(String actionId) _performNative;
  final Future<bool> Function(String key) _claim;
  final Future<void> Function(String key) _release;

  GestureDispatcher({
    required this.settings,
    this.log,
    this.onMarkMoment,
    this.onWorkoutToggle,
    this.onLogWater,
    Future<bool> Function(String actionId)? performNative,
    Future<bool> Function(String key)? claim,
    Future<void> Function(String key)? release,
  })  : _performNative = performNative ?? DeviceActions.perform,
        _claim = claim ?? LocalDb.claimNotifFired,
        _release = release ?? LocalDb.releaseNotifFired;

  static const int _doubleTapEventId = 14; // EventId.doubleTap
  static const Duration _receiptDebounce = Duration(seconds: 2);

  /// receivedAt of the last ACCEPTED tap per `<identity>:<action id>`, for
  /// implausible clocks only.
  final Map<String, DateTime> _lastAccepted = {};

  /// Feed every live event here. Cheap for non-gesture events. Never throws.
  Future<List<GestureOutcome>> handle(StrapEvent e) async {
    if (e.eventId != _doubleTapEventId) return const [];
    final actions = settings.doubleTapActions;
    if (actions.isEmpty) return const [];

    final out = <GestureOutcome>[];
    for (final a in actions) {
      out.add(await _handleOne(e, a));
    }
    return out;
  }

  Future<GestureOutcome> _handleOne(StrapEvent e, DeviceAction a) async {
    GestureOutcome outcome(GestureStatus s, [Object? error]) => GestureOutcome(
        action: a, status: s, timeSource: e.timeSource, error: error);

    // a. Stale check first, before any claim is taken.
    if (!e.isLive &&
        !(a.supportsHistoricalReplay && settings.replayHistorical(a))) {
      log?.call('[gesture] ${a.id}: skipping stale double-tap '
          '(${e.age?.inSeconds}s old)');
      return outcome(GestureStatus.skippedStale);
    }

    final debounceKey = '${e.identity}:${a.id}';
    String? claimKey;
    if (e.plausible) {
      // b. Persistent, atomic once-ever claim. Fail closed.
      claimKey = 'gesture:${e.identity}:${a.id}';
      try {
        if (!await _claim(claimKey)) {
          return outcome(GestureStatus.skippedDuplicate);
        }
      } catch (err) {
        log?.call('[gesture] ${a.id}: claim failed: $err');
        return outcome(GestureStatus.failed, err);
      }
    } else {
      // c. No usable clock: debounce on receipt time. The entry is written
      // before anything is awaited so overlapping deliveries can't both pass.
      final last = _lastAccepted[debounceKey];
      if (last != null && e.receivedAt.difference(last) < _receiptDebounce) {
        return outcome(GestureStatus.skippedDuplicate);
      }
      _lastAccepted.removeWhere(
          (_, t) => e.receivedAt.difference(t) >= _receiptDebounce);
      _lastAccepted[debounceKey] = e.receivedAt;
    }

    // d. Run.
    try {
      log?.call('[gesture] double-tap → ${a.id}');
      await _run(a, e);
      return outcome(GestureStatus.ran);
    } catch (err) {
      log?.call('[gesture] ${a.id} failed: $err');
      // e. Give the occurrence back so a retry can run it.
      if (claimKey != null) {
        try {
          await _release(claimKey);
        } catch (relErr) {
          log?.call('[gesture] ${a.id}: claim release failed: $relErr');
        }
      } else {
        _lastAccepted.remove(debounceKey);
      }
      return outcome(GestureStatus.failed, err);
    }
  }

  Future<void> _run(DeviceAction a, StrapEvent e) async {
    if (a.isInApp) {
      final handler = switch (a) {
        DeviceAction.markMoment => onMarkMoment,
        DeviceAction.workoutToggle => onWorkoutToggle,
        DeviceAction.logWater => onLogWater,
        _ => null,
      };
      // An action offered in the picker that then does nothing is the exact
      // failure the picker exists to end, so a missing handler is a failure.
      if (handler == null) {
        throw StateError('${a.id} is in-app with no handler');
      }
      await handler(e);
      return;
    }
    if (!await _performNative(a.id)) {
      throw StateError('native ${a.id} reported failure');
    }
  }
}
