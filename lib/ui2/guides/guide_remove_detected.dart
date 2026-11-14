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
// pending row (the target is the first); the anchor cannot be that label, which
// is not unique with two or more rows; step 3's
// anchor is the Save label, which exists only while something is staged
// [guide_conformance_test 'review keys'].
// ↳ CLAIM(review-keys)
//
// Step 1's card exists only while something is waiting; with nothing pending
// the Home card reads "Breakdown of your day" and the target is absent (the
// missing-target help says where else to look). Every pending row has its own
// "Discard"; the step outlines the FIRST (GuideTarget.firstLabel) and its caption
// says each item has its own, so the step always points at one control.

import 'package:flutter/widgets.dart' show ValueKey;

import 'guide.dart';
import 'guide_content.dart';
import 'guide_copy.dart';
import 'guide_labels.dart';
import 'guide_target.dart';

final _card = GuideTarget.label(ScreenLabel.homeReviewActivities);
final _reviewNav = GuideTarget.key(const ValueKey('day-review-nav'));
final _discard = GuideTarget.firstLabel(ScreenLabel.dayReviewDiscard);
final _save = GuideTarget.label(ScreenLabel.dayReviewSave);

Guide get removeDetectedGuide => Guide(
      id: 'remove-detected',
      title: GuideCopy.removeTitle,
      start: GuideStart.today,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-detected',
            target: _card,
            anchor: _card,
            action: GuideAction.tap,
            caption: GuideCopy.removeCaptionOpenDetected,
          ),
          GuideStep(
            id: 'discard',
            target: _discard,
            anchor: _reviewNav,
            alsoTap: [EveryLabelled([ScreenLabel.dayReviewDiscard])], // "every item has its own"
            action: GuideAction.tap,
            caption: GuideCopy.removeCaptionDiscard,
          ),
          GuideStep(
            id: 'save',
            target: _save,
            anchor: _save,
            action: GuideAction.tap,
            caption: GuideCopy.removeCaptionSave,
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.anotherWay,
          title: GuideCopy.removeFooter0Title,
          body: GuideCopy.removeFooter0Body,
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: GuideCopy.removeFooter1Title,
          body: GuideCopy.removeFooter1Body,
        ),
      ],
    );
