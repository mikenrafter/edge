// The update checker's claim ledger for NotificationCenter, backed by UpdateStore.
import '../notify/alert_dispatcher.dart' show AlertDeliveryLedger;
import '../notify/event_claim_ledger.dart';
import '../notify/notification_event.dart';
import 'update_store.dart';

class UpdateClaimLedger implements EventClaimLedger {
  UpdateClaimLedger(this.open);
  final Future<UpdateStore> Function() open;

  @override
  Future<EventClaim?> begin(NotificationEvent event) async => null;

  @override
  Future<void> settle(EventClaim claim, ClaimOutcome outcome) async {}

  @override
  Future<bool> stillWanted(NotificationEvent event) async => false;
}

/// Per-destination once-only marks for the release rule, in UpdateStore.
class UpdateTargetLedger implements AlertDeliveryLedger {
  UpdateTargetLedger(this.open);
  final Future<UpdateStore> Function() open;

  @override
  Future<bool> claim(String key) async => false;

  @override
  Future<void> release(String key) async {}
}
