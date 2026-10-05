// Settings > Hardware > "Gesture failures" and its list.
//
// USER: "Settings gets a 'Gesture failures' row (in the Hardware accordion)
// listing them with the same save/report actions." (The Home card says
// dismissed failures stay viewable here.)
//
// ASSUMED API:
//   * lib/ui2/profile/settings.dart, MoreSettingsView: new optional
//     `VoidCallback? onGestureFailures`; the Hardware accordion gets a fourth
//     row, `SetRow` titled "Gesture failures", key `settings-gesture-failures`,
//     LAST in the accordion (after Haptics): My devices, Gestures, Haptics,
//     Gesture failures. Always drawn (an empty list says so). The accordion id
//     stays `settings_band`; no other group changes.
//   * NEW lib/ui2/profile/gesture_failures.dart:
//       class GestureFailuresView extends StatelessWidget {
//         const GestureFailuresView({super.key, required List<GestureFailure>
//             failures, GestureLogSaver? onSave, Future<bool> Function(String
//             url)? onOpenLink});
//       }
//     A screen titled "Gesture failures" (NavBar). [failures] are newest first
//     and ALL are listed, dismissed ones too (marked "Dismissed"). One row per
//     failure, key `gesture-failure-row:<gestureId>`, showing the kind ("ECG
//     gesture" / "Double tap"), the reason, the time, and two actions keyed
//     `gesture-failure-save:<gestureId>` ("Save log file") and
//     `gesture-failure-report:<gestureId>` ("Report", the same sheet as the
//     Home card: `gesture-report-sheet` with the GitHub issues, Discord and
//     Reddit rows). Empty: a line keyed `gesture-failures-empty`, "No gesture
//     failures". Defaults `saveGestureLog` and `open3rdPartyLink`.
//     `class GestureFailures extends StatelessWidget` is the route that feeds
//     it from `AppState.gestureFailures` (listening to the store).
//   * docs/navigation-depth.md names the new row.
//
// Failure mode today: no row, no screen (this file does not compile until
// lib/ui2/profile/gesture_failures.dart exists).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/gesture_failures.dart';
import 'package:openstrap_edge/platform/app_icon.dart';
import 'package:openstrap_edge/ui2/community_links.dart';
import 'package:openstrap_edge/ui2/profile/gesture_failures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/themed_settings_helpers.dart';
import 'support/dart_source_lexical.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 4, 12, 7, 31);

GestureFailure _f(String id,
        {GestureFailureKind kind = GestureFailureKind.ecg,
        String reason = 'start_failed',
        int minute = 0,
        bool dismissed = false}) =>
    GestureFailure(
      gestureId: id,
      at: _t0.add(Duration(minutes: minute)),
      kind: kind,
      reason: reason,
      log: 'log of $id',
      dismissed: dismissed,
    );

class _Rig {
  final saved = <String>[];
  final opened = <String>[];
  bool saveOk = true;

  Widget view(List<GestureFailure> failures, {double scale = 1}) => Builder(
        builder: (c) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: GestureFailuresView(
            failures: failures,
            onSave: (f) async {
              saved.add(f.gestureId);
              return saveOk;
            },
            onOpenLink: (url) async {
              opened.add(url);
              return true;
            },
          ),
        ),
      );
}

