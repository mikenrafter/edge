// wake_trace_text.dart — the persisted wake decision trace, in plain words, for
// the alarm screen's Status section. Pure: no DB, no widgets.
//
// It reports only what the trace holds. No trace, no lines: the screen says
// nothing was recorded rather than guessing what the wake did.

import 'wake_orchestrator.dart';

/// What the latest Natural Wake decision means, by [NaturalReason] name.
String naturalReasonText(String reason) => switch (reason) {
  'fire' => 'it saw the right moment and buzzed the band',
  'off' => 'it is not switched on for this day',
  'upgradePending' =>
    'it is waiting for you to read the Natural Wake '
        'explanation',
  'beforeWindow' => 'it has not started listening yet',
  'windowClosed' => 'its window had already ended',
  'tooSoonAfterOnset' =>
    'you had been asleep for under 45 minutes, so it stayed quiet',
  // Retired reasons: old stored traces still carry them.
  'ineligibleNap' =>
    'this was a nap, and Natural Wake is for your main '
        'sleep only',
  'ineligibleUnknown' =>
    'it could not tell whether this was your main '
        'sleep, so it stayed quiet',
  'acknowledged' => 'you had already said you were up',
  'alreadyFired' => 'it had already buzzed once for this wake',
  'disconnected' => 'the band was not connected to the phone',
  'lateExecution' => 'the phone checked too late to buzz safely',
  'observerFailed' => 'the sleep estimate failed, so it stayed quiet',
  'samplesUnavailable' => 'it could not read the recent band data',
  'abstained' => 'the estimate could not tell what stage you were in',
  'offWrist' => 'the band did not look like it was being worn',
  'missingHr' => 'there was no heart rate data to go on',
  'missingAccel' => 'there was no movement data to go on',
  'lowCoverage' => 'too much recent band data was missing',
  'warmup' => 'it was still gathering the first minutes of data',
  'noEvidence' => 'there was not enough data to estimate a sleep stage',
  'clockRegressed' => 'the band clock went backwards, so it stayed quiet',
  'samplesStale' => 'the newest band data was too old to trust',
  'noRemCandidate' => 'you looked to be in light or deep sleep',
  'remNotStable' => 'a REM or awake stage had not lasted long enough yet',
  'lowConfidence' => 'the REM estimate was not confident enough',
  _ => 'it stayed quiet for a reason this version cannot describe',
};

/// One line per fact the trace records, in a fixed order. Empty for no trace.
List<String> describeWakeTrace(List<WakeTraceEntry> trace) {
  if (trace.isEmpty) return const [];
  final byTime = [...trace]..sort((a, b) => a.atMs.compareTo(b.atMs));
  WakeTraceEntry? last(String kind, {bool Function(WakeTraceEntry)? where}) {
    for (final e in byTime.reversed) {
      if (e.kind == kind && (where == null || where(e))) return e;
    }
    return null;
  }

  final out = <String>[];

  final natural = last('natural');
  if (natural != null) {
    out.add('Natural Wake: ${naturalReasonText('${natural.data['reason']}')}');
  }
  final haptic = last(
    'natural_haptic',
    where: (e) => e.data['phase'] == 'result',
  );
  if (haptic != null) {
    out.add(
      haptic.data['result'] == 'sent'
          ? 'Natural Wake buzzed the band'
          : 'Natural Wake tried to buzz the band, but it was not delivered',
    );
  }

  final steps = byTime.where((e) => e.kind == 'gradual').toList();
  if (steps.isNotEmpty) {
    int n(String result) =>
        steps.where((e) => e.data['result'] == result).length;
    final sent = n('sent');
    final parts = <String>[
      '$sent ${sent == 1 ? 'buzz' : 'buzzes'} sent',
      if (n('skippedLate') > 0)
        '${n('skippedLate')} skipped because they were late',
      if (n('notDelivered') > 0) '${n('notDelivered')} not delivered',
    ];
    out.add('Gradual Wake: ${parts.join(', ')}');
  }

  final fb = last('fallback');
  if (fb != null) {
    final armed = fb.data['armed'];
    final confirmed = fb.data['confirmed'];
    final state = armed == null
        ? 'state unknown'
        : armed != true
        ? 'not armed'
        : confirmed == true
        ? 'armed and confirmed'
        : 'armed, not confirmed yet';
    out.add(
      'Band alarm at wake time: $state'
      '${fb.data['rearmed'] == true ? ' (re-armed by the phone)' : ''}',
    );
  }

  final ack = last('ack');
  if (ack != null) {
    out.add(
      ack.data['cancelled'] == true
          ? 'You said you were up. The band alarm was cancelled'
          : 'You said you were up. The band alarm stays armed',
    );
  }

  final skip = last('skip');
  if (skip != null) {
    out.add('A check was skipped because another background sync was running');
  }
  final err = last('error');
  if (err != null) {
    out.add(
      'Something went wrong in "${err.data['where']}". '
      'The band alarm is not affected',
    );
  }
  return out;
}
