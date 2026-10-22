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
    // Assembles `series`, `clinical` and `scalars` from every group that
    // writes into them (see [kNestedKeyOwner]), so a change to any of those
    // groups changes this one's output.
    deps: [
      'sleep.stage',
      'hrv.freq',
      'night.rhythm',
      'day.blocks',
      'readiness.stress_illness',
      'activity.load',
      'body.spo2_temp_coverage',
      'day.checkpoint',
    ],
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
    // The folded day curves hold the per-window respiration rate
    // (`rsaRespRate`), hence night.rhythm.
    deps: ['found.calibration', 'night.rhythm'],
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
  // `positionSeries` (day.blocks) over the sleep window the sleep group found.
  'wrist_orientation': 'day.blocks',
  'hrv_night_shape': 'hrv.freq',
  'respiration': 'night.rhythm',
  'naps': 'day.blocks',
  'sleep_periods': 'day.blocks',
  'workout_suggestions': 'day.blocks',
  'daytime_hrv': 'day.blocks',
  // Mixed blocks: several groups write nested keys into them. The block is
  // assembled by edge.assembly (which depends on all of them); each nested key
  // has its own owner in [kNestedKeyOwner].
  'series': 'edge.assembly',
  'clinical': 'edge.assembly',
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
  'scalars': 'edge.assembly', // mixed block, see [kNestedKeyOwner]
  'date': 'edge.assembly',
  // Import snapshots (cloud_import, whoop_import) stamp their provenance.
  'imported': 'edge.assembly',
  'source': 'edge.assembly',
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
  'imported':
      'import snapshots only (cloud_import, whoop_import); never on a band derive',
  'source':
      'import snapshots only (cloud_import, whoop_import); never on a band derive',
  'calories_total':
      'wake-day energy block: needs the full wakeDayEnergy inputs (basal + active + profile); the test fixtures do not meet them',
  'movement':
      'ENMO movement minutes: abstains until the personal g floor freezes (about day 5)',
  'wrist_orientation':
      'sleep-window accel positions: needs at least 60 accel epochs in the window',
  'ring_day':
      'Ultrahuman ring day block only; never on a band or other wearable day',
  'series.coverage':
      'only on a day with more than one contributing device (omitted, not {}, on a single-device day)',
  'scalars.active_min':
      'daily active minutes: needs wake-window motion minutes the fixtures do not provide',
  'scalars.dyn_p90':
      'dynamic-acceleration summary: needs wake motion data the fixtures do not provide',
  'scalars.hr_ceiling_bpm':
      'only when the day held an observed heart-rate ceiling',
  'scalars.calories_total':
      'wake-day energy block: needs the full wakeDayEnergy inputs (basal + active + profile)',
  'scalars.steps':
      'only when a step count was measured or estimated for the day',
  'scalars.hrr_bpm': 'only when a workout of the day had a measurable recovery',
  'scalars.hrr_tau_s':
      'only when a workout of the day had a recovery decay that passed the fit gate',
  'scalars.skin_temp_dev_c':
      'WHOOP 5 only; no key on any other device',
  'scalars.skin_temp_ambient_r':
      'only when skin temperature is present and enough minutes exist for the ambient check',
};

/// Top-level blocks several groups write into; owned by edge.assembly, with
/// per-key owners in [kNestedKeyOwner].
const List<String> kMixedBlocks = <String>['series', 'clinical', 'scalars'];

