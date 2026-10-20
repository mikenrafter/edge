// The staged-sleep cache key leaves the stored sleep history out while it is
// too short to matter. That leans on analytics' threshold; pin it.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/staged_sleep_cache.dart';

void main() {
  test(
    'habitual midsleep prior needs kHabitualMidsleepMinDays distinct days',
    () {
      List<({int startSec, int endSec, String dayKey})> history(int days) => [
        for (var d = 0; d < days; d++)
          (
            startSec: 1700000000 + d * 86400,
            endSec: 1700000000 + d * 86400 + 8 * 3600,
            dayKey: 'd$d',
          ),
      ];
      expect(
        ana.habitualMidsleepSecFromHistory(
          history(kHabitualMidsleepMinDays - 1),
        ),
        isNull,
      );
      expect(
        ana.habitualMidsleepSecFromHistory(history(kHabitualMidsleepMinDays)),
        isNotNull,
      );
    },
  );
}
