import 'package:flutter/material.dart' show Locale;
import '../../l10n/app_localizations.dart';

// Internal read names are diagnostic identifiers, never user-facing copy.
String reviewReadLabel(String read, AppLocalizations? localizations) {
  final l = localizations ?? lookupAppLocalizations(const Locale('en'));
  return switch (read) {
    'moments' || 'moment labels' || 'assumed water' || 'water moments' => l.reviewReadMoments,
    'activities' => l.reviewReadActivities,
    'days' || 'available days' => l.reviewReadDays,
    'saved activity reviews' => l.reviewReadSaved,
    'stored today' || 'heart rate, movement and sleep' || 'resting heart rate flags' => l.reviewReadHeart,
    'wear coverage' => l.reviewReadWear,
    'journal fields' || 'journal values' || 'journal notes' || 'symptoms' => l.reviewReadJournal,
    'meals' => l.reviewReadMeals,
    'medication definitions' || 'medication doses' => l.reviewReadMedicines,
    'device observations' || 'observation labels' || 'BMI permissions' => l.reviewReadDevices,
    'calculation timestamp' => l.reviewReadTime,
    'wake timeline' => l.reviewReadWake,
    'profile' => l.reviewReadProfile,
    _ => l.reviewReadSaved,
  };
}
