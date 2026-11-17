// GUIDE #2: set an alarm, or a different time each day.
//
//   Sleep tab, expand the containing section if folded  ->  "Alarm"  ->  Alarm screen:
//   pick a day tab, turn that day on (the first row under the tabs)  ->  its
//   "Wake time", choose the time, then Save.
//
// Also: Settings -> "Alarm" (footer 1). On integrate/next the alarm screen has
// no separate "weekly schedule" list: the seven day tabs choose a day, and
// ONE section under them (Alarm on/off, Wake time, ...) edits that day. So the
// path is: tabs + on/off row (step 2), then Wake time and Save (step 3).
//
// CLAIM(alarm-keys): step 2 and 3 stand on keys, because two of the rows are
// not localised on this screen ("Alarm" prints in English in every language) and
// the Wake time row is drawn dimmed while its day is off. 'alarm-day-enabled'
// is the on/off row; 'alarm-wake-time' exists only while the day is on, so step
// 3 is reached exactly when step 2 is done [alarm.dart; guide_conformance_test].
// ↳ CLAIM(alarm-keys)
//
// One path serves both band generations: alarm.dart and sleep_tab.dart never
// branch on generation (checked by reading them), so ONE 'any' variant. The
// screen draws and edits offline too, so unlike the older screen nothing here
// depends on the band being connected.

import 'package:flutter/widgets.dart' show ValueKey;

import 'guide.dart';
import 'guide_navigation.dart';
import 'guide_content.dart';
import 'guide_copy.dart';
import 'guide_labels.dart';
import 'guide_target.dart';

final _alarmRow = GuideTarget.label(ScreenLabel.settingsAlarmRowTitle);
// The Sleep tab's own warning line: printed on that page in every state (sleep_detail.dart
// `_frame`), so the anchor does not also resolve on Today or Health, which print a
// "Sleep" label of their own.
final _sleepTab = GuideTarget.firstLabel(ScreenLabel.sleepDetailNavTitle);
final _dayOnRow = GuideTarget.key(const ValueKey('alarm-day-enabled'));
final _wakeTime = GuideTarget.key(const ValueKey('alarm-wake-time'));

/// The seven day tabs (0 = Monday ... 6 = Sunday), kept readable on step 2.
final _dayTabs = [for (var d = 0; d < 7; d++) GuideTarget.key(ValueKey('wake-day-$d'))];
final _dayTabKeys = KeyedContent([for (var d = 0; d < 7; d++) ValueKey('wake-day-$d')]);

Guide get alarmScheduleGuide => Guide(
      id: 'alarm-schedule',
      title: GuideCopy.alarmTitle,
      start: GuideStart.sleep,
      variants: [
        GuideVariant(steps: [
          GuideStep(
            id: 'open-alarm',
            node: GuideNode.sleep,
            target: _alarmRow,
            anchor: _sleepTab,
            action: GuideAction.scrollThenTap,
            caption: GuideCopy.alarmCaptionOpenAlarm,
          ),
          GuideStep(
            id: 'pick-day',
            node: GuideNode.alarm,
            target: _dayOnRow,
            anchor: _dayOnRow,
            alsoKeep: _dayTabs,
            alsoTap: [_dayTabKeys], // "Tap the tab of the day you want": all seven
            action: GuideAction.tap,
            caption: GuideCopy.alarmCaptionPickDay,
          ),
          GuideStep(
            id: 'set-wake-time',
            node: GuideNode.alarm,
            target: GuideTarget.label(ScreenLabel.alarmSave),
            // Save exists even with every day off. Wake time gates this step.
            anchor: _wakeTime,
            // Editing the picker is context, not completion: main's alsoTap
            // alternatives complete the action, whose target here is Save.
            alsoKeep: [_wakeTime],
            action: GuideAction.tap,
            caption: GuideCopy.alarmCaptionSetWakeTime,
          ),
        ]),
      ],
      footers: [
        GuideFooter(
          kind: GuideFooterKind.anotherWay,
          title: GuideCopy.alarmFooter0Title,
          body: GuideCopy.alarmFooter0Body,
        ),
        GuideFooter(
          kind: GuideFooterKind.missingTarget,
          title: GuideCopy.alarmFooter1Title,
          body: GuideCopy.alarmFooter1Body,
        ),
      ],
    );
