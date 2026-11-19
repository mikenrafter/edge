// Display projection only; the detectors and episode store own their findings.
import '../compute/findings.dart';
import '../data/pulse_ep/pulse_ep_summary.dart';

sealed class ObservationEntry {
  const ObservationEntry();
  String get day;
  FindingKind get kind;
  bool occursOn(String day);
}
final class DailyObservation extends ObservationEntry {
  const DailyObservation(this.finding);
  final Finding finding;
  @override String get day => finding.date;
  @override FindingKind get kind => finding.kind;
  @override bool occursOn(String day) => this.day == day;
}
final class PulseObservation extends ObservationEntry {
  const PulseObservation(this.episode);
  final PulseEpisodeSummary episode;
  @override String get day => episode.day;
  @override FindingKind get kind => FindingKind.irregularRhythm;
  @override bool occursOn(String day) => episode.occursOn(day);
}
List<ObservationEntry> observationHistory(List<Finding> findings,
    List<PulseEpisodeSummary> episodes) {
  final pulse = {for (final e in episodes) e.id: PulseObservation(e)}.values.toList();
  final daily = {for (final f in findings.reversed)
    if (f.kind != FindingKind.irregularRhythm || !pulse.any((e) => e.occursOn(f.date)))
      '${f.date}:${f.kind.name}': DailyObservation(f)};
  return <ObservationEntry>[...daily.values, ...pulse]..sort((a,b) {
    final date = b.day.compareTo(a.day);
    if (date != 0) return date;
    if (a is PulseObservation && b is PulseObservation) return b.episode.startMs.compareTo(a.episode.startMs);
    if (a is PulseObservation) return -1;
    if (b is PulseObservation) return 1;
    return a.kind.index.compareTo(b.kind.index);
  });
}
