// demo_data_generator.dart — the synthetic ~2-month backfill behind Demo Mode.
//
// WHAT THIS IS FOR. Someone without a band yet (or evaluating the app before
// buying one) taps "Try demo mode" on the pairing screen instead of "Skip for
// now", and the app looks the way it would after two months of real use
// instead of empty. See `lib/ui2/pairing/device_picker.dart` for the button
// and `lib/demo/demo_mode_banner.dart` for the persistent "this isn't real"
// reminder that comes with it.
//
// WHY THIS WRITES THROUGH THE REAL SEAMS. Every row here goes through
// `LocalDb.putDayResult` / `LocalDb.putSession` / `LocalDb.appendRoutePoints`
// — the exact same write paths a real derived day or a hand-logged workout
// use (`compute/manual_session.dart`'s `buildManualSessionRow` +
// `computeManualSessionStats` do the actual session scoring, using the real
// Banister/Keytel formulas over a synthetic HR trace). That means every
// screen renders it through its normal, already-honest read path — nothing
// here is a second, demo-only rendering path that could drift from what a
// real user sees, and the sleep/HR curves this omits (deep clinical/HRV
// detail, stress, respiration, cross-day insights) simply read back absent,
// exactly as they honestly would for a real device early in its life.
//
// ISOLATION FROM REAL DATA. `AppState.isPaired` is never touched — demo mode
// reaches the shell via `OnboardingBypass` (see device_picker.dart), the same
// "skip for now" latch a bandless user already uses, so a real pairing later
// is a completely ordinary first pair. Every row this writes is tagged
// `source: 'demo'` (`day_result` has no source column of its own, so its
// dates are recovered through `metric_series_version`, written in the same
// `putDayResult` transaction) so [purge] can remove precisely what this
// generated and nothing else. `AppState._persistPaired` calls [purge]
// unconditionally, BEFORE it does anything else — including before
// `openSession()` starts real BLE history sync — so demo data can never
// coexist with, or be overwritten mid-write by, a real derivation pass.
//
// DETERMINISTIC. Every random draw is seeded off the calendar day offset, not
// the wall clock, so calling [generate] twice (e.g. exit demo mode, try it
// again) reproduces the same history rather than drifting.

import 'dart:convert';
import 'dart:math' as math;

import '../compute/derivation_engine.dart' show kAlgoVersion;
import '../compute/hr_max.dart' show estimatedMaxHr;
import '../compute/manual_session.dart';
import '../compute/profile.dart';
import '../data/day_label.dart' show dayLabelOf, localDayStartSec;
import '../data/db.dart';
import '../gps/route_models.dart';
import '../state/app_state.dart';
import '../state/prefs.dart';
import '../widget/widget_service.dart';
import 'demo_route.dart';

class DemoDataGenerator {
  DemoDataGenerator._();

  /// How far back the synthetic history reaches. "Today" itself is left
  /// alone — cold-start users see an empty today with yesterday's data
  /// showing through the app's own `_latestBundle` fallback, and demo mode
  /// reproduces that same, already-supported shape rather than inventing a
  /// second one for a day that has not finished yet.
  static const int kBackfillDays = 60;

  static const Profile kDemoProfile = Profile(
    ageYears: 32,
    weightKg: 75,
    heightCm: 178,
    sex: 'm',
  );

  static const Map<String, dynamic> kDemoProfileFields = {
    'age': 32,
    'weight_kg': 75.0,
    'height_cm': 178.0,
    'sex': 'm',
  };

  /// Types drawn for the backfilled workouts — all `Track.distance` or
  /// `Track.stillness` in `ui2/activity/catalogue.dart`, so none of them
  /// needs a `strength_set` row to render sensibly.
  static const List<String> kWorkoutTypes = [
    'running',
    'cycling',
    'walking',
    'hiking',
    'yoga',
  ];

  static const double kRestingHr = 58;

