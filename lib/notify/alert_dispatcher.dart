import 'dart:async';
import 'dart:convert';

import '../data/db.dart';
import '../haptics/band_queue.dart' show BandHold, kBandHoldKey;
import 'alert_rule.dart';
import 'buzz_sequence.dart';

/// Ownership is persisted before a transport runs. Failed targets release their
/// own claim; a successful other target remains consumed across restarts.
abstract interface class AlertDeliveryLedger {
  Future<bool> claim(String key);
  Future<void> release(String key);
}

class DurableAlertDeliveryLedger implements AlertDeliveryLedger {
  const DurableAlertDeliveryLedger();
  @override
  Future<bool> claim(String key) => LocalDb.claimNotifFired('alert:$key');
  @override
  Future<void> release(String key) => LocalDb.releaseNotifFired('alert:$key');
}

/// Only injected by tests. Production never downgrades band delivery to an
/// isolate-local claim when durable storage is unavailable.
class MemoryAlertDeliveryLedger implements AlertDeliveryLedger {
  final Set<String> _claims = {};
  @override
  Future<bool> claim(String key) async => _claims.add(key);
  @override
  Future<void> release(String key) async {
    _claims.remove(key);
  }
}

class AlertDeliveryOutcome {
  const AlertDeliveryOutcome(this.targets, this.suppressionReason);
  final List<String> targets;
  final String? suppressionReason;
}

class AlertDispatcher {
  AlertDispatcher({
    required this.phone,
    required this.band,
    this.bandSequence,
    this.bandSequenceDelivery,
    required this.isConnected,
    this.supportedTargets = const {'phone', 'band'},
    this.supportedTargetsAtDelivery,
    this.supportedBandModes = AlertCapabilityRegistry.liveBandModes,
    this.supportedPhoneModes = AlertCapabilityRegistry.phoneModes,
    DateTime Function()? now,
    this.ledger = const DurableAlertDeliveryLedger(),
    this.transportTimeout = const Duration(seconds: 10),
    this.bandQueueWait = Duration.zero,
    this.sequenceTimeout,
  }) : now = now ?? DateTime.now;

  final Future<bool> Function() phone;
  final Future<bool> Function() band;

  /// Shared saved-pattern delivery covers notification emitters and reminder
  /// timers that use the dispatcher without choosing a transport themselves.
  final Future<bool> Function(BuzzSequence)? bandSequence;

  /// The tri-state form of [bandSequence] (preferred when both are given): the
  /// dispatcher keeps its claim whenever the band may have buzzed.
  final Future<BuzzDelivery> Function(BuzzSequence)? bandSequenceDelivery;
  final bool Function() isConnected;
  final Set<String> supportedTargets;
  final Set<String> Function()? supportedTargetsAtDelivery;
  Set<String> get currentSupportedTargets =>
      supportedTargetsAtDelivery?.call() ?? supportedTargets;
  final Set<AlertExecutionMode> supportedBandModes;
  final Set<AlertExecutionMode> supportedPhoneModes;
  final DateTime Function() now;
  final AlertDeliveryLedger ledger;
  final Duration transportTimeout;

  /// How long a band delivery may wait in the band queue before it starts
  /// (8AC). Added to every band deadline, so the transport still has its own
  /// time once the job gets its turn.
  final Duration bandQueueWait;

  /// How long a rule's saved rhythm needs to play on the connected band (a
  /// compiled plan outlasts the taps' own estimate). Null: the sequence's own
  /// [BuzzSequence.transportTimeout].
  final Duration Function(BuzzSequence)? sequenceTimeout;

  // [work] with a deadline of [limit] that does not run while the band queue
  // holds the job for the Device lab: the queue pauses it through the
  // [BandHold] in the zone and restarts it (in full) when the lab closes. The
  // same hold lets the queue ask whether the alert has gone stale meanwhile.
  Future<T> _within<T>(
    Future<T> Function() work,
    Duration limit,
    T Function() onTimeout,
    DateTime sourceTime,
    Duration staleAfter,
  ) {
    final result = Completer<T>();
    Timer? timer;
    void arm() {
      timer?.cancel();
      if (result.isCompleted) return;
      timer = Timer(limit, () {
        if (!result.isCompleted) result.complete(onTimeout());
      });
    }

    final hold = BandHold(
      onHold: () => timer?.cancel(),
      onRelease: arm,
      isStale: () => now().difference(sourceTime) > staleAfter,
    );
    arm();
    Future<T>.sync(
      () => runZoned(work, zoneValues: <Object?, Object?>{kBandHoldKey: hold}),
    ).then((v) {
      if (!result.isCompleted) result.complete(v);
    }, onError: (Object e, StackTrace st) {
      if (!result.isCompleted) result.completeError(e, st);
    }).whenComplete(() => timer?.cancel());
    return result.future;
  }

