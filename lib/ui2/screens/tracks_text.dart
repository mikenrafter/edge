// Track labels are shared by the hub, editor and timed logger.
import 'package:flutter/widgets.dart';
import '../../l10n/app_localizations.dart';

String tracksText(BuildContext context, String key) {
  final l = AppLocalizations.of(context);
  return switch (key) {
    'LearningNeedData' =>
      l?.tracksLearningNeedData ?? "Waiting for comparable nights",
    'CoverageHold' =>
      l?.tracksCoverageHold ?? "Waiting for better recording coverage",
    'LoggingIncomplete' =>
      l?.tracksLoggingIncomplete ?? "Confirm logging to compare nights",
    'LearningReady' => l?.tracksLearningReady ?? "Learning from matched nights",
    'CannotSeparate' => l?.tracksCannotSeparate ?? "Can't separate yet",
    'GlobalLearning' =>
      l?.tracksGlobalLearning ?? "Observing \u00b7 first 28 days",
    'NoneToday' => l?.tracksNoneToday ?? "None today?",
    'LogEveryTime' => l?.tracksLogEveryTime ?? "I log every time",
    'Title' => l?.tracksTitle ?? "Tracks",
    'Subtitle' => l?.tracksSubtitle ?? "Your activities, timing and context",
    'QuickLog' => l?.tracksQuickLog ?? "Log a track",
    'Create' => l?.tracksCreate ?? "Create track",
    'Edit' => l?.tracksEdit ?? "Edit track",
    'Save' => l?.tracksSave ?? "Save",
    'Remove' => l?.tracksRemove ?? "Remove",
    'Retry' => l?.tracksRetry ?? "Try again",
    'Failed' => l?.tracksFailed ?? "Could not save or read tracks. Try again.",
    'Learning' =>
      l?.tracksLearning ??
          "Learning is not active yet. Values stay as entered.",
    'Never' => l?.tracksNever ?? "Nothing logged yet",
    'Last' => l?.tracksLast ?? "Last logged",
    'Disabled' => l?.tracksDisabled ?? "Off",
    'Enabled' => l?.tracksEnabled ?? "Enabled",
    'Name' => l?.tracksName ?? "Name",
    'Icon' => l?.tracksIcon ?? "Icon / symbol",
    'Kind' => l?.tracksKind ?? "Kind",
    'Consumed' => l?.tracksConsumed ?? "Consumed",
    'Activity' => l?.tracksActivity ?? "Activity",
    'Condition' => l?.tracksCondition ?? "Condition",
    'Unit' => l?.tracksUnit ?? "Unit",
    'Roles' => l?.tracksRoles ?? "Roles",
    'OwnSleep' => l?.tracksOwnSleep ?? "Own sleep track",
    'Detectable' => l?.tracksDetectable ?? "Detectable",
    'WorkoutModifier' => l?.tracksWorkoutModifier ?? "Workout modifier",
    'RecoveryModifier' => l?.tracksRecoveryModifier ?? "Recovery modifier",
    'ExcludeBaselines' => l?.tracksExcludeBaselines ?? "Keep out of baselines",
    'ReminderAware' => l?.tracksReminderAware ?? "Reminder-aware",
    'Systems' => l?.tracksSystems ?? "Affected systems",
    'Sleep' => l?.tracksSleep ?? "Sleep",
    'Hr' => l?.tracksHr ?? "Heart rate",
    'Hrv' => l?.tracksHrv ?? "Heart rate variability",
    'Stress' => l?.tracksStress ?? "Cortisol / stress",
    'BloodPressure' => l?.tracksBloodPressure ?? "Blood pressure",
    'Glucose' => l?.tracksGlucose ?? "Glucose",
    'SkinTemp' => l?.tracksSkinTemp ?? "Skin temperature",
    'Intensity' => l?.tracksIntensity ?? "Workout intensity / strain",
    'Recovery' => l?.tracksRecovery ?? "Recovery / readiness",
    'Mood' => l?.tracksMood ?? "Mood / mental wellness",
    'Respiration' => l?.tracksRespiration ?? "Respiration",
    'CustomSystem' => l?.tracksCustomSystem ?? "Add a system",
    'Kinetics' => l?.tracksKinetics ?? "Timing and kinetics",
    'KineticsNote' =>
      l?.tracksKineticsNote ??
          "Blank means unknown. Lock a field to prevent future learning from changing it.",
    'HalfLife' => l?.tracksHalfLife ?? "Half-life, hours",
    'Onset' => l?.tracksOnset ?? "Onset / lag, hours",
    'Tolerance' => l?.tracksTolerance ?? "Tolerance period, days",
    'Withdrawal' => l?.tracksWithdrawal ?? "Withdrawal period, days",
    'Lock' => l?.tracksLock ?? "Lock value",
    'Subactivities' => l?.tracksSubactivities ?? "Sub-activities",
    'AddSubactivity' => l?.tracksAddSubactivity ?? "Add sub-activity",
    'Overrides' =>
      l?.tracksOverrides ??
          "Optional overrides. Blank inherits the track value.",
    'Bounds' => l?.tracksBounds ?? "Daily detection bounds",
    'Min' => l?.tracksMin ?? "Minimum",
    'Max' => l?.tracksMax ?? "Maximum",
    'BoundsNote' =>
      l?.tracksBoundsNote ??
          "Below minimum can prompt a question. It never creates an occurrence.",
    'History' => l?.tracksHistory ?? "Setup history",
    'NoClean' =>
      l?.tracksNoClean ?? "No unadjusted data: this track is my baseline",
    'AddRange' => l?.tracksAddRange ?? "Add date range",
    'Done' => l?.tracksDone ?? "Done",
    'NotDone' => l?.tracksNotDone ?? "Not done",
    'From' => l?.tracksFrom ?? "From",
    'Until' => l?.tracksUntil ?? "Through",
    'Amount' => l?.tracksAmount ?? "Amount, optional",
    'Date' => l?.tracksDate ?? "Date",
    'Time' => l?.tracksTime ?? "Time",
    'Subactivity' => l?.tracksSubactivity ?? "Sub-activity, optional",
    'None' => l?.tracksNone ?? "None",
    'Logged' => l?.tracksLogged ?? "Logged",
    'Events' => l?.tracksEvents ?? "Recent events",
    'Sources' => l?.tracksSources ?? "Preset sources and limits",
    'Sections' => l?.tracksSections ?? "Your sections",
    'Workouts' => l?.tracksWorkouts ?? "Workouts",
    'Meds' => l?.tracksMeds ?? "Medication",
    'Nutrition' => l?.tracksNutrition ?? "Nutrition",
    'Wellness' => l?.tracksWellness ?? "Mental wellness",
    'Invalid' =>
      l?.tracksInvalid ??
          "Enter a name, valid dates and non-negative finite values. Maximum must be at least minimum.",
    'Untimed' => l?.tracksUntimed ?? "Time unknown",
    'Duration' => l?.tracksDuration ?? "Duration, minutes",
    'DurationRequired' =>
      l?.tracksDurationRequired ??
          "Enter a duration greater than zero to create this workout or nap.",
    'LearningPending' => l?.tracksLearningPending ?? "Learning pending",
    'Unlock' => l?.tracksUnlock ?? 'Unlock value',
    _ => key,
  };
}

