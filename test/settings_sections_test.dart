// Every settings list is split into SettingsAccordion sections that start
// EXPANDED. Pumped headless as the pure *View widgets.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';

import 'support/settings_sections.dart';

final _schedule = fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(weekday: 0, hour: 7, minute: 0, enabled: true),
]);

final _band = HealthSource(
  name: 'Synthetic band',
  kind: 'WHOOP 4',
  tier: SourceTier.wristOptical,
  icon: LucideIcons.watch,
  connected: true,
  isBand: true,
  family: 'gen4',
);

final Map<String, Widget> views = {
  'Settings': const MoreSettingsView(),
  'Notifications': const NotificationSettingsView(relaySupported: true),
  'App notifications on the band':
      const BandNotificationsView(enabled: true, granted: true),
  'Alarm': AlarmScreenView(connected: true, schedule: _schedule),
  'Gestures': const BandGesturesView(
    chosen: {DeviceAction.markMoment},
    supported: {DeviceAction.none, DeviceAction.markMoment, DeviceAction.torch},
  ),
  'Device detail': DeviceDetailView(_band),
  'Edit profile': EditProfileView(onSave: (_) async {}),
};

void main() {
  for (final e in views.entries) {
    testWidgets('${e.key}: has sections and every section starts expanded',
        (t) async {
      await pumpTall(t, e.value);
      await expectAllSectionsExpanded(t, e.key);
    });
  }

  testWidgets('Settings: "Hardware" (was "Band") is a section', (t) async {
    await pumpTall(t, const MoreSettingsView());
    expect(sectionTitles(t), contains('Hardware'));
  });

  testWidgets('App notifications on the band: all three channel sections start open',
      (t) async {
    await pumpTall(t, const BandNotificationsView(enabled: true, granted: true));
    for (final title in ['App notifications', 'Alarms & timers', 'Incoming calls']) {
      expect(sectionTitles(t), contains(title));
    }
    // Every channel's policy rows are visible without a tap.
    expect(find.text('Buzz during Do Not Disturb'), findsNWidgets(3));
  });

  testWidgets('a section header stays put when a row in another section changes',
      (t) async {
    await pumpTall(t, const NotificationSettingsView(relaySupported: true));
    final before = t.getTopLeft(find.text('Device'));
    await pumpTall(
        t,
        NotificationSettingsView(
          relaySupported: true,
          prefs: const NotificationSettingsView().prefs.copyWith(
                waterEnabled: true,
              ),
        ));
    // The water interval row lives ABOVE Device, so it may only push Device
    // down if it was hidden before; it stays present either way.
    expect(t.getTopLeft(find.text('Device')), before);
  });
}