  Future<AlertDeliveryOutcome> dispatch(
    Object rule, {
    required String eventId,
    required DateTime sourceTime,
    required bool historical,
    Future<bool> Function()? phoneTransport,
    Future<bool> Function()? bandTransport,
    // A band transport that can say what it did to the band (see
    // [BuzzDelivery]). Preferred over [bandTransport]. The claim is released only
    // for [BuzzDelivery.rejected]; after a partial or unknown delivery it is
    // KEPT (outcome reason 'deliveryUnconfirmed'), so a retry cannot buzz twice.
    Future<BuzzDelivery> Function()? bandDelivery,
    Set<String>? transportTargets,
    bool Function(String target)? targetAllowed,
    // A band transport that legitimately runs longer than [transportTimeout]
    // (a recorded rhythm: up to 8 buzzes, 2 s apart) asks for the time it
    // needs. Never shorter than the default.
    Duration? bandTimeout,
  }) async {
    final typed = rule is AlertRule
        ? rule
        : AlertRule.fromJson(Map<String, Object?>.from(rule as Map));
    if (!typed.enabled || typed.destinations == 0) {
      return const AlertDeliveryOutcome([], 'disabled');
    }
    final received = now();
    final age = received.difference(sourceTime);
    if (age > Duration(seconds: typed.staleAfterSeconds) ||
        age < const Duration(seconds: -5)) {
      return const AlertDeliveryOutcome([], 'stale');
    }
    if (historical &&
        typed.historicalReplay != AlertHistoricalReplay.historical) {
      return const AlertDeliveryOutcome([], 'historical');
    }
    final availableTargets = currentSupportedTargets;
    final selected = <String>{
      if ((typed.destinations & 1) != 0) 'phone',
      if ((typed.destinations & 2) != 0) 'band',
    };
    String? reason;
    if (selected.contains('band') &&
        (!availableTargets.contains('band') || !isConnected())) {
      selected.remove('band');
      reason = 'bandUnavailable';
      if (typed.fallback == AlertFallback.phoneIfBandUnavailable) {
        selected.add('phone');
      }
    }
    selected.removeWhere((target) {
      final unsupported = AlertCapabilityRegistry.destinationSupportReason(
        typed, target, supportedTargets: availableTargets,
        supportedBandModes: supportedBandModes,
        supportedPhoneModes: supportedPhoneModes);
      if (unsupported != null) { reason ??= unsupported; }
      return unsupported != null;
    });
    if (transportTargets != null) selected.retainAll(transportTargets);
    final delivered = <String>[];
    // Separate claims keep a denied phone permission from consuming band output.
    for (final target in selected) {
      if (targetAllowed != null && !targetAllowed(target)) {
        reason ??= 'channelSuppressed';
        continue;
      }
      final key = jsonEncode([typed.id, eventId, target]);
      var claimed = false;
      var success = false;
      try {
        if (now().difference(sourceTime) > typed.staleAfter) {
          reason = 'stale';
          continue;
        }
        claimed = await ledger.claim(key);
        if (!claimed) continue;
        final saved = typed.buzzSequence;
        final sequencePlayer = bandSequence;
        final sequenceDelivery = bandSequenceDelivery;
        final implicitSequence = target == 'band' &&
            bandTransport == null &&
            bandDelivery == null &&
            saved != null &&
            (sequencePlayer != null || sequenceDelivery != null);
        // Do not release a timed-out ownership: the platform write may still
        // complete. A late success must never race a fresh retry into two buzzes.
        var limit = transportTimeout;
        if (target == 'band') {
          if (bandTimeout != null && bandTimeout > limit) limit = bandTimeout;
          if (implicitSequence) {
            final need =
                sequenceTimeout?.call(saved) ?? saved.transportTimeout;
            if (need > limit) limit = need;
          }
          limit += bandQueueWait;
        }
        final Future<BuzzDelivery> Function()? delivery = target != 'band'
            ? null
            : bandDelivery ??
                (implicitSequence && sequenceDelivery != null
                    ? () => sequenceDelivery(saved)
                    : null);
        if (delivery != null) {
          final d = await _within(
            delivery,
            limit,
            () {
              claimed = false;
              reason = 'deliveryUnconfirmed';
              return BuzzDelivery.unknown;
            },
            sourceTime,
            typed.staleAfter,
          );
          switch (d) {
            case BuzzDelivery.complete:
              success = true;
            case BuzzDelivery.rejected:
              reason ??= 'deliveryFailed';
            case BuzzDelivery.partial:
            case BuzzDelivery.unknown:
              // The band may have buzzed (or will, when a queued write lands):
              // the claim stays consumed. A lost alert, never a second buzz.
              claimed = false;
              reason = 'deliveryUnconfirmed';
          }
        } else {
          final transport = target == 'phone'
              ? phoneTransport ?? phone
              : bandTransport ??
                  (implicitSequence && sequencePlayer != null
                      ? () => sequencePlayer(saved)
                      : band);
          success = await _within(
            transport,
            limit,
            () {
              claimed = false;
              reason = 'deliveryUnconfirmed';
              return false;
            },
            sourceTime,
            typed.staleAfter,
          );
        }
        if (success) {
          delivered.add(target);
        } else {
          reason ??= 'deliveryFailed';
        }
      } catch (_) {
        reason ??= 'deliveryFailed';
      } finally {
        if (claimed && !success) {
          // A storage failure here must not escape dispatch or skip the next
          // target. The claim then stays consumed (fail closed): a lost alert,
          // never a second buzz.
          try {
            await ledger.release(key);
          } catch (_) {}
        }
      }
    }
    return AlertDeliveryOutcome(delivered, reason);
  }
}

/// Phone ownership is taken inside NotificationCenter.emit, which also carries
/// forward the pre-upgrade fire-once keys. Band ownership uses the same SQLite
/// ledger with a distinct per-target namespace.
class NotificationCenterDeliveryLedger implements AlertDeliveryLedger {
  const NotificationCenterDeliveryLedger();
  @override
  Future<bool> claim(String key) async =>
      (jsonDecode(key) as List).last == 'phone'
      ? true
      : await const DurableAlertDeliveryLedger().claim(key);
  @override
  Future<void> release(String key) async {
    if ((jsonDecode(key) as List).last != 'phone') {
      await const DurableAlertDeliveryLedger().release(key);
    }
  }
}