  /// Backfill ~2 months of synthetic days plus a scattering of workouts —
  /// one of them a GPS-tracked run near [app]'s current location, if
  /// location is available. Idempotent: re-running it reproduces the same
  /// history (see file header).
  static Future<void> generate(AppState app) async {
    final anchor = await DemoRoute.anchor();
    await app.updateProfile(kDemoProfileFields);

    final hrMax = estimatedMaxHr(kDemoProfile.ageYears, null)!;
    final today = DateTime.now();

    // Which day offsets (1..kBackfillDays, 1 = yesterday) get a workout: a
    // deterministic walk that never lets more than 3 days pass without one,
    // otherwise a ~35% chance per day — "active, not obsessive" cadence.
    final scheduler = math.Random(0xD5C0);
    final workoutOffsets = <int>[];
    var sinceLast = 0;
    for (var i = kBackfillDays; i >= 1; i--) {
      sinceLast++;
      if (sinceLast >= 3 || scheduler.nextDouble() < 0.35) {
        workoutOffsets.add(i);
        sinceLast = 0;
      }
    }
    final gpsRunOffset =
        workoutOffsets.isEmpty ? null : workoutOffsets.reduce(math.min);

    for (var i = kBackfillDays; i >= 1; i--) {
      final date = dayLabelOf(today.subtract(Duration(days: i)));
      final isWorkoutDay = workoutOffsets.contains(i);
      final rnd = math.Random(i);
      final raw = _rawScalars(dayOffset: i, isWorkout: isWorkoutDay, rnd: rnd);

      final dayStart = localDayStartSec(date)!;
      final wakeSec = dayStart + (6 * 3600 + rnd.nextInt(3600));
      final solSec = ((raw['sol_min'] ?? 10) * 60).round();
      const wasoMin = 6.0;
      final tstMin = raw['tst_min'] ?? 420.0;
      final inBedMin = tstMin + wasoMin + solSec / 60;
      final onsetSec = wakeSec - (inBedMin * 60).round();

      int? workoutStart, workoutEnd;
      String? workoutType;
      if (isWorkoutDay) {
        final wRnd = math.Random(i * 31 + 7);
        workoutType = kWorkoutTypes[wRnd.nextInt(kWorkoutTypes.length)];
        if (i == gpsRunOffset) workoutType = 'running';
        final isRun = workoutType == 'running';
        workoutStart =
            dayStart + (isRun ? 7 : 17) * 3600 + wRnd.nextInt(3600);
        final minutes = (isRun ? 28 : 20) + wRnd.nextInt(25);
        workoutEnd = workoutStart + minutes * 60;
      }

      final bundle = _dayBundle(
        date: date,
        raw: raw,
        dayStartSec: dayStart,
        sleepOnsetSec: onsetSec,
        sleepOffsetSec: wakeSec,
        workoutStartSec: workoutStart,
        workoutEndSec: workoutEnd,
        restingHr: raw['rhr'] ?? kRestingHr,
        rnd: math.Random(i * 97 + 3),
      );

      await LocalDb.putDayResult(
        dayId: date,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode(bundle),
        windowJson: '{}',
        finalized: true,
        rhr: raw['rhr'],
        rmssd: raw['rmssd'],
        readiness: raw['readiness'],
        series: raw,
        source: 'demo',
      );

      if (isWorkoutDay && workoutStart != null && workoutEnd != null) {
        await _writeSession(
          date: date,
          startSec: workoutStart,
          durationSec: workoutEnd - workoutStart,
          type: workoutType!,
          hrMax: hrMax,
          restingHr: kRestingHr,
          rnd: math.Random(i * 131 + 11),
          anchor: anchor,
          gpsRun: i == gpsRunOffset,
        );
      }
    }

    Prefs.setBool(Prefs.demoModeEnabled, true);
  }

