// circadian_explore_data.dart — reads what the circadian explore screen shows
// from the repository, and runs the fit off the UI isolate.
//
// Sleep windows: the Body clock artifact's own repository calls
// (`circadianNightWindows`); no second sleep segmentation. Heart rate: the
// stored minute curve of each of the last [kExploreHrDays] COMPLETE local days
// (today is partial, so it is left out), binned by local hour.

import 'dart:isolate';

import '../../data/circadian_artifact.dart';
import '../../data/day_label.dart';
import '../../data/local_repository.dart';
import 'hourly_hr_bins.dart';
import 'hr_rhythm_fit.dart';
import 'sleep_timing_summary.dart';

/// Nights read for the sleep timing summary.
const int kExploreNights = 14;

/// Complete local days of heart rate read for the rhythm fit.
const int kExploreHrDays = 14;

class CircadianExploreData {
  const CircadianExploreData({required this.summary, required this.rhythm});
  final SleepTimingSummary summary;
  final HrRhythm rhythm;
}

/// Reads and computes. A repository failure throws; it is never an empty
/// result in disguise. [now] is injectable for tests.
Future<CircadianExploreData> loadCircadianExploreData(
  LocalRepository repo, {
  DateTime? now,
}) async {
  final windows = await circadianNightWindows(repo, nights: kExploreNights);
  final summary = summarise([
    for (final w in windows)
      NightWindow(
        onset: DateTime.fromMillisecondsSinceEpoch(w.onsetTs * 1000),
        offset: DateTime.fromMillisecondsSinceEpoch(w.wakeTs * 1000),
      ),
  ]);

  final today = now ?? DateTime.now();
  final have = (await repo.availableDays()).toSet();
  final bins = <HourlyBin>[];
  for (var back = kExploreHrDays; back >= 1; back--) {
    final day = dayLabelOf(DateTime(today.year, today.month, today.day - back));
    if (!have.contains(day)) continue;
    final heart = await repo.getDayHeart(day);
    final curve = heart['hr'];
    if (curve is List) bins.addAll(hourlyBinsFromHrCurve(curve));
  }

  return CircadianExploreData(summary: summary, rhythm: await _fitOffUi(bins));
}

/// The fit is a few hundred small solves; still off the UI isolate (AGENTS.md
/// section 3.10). A top-level helper, so the closure holds [bins] and nothing
/// else from the caller (a repository is not sendable).
Future<HrRhythm> _fitOffUi(List<HourlyBin> bins) =>
    Isolate.run(() => fitHrRhythm(bins));
