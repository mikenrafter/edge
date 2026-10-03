// 8AE C — per-channel "Override quiet hours". A relay channel follows the
// global quiet hours (Alerts) unless it overrides them with its own window.
// RED until ChannelConfig.overrideQuietHours, the relay decision and the
// Band notifications rows exist. See test/phase8/CONTRACTS.md §8AE.
//
// Contract the tests fix where the spec is silent:
//  - The global quiet hours reach the relay decision through the policy map
//    like every other environment value, under the keys `quietEnabled`,
//    `quietStartMin` and `quietEndMin` (the NotificationPrefs field names).
//    A policy that carries none of them means "no global quiet hours", so the
//    existing relay tests (which never set them) keep their behaviour.
//  - Turning the override on seeds the channel's window with 22:00 to 07:00,
//    the same default the old Quiet hours switch used, so the Starts and Ends
//    rows never show a time the relay is not using.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/ui2/profile/band_notifications.dart';

import 'support/sections.dart';

const _min22 = 22 * 60, _min07 = 7 * 60;

Map<String, Object?> _meta({
  String category = 'msg',
  String key = 'key',
}) => {
  'category': category,
  'package': 'com.example',
  'keyHash': key,
  'kind': 'post',
  'postTimeMs': 1000000,
  'receiptTimeMs': 1000000,
  'matchesInterruptionFilter': true,
  'interruptionFilter': 1,
  'ringerMode': 2,
  'ongoing': false,
  'groupSummary': false,
  'importance': 3,
};

Map<String, Object?> _policy({
  int minute = 23 * 60,
  bool? globalOn,
  int globalStart = _min22,
  int globalEnd = _min07,
}) => {
  'enabled': true,
  'dnd': false,
  'respectDnd': true,
  'allowDuringDnd': false,
  'ringer': 'normal',
  'includeVibrate': true,
  'includeSilent': false,
  'connected': true,
  'fallback': 'none',
  'worn': 'worn',
  'onlyWhileWorn': false,
  'packages': ['com.example'],
  'staleAfterMs': 30000,
  'minuteOfDay': minute,
  if (globalOn != null) ...{
    'quietEnabled': globalOn,
    'quietStartMin': globalStart,
    'quietEndMin': globalEnd,
  },
};

NotificationRelay _relay({bool supported = true}) => NotificationRelay(
  buzz: () async {},
  isConnected: () => true,
  debugSupported: supported,
);

/// A controller with a buzz counter. The apps channel is the unit under test.
({RelayController c, int Function() buzzes}) _controller(
  Map<String, Object?> policy,
  ChannelConfig apps,
) {
  var n = 0;
  final c = _relay().debugController(
    policy: policy,
    buzz: (_) async {
      n++;
      return true;
    },
    phone: () async => true,
    nowMs: () => 1000000,
  );
  c.putChannel('apps', apps);
  return (c: c, buzzes: () => n);
}