  /// Remove everything [generate] wrote — and nothing else. Days are found
  /// through `metric_series_version.source = 'demo'` (the same transaction
  /// `putDayResult` writes it in, so it always names exactly the dates demo
  /// mode produced), sessions through `sessions.source = 'demo'`. Safe to
  /// call when demo mode was never enabled — both queries just return empty.
  ///
  /// [app], when given, also clears the fake age/weight/height/sex [generate]
  /// wrote via `updateProfile` — demo mode is only reachable before real
  /// onboarding, where the profile is empty, so this is a plain reset rather
  /// than a guess at what to restore. Without it, a person who tried demo
  /// mode and then paired for real would have every calorie/zone/strain
  /// figure computed off a stranger's invented body forever, since pairing a
  /// band does not itself collect a profile. Nulling the fields (not
  /// omitting them) puts `AppState.profileComplete` back to false, which is
  /// the same "finish your profile in Settings" state a real user who
  /// skipped it during onboarding is already in — not a new, unhandled one.
  static Future<void> purge({AppState? app}) async {
    if (app != null) {
      await app.updateProfile(const {
        'age': null,
        'weight_kg': null,
        'height_cm': null,
        'sex': null,
      });
    }
    final db = await LocalDb.instance;
    await db.transaction((txn) async {
      final dayRows = await txn.query(
        'metric_series_version',
        columns: ['date', 'algo_version'],
        where: 'source = ?',
        whereArgs: ['demo'],
      );
      for (final row in dayRows) {
        final date = row['date'] as String;
        // The provenance stamp identifies one immutable version, not every
        // version on the date. Earlier real/imported results must survive.
        await txn.delete('day_result',
            where: 'day_id = ? AND algo_version = ?',
            whereArgs: [date, row['algo_version']]);
        // Scalar storage has no history or per-key provenance. Clear the demo
        // cache and leave metrics absent rather than guessing an earlier source.
        await txn.delete('metric_series', where: 'date = ?', whereArgs: [date]);
        await txn.delete('metric_series_version',
            where: 'date = ?', whereArgs: [date]);
      }
      final sessionRows = await txn.query(
        'sessions',
        columns: ['id'],
        where: 'source = ?',
        whereArgs: ['demo'],
      );
      for (final row in sessionRows) {
        final id = row['id'] as String;
        await txn.delete('sessions', where: 'id = ?', whereArgs: [id]);
        await txn.delete('workout_route',
            where: 'session_id = ?', whereArgs: [id]);
        await txn.delete('workout_split',
            where: 'session_id = ?', whereArgs: [id]);
      }
    });

    // Two caches outside this table set are populated FROM day_result/sessions
    // as a side effect of merely viewing the app while demo rows exist, and
    // neither corrects itself on its own:
    //   - `compute_freshness` (`getToday()`'s cache) can go stale-but-still
    //     "current for today" and keep pointing at rows just deleted above.
    //   - The WidgetKit/watch snapshot is pushed to the shared App Group on
    //     every foreground regardless of pairing, so a home-screen widget or
    //     watch face can be showing demo numbers right now.
    // Both already have a real-world precedent for this exact situation:
    // `AppState.resetAllData()` clears the widget snapshot for the same
    // reason ("surfaces outside the database that were still showing it").
    await LocalDb.refreshComputeFreshness();
    await WidgetService.clear();
  }

  // ── per-day flat scalars (also written verbatim as `metric_series`) ───────

