// Read-only projection of existing daily flags. A date marker is not an episode time.
import '../../compute/findings.dart';
import '../../data/local_repository.dart';
import '../chart_annotations.dart';

Future<List<ChartAnnotation>> loadRhrAnnotations(LocalRepository repo) async {
  try { return rhrChangeAnnotations(findingsHistory(await repo.getInsights())); }
  catch (_) { return const []; }
}

AnnotationSet? rhrAnnotationsForDay(List<ChartAnnotation> marks, String day, double lastSlot) {
  final flags = dailyAnnotations(marks, [day]);
  return flags.isEmpty ? null : AnnotationSet(items: flags, domainStart: 0, domainEnd: lastSlot);
}
