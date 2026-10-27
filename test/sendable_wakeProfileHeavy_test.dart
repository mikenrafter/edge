// ignore_for_file: file_names
import 'dart:convert';
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
  test(
    'user identity sets and adjustment labels cross the actual worker',
    () async {
      final bed = DateTime(2026, 10, 26, 22);
      final input = WakeProfileInput(
        [],
        [],
        bed.millisecondsSinceEpoch,
        const WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en'),
        definitions: [
          {
            'id': 'reading',
            'payload_json': jsonEncode({
              'id': 'reading',
              'name': 'Reading',
              'kind': 'activity',
              'roles': ['own_sleep'],
              'systems': ['sleep'],
              'enabled': true,
            }),
          },
        ],
        events: [
          {
            'id': 'r',
            'track_id': 'reading',
            'date': '2026-10-26',
            'at_ms': bed
                .subtract(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          },
        ],
      );
      final result = await Isolate.run(() => wakeProfileHeavy(input));
      expect(result.userTrackIds, {'reading'});
      expect(result.adjustedFor, {'Reading 1 h before bed'});
      expect(result.hrArousalBpm, 4);
    },
  );
  // WHY S2: a caffeine journal aggregate raised hrArousalBpm even after the
  // user disabled the caffeine track or removed its sleep system/role.
  // proves: CLAIM(preset-gate)
  for (final edit in <String, Map<String, Object?>>{
    'disabled': {'enabled': false},
    'no sleep system': {'systems': <String>[]},
    'no own_sleep role': {'roles': <String>[]},
    'untouched (control)': <String, Object?>{},
  }.entries) {
    test('caffeine journal aggregate respects edited track: ${edit.key}', () async {
      final control = edit.value.isEmpty;
      final input = WakeProfileInput(
        [],
        [
          {
            'date': '2026-10-26',
            'field': 'caffeine_mg',
            'value': 300,
            'at_min': 20 * 60,
          },
        ],
        DateTime(2026, 10, 26, 22).millisecondsSinceEpoch,
        const WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en'),
        definitions: [
          {
            'id': 'caffeine',
            'payload_json': jsonEncode({
              'id': 'caffeine',
              'name': 'Caffeine',
              'kind': 'consumed',
              'roles': ['own_sleep'],
              'systems': ['sleep'],
              'enabled': true,
              ...edit.value,
            }),
          },
        ],
      );
      final result = await Isolate.run(() => wakeProfileHeavy(input));
      expect(result.caffeine, control);
      expect(result.hrArousalBpm, control ? 6 : 4);
    });
  }
}
