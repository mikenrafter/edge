// edge_groups.dart — edge's registry entries and the key-ownership maps
// (design 06 phase 1a; the analytics groups come from
// `kAnalyticsGroupRegistry` since 1b). Nothing at runtime reads this yet.
//
// The ownership maps are checked against real derives by
// test/groups/group_key_ownership_test.dart: a key a derive writes with no
// owner fails, and an owner entry no derive could produce fails.

import 'group_types.dart';

/// Edge-side groups: the steps edge owns around analytics results.
const List<GroupDecl> kEdgeGroups = <GroupDecl>[
  GroupDecl(
    id: 'edge.assembly',
    kind: GroupKind.edgeTransform,
    counter: 1,
    members: ['deriveDayBundle'],
    files: ['lib/compute/onehz_pipeline.dart'],
  ),
  GroupDecl(
    id: 'edge.series_shaping',
    kind: GroupKind.edgeTransform,
    counter: 1,
    members: ['seriesMethodFor'],
    files: ['lib/compute/inputs/canonical.dart'],
  ),
  GroupDecl(
    id: 'edge.gates_overrides',
    kind: GroupKind.edgeTransform,
    counter: 1,
    members: ['blankNightInBundle'],
    files: ['lib/compute/sleep_blank.dart'],
  ),
  GroupDecl(
    id: 'day.checkpoint',
    kind: GroupKind.edgeTransform,
    counter: 1,
    members: ['foldDayCheckpoint'],
    deps: ['found.calibration'],
    files: ['lib/compute/day_checkpoint_fold.dart'],
  ),
];

/// Members whose per-day cost is not yet measured (the heavy cost test fills
/// them in). A ratchet list: it may only shrink. Holds the three edge
/// entries; the placeholder analytics groups with unmeasured cost are
/// recorded one level up in [kGroupUnknownCostGroups] so this list does not
/// grow before 1b.
const List<String> kGroupUnknownCostMembers = <String>[
  'deriveDayBundle',
  'seriesMethodFor',
  'blankNightInBundle',
];

/// Placeholder groups whose members' costs are not in the measured profile
/// (plan section 4). Dropped in 1b when analytics declares real members and
/// the heavy cost test measures them.
const List<String> kGroupUnknownCostGroups = <String>[
  'readiness.stress_illness',
  'activity.load',
  'body.spo2_temp_coverage',
];

/// Top-level day-bundle key -> owning group id. Includes the keys in
/// [kConditionalKeys].
const Map<String, String> kBundleKeyOwner = <String, String>{
  'sleep': 'sleep.stage',
  'advanced_sleep': 'sleep.stage',
  'restlessness': 'sleep.stage',
  'restlessness_map': 'sleep.stage',
  'hr_sleep_window': 'sleep.stage',
  'wrist_orientation': 'sleep.stage',
  'hrv_night_shape': 'hrv.freq',
  'respiration': 'night.rhythm',
  'naps': 'day.blocks',
  'sleep_periods': 'day.blocks',
  'workout_suggestions': 'day.blocks',
  'daytime_hrv': 'day.blocks',
  'series': 'day.checkpoint',
  'clinical': 'readiness.stress_illness',
  'baselines': 'readiness.stress_illness',
  'stress': 'readiness.stress_illness',
  'readiness_absent_diag': 'readiness.stress_illness',
  'activity': 'activity.load',
  'activity_curve': 'activity.load',
  'calories': 'activity.load',
  'calories_total': 'activity.load',
  'movement': 'activity.load',
  'steps': 'activity.load',
  'zones': 'activity.load',
  'zone_lower_bpm': 'activity.load',
  'zone_max_hr': 'activity.load',
  'zone_source': 'activity.load',
  'max_hr_used': 'activity.load',
  'hr_stats': 'activity.load',
  'hr_ceiling': 'activity.load',
  'spo2': 'body.spo2_temp_coverage',
  'wellness': 'body.spo2_temp_coverage',
  'coverage': 'body.spo2_temp_coverage',
  'wear': 'body.spo2_temp_coverage',
  'absent_notes': 'edge.assembly',
  'scalars': 'edge.assembly',
  'date': 'edge.assembly',
  'data_edge_sec': 'edge.assembly',
  'device_family': 'edge.assembly',
  'day_confidence': 'edge.assembly',
  'flags': 'edge.assembly',
  'ring_day': 'edge.assembly',
  'sleep_source': 'edge.gates_overrides',
  'sleep_charging': 'edge.gates_overrides',
};

/// `metric_series` key -> owning group id.
const Map<String, String> kSeriesKeyOwner = <String, String>{
  'deep_min': 'sleep.stage',
  'light_min': 'sleep.stage',
  'rem_min': 'sleep.stage',
  'tst_min': 'sleep.stage',
  'efficiency': 'sleep.stage',
  'awakenings': 'sleep.stage',
  'longest_sleep_min': 'sleep.stage',
  'sol_min': 'sleep.stage',
  'unobserved_min': 'sleep.stage',
  'midsleep_sec': 'sleep.stage',
  'sleep_onset_sec': 'sleep.stage',
  'lf_hf': 'hrv.freq',
  'hrv_cv': 'hrv.freq',
  'resp_rate': 'night.rhythm',
  'prsa_dc': 'night.rhythm',
  'irregular_rhythm_flag': 'night.rhythm',
  'brv_cv': 'night.rhythm',
  'readiness': 'readiness.stress_illness',
  'readiness_z': 'readiness.stress_illness',
  'rhr': 'readiness.stress_illness',
  'rmssd': 'readiness.stress_illness',
  'sdnn': 'readiness.stress_illness',
  'ln_rmssd': 'readiness.stress_illness',
  'stress': 'readiness.stress_illness',
  'strain': 'activity.load',
  'trimp': 'activity.load',
  'trimp_net': 'activity.load',
  'quiet_hrr': 'activity.load',
  'calories': 'activity.load',
  'calories_total': 'activity.load',
  'steps': 'activity.load',
  'active_min': 'activity.load',
  'dyn_p90': 'activity.load',
  'hr_ceiling_bpm': 'activity.load',
  'nap_min': 'day.blocks',
  'hrr_bpm': 'day.blocks',
  'hrr_tau_s': 'day.blocks',
  'skin_temp_adc': 'body.spo2_temp_coverage',
  'skin_temp_z': 'body.spo2_temp_coverage',
  'skin_temp_coverage_frac': 'body.spo2_temp_coverage',
  'worn_min': 'body.spo2_temp_coverage',
  'dip_pct': 'body.spo2_temp_coverage',
};

/// Bundle keys a derive writes only under a condition the test fixtures may
/// not meet, with that condition (keeps the "no phantom key" check honest).
const Map<String, String> kConditionalKeys = <String, String>{
  'calories_total':
      'wake-day energy block: needs the full wakeDayEnergy inputs (basal + active + profile); the test fixtures do not meet them',
  'movement':
      'ENMO movement minutes: abstains until the personal g floor freezes (about day 5)',
  'wrist_orientation':
      'sleep-window accel positions: needs at least 60 accel epochs in the window',
  'ring_day':
      'Ultrahuman ring day block only; never on a band or other wearable day',
};
