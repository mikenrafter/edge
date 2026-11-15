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

  /// A pass claimed the day and is presenting it right now. Never shown, never
  /// owed: this row IS the claim that keeps another pass from naming the day.
  pending,

  /// A claim was left behind (the process died between claiming and recording).
  /// The alert may or may not have reached the screen; it is never sent again.
  unknown,

  /// The build before this one alerted for the day. Carried over by the
  /// schema 87 step so the first summary leaves it out.
  earlier,
}

/// Why nothing was sent.
enum PulseAlertReason {
  /// The wearer's notification settings (health alerts, phone delivery, quiet
  /// hours) did not allow it.
  off,

  /// Quiet hours held it and the critical override is off.
  quiet,

  /// Settings allowed it, but the OS refused or the present failed.
  blocked,
}

/// One row of `pulse_alert`.
class PulseAlertRecord {
  const PulseAlertRecord(this.state, this.atMs, {this.reason});

  final PulseAlertState state;
  final PulseAlertReason? reason;

  /// [atMs] as a local time.
  DateTime get at => DateTime.fromMillisecondsSinceEpoch(atMs);

  /// Epoch ms the notification was shown, or the attempt that failed.
  final int atMs;

  static const _stateNames = {
    PulseAlertState.sent: 'sent',
    PulseAlertState.summary: 'summary',
    PulseAlertState.notSent: 'not_sent',
    PulseAlertState.pending: 'pending',
    PulseAlertState.unknown: 'unknown',
    PulseAlertState.earlier: 'earlier',
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

  /// The small text under a flagged day, in [l]'s language, or null when there
  /// is nothing to say yet (a claim in flight). [time] is the time of day in the
  /// app's own 12/24 h format (see [at]); the default is the locale's 24 h time.
  String? note(AppLocalizations l, {String? time}) {
    final when = localizedDateTime(at, l.localeName, time: time);
    return switch (state) {
      PulseAlertState.sent => l.pulseAlertSent(when),
      PulseAlertState.summary => l.pulseAlertInSummary(when),
      PulseAlertState.unknown => l.pulseAlertUnknown(when),
      PulseAlertState.earlier => l.pulseAlertEarlier(when),
      PulseAlertState.pending => null,
      PulseAlertState.notSent => switch (reason) {
        PulseAlertReason.blocked => l.pulseAlertNotPermitted,
        PulseAlertReason.quiet => l.pulseAlertQuiet,
        _ => l.pulseAlertOff,
      },
    };
  }
}