const trackRoleLabels = <String, String>{
  'own_sleep': 'OwnSleep',
  'detectable': 'Detectable',
  'workout_modifier': 'WorkoutModifier',
  'recovery_modifier': 'RecoveryModifier',
  'exclude_baselines': 'ExcludeBaselines',
  'reminder_aware': 'ReminderAware',
};
const trackSystemLabels = <String, String>{
  'sleep': 'Sleep',
  'hr': 'Hr',
  'hrv': 'Hrv',
  'stress': 'Stress',
  'blood_pressure': 'BloodPressure',
  'glucose': 'Glucose',
  'skin_temp': 'SkinTemp',
  'workout_intensity': 'Intensity',
  'recovery': 'Recovery',
  'mood': 'Mood',
  'respiration': 'Respiration',
};
const trackKineticLabels = <String, String>{
  'half_life_hours': 'HalfLife',
  'onset_hours': 'Onset',
  'tolerance_days': 'Tolerance',
  'withdrawal_days': 'Withdrawal',
};

String trackLearningText(BuildContext context, String? reason) =>
    tracksText(context, switch (reason) {
      'global_learning' => 'GlobalLearning',
      'cannot_separate' => 'CannotSeparate',
      'estimated' || 'supported' => 'LearningReady',
      'logging_incomplete' => 'LoggingIncomplete',
      'coverage' => 'CoverageHold',
      null => 'LearningPending',
      _ => 'LearningNeedData',
    });
