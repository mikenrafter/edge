// A night the user blanked — "Not sleep", or a window of their own that the
// band's samples cannot back — is a night NOT RECORDED. This file is the one
// place that says which stored values belong to the night, so the live derive,
// the pruned-raw patch and the `metric_series` clean-up cannot disagree.
//
// Pure: no DB, no isolate state.

import 'dart:convert';

/// Every `metric_series` / `day_result.scalars` key that only exists because a
/// night was staged. A blanked night owns none of them.
///
/// Includes keys the current derive no longer writes (`odi_per_hour`, `spo2`):
/// `metric_series` is REPLACE-per-key, so an old row under a retired key is
/// never overwritten by anything and has to be deleted by name.
///
/// NOT here, on purpose: daytime facts (`strain`, `trimp`, `steps`, `calories*`,
/// `active_min`, `worn_min`, `hr_ceiling_bpm`, `nap_min`, `stress`, `dyn_p90`).
const Set<String> kSleepDerivedMetricKeys = {
  'rhr',
  'rhr_nocturnal',
  'rmssd',
  'rmssd_whole',
  'sdnn',
  'ln_rmssd',
  'readiness',
  'resp_rate',
  'skin_temp_z',
  'skin_temp_adc',
  'skin_temp_coverage_frac',
  'skin_temp_settled_frac',
  'prsa_dc',
  'prsa_dc_anchors',
  'dip_pct',
  'odi_per_hour',
  'spo2',
  'sleeping_hr_nadir',
  'sleeping_hr_nadir_ts',
  'waking_hr',
  'rem_min',
  'deep_min',
  'light_min',
  'tst_min',
  'lf_hf',
  'hrv_cv',
  'efficiency',
  'unobserved_min',
  'awakenings',
  'longest_sleep_min',
  'sol_min',
  'midsleep_sec',
  'sleep_onset_sec',
};

/// Top-level `day_result` bundle blocks that are wholly the night's.
const List<String> _nightBlocks = [
  'day_confidence',
  'flags',
  'sleep',
  'spo2',
  'readiness_absent_diag',
  'restlessness',
  'wrist_orientation',
  'restlessness_map',
  'advanced_sleep',
  'sleep_charging',
  'respiration',
  'hrv_night_shape',
  'baselines',
];

/// Sub-keys of `clinical` computed from the night.
const List<String> _nightClinical = [
  'hrv_time',
  'cv',
  'irregular',
  'rmssd_sleep_session',
  'rmssd_nocturnal',
  'hrv_freq',
  'resting_hr',
  'hr_dip',
  'prsa_dc',
  'prsa_ac',
  'readiness_lnrmssd',
  'readiness_composite',
];

/// Bundle blocks a blanked night must not inherit from a previous result when
/// the second half of a derive fails and its detail is carried forward.
const Set<String> kNightOnlyBundleKeys = {
  'wrist_orientation',
  'restlessness_map',
  'advanced_sleep',
  'sleep_charging',
  'respiration',
  'hrv_night_shape',
};

/// The stored night, blanked, for a day whose raw is gone and therefore cannot
/// be re-derived.
///
/// [prev] is the day's current result; [absent] is what the engine itself
/// produces for the same day with no night in it (its own absent envelopes, so
/// no shape is invented here). Only the night's blocks are replaced — the
/// day's strain, steps, calories, naps and curves stay as measured.
Map<String, dynamic> blankNightInBundle(
  Map<String, dynamic> prev,
  Map<String, dynamic> absent, {
  required String source,
}) {
  // Deep copy: [prev] is a decoded row the caller may still hold.
  final out = (jsonDecode(jsonEncode(prev)) as Map).cast<String, dynamic>();

  for (final k in _nightBlocks) {
    if (absent.containsKey(k)) {
      out[k] = absent[k];
    } else {
      out.remove(k);
    }
  }

  final clinical = out['clinical'];
  final absentClinical = absent['clinical'];
  if (clinical is Map && absentClinical is Map) {
    for (final k in _nightClinical) {
      if (absentClinical.containsKey(k)) {
        clinical[k] = absentClinical[k];
      } else {
        clinical.remove(k);
      }
    }
  }

  final series = out['series'];
  if (series is Map) {
    series['hypnogram'] = (absent['series'] as Map?)?['hypnogram'] ?? const [];
  }

  final coverage = out['coverage'];
  if (coverage is Map && coverage.containsKey('sleep_seconds')) {
    coverage['sleep_seconds'] = 0;
  }

  // Naps are not the night: keep them, drop only the main period.
  final periods = out['sleep_periods'];
  if (periods is Map) {
    final list = periods['periods'];
    periods['periods'] = list is List
        ? [
            for (final e in list)
              if (e is Map && e['is_main'] != true) e,
          ]
        : const [];
    periods['total_asleep_min'] = null;
  }

  final scalars = out['scalars'];
  if (scalars is Map) {
    for (final k in kSleepDerivedMetricKeys) {
      if (scalars.containsKey(k)) scalars[k] = null;
    }
  }

  out['sleep_source'] = source;
  out['flags'] = [source == 'rejected' ? 'SLEEP_REJECTED' : 'NO_SLEEP_DETECTED'];
  return out;
}
