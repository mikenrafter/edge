// SCREEN LABELS: the words the app's own screens print, which a guide matches on
// the live screen and quotes in its captions.
//
// An enum, not closures (see guide_text.dart). Each member reads the SAME
// AppLocalizations getter the screen prints, so a guide follows the user's
// language and a renamed label stops resolving instead of drifting
// [guide_conformance_test 'CLAIM(guide-resolves)'].

import '../../l10n/app_localizations.dart';
import 'guide_text.dart';

enum ScreenLabel implements GuideText {
  alarmSave,
  activityLiveFinishSessionLabel,
  activityPickerSearchLabel,
  activitySetupHeartRateLabel,
  activitySetupPrivateLabel,
  activitySetupRouteLabel,
  activitySetupStart,
  activityZonesEditYourOwnLink,
  activityZonesSetYourOwnLink,
  activityZonesTitle,
  activityZonesYourZonesSection,
  dayReviewDiscard,
  dayReviewSave,
  dayStrainHowSet,
  homeReviewActivities,
  homeRingStrain,
  logWorkoutLogIt,
  logWorkoutWhenGroup,
  napsLogANap,
  settingsAlarmRowTitle,
  sleepDetailBackToAutomatic,
  sleepDetailChangeTimes,
  sleepDetailEditNaps,
  sleepDetailMedicalDisclaimer,
  sleepDetailSetTimesMyself,
  workoutDeleteSessionLabel,
  workoutLogPastFix,
  workoutNoSessionsTitle,
  workoutStartSessionLabel,
  workoutTabHistory,
  workoutTrackedLabel,;

  @override
  String of(AppLocalizations l) => switch (this) {
        // The fork alarm header prints Save in every locale (alarm.dart).
        ScreenLabel.alarmSave => 'Save',
        ScreenLabel.activityLiveFinishSessionLabel => l.activityLiveFinishSessionLabel,
        ScreenLabel.activityPickerSearchLabel => l.activityPickerSearchLabel,
        ScreenLabel.activitySetupHeartRateLabel => l.activitySetupHeartRateLabel,
        ScreenLabel.activitySetupPrivateLabel => l.activitySetupPrivateLabel,
        ScreenLabel.activitySetupRouteLabel => l.activitySetupRouteLabel,
        ScreenLabel.activitySetupStart => l.activitySetupStart,
        ScreenLabel.activityZonesEditYourOwnLink => l.activityZonesEditYourOwnLink,
        ScreenLabel.activityZonesSetYourOwnLink => l.activityZonesSetYourOwnLink,
        ScreenLabel.activityZonesTitle => l.activityZonesTitle,
        ScreenLabel.activityZonesYourZonesSection => l.activityZonesYourZonesSection,
        ScreenLabel.dayReviewDiscard => l.dayReviewDiscard,
        ScreenLabel.dayReviewSave => l.dayReviewSave,
        ScreenLabel.dayStrainHowSet => l.dayStrainHowSet,
        ScreenLabel.homeReviewActivities => l.homeReviewActivities,
        ScreenLabel.homeRingStrain => l.homeRingStrain,
        ScreenLabel.logWorkoutLogIt => l.logWorkoutLogIt,
        ScreenLabel.logWorkoutWhenGroup => l.logWorkoutWhenGroup,
        ScreenLabel.napsLogANap => l.napsLogANap,
        ScreenLabel.settingsAlarmRowTitle => l.settingsAlarmRowTitle,
        ScreenLabel.sleepDetailBackToAutomatic => l.sleepDetailBackToAutomatic,
        ScreenLabel.sleepDetailChangeTimes => l.sleepDetailChangeTimes,
        ScreenLabel.sleepDetailEditNaps => l.sleepDetailEditNaps,
        ScreenLabel.sleepDetailMedicalDisclaimer => l.sleepDetailMedicalDisclaimer,
        ScreenLabel.sleepDetailSetTimesMyself => l.sleepDetailSetTimesMyself,
        ScreenLabel.workoutDeleteSessionLabel => l.workoutDeleteSessionLabel,
        ScreenLabel.workoutLogPastFix => l.workoutLogPastFix,
        ScreenLabel.workoutNoSessionsTitle => l.workoutNoSessionsTitle,
        ScreenLabel.workoutStartSessionLabel => l.workoutStartSessionLabel,
        ScreenLabel.workoutTabHistory => l.workoutTabHistory,
        ScreenLabel.workoutTrackedLabel => l.workoutTrackedLabel,
      };
}
