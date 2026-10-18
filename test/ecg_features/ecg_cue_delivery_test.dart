// ECG features, round 2 (RED): ECG cues have their own band-only delivery.
//
// They used to ride the `breath` alert rule, so the breathing alerts' prefs
// silenced them (rule off), turned them into generic "Session cue" phone
// notifications (phone-only destination), or held them for quiet hours. The
// cue now goes through kEcgCueRule: band only, live, no phone fallback, and no
// alert preference applies. It still reaches the band through the band queue
// and the haptic budget (gestureCues.slot -> haptics.deliver).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_cues.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

AlertDispatcher _dispatcher({required void Function(String) onTarget}) =>
    AlertDispatcher(
      phone: () async {
        onTarget('phone');
        return true;
      },
      band: () async {
        onTarget('band');
        return true;
      },
      isConnected: () => true,
      supportedBandModes: const {AlertExecutionMode.phoneLive},
      ledger: MemoryAlertDeliveryLedger(),
    );

void main() {
  group('kEcgCueRule', () {
    test('is band only: no phone destination, no phone fallback', () {
      expect(kEcgCueRule.destinations, AlertRule.band);
      expect(kEcgCueRule.phoneSelected, isFalse);
      expect(kEcgCueRule.bandSelected, isTrue);
      expect(kEcgCueRule.fallback, AlertFallback.none);
      expect(kEcgCueRule.enabled, isTrue);
      expect(kEcgCueRule.executionMode, AlertExecutionMode.phoneLive);
      expect(kEcgCueRule.historicalReplay, AlertHistoricalReplay.liveOnly);
    });

    test('is not any of the preference-backed rules (breath, tasker, ...)', () {
      for (final id in ['breath', 'tasker', 'gesture', 'wake', 'zone']) {
        expect(kEcgCueRule.id, isNot(id));
        expect(kEcgCueRule.channelPolicyId, isNot(id));
      }
    });

    test('dispatches to the band alone and never emits a phone notification',
        () async {
      final targets = <String>[];
      var played = 0;
      final out = await _dispatcher(onTarget: targets.add).dispatch(
        kEcgCueRule,
        eventId: 'ecg:ecg.complete:1',
        sourceTime: DateTime.now(),
        historical: false,
        phoneTransport: () async {
          targets.add('phone-transport');
          return true;
        },
        bandDelivery: () async {
          played++;
          return BuzzDelivery.complete;
        },
      );
      expect(played, 1);
      expect(out.targets, ['band']);
      expect(targets, isNot(contains('phone')));
      expect(targets, isNot(contains('phone-transport')));
    });

    test('with the band away it is silent: no fallback to the phone',
        () async {
      final targets = <String>[];
      final d = AlertDispatcher(
        phone: () async {
          targets.add('phone');
          return true;
        },
        band: () async => true,
        isConnected: () => false,
        supportedBandModes: const {AlertExecutionMode.phoneLive},
        ledger: MemoryAlertDeliveryLedger(),
      );
      final out = await d.dispatch(
        kEcgCueRule,
        eventId: 'ecg:ecg.failed:1',
        sourceTime: DateTime.now(),
        historical: false,
        phoneTransport: () async {
          targets.add('phone-transport');
          return true;
        },
        bandDelivery: () async => BuzzDelivery.complete,
      );
      expect(out.targets, isEmpty);
      expect(targets, isEmpty);
    });
  });

  group('AppState plays ECG cues through it', () {
    final app = File('lib/state/app_state.dart').readAsStringSync();
    final start = app.indexOf('Future<void> _playEcgCue(');
    final fn = app.substring(start, app.indexOf('EcgController _buildEcg'));

    test('the cue player dispatches kEcgCueRule, not an alert rule that has '
        'preferences', () {
      expect(start, greaterThan(0));
      expect(fn, contains('kEcgCueRule'));
      expect(fn, isNot(contains("'breath'")));
      expect(fn, isNot(contains('_dispatchBandAlert(')),
          reason: '_dispatchBandAlert reads the rule from NotificationPrefs '
              'and applies quiet hours and the phone fallback');
    });

    test('it still plays through the cue slots, so the band queue and haptic '
        'budget apply', () {
      expect(fn, contains('gestureCues.slot(slot)'));
      expect(fn, contains('_gestures.loadCues()'));
    });
  });
}