void main() {
  group('ChannelConfig.overrideQuietHours', () {
    test('is off by default, for a bare config and for every channel', () {
      expect(const ChannelConfig().overrideQuietHours, isFalse);
      for (final n in relayChannels) {
        expect(ChannelConfig.forChannel(n).overrideQuietHours, isFalse, reason: n);
      }
    });

    test('copyWith sets it, keeps it, and clears it', () {
      final on = const ChannelConfig().copyWith(overrideQuietHours: true);
      expect(on.overrideQuietHours, isTrue);
      expect(on.copyWith(enabled: true).overrideQuietHours, isTrue,
          reason: 'an unrelated copyWith keeps it');
      expect(on.copyWith(overrideQuietHours: false).overrideQuietHours, isFalse);
    });

    test('JSON writes the key and round-trips both values', () {
      for (final v in [true, false]) {
        final cfg = ChannelConfig(
          overrideQuietHours: v,
          quietStartMinute: _min22,
          quietEndMinute: _min07,
        );
        final json = cfg.toJson();
        expect(json['overrideQuietHours'], v);
        final back = ChannelConfig.fromJson(json, const ChannelConfig());
        expect(back.overrideQuietHours, v);
        // The window survives either way: switching the override off must not
        // throw away the times the user typed.
        expect(back.quietStartMinute, _min22);
        expect(back.quietEndMinute, _min07);
      }
    });

    test('an explicit stored false wins over stored times', () {
      final back = ChannelConfig.fromJson({
        'overrideQuietHours': false,
        'quietStartMinute': _min22,
        'quietEndMinute': _min07,
      }, const ChannelConfig());
      expect(back.overrideQuietHours, isFalse);
    });

    test('an explicit stored true needs no times', () {
      final back = ChannelConfig.fromJson({
        'overrideQuietHours': true,
      }, const ChannelConfig());
      expect(back.overrideQuietHours, isTrue);
    });

    test('legacy config with both times migrates to override on', () {
      final back = ChannelConfig.fromJson({
        'enabled': true,
        'quietStartMinute': 23 * 60,
        'quietEndMinute': 6 * 60,
      }, ChannelConfig.forChannel('apps'));
      expect(back.overrideQuietHours, isTrue,
          reason: 'existing users keep their own window');
      expect(back.quietStartMinute, 23 * 60);
      expect(back.quietEndMinute, 6 * 60);
    });

    test('legacy config with no times, or only one, migrates to off', () {
      for (final j in <Map<String, Object?>>[
        {'enabled': true},
        {'enabled': true, 'quietStartMinute': null, 'quietEndMinute': null},
        {'quietStartMinute': _min22},
        {'quietEndMinute': _min07},
      ]) {
        expect(
          ChannelConfig.fromJson(j, ChannelConfig.forChannel('apps'))
              .overrideQuietHours,
          isFalse,
          reason: '$j',
        );
      }
    });
  });

  group('relay decision', () {
    test('override off follows the global quiet hours and says quietHours',
        () async {
      final r = _controller(
        _policy(globalOn: true),
        const ChannelConfig(enabled: true),
      );
      final res = await r.c.handleMetadata(_meta());
      expect(res.suppression, 'quietHours');
      expect(res.targets, isEmpty);
      expect(r.buzzes(), 0);
    });

    test('override off, outside the global window, buzzes', () async {
      final r = _controller(
        _policy(minute: 12 * 60, globalOn: true),
        const ChannelConfig(enabled: true),
      );
      final res = await r.c.handleMetadata(_meta());
      expect(res.suppression, isNull);
      expect(r.buzzes(), 1);
    });

    test('global quiet hours off: nothing is suppressed, even inside the window',
        () async {
      final r = _controller(
        _policy(globalOn: false),
        const ChannelConfig(enabled: true),
      );
      final res = await r.c.handleMetadata(_meta());
      expect(res.suppression, isNull);
      expect(r.buzzes(), 1);
    });

    test('a policy with no global quiet values suppresses nothing', () async {
      final r = _controller(_policy(), const ChannelConfig(enabled: true));
      final res = await r.c.handleMetadata(_meta());
      expect(res.suppression, isNull);
      expect(r.buzzes(), 1);
    });

    test('override off ignores the channel own stored times', () async {
      // 12:30 is inside the channel's own 12:00 to 13:00 window and outside
      // the global 22:00 to 07:00 one. With the override off the own window is
      // dead data.
      final r = _controller(
        _policy(minute: 12 * 60 + 30, globalOn: true),
        const ChannelConfig(
          enabled: true,
          quietStartMinute: 12 * 60,
          quietEndMinute: 13 * 60,
        ),
      );
      final res = await r.c.handleMetadata(_meta());
      expect(res.suppression, isNull);
      expect(r.buzzes(), 1);
    });

    test('override on uses the channel own window', () async {
      final r = _controller(
        _policy(minute: 12 * 60 + 30, globalOn: true),
        const ChannelConfig(
          enabled: true,
          overrideQuietHours: true,
          quietStartMinute: 12 * 60,
          quietEndMinute: 13 * 60,
        ),
      );
      final res = await r.c.handleMetadata(_meta());
      expect(res.suppression, 'quietHours');
      expect(r.buzzes(), 0);
    });

    test('override on ignores the global window', () async {
      // 23:00 is inside the global window and outside the channel's own.
      final r = _controller(
        _policy(globalOn: true),
        const ChannelConfig(
          enabled: true,
          overrideQuietHours: true,
          quietStartMinute: 12 * 60,
          quietEndMinute: 13 * 60,
        ),
      );
      final res = await r.c.handleMetadata(_meta());
      expect(res.suppression, isNull);
      expect(r.buzzes(), 1);
    });

    test('override on with a window that wraps midnight', () async {
      final wrap = const ChannelConfig(
        enabled: true,
        overrideQuietHours: true,
        quietStartMinute: _min22,
        quietEndMinute: _min07,
      );
      final inside = _controller(_policy(minute: 23 * 60), wrap);
      expect((await inside.c.handleMetadata(_meta())).suppression, 'quietHours');
      final outside = _controller(_policy(minute: 12 * 60), wrap);
      expect((await outside.c.handleMetadata(_meta())).suppression, isNull);
      expect(outside.buzzes(), 1);
    });

    test('override on with no times is never quiet, whatever the global says',
        () async {
      final r = _controller(
        _policy(globalOn: true),
        const ChannelConfig(enabled: true, overrideQuietHours: true),
      );
      final res = await r.c.handleMetadata(_meta());
      expect(res.suppression, isNull);
      expect(r.buzzes(), 1);
    });

    test('override on with only one time is never quiet', () async {
      final r = _controller(
        _policy(globalOn: true),
        const ChannelConfig(
          enabled: true,
          overrideQuietHours: true,
          quietStartMinute: _min22,
        ),
      );
      expect((await r.c.handleMetadata(_meta())).suppression, isNull);
    });

    test('each channel decides for itself', () async {
      final r = _controller(
        _policy(globalOn: true),
        const ChannelConfig(enabled: true),
      );
      // Calls override with no times: never quiet. Apps follow the global.
      r.c.putChannel(
        'calls',
        const ChannelConfig(enabled: true, overrideQuietHours: true),
      );
      final app = await r.c.handleMetadata(_meta());
      final call = await r.c.handleMetadata(_meta(category: 'call', key: 'c'));
      expect(app.suppression, 'quietHours');
      expect(call.suppression, isNull);
      expect(r.buzzes(), 1);
    });
  });

  group('the relay hands the global quiet hours to the decision', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('debugPolicy carries the stored global window', () async {
      SharedPreferences.setMockInitialValues({
        'notif_quiet_enabled': true,
        'notif_quiet_start': 21 * 60,
        'notif_quiet_end': 6 * 60 + 30,
      });
      final r = _relay();
      await r.bootstrap();
      final p = r.debugPolicy(const {});
      expect(p['quietEnabled'], true);
      expect(p['quietStartMin'], 21 * 60);
      expect(p['quietEndMin'], 6 * 60 + 30);
    });

    test('debugPolicy says off when the user switched global quiet hours off',
        () async {
      SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
      final r = _relay();
      await r.bootstrap();
      expect(r.debugPolicy(const {})['quietEnabled'], false);
    });

    test('the override and its times are stored and read back', () async {
      final r = _relay();
      await r.setChannel(
        'alarms',
        const ChannelConfig(
          overrideQuietHours: true,
          quietStartMinute: 13 * 60,
          quietEndMinute: 14 * 60,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final again = _relay();
      await again.bootstrap();
      final cfg = again.controller.channels['alarms']!;
      expect(cfg.overrideQuietHours, isTrue);
      expect(cfg.quietStartMinute, 13 * 60);
      expect(cfg.quietEndMinute, 14 * 60);
      expect(again.controller.channels['calls']!.overrideQuietHours, isFalse);
    });
  });

  group('Band notifications rows', () {
    Finder overrideKey(String ch) =>
        find.byKey(ValueKey('channel-quiet-override-$ch'));
    Finder switchOf(String ch) =>
        find.descendant(of: overrideKey(ch), matching: find.byType(Switch));

    Widget view({
      Map<String, ChannelConfig> channels = const {
        'apps': ChannelConfig(enabled: true),
      },
      void Function(String, ChannelConfig)? onChannel,
    }) => BandNotificationsView(
      enabled: true,
      granted: true,
      channels: channels,
      onChannel: onChannel,
    );

    testWidgets('each channel has the switch, default off, with its sub',
        (t) async {
      await pumpTall(t, view());
      for (final ch in relayChannels) {
        expect(overrideKey(ch), findsOneWidget, reason: ch);
        expect(t.widget<Switch>(switchOf(ch)).value, isFalse, reason: ch);
        expect(
          find.descendant(
            of: overrideKey(ch),
            matching: find.text('Follows your quiet hours in Alerts'),
          ),
          findsOneWidget,
          reason: ch,
        );
        expect(
          find.descendant(
            of: overrideKey(ch),
            matching: find.text('Override quiet hours'),
          ),
          findsOneWidget,
          reason: ch,
        );
      }
    });

    testWidgets('the old per-channel Quiet hours switch is gone', (t) async {
      await pumpTall(t, view());
      expect(find.text('Quiet hours'), findsNothing);
      expect(find.text('Override quiet hours'), findsNWidgets(3));
    });

    testWidgets('Starts and Ends are hidden while no channel overrides',
        (t) async {
      await pumpTall(t, view());
      expect(find.text('Starts'), findsNothing);
      expect(find.text('Ends'), findsNothing);
    });

    testWidgets('Starts and Ends show only on the channel that overrides',
        (t) async {
      await pumpTall(
        t,
        view(
          channels: const {
            'apps': ChannelConfig(
              enabled: true,
              overrideQuietHours: true,
              quietStartMinute: 23 * 60,
              quietEndMinute: 6 * 60,
            ),
          },
        ),
      );
      expect(t.widget<Switch>(switchOf('apps')).value, isTrue);
      expect(t.widget<Switch>(switchOf('alarms')).value, isFalse);
      expect(find.text('Starts'), findsOneWidget);
      expect(find.text('Ends'), findsOneWidget);
      expect(find.text('23:00'), findsOneWidget);
      expect(find.text('06:00'), findsOneWidget);
    });

    testWidgets('stored times with the override off stay hidden', (t) async {
      await pumpTall(
        t,
        view(
          channels: const {
            'apps': ChannelConfig(
              enabled: true,
              quietStartMinute: 23 * 60,
              quietEndMinute: 6 * 60,
            ),
          },
        ),
      );
      expect(t.widget<Switch>(switchOf('apps')).value, isFalse);
      expect(find.text('Starts'), findsNothing);
    });

    testWidgets('switching it on reports the channel with the override on',
        (t) async {
      final puts = <(String, ChannelConfig)>[];
      await pumpTall(t, view(onChannel: (n, c) => puts.add((n, c))));
      await t.tap(switchOf('apps'));
      await t.pump();
      expect(puts, hasLength(1));
      expect(puts.single.$1, 'apps');
      final cfg = puts.single.$2;
      expect(cfg.overrideQuietHours, isTrue);
      expect(cfg.enabled, isTrue, reason: 'nothing else changes');
      expect(cfg.quietStartMinute, _min22,
          reason: 'seeded, so the Starts row is not showing an unused time');
      expect(cfg.quietEndMinute, _min07);
    });

    testWidgets('switching it off reports the channel with the override off',
        (t) async {
      final puts = <(String, ChannelConfig)>[];
      await pumpTall(
        t,
        view(
          channels: const {
            'calls': ChannelConfig(
              enabled: true,
              overrideQuietHours: true,
              quietStartMinute: _min22,
              quietEndMinute: _min07,
            ),
          },
          onChannel: (n, c) => puts.add((n, c)),
        ),
      );
      await t.tap(switchOf('calls'));
      await t.pump();
      expect(puts, hasLength(1));
      expect(puts.single.$1, 'calls');
      expect(puts.single.$2.overrideQuietHours, isFalse);
    });
  });
}
