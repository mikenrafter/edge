// RED (Sol r2 P2s #3 and #4 on the 2026-10-22 bug batch).
//
// #3: every preference the re-entry store owns is device-only and must be in
//     kPrefsNotBackedUp (`import_reentry_stale` was missing).
// #4: an imported workout keeps a name the source can vouch for. A health-store
//     sport enum (FENCING, SAILING, BIKING) shows readable; an internal slug
//     ('other', 'kite_surfing_2') or the store's OTHER shows the localized
//     "Workout"; a raw slug or an all-caps code is never shown.
//
// Compile stubs (production files, returning the pre-fix behaviour):
//   recognizedSportTitle (lib/health/health_workout_import.dart),
//   importedWorkoutLabel (lib/ui2/activity/catalogue.dart),
//   ImportReentryStore.prefKeys (lib/data/import_reentry_store.dart).
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/backup_extras.dart';
import 'package:openstrap_edge/data/import_reentry_store.dart';
import 'package:openstrap_edge/health/health_workout_import.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/activity/catalogue.dart';

void main() {
  test('every preference key ImportReentryStore owns is device-only', () {
    for (final k in ImportReentryStore.prefKeys) {
      expect(prefsKeyBackedUp(k), isFalse, reason: '$k must be in kPrefsNotBackedUp');
      expect(kPrefsNotBackedUp[k], isNotEmpty);
    }
  });

  group('recognizedSportTitle', () {
    test('a health-store sport enum is made readable', () {
      expect(recognizedSportTitle('FENCING'), 'Fencing');
      expect(recognizedSportTitle('SAILING'), 'Sailing');
      expect(recognizedSportTitle('BIKING'), 'Biking');
      expect(recognizedSportTitle('TABLE_TENNIS'), 'Table Tennis');
    });
    test('internal slugs, OTHER and junk are not names', () {
      for (final k in ['other', 'OTHER', 'kite_surfing_2', 'Kite Surfing', 'fencing',
          'FENCING_2', '', '  ', null, 42]) {
        expect(recognizedSportTitle(k), isNull, reason: '$k');
      }
    });
  });

  group('importedWorkoutLabel', () {
    late AppLocalizations l;
    setUpAll(() async => l = await AppLocalizations.delegate.load(const Locale('en')));

    test('recognized sports keep a readable name', () {
      expect(importedWorkoutLabel(l, 'FENCING'), 'Fencing');
      expect(importedWorkoutLabel(l, 'SAILING'), 'Sailing');
      final biking = importedWorkoutLabel(l, 'BIKING');
      expect(biking, isNot('Workout'));
      expect(biking, isNot(contains('_')));
      expect(biking, isNot('BIKING'));
    });
    test('the catalogue wins when it knows the type', () {
      expect(importedWorkoutLabel(l, 'RUNNING'), 'Running');
    });
    test('other and unknown slugs are "Workout", never the raw text', () {
      for (final k in ['other', 'OTHER', 'kite_surfing_2', null]) {
        expect(importedWorkoutLabel(l, k), 'Workout', reason: '$k');
      }
    });
  });
}
