// "ONLY BUZZ WHILE WORN" IS ONE SETTING FOR THE RELAY, NOT ONE PER CHANNEL.
// The channels are all "buzz the band"; whether to hold buzzes while the band
// is off the wrist is a single choice, off by default, and its answer comes
// from what the band itself reports (`DeviceState.wristOn`). A band that has
// said nothing is "unknown", never "worn".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SwitchRow;
import 'package:openstrap_edge/ui2/ui2.dart';

NotificationRelay _relay({String Function()? worn}) => NotificationRelay(
  buzz: () async {},
  isConnected: () => true,
  worn: worn,
  debugSupported: true,
);

Future<void> _pump(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(390 * 3, 4000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: w));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the band\'s own report', () {
    test('maps true, false and silence to worn, notWorn and unknown', () {
      expect(wearReportOf(true), 'worn');
      expect(wearReportOf(false), 'notWorn');
      expect(wearReportOf(null), 'unknown');
    });
  });

  group('one setting for the relay', () {
    test('is off by default', () {
      expect(_relay().onlyWhileWorn, isFalse);
      expect(_relay().debugPolicy(const {})['onlyWhileWorn'], false);
    });

    test('is stored, and read back at startup', () async {
      final r = _relay();
      await r.setOnlyWhileWorn(true);
      expect(r.onlyWhileWorn, isTrue);
      expect(r.debugPolicy(const {})['onlyWhileWorn'], true);
      final again = _relay();
      await again.bootstrap();
      expect(again.onlyWhileWorn, isTrue);
    });

    test('no channel carries its own copy', () {
      for (final n in relayChannels) {
        final c = ChannelConfig.forChannel(n);
        expect(c.toJson().containsKey('onlyWhileWorn'), isFalse);
        expect(c.policy.containsKey('onlyWhileWorn'), isFalse);
      }
    });

    test('the policy carries what the band reports', () {
      var report = 'unknown';
      final r = _relay(worn: () => report);
      expect(r.debugPolicy(const {})['worn'], 'unknown');
      report = 'worn';
      expect(r.debugPolicy(const {})['worn'], 'worn');
      report = 'notWorn';
      expect(r.debugPolicy(const {})['worn'], 'notWorn');
    });

    test('no wear source at all is unknown', () {
      expect(_relay().debugPolicy(const {})['worn'], 'unknown');
    });
  });

  group('the screen', () {
    testWidgets('has the switch once, in the Relay group, not in each channel',
        (t) async {
      await _pump(t, const BandNotificationsView(enabled: true, granted: true));
      expect(find.widgetWithText(SwitchRow, 'Only buzz while worn'),
          findsOneWidget);
      expect(find.text('Only while worn'), findsNothing);
    });

    testWidgets('toggles through onOnlyWhileWorn', (t) async {
      bool? got;
      await _pump(
        t,
        BandNotificationsView(
          enabled: true,
          granted: true,
          onOnlyWhileWorn: (v) => got = v,
        ),
      );
      final row = find.widgetWithText(SwitchRow, 'Only buzz while worn');
      t.widget<SwitchRow>(row).onChanged!(true);
      expect(got, isTrue);
    });

    for (final c in const [
      (false, 'unknown', 'Off. The band buzzes whether or not it is on your wrist.'),
      (true, 'worn', 'On. The band says it is on your wrist.'),
      (true, 'notWorn', 'On. The band says it is off your wrist, so nothing buzzes.'),
      (
        true,
        'unknown',
        'On. This band has not reported wear, so nothing buzzes. Turn this off to buzz anyway.',
      ),
    ]) {
      testWidgets('says what it will do: ${c.$1} / ${c.$2}', (t) async {
        await _pump(
          t,
          BandNotificationsView(
            enabled: true,
            granted: true,
            onlyWhileWorn: c.$1,
            wearReport: c.$2,
          ),
        );
        expect(find.text(c.$3), findsOneWidget);
      });
    }
  });
}
