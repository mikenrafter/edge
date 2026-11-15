// Read-only projection of existing daily flags. A date marker is not an episode time.
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../theme.dart';
import '../../compute/findings.dart';
import '../../data/local_repository.dart';
import '../chart_annotations.dart';

Future<List<ChartAnnotation>> loadRhrAnnotations(LocalRepository repo) async {
  try { return rhrChangeAnnotations(findingsHistory(await repo.getInsights())); }
  catch (_) { return const []; }
}

// A daily flag has no timestamp. Keep it outside all time-of-day axes.
class DayRhrNotice extends StatelessWidget {
  const DayRhrNotice(this.marks, this.day, {super.key});
  final List<ChartAnnotation> marks;
  final String? day;
  @override
  Widget build(BuildContext context) {
    final flag = marks.where((a) => a.id == 'rhr-shift:$day').firstOrNull;
    if (flag == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('en'));
    return Padding(key: ValueKey('day-rhr-flag:$day'), padding: const EdgeInsets.only(top: S.x3),
      child: Text(flag.localized(l).label, style: F.cap.copyWith(color: P.of(context).ink2)));
  }
}