/// Nested key path (`block.key`) -> owning group id, for [kMixedBlocks]. The
/// owner is the group whose function computes the value, so a change to it
/// reaches exactly the keys it changes.
const Map<String, String> kNestedKeyOwner = <String, String>{
  'clinical.hrv_time': 'hrv.freq',
  'clinical.cv': 'hrv.freq',
  'clinical.rmssd_sleep_session': 'hrv.freq',
  'clinical.rmssd_nocturnal': 'hrv.freq',
  'clinical.hrv_freq': 'hrv.freq',
  'clinical.irregular': 'night.rhythm',
  'clinical.irregular_24h': 'night.rhythm',
  'clinical.brv': 'night.rhythm',
  'clinical.prsa_dc': 'night.rhythm',
  'clinical.prsa_ac': 'night.rhythm',
  'clinical.resting_hr': 'readiness.stress_illness',
  'clinical.readiness_lnrmssd': 'readiness.stress_illness',
  'clinical.readiness_composite': 'readiness.stress_illness',
  'clinical.hr_dip': 'body.spo2_temp_coverage',
  'clinical.strain': 'activity.load',
  'clinical.trimp': 'activity.load',
  'series.hr_curve': 'edge.assembly',
  'series.hypnogram': 'sleep.stage',
  'series.hrv_timeline': 'hrv.freq',
  'series.strain_curve': 'activity.load',
  'series.zone_timeline': 'activity.load',
  'series.hrv_day': 'day.checkpoint',
  'series.resp_day': 'day.checkpoint',
  'series.skin_temp_day': 'day.checkpoint',
  'series.coverage': 'edge.assembly',
  'scalars.awakenings': 'sleep.stage',
  'scalars.deep_min': 'sleep.stage',
  'scalars.light_min': 'sleep.stage',
  'scalars.rem_min': 'sleep.stage',
  'scalars.tst_min': 'sleep.stage',
  'scalars.efficiency': 'sleep.stage',
  'scalars.longest_sleep_min': 'sleep.stage',
  'scalars.sol_min': 'sleep.stage',
  'scalars.unobserved_min': 'sleep.stage',
  'scalars.midsleep_sec': 'sleep.stage',
  'scalars.sleep_onset_sec': 'sleep.stage',
  'scalars.lf_hf': 'hrv.freq',
  'scalars.hrv_cv': 'hrv.freq',
  'scalars.rmssd_whole': 'hrv.freq',
  'scalars.sdnn_window': 'hrv.freq',
  'scalars.resp_rate': 'night.rhythm',
  'scalars.prsa_dc': 'night.rhythm',
  'scalars.prsa_dc_anchors': 'night.rhythm',
  'scalars.brv_cv': 'night.rhythm',
  'scalars.brv_slope': 'night.rhythm',
  'scalars.irregular_rhythm_flag': 'night.rhythm',
  'scalars.rhr': 'readiness.stress_illness',
  'scalars.rhr_nocturnal': 'readiness.stress_illness',
  'scalars.rmssd': 'readiness.stress_illness',
  'scalars.sdnn': 'readiness.stress_illness',
  'scalars.ln_rmssd': 'readiness.stress_illness',
  'scalars.readiness': 'readiness.stress_illness',
  'scalars.readiness_z': 'readiness.stress_illness',
  'scalars.stress': 'readiness.stress_illness',
  'scalars.stress_si': 'readiness.stress_illness',
  'scalars.sleeping_hr_nadir': 'readiness.stress_illness',
  'scalars.sleeping_hr_nadir_ts': 'readiness.stress_illness',
  'scalars.strain': 'activity.load',
  'scalars.trimp': 'activity.load',
  'scalars.trimp_net': 'activity.load',
  'scalars.quiet_hrr': 'activity.load',
  'scalars.calories': 'activity.load',
  'scalars.max_hr_used': 'activity.load',
  'scalars.nap_min': 'day.blocks',
  'scalars.dip_pct': 'body.spo2_temp_coverage',
  'scalars.waking_hr': 'body.spo2_temp_coverage',
  'scalars.skin_temp_adc': 'body.spo2_temp_coverage',
  'scalars.skin_temp_z': 'body.spo2_temp_coverage',
  'scalars.skin_temp_coverage_frac': 'body.spo2_temp_coverage',
  'scalars.skin_temp_settled_frac': 'body.spo2_temp_coverage',
  'scalars.worn_min': 'body.spo2_temp_coverage',
  // Literal-null placeholders the pipeline writes itself.
  'scalars.spo2': 'edge.assembly',
  'scalars.odi_per_hour': 'edge.assembly',
  // Only under a condition the test fixtures do not meet (see
  // [kConditionalKeys]).
  'scalars.active_min': 'activity.load',
  'scalars.dyn_p90': 'activity.load',
  'scalars.hr_ceiling_bpm': 'activity.load',
  'scalars.calories_total': 'activity.load',
  'scalars.steps': 'activity.load',
  'scalars.hrr_bpm': 'day.blocks',
  'scalars.hrr_tau_s': 'day.blocks',
  'scalars.skin_temp_dev_c': 'body.spo2_temp_coverage',
  'scalars.skin_temp_ambient_r': 'body.spo2_temp_coverage',
};

