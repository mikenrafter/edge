import 'package:openstrap_edge/compute/crossday_artifact_worker.dart';
import 'package:openstrap_edge/util/worker_init.dart';

CrossDayArtifactInput crossDayArtifactFixture() => CrossDayArtifactInput(
    const WorkerInputs(nowEpochMs: 1792713600000, zoneId: 'UTC', localeTag: 'en'),
    [for (var i = 1; i <= 14; i++) <String, dynamic>{
      'date': '2026-10-${i.toString().padLeft(2, '0')}',
      'rhr': 50.0 + i % 3, 'rmssd': 45.0 + i % 4,
      'trimp': 20.0, 'tst_min': 420.0,
    }],
    const {'age_years': 32, 'weight_kg': 70.0},
    const ['2026-10-01'], const {'2026-10-14': ['running']},
    const {'whoop_gen4': 'cardio'}, 125, '2026-10-15', 1792713600,
    'UTC|0|0|0', 'fixture-signature');
