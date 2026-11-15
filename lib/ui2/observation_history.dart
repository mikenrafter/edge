// Presentation of stored observations. No detector runs here.
import '../compute/findings.dart';
import '../data/pulse_episode_store.dart';

sealed class ObservationEntry {
  const ObservationEntry();
  String get day;
  FindingKind get kind;
  bool occursOn(String day);
}

final class DailyObservation extends ObservationEntry {
  const DailyObservation(this.finding);
  final Finding finding;
  @override
  String get day => finding.date;
  @override
  FindingKind get kind => finding.kind;
  @override
  bool occursOn(String day) => this.day == day;
}

final class PulseObservation extends ObservationEntry {
  const PulseObservation(this.episode);
  final PulseEpisodeSnapshot episode;
  @override
  String get day => episode.row['day'] as String;
  String get endDay => episode.row['end_day'] as String? ?? day;
  @override
  FindingKind get kind => FindingKind.irregularRhythm;
  @override
  bool occursOn(String day) =>
      day.compareTo(this.day) >= 0 && day.compareTo(endDay) <= 0;
}

// CLAIM(observations-once): an episode replaces only covered daily pulse flags;
// other detectors and uncovered flags survive [observations_pilot_feedback_test].
// CLAIM(observations-newest): both surfaces share newest-first ordering. On the
// same date, prefer a timed recording to a daily flag [same test].
List<ObservationEntry> observationHistory(
  List<Finding> findings,
  List<PulseEpisodeSnapshot> episodes,
) {
  final pulse = {
    for (final episode in episodes) episode.id: PulseObservation(episode),
  }.values.toList();
  final daily = <String, DailyObservation>{
    for (final finding in findings)
      if (finding.kind != FindingKind.irregularRhythm ||
          !pulse.any((entry) => entry.occursOn(finding.date)))
        '${finding.date}:${finding.kind.name}': DailyObservation(finding),
  };
  return <ObservationEntry>[...daily.values, ...pulse]..sort((a, b) {
    final date = b.day.compareTo(a.day);
    if (date != 0) return date;
    if (a is PulseObservation && b is PulseObservation) {
      final time = b.episode.startMs.compareTo(a.episode.startMs);
      return time != 0 ? time : b.episode.id.compareTo(a.episode.id);
    }
    if (a is PulseObservation) return -1;
    if (b is PulseObservation) return 1;
    return a.kind.index.compareTo(b.kind.index);
  });
}