/// Key path -> the registered functions whose call produces it, for every
/// key in [kNestedKeyOwner] and for `wrist_orientation`. Each name is a
/// member or api entry of some group and has a call site under lib/compute
/// (checked by test/groups/group_key_ownership_test.dart), and sits in the
/// owner's members/api or in a transitive dependency's. Where edge code
/// reshapes an analytics result (a rolling window, a downsample) the entry
/// names the analytics function it is built from; keys edge computes
/// outright name `deriveDayBundle`.
const Map<String, List<String>> kKeyProducers = <String, List<String>>{
  'wrist_orientation': ['positionSeries'],
  'clinical.hrv_time': ['hrvTime'],
  'clinical.cv': ['hrvTime'],
  'clinical.rmssd_sleep_session': ['sleepSessionRmssdDetail'],
  'clinical.rmssd_nocturnal': ['nocturnalRmssd'],
  'clinical.hrv_freq': ['hrvFreq'],
  'clinical.irregular': ['irregularBeatScreenDetailed'],
  'clinical.irregular_24h': ['irregularBeatScreenDetailed'],
  'clinical.brv': ['breathingRateVariability'],
  'clinical.prsa_dc': ['decelerationCapacity'],
  'clinical.prsa_ac': ['accelerationCapacity'],
  'clinical.resting_hr': ['nocturnalRhr'],
  'clinical.readiness_lnrmssd': ['readinessLnRmssd'],
  'clinical.readiness_composite': ['readinessComposite'],
  'clinical.hr_dip': ['hrDip'],
  'clinical.strain': ['strainScoreFromSeries'],
  'clinical.trimp': ['banisterTrimp'],
  'series.hr_curve': ['deriveDayBundle'],
  'series.hypnogram': ['segmentSleep'],
  'series.hrv_timeline': ['correctRr'],
  'series.strain_curve': ['strainCurveFromSeries'],
  'series.zone_timeline': [
    'HeartRateZones.zonesFromMaxHr',
    'HeartRateZones.reserveZones',
  ],
  'series.hrv_day': ['foldDayCheckpoint'],
  'series.resp_day': ['foldDayCheckpoint', 'rsaRespRate'],
  'series.skin_temp_day': ['foldDayCheckpoint'],
  'series.coverage': ['deriveDayBundle'],
  'scalars.awakenings': ['segmentSleep'],
  'scalars.deep_min': ['segmentSleep'],
  'scalars.light_min': ['segmentSleep'],
  'scalars.rem_min': ['segmentSleep'],
  'scalars.tst_min': ['segmentSleep'],
  'scalars.efficiency': ['segmentSleep'],
  'scalars.longest_sleep_min': ['segmentSleep'],
  'scalars.sol_min': ['segmentSleep'],
  'scalars.unobserved_min': ['segmentSleep'],
  'scalars.midsleep_sec': ['segmentSleep'],
  'scalars.sleep_onset_sec': ['segmentSleep'],
  'scalars.lf_hf': ['hrvFreq'],
  'scalars.hrv_cv': ['hrvTime'],
  'scalars.rmssd_whole': ['hrvTime'],
  'scalars.sdnn_window': ['hrvTime'],
  'scalars.resp_rate': ['rsaRespRate'],
  'scalars.prsa_dc': ['decelerationCapacity'],
  'scalars.prsa_dc_anchors': ['decelerationCapacity'],
  'scalars.brv_cv': ['breathingRateVariability'],
  'scalars.brv_slope': ['breathingRateVariability'],
  'scalars.irregular_rhythm_flag': ['irregularBeatScreenDetailed'],
  'scalars.rhr': ['nocturnalRhr'],
  'scalars.rhr_nocturnal': ['nocturnalRhr'],
  'scalars.rmssd': ['sleepSessionRmssdDetail'],
  'scalars.sdnn': ['hrvTime'],
  'scalars.ln_rmssd': ['readinessLnRmssd'],
  'scalars.readiness': ['readinessComposite'],
  'scalars.readiness_z': ['readinessComposite'],
  'scalars.stress': ['baevskyStressIndex'],
  'scalars.stress_si': ['baevskyStressIndex'],
  'scalars.sleeping_hr_nadir': ['nocturnalRhr'],
  'scalars.sleeping_hr_nadir_ts': ['nocturnalRhr'],
  'scalars.strain': ['strainScoreFromSeries'],
  'scalars.trimp': ['banisterTrimp'],
  'scalars.trimp_net': ['netTrimpAboveQuiet'],
  'scalars.quiet_hrr': ['dailyQuietWakingHrr'],
  'scalars.calories': ['Calories.dailyEnergy'],
  'scalars.max_hr_used': ['sessionHrCeiling'],
  'scalars.nap_min': ['detectNaps'],
  'scalars.dip_pct': ['hrDip'],
  'scalars.waking_hr': ['hrDip'],
  'scalars.skin_temp_adc': ['nightlySkinTemp'],
  'scalars.skin_temp_z': ['nightlySkinTemp'],
  'scalars.skin_temp_coverage_frac': ['nightlySkinTemp'],
  'scalars.skin_temp_settled_frac': ['nightlySkinTemp'],
  'scalars.worn_min': ['calibrationFor'],
  'scalars.spo2': ['deriveDayBundle'],
  'scalars.odi_per_hour': ['deriveDayBundle'],
  'scalars.active_min': ['dailyActiveMinutes'],
  'scalars.dyn_p90': ['dailyDynSummary'],
  'scalars.hr_ceiling_bpm': ['sessionHrCeiling'],
  'scalars.calories_total': ['Calories.dailyEnergy'],
  'scalars.steps': ['enmoSeries'],
  'scalars.hrr_bpm': ['hrRecovery'],
  'scalars.hrr_tau_s': ['hrRecovery'],
  'scalars.skin_temp_dev_c': ['nightlySkinTemp'],
  'scalars.skin_temp_ambient_r': ['nightlySkinTemp'],
};
