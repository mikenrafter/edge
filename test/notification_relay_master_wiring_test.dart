// ONE RELAY, NOT TWO SWITCHES. The relay exists only to buzz the band, so the
// master "Buzz on app notifications" switch and each channel's "Relay to the
// band" switch must agree: a channel that reads On has to actually be able to
// buzz, and the master reads Off exactly when no channel can.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SwitchRow;
import 'package:openstrap_edge/ui2/ui2.dart';

NotificationRelay _relay() => NotificationRelay(
  buzz: () async {},
  isConnected: () => false,
  debugSupported: true,
);

Future<bool> _ruleOn() async =>
    (await NotificationPrefs.load()).alertRule('relay').enabled;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('turning a channel on turns the relay on', () async {
    final r = _relay();
    expect(r.enabled, isFalse);
    await r.setChannel(
      'alarms',
      r.controller.channels['alarms']!.copyWith(enabled: true),
    );
    expect(r.enabled, isTrue);
    expect(await _ruleOn(), isTrue);
  });

  test('turning the last channel off turns the relay off', () async {
    final r = _relay();
    await r.setEnabled(true);
    expect(r.controller.channels['apps']!.enabled, isTrue);
    await r.setChannel(
      'apps',
      r.controller.channels['apps']!.copyWith(enabled: false),
    );
    expect(r.enabled, isFalse);
    expect(await _ruleOn(), isFalse);
  });

  test('turning one of two channels off leaves the relay on', () async {
    final r = _relay();
    await r.setChannel(
      'calls',
      r.controller.channels['calls']!.copyWith(enabled: true),
    );
    await r.setChannel(
      'apps',
      r.controller.channels['apps']!.copyWith(enabled: false),
    );
    expect(r.enabled, isTrue);
    expect(r.controller.channels['calls']!.enabled, isTrue);
  });

  test('switching the relay on with every channel off arms App notifications',
      () async {
    final r = _relay();
    for (final n in relayChannels) {
      r.controller.putChannel(
        n,
        r.controller.channels[n]!.copyWith(enabled: false),
      );
    }
    await r.setEnabled(true);
    expect(r.enabled, isTrue);
    expect(r.controller.channels['apps']!.enabled, isTrue);
  });

  test('switching the relay off keeps each channel\'s own choices', () async {
    final r = _relay();
    await r.setChannel(
      'alarms',
      r.controller.channels['alarms']!.copyWith(enabled: true),
    );
    await r.setEnabled(false);
    expect(r.enabled, isFalse);
    expect(r.controller.channels['alarms']!.enabled, isTrue);
    await r.setEnabled(true);
    expect(r.controller.channels['alarms']!.enabled, isTrue);
  });

  testWidgets('a channel switch reads Off while the relay is off', (t) async {
    t.view.physicalSize = const Size(390 * 3, 4000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: BandNotificationsView(
        enabled: false,
        channels: {'apps': ChannelConfig.forChannel('apps')},
      ),
    ));
    await t.pumpAndSettle();
    // 8C: all three channel sections start open, so the switch is drawn once
    // per channel, and every one of them reads Off while the relay is off.
    final rows = find.widgetWithText(SwitchRow, 'Relay to the band');
    expect(rows, findsNWidgets(3));
    for (final r in rows.evaluate()) {
      expect((r.widget as SwitchRow).value, isFalse);
    }
  });
}
