// The update checker's claim ledgers for the shared notification emitter, both
// backed by UpdateStore. The emitter never opens the health database for a
// release announcement: claims, OS ids and consent come from here.
import 'dart:convert';

import 'package:clock/clock.dart';

import '../notify/alert_dispatcher.dart' show AlertDeliveryLedger;
import '../notify/event_claim_ledger.dart';
import '../notify/notification_event.dart';
import 'update_store.dart';

/// One permanent claim per `(repository, release id)`; see
/// [UpdateStore.beginRelease] for the states.
class UpdateClaimLedger implements EventClaimLedger {
  UpdateClaimLedger(this.open, {this.clock = const Clock()});
  final Future<UpdateStore> Function() open;
  final Clock clock;

  @override
  Future<EventClaim?> begin(NotificationEvent event) async {
    final ticket = await (await open()).beginRelease(event.dedupeKey, clock.now());
    return ticket == null ? null : EventClaim(osId: ticket.osId, token: ticket);
  }

  @override
  Future<void> settle(EventClaim claim, ClaimOutcome outcome) async =>
      (await open()).settleRelease(claim.token as ReleaseTicket, outcome);

  /// Consent to release alerts is the automatic-check opt-in. A one-time
  /// Check now does not authorize a continuing alert channel.
  @override
  Future<bool> stillWanted(NotificationEvent event) async =>
      (await (await open()).read()).enabled;
}

/// Once-only marks for each routed destination of a release rule (phone, band),
/// replacing the health-database claim the dispatcher would otherwise take.
class UpdateTargetLedger implements AlertDeliveryLedger {
  UpdateTargetLedger(this.open);
  final Future<UpdateStore> Function() open;

  ({String identity, String target}) _split(String key) {
    final parts = jsonDecode(key) as List;
    return (identity: parts[1] as String, target: parts[2] as String);
  }

  @override
  Future<bool> claim(String key) async {
    final k = _split(key);
    return (await open()).claimTarget(k.identity, k.target);
  }

  @override
  Future<void> release(String key) async {
    final k = _split(key);
    await (await open()).releaseTarget(k.identity, k.target);
  }
}
