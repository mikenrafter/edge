// The ECG counts are named "Double tap + N ECG tap(s)" on every
// screen that shows one.
//
// ASSUMED BEHAVIOUR (no new public symbol: every failure is an assertion):
//   * lib/ui2/profile/gestures.dart, BandGesturesView, ECG method: the gesture
//     tabs are named "Double tap" (count 2), "Double tap + 1 ECG tap" (3),
//     "Double tap + 2 ECG taps" (4), "Double tap + 3 ECG taps" (5): the name
//     line in each tab, and the tab's screen-reader label (the tab itself is
//     the short "+1 ECG"). They once read "2 taps" ... "5 taps" (rows, with a
//     sheet headed "3 taps does"; the sheet went with the sub-tabs). With
//     AppLocalizations in the tree the text comes from the plural message
//     (same English); with none (these plain pumps) the English fallback is
//     the same text.
//   * The "More double taps" method keeps its own names ("Double tap", "2
//     double taps", "3 double taps", "4 double taps"): only the ECG counts
//     are renamed (regression guard).
//   * lib/gestures/lab_log.dart, DeviceLabLog.endSession: for an "ECG sensor
//     touches" session the counted result reads as the name ("... | Double tap
//     + 3 ECG taps | 3.2 s in total"), a count of 2 as "Double tap"; an
//     abandoned session and a "More double taps" session are unchanged (the
//     latter still "5 taps"; there the count is double taps in a row).
//   * lib/state/app_state.dart no longer writes a bare "Result: N taps." for
//     the ECG session (source guard: it imports the name helper).
//
// Failure mode before: the rows read "2 taps" ... "5 taps".

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart' show TapCountMethod;
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/settings_sections.dart';

const _supported = {
  DeviceAction.none,
  DeviceAction.markMoment,
  DeviceAction.logWater,
};

BandGesturesView _view({bool ecg = true}) => BandGesturesView(
      chosen: const <DeviceAction>{},
      supported: _supported,
      ecgSupported: ecg,
      tapMethod: ecg ? TapCountMethod.ecg : null,
      tapActions: const {
        3: <DeviceAction>{},
        4: <DeviceAction>{},
        5: <DeviceAction>{},
      },
      onTapToggle: (n, a, on) async {},
    );

Future<void> _pumpLocalized(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 24000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: w,
  ));
  await t.pumpAndSettle();
}

const _ecgRows = [
  'Double tap',
  'Double tap + 1 ECG tap',
  'Double tap + 2 ECG taps',
  'Double tap + 3 ECG taps',
];

void main() {
  group('Gestures screen, ECG method', () {
    Future<void> expectNames(WidgetTester t) async {
      for (var n = 2; n <= 5; n++) {
        await openGesturesTab(t, n);
        expect(gesturesTabName(t), _ecgRows[n - 2], reason: 'tab $n');
      }
    }

    testWidgets('the tabs carry the new names (English fallback)', (t) async {
      await pumpTall(t, _view());
      await expectNames(t);
      expect(
          t.widget<SubTabs>(find.byType(SubTabs)).semanticLabels,
          [for (final name in _ecgRows) '$name, gesture']);
      for (final old in const ['2 taps', '3 taps', '4 taps', '5 taps']) {
        expect(find.text(old), findsNothing, reason: old);
      }
    });

    testWidgets('the same names through AppLocalizations (the plural)',
        (t) async {
      await _pumpLocalized(t, _view());
      await expectNames(t);
      expect(find.text('3 taps'), findsNothing);
    });

    testWidgets('there is no sheet to name: a tab opens no bottom sheet',
        (t) async {
      await pumpTall(t, _view());
      await openGesturesTab(t, 3);
      expect(find.text('Double tap + 1 ECG tap does'), findsNothing);
      expect(find.text('3 taps does'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    });
  });

  group('Gestures screen, More double taps method (regression guard)', () {
    testWidgets('its tabs keep their own names', (t) async {
      await pumpTall(t, _view(ecg: false));
      for (final (n, name) in const [
        (2, 'Double tap'),
        (3, '2 double taps'),
        (4, '3 double taps'),
        (5, '4 double taps'),
      ]) {
        await openGesturesTab(t, n);
        expect(gesturesTabName(t), name, reason: 'tab $n');
      }
      expect(find.textContaining('ECG tap'), findsNothing);
    });
  });

  group('Device lab log', () {
    String summary(String method, {int? count, String? reason}) {
      final lab = DeviceLabLog();
      final t0 = DateTime.utc(2026, 10, 4, 2, 7, 4);
      lab.beginSession(
          method: method, settings: 'start 200 ms', tapAt: t0, at: t0);
      lab.endSession(
          count: count, reason: reason, at: t0.add(const Duration(seconds: 3)));
      return lab.sessionSummaries.single;
    }

    test('an ECG session that counted 5 reads "Double tap + 3 ECG taps"', () {
      final s = summary('ECG sensor touches', count: 5);
      expect(s, contains('Double tap + 3 ECG taps'));
      expect(s, isNot(contains('5 taps')));
    });

    test('a count of 2 reads "Double tap", and 3 reads "+ 1 ECG tap"', () {
      expect(summary('ECG sensor touches', count: 2),
          contains('| Double tap |'));
      expect(summary('ECG sensor touches', count: 3),
          contains('Double tap + 1 ECG tap |'));
    });

    test('regression guard (passes today): an abandoned ECG session is '
        'unchanged', () {
      expect(summary('ECG sensor touches', reason: 'start_failed'),
          contains('abandoned (start_failed)'));
    });

    test('regression guard (passes today): a More double taps session keeps '
        '"N taps"', () {
      expect(summary('More double taps', count: 5), contains('| 5 taps |'));
    });
  });

  test('the gesture controller names the ECG result with the helper, not a '
      'bare count', () {
    final src = File('lib/state/gesture_controller.dart').readAsStringSync();
    expect(src, contains('gestures/tap_names.dart'));
    // The ECG session's construction in the controller, up to the next member.
    final from = src.indexOf('EcgTapSession _newEcgSession()');
    final to = src.indexOf('Completer<int?>? _tapCount;', from);
    expect(from, greaterThan(0));
    final session = src.substring(from, to);
    expect(session, contains('ecgTapCountName('));
    expect(session, isNot(contains(r"'Result: $count taps.")));
  });
}
