// The day's ACTIVE calories and its TOTAL calories must come from one HR-flex
// pass, so that `calories_total - calories == basal` holds by construction.
//
// They used to come from two different implementations. `calories` was summed
// by a derivation-local copy of Keytel (`_keytelCaloriesWake`) that billed the
// FULL Keytel rate on every active minute, while `calories_total` came from
// `ana.Calories.dailyEnergy`, whose active component nets out the basal minute
// you are also counting inside the total. The same minute was therefore paid
// for twice in `calories`: once as basal (inside total) and again as part of
// the active rate. Active read high by exactly basalPerMin x active-minutes,
// and the basal figure the Health export derives as `total - active` read low
// by the same amount.
//
// This test keeps the edge-owned cadence alignment contract; metric arithmetic
// is covered by the pinned analytics package.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/onehz_pipeline.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';

// age 34 -> Tanaka HRmax = 208 - 0.7*34 = 184.2, HR-flex point = 0.50 * = 92.1
const _profile = Profile(
  ageYears: 34,
  weightKg: 72,
  heightCm: 178,
  sex: 'm',
);

// Mifflin-St Jeor (male): 10*72 + 6.25*178 - 5*34 + 5 = 1667.5 kcal/day
void main() {
  group('DerivationEngine.wakeDayEnergy input alignment', () {
    final walkHr = <double>[
      for (var i = 0; i < 60; i++) 95.0,
      for (var i = 0; i < 1380; i++) 55.0,
    ];
    final walkCad = <double?>[
      for (var i = 0; i < 60; i++) 110.0,
      for (var i = 0; i < 1380; i++) null,
    ];

    test('cadence stays aligned across the off-skin filter', () {
      final hr = <double>[0.0, ...walkHr];
      final cad = <double?>[null, ...walkCad];
      final aligned = DerivationEngine.wakeDayEnergy(hr,
          profile: _profile,
          restingHr: 55,
          deviceFamily: 'gen4',
          cadenceSpmPerMin: cad)!;
      final unshifted = DerivationEngine.wakeDayEnergy(walkHr,
          profile: _profile,
          restingHr: 55,
          deviceFamily: 'gen4',
          cadenceSpmPerMin: walkCad)!;
      expect(aligned.walking, unshifted.walking);
    });
  });

  // The derived scalar pair survives day composition and remains consistent
  // with the bundle consumed by Health export.
  group('the scalar pair a persisted day carries', () {
    // A 70-year-old is the sharpest case for the wake-vs-whole-day question:
    // `dailyEnergy`'s flex gate is 0.50 x Tanaka HRmax = 104 - 0.35*age, so at
    // 70 it sits at 79.5 bpm — under a perfectly ordinary sleeping heart rate.
    const older = Profile(
        ageYears: 70, weightKg: 80, heightCm: 175, sex: 'm',
        // The active gate is a %HRR flex point now, so the lower reserve anchor
        // is a term in it — no resting HR, no gate, no figure.
        restingHrManual: 55);
    // Mifflin (male): 10*80 + 6.25*175 - 5*70 + 5 = 1548.75 kcal/day
    const olderBasalPerMin = 1548.75 / 1440.0;

    // Six hours of substrate: two asleep at 82 bpm (above the 79.5 flex point),
    // one awake and working at 120, three awake and quiet at 60.
    const dayStart = 1767225600; // a whole minute, so the sleep window aligns
    const sleepOnset = dayStart;
    const sleepOffset = dayStart + 2 * 3600;
    const hardUntil = dayStart + 3 * 3600;
    const dayEnd = dayStart + 6 * 3600;

    Substrate build() {
      final ts = <int>[];
      final hr = <int>[];
      final ax = <double>[], ay = <double>[], az = <double>[];
      for (var t = dayStart; t < dayEnd; t++) {
        ts.add(t);
        hr.add(t < sleepOffset ? 82 : (t < hardUntil ? 120 : 60));
        // A little movement so ENMO produces real minutes; the figures under
        // test are HR-driven and do not depend on its magnitude.
        ax.add(0.01 * ((t % 7) - 3));
        ay.add(0.01 * ((t % 5) - 2));
        az.add(1.0);
      }
      final n = ts.length;
      return Substrate(
        tsSec: ts,
        hr: hr,
        rrTsMs: const [],
        rrMs: const [],
        ax: ax,
        ay: ay,
        az: az,
        spo2Red: List<int>.filled(n, 0),
        spo2Ir: List<int>.filled(n, 0),
        skinTemp: List<int>.filled(n, 0),
        skinContact: List<int>.filled(n, 0),
        // A stamped strap: without one there is no HR ceiling and the whole
        // energy triple abstains (hr_max.dart).
        deviceFamily: 'gen4',
      );
    }

    ({Map<String, dynamic> bundle, Map<String, dynamic> scalars}) run() {
      final bundle = <String, dynamic>{};
      final scalars = <String, dynamic>{};
      final daySub = build();
      DerivationEngine.applyDayActivity(
        bundle: bundle,
        scalars: scalars,
        daySub: daySub,
        profile: older,
        sleepOnsetSec: sleepOnset,
        sleepOffsetSec: sleepOffset,
        // Wear/coverage is not what this test measures — the substrate's own
        // span is the day. See wear_coverage_test.dart for the denominator.
        dayStartSec: daySub.tsSec.first,
        dayCalendarEndSec: daySub.tsSec.last + 1,
        dataNowSec: daySub.tsSec.last + 1,
      );
      return (bundle: bundle, scalars: scalars);
    }

    test('calories_total - calories == basal on the pair, not just the helper',
        () {
      final out = run();
      final active = out.scalars['calories'] as double;
      final total = out.scalars['calories_total'] as double;
      final block = (out.bundle['calories_total'] as Map).cast<String, dynamic>();

      // The subtraction health_export performs to write BASAL_ENERGY_BURNED.
      expect(total - active, closeTo((block['basal'] as int).toDouble(), 0.51));
      // Six covered hours of Mifflin, pro-rated: 1.07552 * 360 = 387.19 kcal.
      expect(total - active, closeTo(olderBasalPerMin * 360, 2.0));
    });

    test('sleep is not billed as active energy', () {
      final out = run();
      final active = out.scalars['calories'] as double;

      // Only the hard wake hour is active. Keytel (male, 80 kg, 70 y) at 120
      // bpm is 50.6341 kJ/min = 12.1018 kcal/min; netting the basal minute
      // leaves 11.0263 kcal/min over 60 minutes.
      expect(active, closeTo(661.58, 2.0));

      // Scoring the whole-day series instead would add the two sleeping hours:
      // Keytel at 82 bpm is 6.3721 kcal/min, 5.2966 over basal, x 120 minutes =
      // 635.6 kcal of fabricated "active" energy per night.
      expect(
        active,
        lessThan(800.0),
        reason: 'an 82 bpm sleeping heart rate clears the 79.5 bpm flex gate, '
            'so a whole-day active term bills the night as exercise',
      );
    });

    test('the quiet wake hours contribute nothing, and are not dropped', () {
      // The three hours at 60 bpm sit below the flex point, so they add no
      // active energy — but they are still COVERED minutes and must still be
      // billed basal, or a sedentary afternoon shortens the day's BMR.
      final out = run();
      final block = (out.bundle['calories_total'] as Map).cast<String, dynamic>();

      expect(block['basal'] as int, closeTo(olderBasalPerMin * 360, 2.0));
      expect(block['active'] as int, closeTo(661.58, 2.0));
      // Within a kcal, not exactly equal. The three ints are rounded
      // independently off one double triple that DOES satisfy
      // total == basal + active, and round(a + b) is not round(a) + round(b)
      // once the fractional parts carry. This fixture happens not to carry, so
      // exact equality passed on the arithmetic of these particular numbers and
      // would have failed by one on a different bpm, duration or profile while
      // the production invariant stayed intact. The exact form is asserted on
      // the doubles above, which is where it actually holds.
      expect(
        ((block['value'] as int) -
                ((block['active'] as int) + (block['basal'] as int)))
            .abs(),
        lessThanOrEqualTo(1),
      );
    });

    test('an unanchored profile leaves the pair absent, not zero', () {
      // No sex means no Keytel coefficient block. The day still has heart rate,
      // movement and a step count; it must simply carry no calorie figure.
      final bundle = <String, dynamic>{};
      final scalars = <String, dynamic>{};
      final daySub = build();
      DerivationEngine.applyDayActivity(
        bundle: bundle,
        scalars: scalars,
        daySub: daySub,
        profile: const Profile(
            ageYears: 70,
            weightKg: 80,
            heightCm: 175,
            restingHrManual: 55),
        sleepOnsetSec: sleepOnset,
        sleepOffsetSec: sleepOffset,
        dayStartSec: daySub.tsSec.first,
        dayCalendarEndSec: daySub.tsSec.last + 1,
        dataNowSec: daySub.tsSec.last + 1,
      );

      expect(scalars.containsKey('calories'), isFalse);
      expect(scalars.containsKey('calories_total'), isFalse);
      expect(bundle.containsKey('calories_total'), isFalse);
      // The unrelated blocks still ran — abstaining from energy must not
      // silently take movement down with it.
      expect(bundle['movement'], isNotNull);
    });

    group('workout-gap credit (Active Energy missed a session)', () {
      // The bug this covers: a workout scores its own calories through the
      // SEPARATE session pipeline, but the day trace above never reads
      // `sessions` at all — so a session whose window the band's PPG never
      // once covered contributed nothing to `calories`/`calories_total`,
      // silently, even though it "was recorded" and had a real number of its
      // own. `dayEnd` sits one second past this fixture's last covered
      // second, so a session starting there is a clean, total gap.
      Map<String, dynamic> session({
        double? calories,
        String status = 'done',
        int? private,
        int startOffsetSec = 0,
        int durationSec = 1800,
      }) =>
          {
            'start_ts': dayEnd + startOffsetSec,
            'end_ts': dayEnd + startOffsetSec + durationSec,
            'calories': calories,
            'status': status,
            'private': private,
          };

      test('a session with NO HR coverage at all credits its calories in',
          () {
        final bundle = <String, dynamic>{};
        final scalars = <String, dynamic>{};
        DerivationEngine.applyDayActivity(
          bundle: bundle,
          scalars: scalars,
          daySub: build(),
          profile: older,
          sleepOnsetSec: sleepOnset,
          sleepOffsetSec: sleepOffset,
          dayStartSec: dayStart,
          dayCalendarEndSec: dayEnd + 3600,
          dataNowSec: dayEnd + 3600,
          sessions: [session(calories: 250.0)],
        );
        final activeNoCredit = 661.58; // from the sibling test above
        expect(scalars['calories'], closeTo(activeNoCredit + 250.0, 2.0));
        expect(
          scalars['calories_total'],
          closeTo(
            (scalars['calories'] as double) +
                ((bundle['calories_total'] as Map)['basal'] as int),
            1.0,
          ),
          reason: 'crediting a gap must not break calories_total - calories '
              '== basal',
        );
      });

      test('a session the trace already covers is never double-billed', () {
        final bundle = <String, dynamic>{};
        final scalars = <String, dynamic>{};
        DerivationEngine.applyDayActivity(
          bundle: bundle,
          scalars: scalars,
          daySub: build(),
          profile: older,
          sleepOnsetSec: sleepOnset,
          sleepOffsetSec: sleepOffset,
          dayStartSec: dayStart,
          dayCalendarEndSec: dayEnd + 1,
          dataNowSec: dayEnd + 1,
          // Inside the fixture's own covered span (the hard hour), which
          // already has real HR — so this must NOT add on top of it.
          sessions: [
            {
              'start_ts': dayStart,
              'end_ts': hardUntil,
              'calories': 999.0,
              'status': 'done',
            }
          ],
        );
        expect(scalars['calories'], closeTo(661.58, 2.0));
      });

      test('a private session is never credited', () {
        final bundle = <String, dynamic>{};
        final scalars = <String, dynamic>{};
        DerivationEngine.applyDayActivity(
          bundle: bundle,
          scalars: scalars,
          daySub: build(),
          profile: older,
          sleepOnsetSec: sleepOnset,
          sleepOffsetSec: sleepOffset,
          dayStartSec: dayStart,
          dayCalendarEndSec: dayEnd + 3600,
          dataNowSec: dayEnd + 3600,
          sessions: [session(calories: 250.0, private: 1)],
        );
        expect(scalars['calories'], closeTo(661.58, 2.0));
      });

      test('a live (not-yet-done) session is never credited', () {
        final bundle = <String, dynamic>{};
        final scalars = <String, dynamic>{};
        DerivationEngine.applyDayActivity(
          bundle: bundle,
          scalars: scalars,
          daySub: build(),
          profile: older,
          sleepOnsetSec: sleepOnset,
          sleepOffsetSec: sleepOffset,
          dayStartSec: dayStart,
          dayCalendarEndSec: dayEnd + 3600,
          dataNowSec: dayEnd + 3600,
          sessions: [session(calories: 250.0, status: 'live')],
        );
        expect(scalars['calories'], closeTo(661.58, 2.0));
      });
    });
  });

  // The 1 Hz pipeline computes the SAME active quantity for the early-read path
  // that Today draws before a full day result exists. It has to gate on height
  // for the same reason `wakeDayEnergy` does, or Today shows an imputed figure
  // that the derived day then withdraws.
  group('the pure pipeline mirrors the gate', () {
    const dayStart = 1767225600;
    const n = 3600;

    Map<String, dynamic> bundleFor(Map<String, dynamic> profile) {
      final ts = [for (var i = 0; i < n; i++) dayStart + i];
      final hr = [for (var i = 0; i < n; i++) 130];
      return deriveDayBundle(
        DayBundleInput(
          date: '2026-01-01',
          dayTsSec: ts,
          dayHr: hr,
          sleepTsSec: const [],
          sleepHr: const [],
          sleepRrTsMs: const [],
          sleepRrMs: const [],
          sleepSkinTemp: const [],
          sleepJson: const {},
          hypnoStages: const [],
          sleepOnsetSec: 0,
          sleepOffsetSec: 0,
          profile: profile,
          dayConfidence: 0.5,
          dayFlags: const [],
          deviceFamily: 'gen4',
        ).toJson(),
      );
    }

    num? caloriesOf(Map<String, dynamic> profile) {
      final scalars =
          (bundleFor(profile)['scalars'] as Map).cast<String, dynamic>();
      return scalars['calories'] as num?;
    }

    test('scores the day when the profile carries a real height', () {
      expect(
        caloriesOf(const {
          'age': 34,
          'sex': 'm',
          'weight_kg': 72,
          'height_cm': 178,
          // The active gate is a %HRR flex point now, so the lower reserve
          // anchor is a term in it. This day has no sleep, so the manual one
          // is the only resting HR there is.
          'resting_hr': 55,
        }),
        isNotNull,
      );
    });

    test('abstains without one instead of standing 170 cm in', () {
      expect(
        caloriesOf(const {'age': 34, 'sex': 'm', 'weight_kg': 72}),
        isNull,
        reason: 'the active term is a surplus over the Mifflin basal minute, '
            'so an imputed height moves it',
      );
    });
  });
}