  /// The ~35 keys `DerivationEngine` actually populates under `scalars`
  /// (`compute/onehz_pipeline.dart`), as smooth, physiologically plausible
  /// trends rather than white noise: a slow fitness improvement over the
  /// whole window, a weekly wave, and workout days nudging strain/calories/
  /// steps/HRR up and readiness down the next scalar the way real training
  /// load does. Deterministic in [dayOffset] alone (via [rnd] and the wave
  /// phases below) — no wall-clock input anywhere in this function.
  static Map<String, double?> _rawScalars({
    required int dayOffset,
    required bool isWorkout,
    required math.Random rnd,
  }) {
    double wave(double periodDays, double phase) =>
        math.sin(2 * math.pi * dayOffset / periodDays + phase);
    double jitter(double spread) => (rnd.nextDouble() - 0.5) * spread;
    // 1.0 for the oldest backfilled day, ~0 for the most recent.
    final aging = dayOffset / kBackfillDays;

    // `num.clamp` returns `num`, not the receiver's type (a well-known Dart
    // gotcha) — every call below is followed by `.toDouble()` so this
    // function's return type (`Map<String, double?>`) actually holds.
    final rhr = (58 + 4 * aging + 3 * wave(21, 0.3) + jitter(2.0))
        .clamp(46.0, 70.0)
        .toDouble();
    final rmssd = (44 - 8 * aging + 14 * wave(14, 1.1) + jitter(8.0))
        .clamp(20.0, 95.0)
        .toDouble();
    final sdnn = (rmssd * 1.35 + jitter(5)).clamp(25.0, 130.0).toDouble();
    final readiness =
        (60 + 12 * wave(7, 0.5) - 8 * aging + (isWorkout ? -6 : 4) + jitter(9))
            .clamp(28.0, 97.0)
            .toDouble();
    final tstMin =
        (410 + 30 * wave(7, 1.4) + jitter(25)).clamp(300.0, 500.0).toDouble();
    final remMin =
        (tstMin * (0.20 + jitter(0.06))).clamp(30.0, tstMin * 0.35).toDouble();
    final deepMin =
        (tstMin * (0.16 + jitter(0.06))).clamp(20.0, tstMin * 0.3).toDouble();
    final lightMin = (tstMin - remMin - deepMin).clamp(0.0, tstMin).toDouble();
    final strain =
        (isWorkout ? 11 + rnd.nextDouble() * 6 : 3 + rnd.nextDouble() * 4)
            .clamp(0.0, 21.0)
            .toDouble();
    final steps = (5200 +
            (isWorkout ? 4200 : 0) +
            1800 * wave(7, 0.2) +
            jitter(900))
        .clamp(1500.0, 15000.0)
        .roundToDouble();
    final calories =
        (1900 + (isWorkout ? 350 : 0) + 150 * wave(7, 1) + jitter(120))
            .clamp(1500.0, 3200.0)
            .toDouble();

    return {
      'rhr': rhr,
      'rhr_nocturnal': rhr,
      'rmssd': rmssd,
      'rmssd_whole': rmssd,
      'sdnn': sdnn,
      'readiness': readiness,
      'ln_rmssd': math.log(math.max(rmssd, 1)),
      'resp_rate': (14.5 + wave(10, 0) + jitter(1.2)).clamp(11.0, 19.0).toDouble(),
      'skin_temp_z': (wave(30, 2) * 0.8 + jitter(0.6)).clamp(-2.5, 2.5).toDouble(),
      'skin_temp_adc': 20500 + 400 * wave(30, 2) + jitter(150),
      'dip_pct': (14 + 4 * wave(14, 0.7) + jitter(3)).clamp(4.0, 26.0).toDouble(),
      'strain': strain,
      'trimp': strain * 6.5,
      'stress': (35 + 20 * wave(5, 0) + (isWorkout ? -8 : 6) + jitter(12))
          .clamp(5.0, 92.0)
          .toDouble(),
      'calories': calories,
      'calories_total': calories + 700 + jitter(100),
      'steps': steps,
      'active_min':
          (28 + (isWorkout ? 35 : 0) + jitter(10)).clamp(5.0, 110.0).toDouble(),
      'dyn_p90': 0.03 + jitter(0.01),
      'nap_min': rnd.nextDouble() < 0.12 ? 15 + rnd.nextDouble() * 20 : 0.0,
      'rem_min': remMin,
      'deep_min': deepMin,
      'light_min': lightMin,
      'tst_min': tstMin,
      'lf_hf': (1.4 + wave(11, 0.4) + jitter(0.5)).clamp(0.4, 3.2).toDouble(),
      'hrv_cv': (0.18 + jitter(0.06)).clamp(0.05, 0.4).toDouble(),
      'irregular_rhythm_flag': 0.0,
      'brv_cv': (0.14 + jitter(0.05)).clamp(0.04, 0.3).toDouble(),
      'efficiency': (88 + wave(9, 0.9) * 4 + jitter(4)).clamp(72.0, 98.0).toDouble(),
      'worn_min': (1410 + jitter(25)).clamp(1200.0, 1440.0).toDouble(),
      'unobserved_min': (8 + jitter(10)).clamp(0.0, 45.0).toDouble(),
      'awakenings': (1 + rnd.nextInt(4)).toDouble(),
      'longest_sleep_min':
          (tstMin * 0.55 + jitter(20)).clamp(120.0, tstMin).toDouble(),
      'sol_min': (10 + jitter(8)).clamp(2.0, 35.0).toDouble(),
      'hrr_bpm':
          isWorkout ? (24 + rnd.nextDouble() * 10).clamp(10.0, 45.0).toDouble() : null,
      'hrr_tau_s': isWorkout ? 55 + rnd.nextDouble() * 30 : null,
      'prsa_dc': (6.5 + wave(18, 0.2) + jitter(2.0)).clamp(2.0, 13.0).toDouble(),
      'skin_temp_coverage_frac':
          (0.94 + jitter(0.06)).clamp(0.5, 1.0).toDouble(),
    };
  }

