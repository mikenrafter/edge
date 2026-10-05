// 8K — dependent setting rows are never hidden. While their parent is off they
// are present, disabled (taps do nothing) and dimmed (an Opacity < 1 at or
// above the row). Platform-irrelevant rows are still omitted (phase 3).
// See test/phase8/CONTRACTS.md §8K.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';

import 'support/dart_source_lexical.dart';
import 'support/settings_sections.dart';

void main() {
  group('Alarm', () {
    testWidgets('a day that is off keeps its Wake time row, dimmed and inert',
        (t) async {
      final schedule = fillDefaultAlarmSchedule(const [
        AlarmScheduleEntry(weekday: 0, hour: 7, minute: 0, enabled: true),
      ]);
      await pumpTall(t, AlarmScreenView(connected: true, schedule: schedule));
      // The day tabs pick the day; Tuesday is off.
      await t.tap(find.byKey(const ValueKey('wake-day-1')));
      await t.pumpAndSettle();
      final row = find.text('Wake time');
      expect(row, findsOneWidget, reason: 'present on a day that is off');
      expect(isDimmed(t, row), isTrue);
      await t.tap(row, warnIfMissed: false);
      await t.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsNothing,
          reason: 'a disabled row opens nothing');
    });
  });

  group('Notifications', () {
    testWidgets('water off: "Remind me every" is present, dimmed, inert',
        (t) async {
      final changes = <NotificationPrefs>[];
      await pumpTall(
          t,
          NotificationSettingsView(
            prefs: const NotificationPrefs(waterEnabled: false),
            onChanged: (n) async => changes.add(n),
          ));
      final row = find.text('Remind me every');
      expect(row, findsOneWidget);
      expect(isDimmed(t, row), isTrue);
      await t.tap(row, warnIfMissed: false);
      expect(changes, isEmpty);
    });

    testWidgets('band alerts off: "Alert me at" is present, dimmed, inert',
        (t) async {
      final changes = <NotificationPrefs>[];
      await pumpTall(
          t,
          NotificationSettingsView(
            prefs: const NotificationPrefs(deviceEnabled: false),
            onChanged: (n) async => changes.add(n),
          ));
      final row = find.text('Alert me at');
      expect(row, findsOneWidget);
      expect(isDimmed(t, row), isTrue);
      await t.tap(row, warnIfMissed: false);
      expect(changes, isEmpty);
    });

    testWidgets('a parent that is ON leaves its row enabled', (t) async {
      await pumpTall(
          t,
          const NotificationSettingsView(
            prefs: NotificationPrefs(waterEnabled: true),
          ));
      expect(find.text('Remind me every'), findsOneWidget);
      expect(isDimmed(t, find.text('Remind me every')), isFalse);
    });
  });

  group('Band notifications', () {
    testWidgets('relay off: the app list is present, dimmed, inert', (t) async {
      final taps = <String>[];
      await pumpTall(
          t,
          BandNotificationsView(
            enabled: false,
            granted: true,
            apps: const [RelayApp('com.whatsapp', on: true)],
            onApp: (pkg, _) => taps.add(pkg),
          ));
      final count = find.text('Apps that can buzz');
      expect(count, findsOneWidget);
      expect(isDimmed(t, count), isTrue);
      final app = find.text('com.whatsapp');
      expect(app, findsOneWidget);
      expect(isDimmed(t, app), isTrue);
      await t.tap(app, warnIfMissed: false);
      expect(taps, isEmpty);
    });

    // 8AE: Starts/Ends belong to a channel's own override and are not drawn
    // while it follows the global quiet hours (the one deliberate exception to
    // disable-not-hide: a time with no setting behind it would mislead).
    testWidgets('override off: Starts/Ends are hidden, the switch is present',
        (t) async {
      await pumpTall(
          t,
          const BandNotificationsView(
            enabled: true,
            granted: true,
            channels: {'apps': ChannelConfig(enabled: true)},
          ));
      expect(find.text('Starts'), findsNothing);
      expect(find.text('Ends'), findsNothing);
      expect(find.text('Override quiet hours'), findsWidgets);
    });

    testWidgets('alarm haptic matching off: Fallback rhythm present, dimmed',
        (t) async {
      await pumpTall(
          t,
          const BandNotificationsView(
            enabled: true,
            granted: true,
            channels: {'alarms': ChannelConfig(enabled: true)},
          ));
      final row = find.text('Fallback rhythm');
      expect(row, findsOneWidget);
      expect(isDimmed(t, row), isTrue);
    });
  });

  group('Gestures', () {
    testWidgets('Mark moment off: the replay switch is present and disabled',
        (t) async {
      await pumpTall(
          t,
          BandGesturesView(
            chosen: const {},
            supported: const {DeviceAction.none, DeviceAction.markMoment},
            onToggle: (_, _) {},
            onReplay: (_, _) {},
          ));
      final label = find.text('Also run for taps replayed from history');
      expect(label, findsOneWidget);
      final sw = find.descendant(
          of: find.ancestor(of: label, matching: find.byType(Row)).first,
          matching: find.byType(Switch));
      expect(t.widget<Switch>(sw).onChanged, isNull);
      expect(isDimmed(t, label), isTrue);
    });
  });

  group('Alerts', () {
    // The HR zone alert moved from Settings > Band to Alerts (8AF.6).
    testWidgets('HR zone alert off: Target zone present, dimmed', (t) async {
      await pumpTall(t, const NotificationSettingsView());
      final row = find.text('Target zone');
      expect(row, findsOneWidget);
      expect(isDimmed(t, row), isTrue);
    });
  });

  group('source guard: no setting row is revealed by a collection-if', () {
    // Scanned: the settings views. A collection-if whose body is a settings
    // row (SetRow, SwitchRow, _AlertRow, _AppRow, the local `row(` helper),
    // a `...[` list whose direct children include one, or a spread of a
    // `..._xxxRows(` helper, is flagged unless EVERY `&&`/`||` term of its
    // condition is on the allow-list below.
    //
    // ALLOW-LIST (documented in CONTRACTS.md §8K):
    //   platform/OS capability: Platform.isX, defaultTargetPlatform, android,
    //     ios, *supported / *Supported, .supportsX, appIcon != null
    //   build capability: showHealthShare, showUpdateChecks, devMode,
    //     version.isNotEmpty
    //   load state: loaded
    //   structural identity: name == ... (which channel this row list is for)
    //   8AE: cfg.overrideQuietHours (a channel's own Starts/Ends exist only
    //     while it overrides the global quiet hours)
    // Permission/status CARDS are StatusCard, not rows, so they never match.
    const files = [
      'lib/ui2/profile/settings.dart',
      'lib/ui2/profile/band_notifications.dart',
      'lib/ui2/profile/alarm.dart',
      'lib/ui2/profile/gestures.dart',
      'lib/ui2/profile/data.dart',
    ];
    final rowStart = RegExp(
        r'^(const\s+)?(SetRow(\.brand)?|SwitchRow|_AlertRow|_AppRow|row)\s*\(');
    final rowsSpread = RegExp(r'^\.\.\.\s*_\w*[Rr]ows\s*\(');
    final allowed = [
      RegExp(r'^Platform\.is\w+$'),
      RegExp(r'defaultTargetPlatform'),
      RegExp(r'^(android|ios|isAndroid|isIOS)$'),
      RegExp(r'^[\w.]*[sS]upported$'),
      RegExp(r'^[\w.]*\.supports\w+$'),
      RegExp(r'^appIcon != null$'),
      RegExp(r'^(showHealthShare|showUpdateChecks|devMode|loaded)$'),
      RegExp(r'^version\.isNotEmpty$'),
      RegExp(r'^name == '),
      // Gestures: which tab this is (the replay switch is the double tap\'s).
      RegExp(r'^taps == \d$'),
      RegExp(r'^cfg\.overrideQuietHours$'),
    ];

    bool termAllowed(String term) {
      var s = term.trim();
      while (s.startsWith('!') || (s.startsWith('(') && s.endsWith(')'))) {
        s = s.startsWith('!')
            ? s.substring(1).trim()
            : s.substring(1, s.length - 1).trim();
      }
      return allowed.any((r) => r.hasMatch(s));
    }

    /// Direct children of the list literal starting at [open] ('[').
    List<String> directChildren(String code, int open) {
      final close = closingOf(code, open);
      final kids = <String>[];
      var depth = 0, start = open + 1;
      for (var i = open + 1; i < close; i++) {
        final ch = code[i];
        if ('([{'.contains(ch)) depth++;
        if (')]}'.contains(ch)) depth--;
        if (depth == 0 && ch == ',') {
          kids.add(code.substring(start, i).trim());
          start = i + 1;
        }
      }
      kids.add(code.substring(start, close).trim());
      return kids.where((k) => k.isNotEmpty).toList();
    }

    List<String> scan(String path, String src) {
      final code = codeOnly(src);
      final out = <String>[];
      for (final m in RegExp(r'\bif\s*\(').allMatches(code)) {
        final open = m.end - 1;
        final close = closingOf(code, open);
        if (close < 0) continue;
        final cond = code.substring(open + 1, close);
        final rest = code.substring(close + 1).trimLeft();
        var revealsRow = rowStart.hasMatch(rest) || rowsSpread.hasMatch(rest);
        if (!revealsRow && rest.startsWith('...')) {
          final bracket = rest.indexOf('[');
          if (bracket >= 0 && rest.substring(3, bracket).trim().isEmpty) {
            final at = code.length - rest.length + bracket;
            revealsRow = directChildren(code, at).any(rowStart.hasMatch);
          }
        }
        if (!revealsRow) continue;
        final terms = cond.split(RegExp(r'&&|\|\|'));
        if (terms.every(termAllowed)) continue;
        out.add('$path:${lineOf(code, m.start)} if (${cond.trim()})');
      }
      return out;
    }

    test('the scanner flags a known reveal and passes a platform gate', () {
      const sample = '''
final a = [
  if (prefs.waterEnabled) SetRow(i, c, 'x'),
  if (relaySupported) SetRow(i, c, 'y'),
  if (day.enabled) ...[ SetRow(i, c, 'z') ],
  if (enabled && granted) ..._appRows(c, l),
  if (loaded) ...[ SettingsAccordion('a', children: [row('b')]) ],
];
''';
      final hits = scan('sample', sample);
      expect(hits, hasLength(3));
      expect(hits.join('\n'), contains('prefs.waterEnabled'));
      expect(hits.join('\n'), contains('day.enabled'));
      expect(hits.join('\n'), contains('enabled && granted'));
    });

    test('settings views reveal no rows behind a setting', () {
      final offenders = [
        for (final f in files) ...scan(f, File(f).readAsStringSync()),
      ];
      expect(offenders, isEmpty,
          reason: 'show these disabled and dimmed instead:\n'
              '${offenders.join('\n')}');
    });
  });
}
