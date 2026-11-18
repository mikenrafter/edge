import 'dart:async';
import 'dart:convert';

import '../data/db.dart';
import '../haptics/band_queue.dart' show BandHold, kBandHoldKey, kAlertHandoffKey;
import 'alert_rule.dart';
import 'alert_policy.dart';
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
    this.policy,
    this.fallbackDestination,
    this.latestRule,
  }) : now = now ?? DateTime.now;

  final Future<bool> Function(AlertRule, String)? policy;
  final Future<String> Function()? fallbackDestination;
  final Future<AlertRule> Function(AlertRule)? latestRule;
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

  /// How long a band delivery may wait in the band queue before it starts.
  /// Added to every band deadline, so the transport still has its own
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
    // The rule's own [AlertRule.fallback] decides whether anything covers an
    // unavailable destination: phoneIfBandUnavailable chooses the phone and
    // none chooses nothing. Otherwise the global [fallbackDestination] decides.
    // Session cues never take alert fallback. The relay turns this on because
    // fallback is a per-channel user switch.
    bool ruleDecidesFallback = false,
    // Set only by the retry below: the band already refused this event, so it
    // counts as unavailable even though it is still connected.
    bool bandRefusedThisEvent = false,
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
    final selected = <String>{
      if ((typed.destinations & 1) != 0) 'phone',
      if ((typed.destinations & 2) != 0) 'band',
    };
    String? reason;
    String? unavailable(String target, [AlertRule? rule]) {
      if (transportTargets != null && !transportTargets.contains(target)) {
        return 'transportUnavailable';
      }
      if (target == 'band' && (bandRefusedThisEvent || !isConnected())) {
        return 'bandUnavailable';
      }
      return AlertCapabilityRegistry.destinationSupportReason(rule ?? typed, target,
        supportedTargets: currentSupportedTargets,
        supportedBandModes: supportedBandModes,
        supportedPhoneModes: supportedPhoneModes);
    }
    Future<String?> configuredFallback() async {
      // Session cues are skipped deliberately when they cannot play now.
      if (AlertPolicy.isSessionCue(typed)) return null;
      if (ruleDecidesFallback) {
        return typed.fallback == AlertFallback.phoneIfBandUnavailable
            ? 'phone' : null;
      }
      return await fallbackDestination?.call() ??
          (typed.fallback == AlertFallback.phoneIfBandUnavailable ? 'phone' : null);
    }
    final lost = selected.where((t) => unavailable(t) != null).toList();
    for (final target in lost) {
      reason ??= unavailable(target);
      selected.remove(target);
    }
    if (lost.isNotEmpty) {
      final fallback = await configuredFallback();
      if (fallback != null && unavailable(fallback) == null) selected.add(fallback);
    }
    final delivered = <String>[];
    var bandRefused = false;
    // Separate claims keep a denied phone permission from consuming band output.
    for (final target in selected) {
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
        // The durable claim awaits storage; policy may change while it waits.
        // Refuse immediately before transport, and release this unused claim.
        if (targetAllowed != null && !targetAllowed(target)) {
          reason ??= 'channelSuppressed';
          continue;
        }

        Future<bool> permit() async {
          if (unavailable(target) != null) return false;
          final current = await latestRule?.call(typed) ?? typed;
          if (!current.enabled || current.destinations == 0 ||
              unavailable(target, current) != null) {
            return false;
          }
          final selectedNow = target == 'phone' ? current.phoneSelected : current.bandSelected;
          if (!selectedNow) {
            final fallback = await configuredFallback();
            final primaryAvailable =
                (current.phoneSelected && unavailable('phone', current) == null) ||
                (current.bandSelected && unavailable('band', current) == null);
            if (fallback != target || primaryAvailable) return false;
          }
          if (!(await policy?.call(current, target) ?? true)) return false;
          final allowed = targetAllowed;
          return unavailable(target, current) == null &&
              (allowed == null || [target].every(allowed));
        }
        if (!await permit()) {
          if (target == 'band' && unavailable(target) != null) bandRefused = true;
          reason ??= unavailable(target) ?? 'channelSuppressed';
          continue;
        }
        Future<T> guarded<T>(Future<T> Function() work) => runZoned(work,
          zoneValues: <Object?, Object?>{kAlertHandoffKey: permit});

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
            () => guarded(delivery),
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
              bandRefused = true;
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
            () => guarded(transport),
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
    if (delivered.isEmpty && bandRefused) {
      final fallback = await configuredFallback();
      if (fallback != null && !selected.contains(fallback) && unavailable(fallback) == null) {
        final retry = await dispatch(typed.copyWith(destinations: fallback == 'phone' ? 1 : 2),
          eventId: eventId, sourceTime: sourceTime, historical: historical,
          phoneTransport: phoneTransport, bandTransport: bandTransport,
          bandDelivery: bandDelivery, transportTargets: transportTargets,
          targetAllowed: targetAllowed, bandTimeout: bandTimeout,
          ruleDecidesFallback: ruleDecidesFallback, bandRefusedThisEvent: true);
        return retry.targets.isNotEmpty ? retry
            : AlertDeliveryOutcome(retry.targets, reason ?? retry.suppressionReason);
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
