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
    'user identity sets cross the actual worker; labels need learned parameters',
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
      // WHY S12: a first-ever log is observed context (identity thresholds), not
      // an adjustment, so no "Adjusted for" label until learned parameters exist.
      // proves: CLAIM(adjusted-only-if-learned)
      expect(result.adjustedFor, isEmpty);
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

  test('a track is labelled adjusted only once learned parameters apply', () async {
    final bed = DateTime(2026, 10, 26, 22);
    WakeProfileInput input(List<Map<String, Object?>> learned) => WakeProfileInput(
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
          'at_ms': bed.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
        },
      ],
      userParameters: learned,
    );
    Map<String, Object?> row(num offset, num lead) => {
      'key': 'natural_wake_user_reading',
      'value': jsonEncode({
        'triggerRunOffsetSec': offset,
        'windowLeadMinutes': lead,
      }),
    };
    final zero = await Isolate.run(() => wakeProfileHeavy(input([row(0, 0)])));
    expect(zero.adjustedFor, isEmpty);
    final learnedProfile = await Isolate.run(
      () => wakeProfileHeavy(input([row(-15, 1)])),
    );
    expect(learnedProfile.userTrackIds, {'reading'});
    expect(learnedProfile.adjustedFor, {'Reading 1 h before bed'});
  });

  // WHY R2-9: disabling illness (or removing its sleep role/system) still let a
  // "sick" journal tag raise HR and tighten motion; late meal and workout
  // likewise. proves: CLAIM(preset-gate)
  for (final (tag, trackId, edit) in <(String, String, Map<String, Object?>)>[
    ('sick', 'illness', {'enabled': false}),
    ('late meal', 'late_meal', {'systems': <String>[]}),
    ('workout', 'late_workout', {'roles': <String>[]}),
  ]) {
    test('journal tag "$tag" respects the edited $trackId track', () async {
      WakeProfileInput input(Map<String, Object?> change) => WakeProfileInput(
        [
          {'date': '2026-10-26', 'tags_json': jsonEncode([tag, 'stress'])},
        ],
        [],
        DateTime(2026, 10, 26, 22).millisecondsSinceEpoch,
        const WorkerInputs(nowEpochMs: 0, zoneId: 'UTC', localeTag: 'en'),
        definitions: [
          {
            'id': trackId,
            'payload_json': jsonEncode({
              'id': trackId,
              'name': trackId,
              'kind': 'activity',
              'roles': ['own_sleep'],
              'systems': ['sleep'],
              'enabled': true,
              ...change,
            }),
          },
        ],
      );
      final control = await Isolate.run(() => wakeProfileHeavy(input({})));
      final edited = await Isolate.run(() => wakeProfileHeavy(input(edit)));
      // Control: the tag takes effect through the unedited preset.
      final flag = {
        'sick': control.sick,
        'late meal': control.lateMeal,
        'workout': control.workout,
      }[tag]!;
      expect(flag, isTrue);
      expect(
        {'sick': edited.sick, 'late meal': edited.lateMeal, 'workout': edited.workout}[tag],
        isFalse,
      );
      // An ungated tag (stress has no preset track) is untouched.
      expect(edited.stress, isTrue);
    });
  }
}
