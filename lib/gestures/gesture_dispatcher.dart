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
// ECG on double tap (8I/8L, WHOOP MG only): while GestureSettings.ecgOnDoubleTap
// is on, a live double tap starts the ECG capture through [onEcgTap] instead of
// its actions, which are suspended (the Device lab owns that mode). It takes the
// same once-ever claim / receipt debounce as an action, under `...:ecg`.
// With the switch OFF, on an MG with a 3-5 tap mapping, a live double tap runs
// the same capture as a touch COUNTER ([onCountTaps]): the actions mapped to the
// final count (2-5) then run through the path above, claimed per tap identity
// and count (`gesture:<identity>:t<count>:<action>`; a count of 2 keeps the plain
// key). An abandoned count runs nothing; its outcomes carry `taps`, which keeps
// the 8H tap-ack quiet (the counter's own buzzes are the acknowledgement).
//
// Two ways to count the taps beyond the firmware's double tap, chosen per band
// (GestureSettings.tapMethodFor): ECG sensor touches (above; WHOOP MG only) or
// MORE DOUBLE TAPS, which any band can do. The second opens a window at the
// first live double tap; every tap, opener or member, takes its own once-ever
// claim before it is accepted, and the session groups taps by the band's clock
// (a tap too long after the last one starts the next group). Each further live
// double tap inside it adds one,
// buzzes once and restarts the window; when it runs out the actions mapped to
// the count run. The first [handle] call waits for that and returns the
// outcomes; the later calls return nothing at once. A single double tap is only
// delayed when some 3-5 slot is actually mapped (otherwise it runs at once, as
// always). Late taps never count. In the Device lab (repeatTapsLab) the same
// window runs with the max at 5 and NO action runs.
//
// Rollout switch (FeatureFlag.tapClassifiers, default on). OFF: a double tap is
// only a double tap. The ECG lab, the repeated-double-tap lab and both 3-5 tap
// counters are skipped, so the mapped 2-tap actions run at once, whatever the
// 3-5 slots or the lab switches hold in storage.
//
// One action failing never stops the next, and nothing escapes as an unhandled
// async error: [handle] always completes with a list of outcomes.
//
// No wall clock is read here: recency and the debounce both use the event's own
// `receivedAt`, which keeps this deterministic under test.
//
// Claim growth: one `gesture:<identity>:<action>` row per tap per action in
// notif_fired. LocalDb.pruneNotifFired (run whenever a notification fires)
// drops them after 90 days.

import 'dart:async' show TimeoutException;

import 'device_action.dart';
import 'double_tap_repeat.dart';
import 'gesture_failures.dart';
import 'gesture_settings.dart';
import 'strap_event.dart';
import 'tap_names.dart';
import '../data/db.dart';
import '../platform/device_actions.dart';
import '../state/feature_flags.dart';

enum GestureStatus { ran, skippedStale, skippedDuplicate, failed }

class GestureOutcome {
  const GestureOutcome({
    required this.action,
    required this.status,
    required this.timeSource,
    this.error,
    this.taps,
  });

  final DeviceAction action;
  final GestureStatus status;

  /// Where the EVENT's time came from; the same on every outcome of one tap.
  final EventTimeSource timeSource;

  /// Non-null iff [status] is [GestureStatus.failed].
  final Object? error;

  /// The touch counter's final count when this ran because of a counted tap
  /// (8L); null for an immediate double tap.
  final int? taps;
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

  /// 8I: true only on a positively identified WHOOP MG.
  final bool Function()? ecgSupported;

  /// 8I: start the ECG capture for this live double tap. A throw gives the
  /// claim back so a retry can run.
  final GestureHandler? onEcgTap;

  /// 8L: count the taps of this live double tap (the ECG touch counter) and
  /// complete with the final count, or null when the gesture was abandoned (a
  /// link drop or stall). Throws when it could not start; the claim is then
  /// given back and the double-tap actions run at once, as without counting.
  final Future<int?> Function(StrapEvent)? onCountTaps;

  /// The repeated-double-tap window (the method that needs no ECG). Null: the
  /// method is unavailable and a double tap always runs at once.
  final DoubleTapRepeatSession? repeatSession;

  /// 8AK: a tap's mapped action FAILED (threw, answered false or timed out):
  /// called once per tap with the kind of route it took (`ecg` after counting
  /// touches, `doubleTap` otherwise) and a reason that names the action. Never
  /// for an action that ran, a stale skip or a duplicate. The ECG route's own
  /// start failures are the session's to report, so one failure is not
  /// recorded twice. May throw: it is swallowed.
  final void Function(StrapEvent e, GestureFailureKind kind, String reason)?
      onFailed;

  /// How long one action may take. A native or in-app action that never answers
  /// is a failed outcome and the next action still runs. Its claim is KEPT: the
  /// action may yet have run, and a re-sent tap must not run it a second time.
  final Duration actionTimeout;

  /// FeatureFlag.tapClassifiers, read on every tap so the switch bites at once.
  final bool Function() _tapClassifiersOn;