Widget _settings(VoidCallback? onFailures, {bool dev = false}) {
  final named = <Symbol, dynamic>{
    #devMode: dev,
    #relaySupported: true,
    #version: '0.9.99 (1)',
    #appIcon: AppIconChoice.colourful,
    #showHealthShare: true,
    #showUpdateChecks: true,
    #onGestureFailures: onFailures,
  };
  try {
    return Function.apply(MoreSettingsView.new, const [], named) as Widget;
  } on NoSuchMethodError {
    named.remove(#onGestureFailures);
    return Function.apply(MoreSettingsView.new, const [], named) as Widget;
  }
}

Finder _section(String title) => find.byWidgetPredicate(
    (w) => w is SettingsAccordion && w.title == title,
    description: 'SettingsAccordion "$title"');

List<String> _rows(WidgetTester t, String section) => [
      for (final r in t.widgetList<SetRow>(find.descendant(
          of: _section(section), matching: find.byType(SetRow))))
        r.title,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboardCalls = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clipboardCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method.startsWith('Clipboard.')) clipboardCalls.add(call.method);
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  group('the Settings row', () {
    testWidgets('Hardware lists it last, after Haptics; no other group '
        'changed', (t) async {
      g123View(t, height: 30000);
      await t.pumpWidget(g123App(_settings(() {})));
      await g123Settle(t);
      expect(_rows(t, 'Hardware'),
          ['My devices', 'Gestures', 'Haptics', 'Gesture failures']);
      expect(
          [for (final a in t.widgetList<SettingsAccordion>(
              find.byType(SettingsAccordion))) a.title],
          [
            'You & preferences',
            'Hardware',
            'Alerts',
            'Data & privacy',
            'Community',
            'Connections',
            'About',
          ]);
      expect(t.widget<SettingsAccordion>(_section('Hardware')).id,
          'settings_band');
    });

    testWidgets('tapping the row calls onGestureFailures once', (t) async {
      var opened = 0;
      g123View(t, height: 30000);
      await t.pumpWidget(g123App(_settings(() => opened++)));
      await g123Settle(t);
      await t.tap(find.byKey(const ValueKey('settings-gesture-failures')));
      await t.pumpAndSettle();
      expect(opened, 1);
    });

    test('the stateful Settings passes the callback and the route exists', () {
      final src = File('lib/ui2/profile/settings.dart').readAsStringSync();
      final code = codeOnly(src);
      expect(code, contains('onGestureFailures:'));
      expect(code, contains('GestureFailures()'));
      expect(src, contains('gesture_failures.dart'));
    });

    test('docs/navigation-depth.md names the row', () {
      final doc = File('docs/navigation-depth.md').readAsStringSync();
      expect(doc, contains('Gesture failures'));
    });
  });

  group('the list', () {
    testWidgets('empty: says so', (t) async {
      g123View(t);
      await t.pumpWidget(g123App(_Rig().view(const [])));
      await g123Settle(t);
      expect(find.byKey(const ValueKey('gesture-failures-empty')),
          findsOneWidget);
      expect(find.text('No gesture failures'), findsOneWidget);
    });

    testWidgets('every failure is listed, newest first, dismissed ones '
        'marked', (t) async {
      g123View(t, height: 1600);
      final all = [
        _f('c', minute: 20),
        _f('b', kind: GestureFailureKind.doubleTap, reason: 'log_water', minute: 10),
        _f('a', dismissed: true),
      ];
      await t.pumpWidget(g123App(_Rig().view(all)));
      await g123Settle(t);
      final ys = [
        for (final id in ['c', 'b', 'a'])
          t.getTopLeft(find.byKey(ValueKey('gesture-failure-row:$id'))).dy,
      ];
      expect(ys[0], lessThan(ys[1]));
      expect(ys[1], lessThan(ys[2]));
      final dismissedRow = find.byKey(const ValueKey('gesture-failure-row:a'));
      expect(find.descendant(of: dismissedRow, matching: find.text('Dismissed')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('gesture-failure-row:c')),
              matching: find.text('Dismissed')),
          findsNothing);
    });

    testWidgets('a row says the kind and the reason', (t) async {
      g123View(t, height: 1600);
      await t.pumpWidget(g123App(_Rig().view([
        _f('b', kind: GestureFailureKind.doubleTap, reason: 'log_water'),
        _f('a', minute: -5),
      ])));
      await g123Settle(t);
      final ecg = find.byKey(const ValueKey('gesture-failure-row:a'));
      expect(find.descendant(of: ecg, matching: find.textContaining('ECG')),
          findsWidgets);
      expect(find.descendant(of: ecg, matching: find.textContaining('start_failed')),
          findsWidgets);
      final dt = find.byKey(const ValueKey('gesture-failure-row:b'));
      expect(find.descendant(of: dt, matching: find.textContaining('log_water')),
          findsWidgets);
      expect(find.descendant(of: dt, matching: find.textContaining('ECG')),
          findsNothing);
    });

    testWidgets('Save log file on a row saves THAT failure, never the '
        'clipboard', (t) async {
      g123View(t, height: 1600);
      final r = _Rig();
      await t.pumpWidget(
          g123App(r.view([_f('b', minute: 10), _f('a')])));
      await g123Settle(t);
      await t.tap(find.byKey(const ValueKey('gesture-failure-save:a')));
      await t.pumpAndSettle();
      expect(r.saved, ['a']);
      await t.tap(find.byKey(const ValueKey('gesture-failure-save:b')));
      await t.pumpAndSettle();
      expect(r.saved, ['a', 'b']);
      expect(clipboardCalls, isEmpty);
    });

    testWidgets('Report opens the same sheet: the GitHub issues, Discord '
        'and Reddit links', (t) async {
      g123View(t, height: 1600);
      final r = _Rig();
      await t.pumpWidget(g123App(r.view([_f('a')])));
      await g123Settle(t);
      await t.tap(find.byKey(const ValueKey('gesture-failure-report:a')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('gesture-report-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('gesture-report-encourage')),
          findsOneWidget);
      await t.tap(find.byKey(const ValueKey('gesture-report-github')));
      await t.pumpAndSettle();
      expect(r.opened.last, '$kGithubUrl/issues');
    });

    for (final scale in const [1.0, 1.3]) {
      testWidgets('fits 360 pt at text scale $scale', (t) async {
        g123View(t, width: 360, height: 1600);
        await t.pumpWidget(g123App(_Rig().view([
          _f('c', minute: 20),
          _f('b', kind: GestureFailureKind.doubleTap, reason: 'log_water: no band', minute: 10),
          _f('a', dismissed: true),
        ], scale: scale)));
        await g123Settle(t);
        expect(t.takeException(), isNull);
        for (final id in ['a', 'b', 'c']) {
          final row = t.getRect(find.byKey(ValueKey('gesture-failure-row:$id')));
          expect(row.right, lessThanOrEqualTo(360), reason: id);
          for (final k in ['gesture-failure-save:$id', 'gesture-failure-report:$id']) {
            final b = t.getRect(find.byKey(ValueKey(k)));
            expect(b.right, lessThanOrEqualTo(360), reason: k);
          }
        }
      });
    }
  });

  test('the route feeds the list from AppState.gestureFailures', () {
    final src =
        File('lib/ui2/profile/gesture_failures.dart').readAsStringSync();
    final code = codeOnly(src);
    expect(code, contains('gestureFailures'));
    expect(code, contains('GestureFailuresView('));
  });
}