  // ── day_result bundle assembly ─────────────────────────────────────────

  /// `_envelope` from `compute/onehz_pipeline.dart` — the shape every
  /// non-scalar block (`sleep.window`, `.accounting`, `.stager`, …) actually
  /// uses: `{value, confidence, tier, inputs_used}`, `value: '—'` and
  /// `confidence: 0` when there is nothing to report. Demo mode never
  /// abstains (there is always a synthetic value), so [value] here is never
  /// null in practice, but the shape is kept exact for anything downstream
  /// that checks `confidence == 0` as its absence test.
  static Map<String, dynamic> _envelope(
    Object? value, {
    required double confidence,
    required String tier,
    required List<String> inputs,
  }) =>
      {
        'value': value ?? '—',
        'confidence': value == null ? 0 : confidence,
        'tier': tier,
        'inputs_used': inputs,
      };

  static Map<String, dynamic> _dayBundle({
    required String date,
    required Map<String, double?> raw,
    required int dayStartSec,
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required int? workoutStartSec,
    required int? workoutEndSec,
    required double restingHr,
    required math.Random rnd,
  }) {
    final tstMin = raw['tst_min'] ?? 420;
    final remMin = raw['rem_min'] ?? 80;
    final deepMin = raw['deep_min'] ?? 70;
    final lightMin = raw['light_min'] ?? (tstMin - remMin - deepMin);
    const wasoMin = 6.0;
    final inBedMin = tstMin + wasoMin + (raw['sol_min'] ?? 10);
    final efficiencyPct = raw['efficiency'] ?? 88;

    final accounting = {
      'tst_sec': (tstMin * 60).round(),
      'waso_sec': (wasoMin * 60).round(),
      'in_bed_sec': (inBedMin * 60).round(),
      'unobserved_sec': ((raw['unobserved_min'] ?? 8) * 60).round(),
      'observed_in_bed_sec':
          ((inBedMin - (raw['unobserved_min'] ?? 8)) * 60).round(),
      'efficiency_pct': efficiencyPct,
      'nrem_sec': ((deepMin + lightMin) * 60).round(),
      'light_sec': (lightMin * 60).round(),
      'deep_sec': (deepMin * 60).round(),
      'rem_sec': (remMin * 60).round(),
      'wake_sec': (wasoMin * 60).round(),
      'deep_low_confidence': true,
      'awakenings': (raw['awakenings'] ?? 2).round(),
      'longest_sleep_sec': ((raw['longest_sleep_min'] ?? tstMin * 0.55) * 60).round(),
      'sol_sec': ((raw['sol_min'] ?? 10) * 60).round(),
    };

    final scalars = {
      for (final e in raw.entries)
        if (e.value != null) e.key: e.value,
    };

    return {
      'date': date,
      'scalars': scalars,
      'sleep': {
        'window': _envelope(
          {
            'onset_ms': sleepOnsetSec * 1000,
            'offset_ms': sleepOffsetSec * 1000,
            'spt_sec': sleepOffsetSec - sleepOnsetSec,
          },
          confidence: 0.9,
          tier: 'HIGH',
          inputs: const ['accel_1hz', 'hr_1hz'],
        ),
        'accounting': _envelope(
          accounting,
          confidence: 0.85,
          tier: 'ESTIMATE',
          inputs: const ['sleep_stages'],
        ),
        'stager': _envelope(
          {
            'wake_pct': double.parse((wasoMin / inBedMin).toStringAsFixed(3)),
            'nrem_pct': double.parse(
                ((deepMin + lightMin) / tstMin).toStringAsFixed(3)),
            'rem_pct': double.parse((remMin / tstMin).toStringAsFixed(3)),
            'epoch_sec': 1,
            'epochs': (inBedMin * 60).round(),
          },
          confidence: 0.8,
          tier: 'ESTIMATE',
          inputs: const ['hr_1hz', 'immobility'],
        ),
      },
      'sleep_periods': {
        'periods': [
          {
            'is_main': true,
            'onset_ts': sleepOnsetSec,
            'wake_ts': sleepOffsetSec,
            'duration_min': tstMin.round(),
            'in_bed_min': inBedMin.round(),
            'efficiency': efficiencyPct,
          },
        ],
        'total_asleep_min': tstMin.round(),
      },
      'series': {
        'hr_curve': _hrCurve(
          dayStartSec: dayStartSec,
          sleepOnsetSec: sleepOnsetSec,
          sleepOffsetSec: sleepOffsetSec,
          workoutStartSec: workoutStartSec,
          workoutEndSec: workoutEndSec,
          restingHr: restingHr,
          rnd: rnd,
        ),
      },
      'activity_curve': _activityCurve(
        dayStartSec: dayStartSec,
        sleepOnsetSec: sleepOnsetSec,
        sleepOffsetSec: sleepOffsetSec,
        workoutStartSec: workoutStartSec,
        workoutEndSec: workoutEndSec,
        rnd: rnd,
      ),
    };
  }