  final Future<bool> Function(String actionId) _performNative;
  final Future<bool> Function(String key) _claim;
  final Future<void> Function(String key) _release;

  GestureDispatcher({
    required this.settings,
    this.log,
    this.onMarkMoment,
    this.onWorkoutToggle,
    this.onLogWater,
    this.ecgSupported,
    this.onEcgTap,
    this.onCountTaps,
    this.repeatSession,
    this.onFailed,
    bool Function()? tapClassifiersOn,
    this.actionTimeout = const Duration(seconds: 10),
    Future<bool> Function(String actionId)? performNative,
    Future<bool> Function(String key)? claim,
    Future<void> Function(String key)? release,
  })  : _tapClassifiersOn = tapClassifiersOn ??
            (() => FeatureFlags.isOn(FeatureFlag.tapClassifiers)),
        _performNative = performNative ?? DeviceActions.perform,
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
    if (!_tapClassifiersOn()) return _runActions(e, settings.doubleTapActions);
    // Lab mode: suspended whether or not the capture below can start (a late
    // tap, a duplicate, a failed start) so a tap never runs half the lab and
    // half the normal actions.
    if (settings.ecgOnDoubleTap && ecgSupported?.call() == true) {
      if (e.isLive) await _ecgTap(e);
      return const [];
    }
    // The Device lab's other bench: count repeated double taps, run nothing.
    final repeat = repeatSession;
    if (settings.repeatTapsLab && repeat != null) {
      if (e.isLive) await _repeatTap(e, repeat, lab: true);
      return const [];
    }
    final mg = ecgSupported?.call() == true;
    final method = settings.tapMethodFor(ecgSupported: mg);
    // 8L: with a 3-5 tap mapping, a live double tap is counted and its actions
    // wait for the final count. A late tap is never counted (the touch would be
    // for a tap from the past) and runs as before.
    if (e.isLive && settings.maxMappedTaps > 2) {
      if (method == TapCountMethod.ecg && onCountTaps != null && mg) {
        return _countedTap(e);
      }
      if (method == TapCountMethod.repeat && repeat != null) {
        return _repeatTap(e, repeat);
      }
    }
    // A late tap while a window is open is still not counted: it takes the
    // ordinary path (stale rules) below.
    return _runActions(e, settings.doubleTapActions);
  }

  Future<List<GestureOutcome>> _runActions(StrapEvent e, Set<DeviceAction> actions,
      {int? taps,
      GestureFailureKind kind = GestureFailureKind.doubleTap}) async {
    final out = <GestureOutcome>[];
    for (final a in actions) {
      out.add(await _handleOne(e, a, taps: taps));
    }
    // One report per tap, for the first action that failed.
    for (final o in out) {
      if (o.status != GestureStatus.failed) continue;
      try {
        onFailed?.call(e, kind, '${o.action.id}: ${_why(o.error)}');
      } catch (_) {}
      break;
    }
    return out;
  }

  // A short, single-line reason for a failed outcome.
  static String _why(Object? error) {
    final t = (error ?? 'failed').toString().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > 120 ? '${t.substring(0, 120)}...' : t;
  }

  /// Take the once-ever claim (or the receipt debounce) for the ECG session of
  /// this tap, under `...:ecg`. Null: skip, this tap already has one.
  Future<({String? claimKey, String debounceKey})?> _takeEcgTap(
      StrapEvent e, [String kind = 'ecg']) async {
    final debounceKey = '${e.identity}:$kind';
    String? claimKey;
    if (e.plausible) {
      claimKey = 'gesture:$debounceKey';
      try {
        if (!await _claim(claimKey)) return null;
      } catch (err) {
        log?.call('[gesture] ecg: claim failed: $err');
        return null;
      }
    } else {
      final last = _lastAccepted[debounceKey];
      if (last != null && e.receivedAt.difference(last) < _receiptDebounce) {
        return null;
      }
      _lastAccepted.removeWhere(
          (_, t) => e.receivedAt.difference(t) >= _receiptDebounce);
      _lastAccepted[debounceKey] = e.receivedAt;
    }
    return (claimKey: claimKey, debounceKey: debounceKey);
  }

  Future<void> _giveBackEcgTap(
      ({String? claimKey, String debounceKey}) taken) async {
    final claimKey = taken.claimKey;
    if (claimKey != null) {
      try {
        await _release(claimKey);
      } catch (relErr) {
        log?.call('[gesture] ecg: claim release failed: $relErr');
      }
    } else {
      _lastAccepted.remove(taken.debounceKey);
    }
  }

  Future<void> _ecgTap(StrapEvent e) async {
    final start = onEcgTap;
    if (start == null) return;
    final taken = await _takeEcgTap(e);
    if (taken == null) return;
    try {
      log?.call('[gesture] double-tap → ecg');
      await start(e);
    } catch (err) {
      log?.call('[gesture] ecg start failed: $err');
      await _giveBackEcgTap(taken);
    }
  }

  /// 8L: count the taps, then run the final count's actions. An abandoned
  /// gesture runs nothing and keeps its claim (a re-send is the same tap). One
  /// that could not START never counted anything, so it gives the claim back
  /// and the tap does what it always did.
  Future<List<GestureOutcome>> _countedTap(StrapEvent e) async {
    final taken = await _takeEcgTap(e);
    if (taken == null) return const [];
    final int? count;
    try {
      log?.call('[gesture] double-tap → counting taps');
      count = await onCountTaps!(e);
    } catch (err) {
      log?.call('[gesture] tap counting did not start: $err');
      await _giveBackEcgTap(taken);
      return _runActions(e, settings.doubleTapActions);
    }
    if (count == null) {
      log?.call('[gesture] tap counting abandoned; no action');
      return const [];
    }
    log?.call('[gesture] counted ${ecgTapCountName(count)}');
    return _runActions(e, settings.actionsForTaps(count),
        taps: count, kind: GestureFailureKind.ecg);
  }

  /// A member of an open repeated-double-tap group takes its own once-ever claim
  /// (`gesture:<identity>:rep`) BEFORE the session sees it, so a member that is
  /// re-delivered after its group finished (history replay, reconnect) is
  /// skipped instead of opening a new window or running an action twice. Null:
  /// skip, already claimed (or the claim store failed: fail closed). An
  /// implausible strap clock has no stable identity, so such a member takes no
  /// claim here; the session's receipt debounce guards it.
  Future<({String? claimKey, String debounceKey})?> _takeMember(
      StrapEvent e) async {
    final debounceKey = '${e.identity}:rep';
    if (!e.plausible) return (claimKey: null, debounceKey: debounceKey);
    final claimKey = 'gesture:$debounceKey';
    try {
      if (!await _claim(claimKey)) return null;
    } catch (err) {
      log?.call('[gesture] rep: claim failed: $err');
      return null;
    }
    return (claimKey: claimKey, debounceKey: debounceKey);
  }

  /// The repeated-double-tap method. A later tap inside an open window only
  /// adds to it and returns nothing; the tap that opened the window waits for
  /// the final count and runs its actions (none in the lab). EVERY tap, opener
  /// or member, takes the same once-ever claim / receipt debounce as the ECG
  /// route, under `...:rep`, before it is accepted, so a re-send cannot open a
  /// second window or count twice. A member the session reports as starting the
  /// NEXT group (too long after the last tap by the band clock) has already
  /// finished the open group and opens its own window with the claim it holds.
  Future<List<GestureOutcome>> _repeatTap(
      StrapEvent e, DoubleTapRepeatSession session,
      {bool lab = false}) async {
    final taken =
        session.open ? await _takeMember(e) : await _takeEcgTap(e, 'rep');
    if (taken == null) return const [];
    if (session.open) {
      // A member, or another tap opened the window while this one took its
      // claim. Counted or ignored, the claim stays: a re-send is the same tap.
      if (session.offer(e) != RepeatOffer.newGroup) return const [];
    }
    if (taken.claimKey == null) {
      _lastAccepted[taken.debounceKey] = e.receivedAt;
    }
    log?.call('[gesture] double-tap → counting double taps');
    final int count;
    try {
      count = await session.begin(e);
    } catch (err) {
      log?.call('[gesture] double-tap window did not open: $err');
      await _giveBackEcgTap(taken);
      return lab ? const [] : _runActions(e, settings.doubleTapActions);
    }
    log?.call('[gesture] counted $count double taps');
    if (lab) return const [];
    // The session played the start, one follow-up per added tap and the
    // confirm, a count of 2 included (8AK), so every count is marked: the 8H
    // ack stays out and the wearer feels the confirm once.
    return _runActions(e, settings.actionsForTaps(count), taps: count);
  }

  Future<GestureOutcome> _handleOne(StrapEvent e, DeviceAction a,
      {int? taps}) async {
    GestureOutcome outcome(GestureStatus s, [Object? error]) => GestureOutcome(
        action: a,
        status: s,
        timeSource: e.timeSource,
        error: error,
        taps: taps);

    // A count of 2 is the plain double tap; 3-5 are their own occurrences.
    final scope = taps == null || taps == 2 ? '' : 't$taps:';

    // a. Stale check first, before any claim is taken.
    if (!e.isLive &&
        !(a.supportsHistoricalReplay && settings.replayHistorical(a))) {
      log?.call('[gesture] ${a.id}: skipping stale double-tap '
          '(${e.age?.inSeconds}s old)');
      return outcome(GestureStatus.skippedStale);
    }

    final debounceKey = '${e.identity}:$scope${a.id}';
    String? claimKey;
    if (e.plausible) {
      // b. Persistent, atomic once-ever claim. Fail closed.
      claimKey = 'gesture:${e.identity}:$scope${a.id}';
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
      await _run(a, e).timeout(actionTimeout);
      return outcome(GestureStatus.ran);
    } on TimeoutException catch (err) {
      log?.call('[gesture] ${a.id} did not answer in $actionTimeout');
      return outcome(GestureStatus.failed, err);
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
