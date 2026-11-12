// GUIDE #6: delete a workout.
//
//   Activity tab  ->  sub-tab "History"  ->  the bin icon at the end of the
//   session's row  ->  a confirm dialog (not framed; the first footer says what
//   confirming does).
//
// There is no delete on a session's summary: the bin is an icon with only a
// semantics label (workout_screen.dart:1113). The row shows it only for a
// session with an id. With several sessions the label is several controls: the
// target is then ambiguous and the run says so (the missing-target help). One
// 'any' variant.

import 'guide.dart';
import 'guide_copy.dart';
import 'guide_labels.dart';
import 'guide_target.dart';

final _historyTab = GuideTarget.label(ScreenLabel.workoutTabHistory);
final _bin = GuideTarget.label(ScreenLabel.workoutDeleteSessionLabel);

Guide get deleteWorkoutGuide => Guide(
      id: 'delete-workout',
      title: GuideCopy.deleteWorkoutTitle,
      start: GuideStart.activity,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-history',
            target: _historyTab,
            anchor: _historyTab,
            action: GuideAction.tap,
            caption: GuideCopy.deleteWorkoutCaptionOpenHistory,
          ),
          GuideStep(
            id: 'delete-session',
            target: _bin,
            anchor: GuideTarget.label(ScreenLabel.workoutTrackedLabel),
            action: GuideAction.tap,
            caption: GuideCopy.deleteWorkoutCaptionDeleteSession,
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.note,
          title: GuideCopy.deleteWorkoutFooter0Title,
          body: GuideCopy.deleteWorkoutFooter0Body,
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: GuideCopy.deleteWorkoutFooter1Title,
          body: GuideCopy.deleteWorkoutFooter1Body,
        ),
      ],
    );
