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
    'ExperimentStart' => l?.tracksExperimentStart ?? 'Start an experiment',
    'ExperimentView' => l?.tracksExperimentView ?? 'View experiment',
    'ExperimentViewLast' =>
      l?.tracksExperimentViewLast ?? 'View last experiment',
    'Prescribed' =>
      l?.tracksPrescribed ?? 'Prescribed by a clinician',
    'PrescribedNote' =>
      l?.tracksPrescribedNote ??
          'The app never asks you to skip a prescribed treatment.',
    'ExperimentPrescribed' =>
      l?.tracksExperimentPrescribed ??
          'Prescribed treatments are never randomized; the app will not ask you to skip one. Talk to your clinician about changes.',
    'ExperimentStop' => l?.tracksExperimentStop ?? 'Stop experiment',
    'ExperimentStopped' => l?.tracksExperimentStopped ?? 'Stopped',
    'ExperimentStoppedNote' =>
      l?.tracksExperimentStoppedNote ??
          'You stopped this experiment early, so no effect is reported and no more reminders are sent.',
    'ExperimentDid' => l?.tracksExperimentDid ?? 'I did it',
    'ExperimentDidnt' => l?.tracksExperimentDidnt ?? 'I did not',
    'ExperimentSetup' => l?.tracksExperimentSetup ?? 'Experiment setup',
    'ExperimentTitle' => l?.tracksExperimentTitle ?? 'Experiment',
    'ExperimentExplain' =>
      l?.tracksExperimentExplain ??
          'The app randomly assigns each day to do it or skip it, in balanced pairs, and reminds you each morning. Log it on do days and confirm none on skip days; only confirmed days count. At the end it reports the effect with its uncertainty.',
    'ExperimentBegin' => l?.tracksExperimentBegin ?? 'Begin experiment',
    'ExperimentFailed' =>
      l?.tracksExperimentFailed ??
          'Could not start. Another experiment may already cover these days.',
    'ExperimentRunning' => l?.tracksExperimentRunning ?? 'Running',
    'ExperimentCompleted' => l?.tracksExperimentCompleted ?? 'Completed',
    'ExperimentPending' =>
      l?.tracksExperimentPending ??
          'The effect, with its uncertainty, is reported when the experiment ends.',
    'ExperimentEffectHeading' =>
      l?.tracksExperimentEffectHeading ?? 'Effect with uncertainty',
    'ExperimentLowAdherence' =>
      l?.tracksExperimentLowAdherence ??
          'Too few assigned days were confirmed to report an effect.',
    'ExperimentLowData' =>
      l?.tracksExperimentLowData ??
          'Not enough nights on both kinds of day to report an effect.',
    'ExperimentDo' => l?.tracksExperimentDo ?? 'Do it',
    'ExperimentSkip' => l?.tracksExperimentSkip ?? 'Skip it',
    'ExperimentLearning' =>
      l?.tracksExperimentLearning ??
          'Experiment running: only its days count',
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
      'experiment_learning' => 'ExperimentLearning',
      null => 'LearningPending',
      _ => 'LearningNeedData',
    });

String experimentWeeksText(BuildContext context, int weeks) =>
    AppLocalizations.of(context)?.tracksExperimentWeeks(weeks) ?? '$weeks weeks';

String experimentAdherenceText(BuildContext context, int followed, int total) =>
    AppLocalizations.of(context)?.tracksExperimentAdherence(followed, total) ??
    '$followed of $total assigned days confirmed';

/// Unit of each system's stored nightly outcome (see _experimentReport):
/// sleep is total sleep time in minutes, hr is resting bpm, hrv is RMSSD ms.
const experimentUnits = <String, String>{
  'sleep': 'min',
  'hr': 'bpm',
  'hrv': 'ms',
  'stress': 'points',
  'skin_temp': '°C',
  'workout_intensity': 'points',
  'recovery': 'points',
  'respiration': 'breaths/min',
};

/// Difference of means, do minus skip, in the system's unit, with its 95%
/// interval and arm sizes.
String experimentEffectText(
  BuildContext context,
  String systemKey,
  String system,
  Map effect,
) {
  String n(Object? v) => (v as num).toStringAsFixed(1);
  final unit = experimentUnits[systemKey] ?? '';
  String signed(Object? v) => (v as num) > 0 ? '+${n(v)}' : n(v);
  return AppLocalizations.of(context)?.tracksExperimentEffectLine(
        system,
        signed(effect['effect']),
        unit,
        n(effect['lower']),
        n(effect['upper']),
        effect['n_do'] as int,
        effect['n_dont'] as int,
      ) ??
      '$system: ${signed(effect['effect'])} $unit (do minus skip; 95% interval ${n(effect['lower'])} to ${n(effect['upper'])} $unit); '
          '${effect['n_do']} do days, ${effect['n_dont']} skip days';
}

/// One line saying that several 95% intervals were reported side by side.
String experimentMultiplicityText(BuildContext context, int count) =>
    AppLocalizations.of(context)?.tracksExperimentMultiplicity(count) ??
    'Each interval covers one system at 95%. With $count systems compared, about one in twenty intervals would miss by chance alone, so treat one that only just excludes zero with caution.';

/// Why a long-washout track cannot be randomized in two-day blocks.
String experimentWashoutText(BuildContext context, double days) {
  final shown = days.toStringAsFixed(1);
  return AppLocalizations.of(context)?.tracksExperimentWashout(shown) ??
      'This track takes about $shown days to wear off (five half-lives, or its withdrawal period). '
          'Experiment days alternate every day, so a skip day would still carry the last dose and the result would be biased. '
          'Experiments are not offered for it.';
}
