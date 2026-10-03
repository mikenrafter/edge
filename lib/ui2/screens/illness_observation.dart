// The illness-watch card, written once for Home and for Health.
//
// Home and Health each used to build their own copy of this card, and the two
// drifted: different advice, different body text, a different way to say which
// night. One screen told the user to "check in with a doctor" and the other to
// "make a note of it" about the same finding. Both call this now, so the words
// cannot differ (AGENTS.md 4.10).

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'home_screen.dart' show prettyDay;

/// The card for the CUSUM watch, or null when there is nothing to say.
///
/// Null on green and on no state at all: "you are not getting sick" is not an
/// observation worth a slot. The watch runs on nocturnal resting heart rate
/// alone, so the copy names that one signal and says it cannot give a cause.
///
/// [sameNight] is whether the flagged night is last night; when it is not, the
/// title names the night by its date. [z] is the latest night's own deviation
/// from the baseline. The accumulator only clears after two nights back under,
/// so the stored z can be negative while the run is still up, and the body says
/// which side it was on rather than calling it "above" regardless.
Observation? illnessObservation(
  BuildContext c, {
  required String? state,
  required bool sameNight,
  String? day,
  num? z,
  VoidCallback? onTap,
}) {
  if (state == null || state == 'green') return null;
  final l = AppLocalizations.of(c);
  return Observation(
    state == 'red'
        ? (l?.healthIllnessRedTitle ??
            'Several nights in a row were outside your normal range')
        : sameNight
            ? (l?.healthIllnessLastNightTitle ??
                'Last night was outside your normal range')
            : (l?.healthIllnessDayTitle(prettyDay(day, l)) ??
                '${prettyDay(day, l)} was outside your normal range'),
    z == null
        ? (l?.healthIllnessBodyNoZ ??
            'Your overnight resting heart rate has been above your own '
                'baseline. This check uses that one signal and cannot '
                'identify a cause.')
        : (l?.healthIllnessBodyWithZ(
                z.abs().toStringAsFixed(1),
                z >= 0 ? l.healthDirectionAbove : l.healthDirectionBelow) ??
            'Your overnight resting heart rate has been above your own '
                'baseline. That night was ${z.abs().toStringAsFixed(1)} '
                'standard deviations ${z >= 0 ? 'above' : 'below'} your '
                'baseline. This check uses that one signal and cannot '
                'identify a cause.'),
    advice: l?.healthIllnessAdvice ??
        'If it continues past a couple of days, make a note of it.',
    onTap: onTap,
  );
}
