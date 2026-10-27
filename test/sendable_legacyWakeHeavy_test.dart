// ignore_for_file: file_names
import 'dart:convert';
import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/util/worker_init.dart';
import 'package:openstrap_edge/wake/legacy_smart_wake.dart';
import 'package:openstrap_edge/wake/wake_confounders.dart';

void main() {
  test(
    'primitive rows cross the production worker with historical fallback',
    () async {
      const now = 12 * 3600000;
      final rows = [
        for (var s = 0; s < 300; s++)
          <String, Object?>{
            'rec_ts': now ~/ 1000 - 300 + s,
            'hr': 54,
            'ax': 0.0,
            'ay': 0.0,
            'az': 1.0,
          },
      ];
      final nights = <Map<String, Object?>>[
        {
          'finalized': 1,
          'partial': 0,
          'skipped': 0,
          'payload_json': jsonEncode({
            'scalars': {'hr_min_night': 50},
          }),
          'window_json': jsonEncode({
            'value': {'onset_ms': -10 * 3600000, 'offset_ms': 0},
          }),
        },
      ];
      const worker = WorkerInputs(
        nowEpochMs: now,
        zoneId: 'UTC',
        localeTag: 'en',
      );
      final input = LegacyWakeInput(
        worker,
        now + 600000,
        rows,
        nights,
        const ConfounderProfile(),
        now - 3 * 3600000,
      );
      expect(await Isolate.run(() => legacyWakeHeavy(input)), isTrue);
      final veto = LegacyWakeInput(
        worker,
        now + 600000,
        rows,
        nights,
        const ConfounderProfile(alcohol: true, stress: true),
        now - 3 * 3600000,
      );
      expect(await Isolate.run(() => legacyWakeHeavy(veto)), isFalse);
    },
  );
}
