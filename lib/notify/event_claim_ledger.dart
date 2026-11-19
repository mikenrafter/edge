// event_claim_ledger.dart — a category's own once-only claim for its events.
//
// The shared emitter normally claims an event in the health database
// (FiredKeyStore) and allocates its OS id there. A category whose state must
// live elsewhere registers a ledger here instead: the emitter then claims,
// settles and takes the OS id through it, and never opens the health database
// for that category's events. The update checker is the one registrant.
import 'notification_event.dart';

/// What a settled claim means for the next attempt.
enum ClaimOutcome {
  /// Presented. The claim is permanent.
  sent,

  /// Held by the quiet/sleep policy. The claim stays reserved and the same
  /// claim is reused when the policy releases the alert.
  held,

  /// Known non-delivery outside a hold (permission denied, the user opted
  /// out). The unused claim is given back.
  released,

  /// The transport may have shown it (timeout, crash). The claim stays
  /// consumed: at most once beats exactly once.
  unknown,
}

/// A claim an emitter holds while it delivers one event.
class EventClaim {
  const EventClaim({required this.osId, required this.token});

  /// The OS notification id owned by this event, from the ledger's own store.
  final int osId;

  /// Opaque to the emitter; identifies this attempt to the ledger.
  final Object token;
}

abstract interface class EventClaimLedger {
  /// Take (or take back, after a hold) the claim for [event]. Null when the
  /// event is already consumed, or another owner holds the claim now.
  Future<EventClaim?> begin(NotificationEvent event);

  /// Record what happened to [claim].
  Future<void> settle(EventClaim claim, ClaimOutcome outcome);

  /// Whether consent to this category's alerts still stands. Checked again after
  /// every await between claim and handoff.
  Future<bool> stillWanted(NotificationEvent event, EventClaim claim);
}
