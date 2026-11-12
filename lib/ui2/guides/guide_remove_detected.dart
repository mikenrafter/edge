// GUIDE #4: remove a nap or workout that wasn't real.
//
//   Today: the "Review activities" card (shown only while something waits)  ->
//   the review screen: "Discard" on the nap or workout that didn't happen  ->
//   "Save" in the bar that appears once a decision is staged.
//
// On integrate/next the review is the day breakdown in review mode
// (day_timeline.dart + day_review.dart): every pending row carries Keep /
// Discard / Edit, and a Discard is STAGED until Save (nothing is removed
// before). So there is no "Not a nap" / "Not a workout" pair here; those two
// labels live on the Naps screen only (footer 1).
//
// CLAIM(review-keys): step 2's anchor is the review screen's nav bar, keyed
// 'day-review-nav' only while reviewing, because "Discard" is printed once per
// pending row and so is ambiguous (not found) with two or more rows; step 3's
// anchor is the Save label, which exists only while something is staged
// [guide_conformance_test 'review keys'].
// ↳ CLAIM(review-keys)
//
// Step 1's card exists only while something is waiting; with nothing pending
// the Home card reads "Breakdown of your day" and the target is absent (the
// missing-target help says where else to look). With several pending rows the
// "Discard" target is ambiguous and the card is shown without an outline.

import 'package:flutter/widgets.dart' show ValueKey;

import 'guide.dart';
import 'guide_target.dart';

final _card = GuideTarget.label((l) => l.homeReviewActivities);
final _reviewNav = GuideTarget.key(const ValueKey('day-review-nav'));
final _discard = GuideTarget.label((l) => l.dayReviewDiscard);
final _save = GuideTarget.label((l) => l.dayReviewSave);

Guide get removeDetectedGuide => Guide(
      id: 'remove-detected',
      title: (l) => l.guideRemoveTitle,
      start: GuideStart.today,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-detected',
            target: _card,
            anchor: _card,
            action: GuideAction.tap,
            caption: (l) => l.guideRemoveStep1(l.tabToday, l.homeReviewActivities),
          ),
          GuideStep(
            id: 'discard',
            target: _discard,
            anchor: _reviewNav,
            action: GuideAction.tap,
            caption: (l) => l.guideRemoveStep2(l.dayReviewDiscard),
          ),
          GuideStep(
            id: 'save',
            target: _save,
            anchor: _save,
            action: GuideAction.tap,
            caption: (l) => l.guideRemoveStep3(l.dayReviewSave),
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.anotherWay,
          title: (l) => l.guideRemoveSavedTitle,
          body: (l) => l.guideRemoveSavedBody(l.tabSleep, l.sleepDetailEditNaps, l.napsNotANapLabel, l.napsDeleteLabel),
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: (l) => l.guideRemoveMissingTitle(l.homeReviewActivities),
          body: (l) => l.guideRemoveMissingBody(l.tabSleep, l.sleepDetailEditNaps, l.tabActivity, l.workoutTabHistory),
        ),
      ],
    );
