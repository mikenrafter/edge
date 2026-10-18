// One name per feature. The phone-notification relay is "App
// notifications on the band" wherever its title shows; the battery alerts
// group is "Band battery"; the Alarm screen has no Haptics group (the alarm
// buzz is the band's own) and says so once, in Wake.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show NavBar;

import 'support/settings_sections.dart';

const _relayName = 'App notifications on the band';
// Dropped from the Alarm screen (Oct 4); the test says it stays gone.
const _alarmCaption = "The alarm uses the band's own buzz.";

final _schedule = fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(weekday: 5, hour: 6, minute: 30, enabled: true),
  AlarmScheduleEntry(weekday: 2, hour: 7, minute: 0, enabled: true),
]);

AlarmScreenView _alarm({bool connected = true}) => AlarmScreenView(
  connected: connected,
  schedule: _schedule,
  armedAt: DateTime(2026, 8, 22, 6, 30),
  state: AlarmArmState.confirmed,
  now: DateTime(2026, 8, 21, 22, 40),
);

void main() {
  group('App notifications on the band', () {
    testWidgets('is the screen title, and the old title is gone', (t) async {
      await pumpTall(t, const BandNotificationsView(enabled: true, granted: true));
      expect(
        find.descendant(
          of: find.byType(NavBar),
          matching: find.text(_relayName),
        ),
        findsOneWidget,
      );
      expect(find.text('Band notifications'), findsNothing);
    });

    testWidgets('is the first group header, replacing "Relay"', (t) async {
      await pumpTall(t, const BandNotificationsView(enabled: true, granted: true));
      final titles = sectionTitles(t);
      expect(titles, contains(_relayName));
      expect(titles, isNot(contains('Relay')));
      expect(titles.first, _relayName);
    });

    testWidgets('names the Settings row', (t) async {
      await pumpTall(t, const MoreSettingsView(relaySupported: true));
      expect(find.text(_relayName), findsOneWidget);
      expect(find.text('Band notifications'), findsNothing);
    });

    testWidgets('Alerts no longer shows an Android Relay group', (t) async {
      await pumpTall(t, const NotificationSettingsView(relaySupported: true));
      expect(find.text('Android Relay'), findsNothing);
      expect(sectionTitles(t), isNot(contains('Android Relay')));
    });
  });

  group('Band battery', () {
    testWidgets('replaces "Band alerts" in Alerts', (t) async {
      await pumpTall(t, const NotificationSettingsView());
      expect(find.text('Band alerts'), findsNothing);
      expect(find.text('Band battery'), findsWidgets);
    });
  });

  group('Alarm', () {
    testWidgets('has Alarm and wake, then Timeline and status, and no Haptics '
        'group', (t) async {
      await pumpTall(t, _alarm());
      expect(sectionTitles(t), ['Alarm and wake', 'Timeline and status']);
      expect(find.text('Haptics'), findsNothing);
    });

    testWidgets('has no disabled Buzz pattern row', (t) async {
      await pumpTall(t, _alarm());
      expect(find.text('Buzz pattern'), findsNothing);
      expect(
        find.text("The band alarm uses the band's own buzz"),
        findsNothing,
        reason: 'the old Haptics wording is gone with the group',
      );
    });

    for (final connected in [true, false]) {
      testWidgets('no own-buzz caption anywhere (connected: $connected)',
          (t) async {
        await pumpTall(t, _alarm(connected: connected));
        expect(find.text(_alarmCaption), findsNothing,
            reason: 'dropped with the Alarm rework (Oct 4)');
      });
    }
  });
}