  /// One `{t: epoch sec (60 s bucket), v: bpm}` entry per minute of [date],
  /// matching `onehz_pipeline._downsampleHr`'s shape exactly — low during
  /// the sleep window, an ordinary daytime wander otherwise, and a workout
  /// bump (ease in / hold / ease out) when [workoutStartSec] is given.
  static List<Map<String, num>> _hrCurve({
    required int dayStartSec,
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required int? workoutStartSec,
    required int? workoutEndSec,
    required double restingHr,
    required math.Random rnd,
  }) {
    final out = <Map<String, num>>[];
    for (var m = 0; m < 24 * 60; m++) {
      final tSec = dayStartSec + m * 60;
      double bpm;
      if (tSec >= sleepOnsetSec && tSec < sleepOffsetSec) {
        bpm = restingHr - 3 + rnd.nextDouble() * 4;
      } else if (workoutStartSec != null &&
          workoutEndSec != null &&
          tSec >= workoutStartSec &&
          tSec < workoutEndSec) {
        final span = workoutEndSec - workoutStartSec;
        final frac = (tSec - workoutStartSec) / span;
        final shape =
            frac < 0.15 ? frac / 0.15 : (frac > 0.85 ? (1 - frac) / 0.15 : 1.0);
        bpm = restingHr + 20 + 70 * shape;
      } else {
        bpm = restingHr + 15 + 10 * math.sin(m / 180) + rnd.nextDouble() * 8;
      }
      out.add({'t': tSec, 'v': bpm.round()});
    }
    return out;
  }

