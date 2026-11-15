// Owner: the durable per-day record of what happened to an irregular-pulse
// flag's alert. Display only: nothing here decides whether a flag exists.
import '../l10n/app_localizations.dart';
import '../l10n/date_text.dart';

/// What became of a flagged day's alert.
enum PulseAlertState {
  /// Its own notification reached the OS.
  sent,

  /// It was named in a summary notification that reached the OS.
  summary,

  /// Nothing reached the OS; see [PulseAlertRecord.reason]. A day in this state
  /// is announced in the next summary that can be delivered.
  notSent,
}

/// Why nothing was sent.
enum PulseAlertReason {
  /// The wearer's notification settings (health alerts, phone delivery, quiet
  /// hours) did not allow it.
  off,

  /// Settings allowed it, but the OS refused or the present failed.
  blocked,
}

/// One row of `pulse_alert`.
class PulseAlertRecord {
  const PulseAlertRecord(this.state, this.atMs, {this.reason});

  final PulseAlertState state;
  final PulseAlertReason? reason;

  /// Epoch ms the notification was shown, or the attempt that failed.
  final int atMs;

  static const _stateNames = {
    PulseAlertState.sent: 'sent',
    PulseAlertState.summary: 'summary',
    PulseAlertState.notSent: 'not_sent',
  };
  static String stateName(PulseAlertState s) => _stateNames[s]!;
  static String? reasonName(PulseAlertReason? r) => r?.name;

  static PulseAlertRecord? fromRow(Map<String, Object?> row) {
    final state = _stateNames.entries
        .where((e) => e.value == row['state'])
        .map((e) => e.key)
        .firstOrNull;
    if (state == null) return null;
    final reason = PulseAlertReason.values
        .where((r) => r.name == row['reason'])
        .firstOrNull;
    return PulseAlertRecord(state, (row['at_ms'] as num).toInt(), reason: reason);
  }

  /// The small text under a flagged day, in [l]'s language.
  String note(AppLocalizations l) {
    final when = localizedDateTime(
      DateTime.fromMillisecondsSinceEpoch(atMs),
      l.localeName,
    );
    return switch (state) {
      PulseAlertState.sent => l.pulseAlertSent(when),
      PulseAlertState.summary => l.pulseAlertInSummary(when),
      PulseAlertState.notSent => reason == PulseAlertReason.blocked
          ? l.pulseAlertNotPermitted
          : l.pulseAlertOff,
    };
  }
}
