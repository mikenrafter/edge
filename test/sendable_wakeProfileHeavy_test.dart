// ignore_for_file: file_names
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:openstrap_edge/wake/wake_night_context_db.dart';

void main() {
  test(
    'dated journal maps cross the profile worker including midnight',
    () async {
      final input = WakeProfileInput(
        [
          {'date': '2026-10-25', 'tags_json': '["stress","sick","late meal"]'},
        ],
        [
          {
            'date': '2026-10-25',
            'field': 'alcohol_units',
            'value': 2,
            'at_min': 23 * 60,
          },
        ],
        DateTime(2026, 10, 26, 1).millisecondsSinceEpoch,
        const WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en'),
      );
      final result = await Isolate.run(() => wakeProfileHeavy(input));
      expect(result.hrArousalBpm, 6);
      expect(result.motionCeilingG, .06);
      expect(result.trendThresholdFactor, .75);
      expect(result.disableEarlyDelivery, isTrue);
    },
  );
}
