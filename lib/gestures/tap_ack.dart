// tap_ack.dart — the one buzz that tells the wearer a double tap did something.
//
// The tap itself gives no feedback: the band cannot know whether the phone ran
// anything. So once at least one mapped action RAN for a LIVE tap, the phone
// sends a single short buzz back. It goes through AlertDispatcher like every
// other band haptic — band-only, live-only, a few seconds of life — so a late
// tap, a duplicate, a tap where every action failed or was skipped, and a
// reconnect long after the fact all stay silent, and it can never replay.
//
// Foreground path only: the headless drain never acks (AppState._onLiveEvent
// is the single caller).

import '../notify/alert_dispatcher.dart';
import '../notify/alert_rule.dart';
import '../notify/buzz_sequence.dart' show BuzzDelivery;
import 'gesture_dispatcher.dart';
import 'strap_event.dart';

const AlertRule kGestureAckRule = AlertRule(
  id: 'gesture_ack',
  kind: 'gesture',
  destinations: AlertRule.band,
  executionMode: AlertExecutionMode.phoneLive,
  historicalReplay: AlertHistoricalReplay.liveOnly,
  fallback: AlertFallback.none,
  staleAfter: kLiveEventWindow,
  channelPolicyId: 'gesture',
);

/// True iff [e] is a live double tap and at least one of its actions ran.
///
/// Not for a COUNTED tap (8L, `GestureOutcome.taps` set): the touch counter has
/// already buzzed the count and confirmed the final one, so a further buzz when
/// its actions run would double up.
bool shouldAckTap(StrapEvent e, List<GestureOutcome> outcomes) =>
    e.eventId == 14 &&
    e.isLive &&
    outcomes.every((o) => o.taps == null) &&
    outcomes.any((o) => o.status == GestureStatus.ran);

/// Buzz the band once for this tap, through [d]'s default band transport, or
/// through [bandDelivery] (the gesture confirm cue, 8AF.6) when given. Returns
/// whether a buzz was delivered. Never throws.
Future<bool> ackTap(
  AlertDispatcher d,
  StrapEvent e,
  List<GestureOutcome> outcomes, {
  Future<BuzzDelivery> Function()? bandDelivery,
}) async {
  if (!shouldAckTap(e, outcomes)) return false;
  // An unset RTC gives every tap one identity; receipt time keeps the second
  // ack from being swallowed by the first one's claim.
  final id = e.plausible
      ? e.identity
      : '${e.identity}:${e.receivedAt.microsecondsSinceEpoch}';
  try {
    final r = await d.dispatch(
      kGestureAckRule,
      eventId: id,
      sourceTime: e.effectiveTime,
      historical: false,
      bandDelivery: bandDelivery,
    );
    return r.targets.contains('band');
  } catch (_) {
    return false;
  }
}
