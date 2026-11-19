// Owner: the Pulse episode store's typed vocabulary (pulse_ep_*). Every stored
// state string parses here once; an unknown string is `unknown`, never owed.

/// Delivery state of one episode's alert debt (`pulse_ep_outbox.state`).
///
/// CLAIM(pulse-claim): a state that may already have reached the user is
/// consumed and is never replayed; `owed`, `held` and `notSent` are the only
/// states a later pass may still deliver.
enum PulseDelivery {
  owed('owed'),
  held('held'),
  notSent('not_sent'),
  pending('pending'),
  unknown('unknown'),
  sent('sent'),
  summary('summary'),
  beforeVersion('before_version'),
  deleted('deleted');

  const PulseDelivery(this.wire);
  final String wire;

  /// A stored string that names no state is [unknown]: never owed, never sent.
  static PulseDelivery parse(Object? raw) {
    for (final d in values) {
      if (d.wire == raw) return d;
    }
    return unknown;
  }

  /// May already have reached the user (or was deliberately closed): no
  /// automatic replay, whatever the episode does afterwards.
  bool get consumed => switch (this) {
    pending || unknown || sent || summary || beforeVersion || deleted => true,
    owed || held || notSent => false,
  };
}

/// Where an episode's evidence stands (`pulse_ep_revision.evidence_status`).
enum PulseEvidenceStatus {
  available('available'),
  partial('partial'),
  expired('expired'),
  omitted('omitted'),
  corrupt('corrupt'),
  unsupported('unsupported');

  const PulseEvidenceStatus(this.wire);
  final String wire;
  static PulseEvidenceStatus? tryParse(Object? raw) {
    for (final s in values) {
      if (s.wire == raw) return s;
    }
    return null;
  }
}

/// Result of a store mutation. Nothing returns a bare bool.
sealed class PulseApply {
  const PulseApply();
}

final class PulseApplied extends PulseApply {
  const PulseApplied(this.episodeId, this.revision, {required this.created});
  final String episodeId;
  final int revision;
  final bool created;
}

final class PulseUnchanged extends PulseApply {
  const PulseUnchanged(this.episodeId);
  final String episodeId;
}

final class PulseRefused extends PulseApply {
  const PulseRefused(this.reason);
  final String reason;
}

final class PulseFailed extends PulseApply {
  const PulseFailed(this.error);
  final Object error;
}

/// A half-open `[startMs, endMs)` range of epoch milliseconds.
class PulseRange {
  const PulseRange(this.startMs, this.endMs, [this.reason = 'omitted'])
    : assert(startMs <= endMs);
  final int startMs, endMs;
  final String reason;
  @override
  bool operator ==(Object other) =>
      other is PulseRange &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.reason == reason;
  @override
  int get hashCode => Object.hash(startMs, endMs, reason);
  @override
  String toString() => 'PulseRange($startMs, $endMs, $reason)';
}

/// Compact per-window novelty proof from the checked snapshot. The comparison
/// reruns the same detector on captured record identities, including interiors.
class PulseWindowSupport {
  const PulseWindowSupport({required this.startMs, required this.endMs,
      required this.qualified, required this.preUpgradeQualified, required this.novelRecords});
  final int startMs, endMs, novelRecords;
  final bool qualified, preUpgradeQualified;
  bool get newlyQualifies => qualified && !preUpgradeQualified && novelRecords > 0;
  Map<String, Object?> toJson() => {
    'start': startMs, 'end': endMs, 'qualified': qualified,
    'preUpgradeQualified': preUpgradeQualified, 'novelRecords': novelRecords,
  };
}