  /// One `{t: epoch sec (5 min bucket), v: 0..1 movement fraction}` entry,
  /// matching `derivation_engine._activityCurve`'s shape — near zero asleep,
  /// a low daytime wander, high during a workout.
  static List<Map<String, num>> _activityCurve({
    required int dayStartSec,
    required int sleepOnsetSec,
    required int sleepOffsetSec,
    required int? workoutStartSec,
    required int? workoutEndSec,
    required math.Random rnd,
  }) {
    final out = <Map<String, num>>[];
    for (var b = 0; b < (24 * 60) ~/ 5; b++) {
      final tSec = dayStartSec + b * 300;
      double v;
      if (tSec >= sleepOnsetSec && tSec < sleepOffsetSec) {
        v = rnd.nextDouble() * 0.03;
      } else if (workoutStartSec != null &&
          workoutEndSec != null &&
          tSec >= workoutStartSec &&
          tSec < workoutEndSec) {
        v = 0.55 + rnd.nextDouble() * 0.35;
      } else {
        v = 0.06 + rnd.nextDouble() * 0.18;
      }
      out.add({'t': tSec, 'v': double.parse(v.toStringAsFixed(3))});
    }
    return out;
  }

  // ── workouts ────────────────────────────────────────────────────────────

  /// Score and store one backfilled workout through the exact same pure
  /// scorer a hand-logged session uses ([computeManualSessionStats] over a
  /// synthetic per-second HR trace, [buildManualSessionRow] for the row
  /// shape) — so `strain`/`calories`/`zone_min_json` come out of the real
  /// Banister/Keytel formulas, internally consistent with everything else
  /// this profile produces, rather than being invented numbers of their own.
  static Future<void> _writeSession({
    required String date,
    required int startSec,
    required int durationSec,
    required String type,
    required double hrMax,
    required double restingHr,
    required math.Random rnd,
    required bool gpsRun,
    GpsSample? anchor,
  }) async {
    final peakFrac = switch (type) {
      'running' => 0.86,
      'cycling' => 0.80,
      'hiking' => 0.72,
      'walking' => 0.62,
      _ => 0.55,
    };
    final peakHr = restingHr + (hrMax - restingHr) * peakFrac;
    const easeSec = 180;
    final hrTs = <int>[];
    final hrBpm = <int>[];
    for (var s = 0; s < durationSec; s++) {
      double frac;
      if (s < easeSec) {
        frac = s / easeSec;
      } else if (durationSec - s < easeSec) {
        frac = math.max(0.2, (durationSec - s) / easeSec);
      } else {
        frac = 1.0;
      }
      final target = restingHr + 15 + (peakHr - restingHr - 15) * frac;
      hrTs.add(startSec + s);
      // clamp BEFORE round: `num.clamp` returns `num`, but `num.round()`
      // always returns `int` — the other way round would hand `List<int>`
      // a `num` and fail to compile.
      hrBpm.add((target + (rnd.nextDouble() - 0.5) * 6).clamp(40.0, 210.0).round());
    }

    final stats = computeManualSessionStats(
      hrTs: hrTs,
      hrBpm: hrBpm,
      profile: kDemoProfile,
      hrMax: hrMax,
      restingHr: restingHr,
    );
    final row = buildManualSessionRow(
      startSec: startSec,
      endSec: startSec + durationSec,
      type: type,
      stats: stats,
      createdAtMs: startSec * 1000,
      sessionId: 'demo:$date:$type',
      source: 'demo',
    );
    await LocalDb.putSession(row);

    if (gpsRun) {
      final id = row['id'] as String;
      final points = DemoRoute.generateLoop(
        origin: anchor,
        startTsMs: startSec * 1000,
        durationSec: durationSec,
        seed: startSec,
      );
      await LocalDb.appendRoutePoints(
        id,
        [for (final p in points) p.toRow(id)],
      );
    }
  }
}
