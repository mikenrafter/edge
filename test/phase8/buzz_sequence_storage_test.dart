// 8D — where a BuzzSequence is stored and how delivery picks it up.
//
// AlertRule carries an optional sequence (absent = registry default);
// NotificationPrefs resolves the effective one by stable registry order; the
// relay's App notifications channel and each per-app entry carry one too.
// See test/phase8/CONTRACTS.md §8D.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dart_source.dart';

/// The rule registry order as it stands today. Persisted defaults hang off
/// these positions, so they are frozen: append, never reorder.
const _frozenOrder = [
  'health',
  'recovery',
  'reminders',
  'device',
  'water',
  'autoDetect',
  'movement',
  'meds',
  'checkIn',
  'stepGoal',
  'windDown',
  'alarmLatchFailed',
  'alarmNightCheck',
  'alarm',
  'nativeAlarm',
  'zone',
  'wake',
  'breath',
  'tasker',
  'relay',
  'gesture',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AlertRule.buzzSequence', () {
    const base = AlertRule(
      id: 'water',
      kind: 'water',
      destinations: AlertRule.band,
      executionMode: AlertExecutionMode.phoneLive,
      channelPolicyId: 'water',
    );

    test('absent by default and absent from JSON', () {
      expect(base.buzzSequence, isNull);
      expect(base.toJson().containsKey('buzzSequence'), isFalse);
      expect(AlertRule.fromJson(base.toJson()).buzzSequence, isNull);
    });

    test('round-trips through JSON', () {
      final r = base.copyWith(buzzSequence: BuzzSequence(const [0, 300, 900]));
      final json = jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>;
      expect(json['buzzSequence'], [0, 300, 900]);
      expect(AlertRule.fromJson(json).buzzSequence,
          BuzzSequence(const [0, 300, 900]));
    });

    test('survives an unrelated copyWith', () {
      final r = base
          .copyWith(buzzSequence: BuzzSequence(const [0, 500]))
          .copyWith(destinations: AlertRule.phone | AlertRule.band);
      expect(r.buzzSequence, BuzzSequence(const [0, 500]));
    });

    test('an invalid stored sequence is rejected, not silently changed', () {
      expect(
          () => AlertRule.fromJson({
                ...base.toJson(),
                'buzzSequence': [0, 0],
              }),
          throwsFormatException);
    });
  });

  group('NotificationPrefs: registry order and effective sequence', () {
    test('the registry order is frozen (append only)', () {
      expect(NotificationPrefs.alertRuleOrder.take(_frozenOrder.length),
          _frozenOrder);
      expect(
          const NotificationPrefs()
              .effectiveAlertRules
              .keys
              .take(_frozenOrder.length),
          _frozenOrder,
          reason: 'effectiveAlertRules iterates in registry order');
    });

    test('an unset rule takes the default for its registry index', () {
      const prefs = NotificationPrefs();
      for (var i = 0; i < _frozenOrder.length; i++) {
        expect(prefs.buzzSequenceFor(_frozenOrder[i]),
            BuzzSequence.defaultFor(i),
            reason: _frozenOrder[i]);
      }
      // Spot checks against the documented table.
      expect(prefs.buzzSequenceFor('health').offsetsMs, [0]);
      expect(prefs.buzzSequenceFor('recovery').offsetsMs, [0, 500]);
      expect(prefs.buzzSequenceFor('reminders').offsetsMs, [0, 500, 1000]);
      expect(prefs.buzzSequenceFor('water').offsetsMs, [0, 1000]);
    });

    test('a rule\'s own sequence wins over the default', () {
      final prefs = const NotificationPrefs().withAlertRule({
        ...const NotificationPrefs().alertRule('water').toJson(),
        'enabled': true,
        'destinations': AlertRule.band,
        'buzzSequence': [0, 250, 500],
      });
      expect(prefs.buzzSequenceFor('water'), BuzzSequence(const [0, 250, 500]));
    });

    test('the stored blob round-trips the sequence (additive, same schema)',
        () {
      final prefs = const NotificationPrefs().withAlertRule({
        ...const NotificationPrefs().alertRule('meds').toJson(),
        'enabled': true,
        'destinations': AlertRule.band,
        'buzzSequence': [0, 600],
      });
      final json = jsonDecode(jsonEncode(prefs.toJson())) as Map<String, dynamic>;
      expect(json['schemaVersion'], NotificationPrefs.schemaVersion);
      final back = NotificationPrefs.fromJson(json);
      expect(back.buzzSequenceFor('meds'), BuzzSequence(const [0, 600]));
      // Idempotent: a second pass changes nothing.
      expect(jsonEncode(NotificationPrefs.fromJson(
              jsonDecode(jsonEncode(back.toJson())) as Map<String, dynamic>)
          .toJson()), jsonEncode(back.toJson()));
    });

    test('a blob saved before 8D (no sequence anywhere) still loads', () {
      final old = jsonDecode(jsonEncode(const NotificationPrefs().toJson()))
          as Map<String, dynamic>;
      for (final r in (old['rules'] as Map).values) {
        (r as Map).remove('buzzSequence');
      }
      final back = NotificationPrefs.fromJson(old);
      expect(back.buzzSequenceFor('health'), BuzzSequence.defaultFor(0));
    });
  });

  group('relay: App notifications channel and per-app entries', () {
    final relayIndex = _frozenOrder.indexOf('relay');

    test('channel default is the relay rule default; app default is the channel',
        () {
      const cfg = ChannelConfig(enabled: true);
      expect(cfg.buzzSequence, isNull);
      expect(cfg.appSequences, isEmpty);
      expect(cfg.effectiveSequence, BuzzSequence.defaultFor(relayIndex));
      expect(cfg.sequenceForApp('com.example'), cfg.effectiveSequence);

      final chosen = cfg.copyWith(buzzSequence: BuzzSequence(const [0, 700]));
      expect(chosen.sequenceForApp('com.example'),
          BuzzSequence(const [0, 700]));
    });

    test('a per-app sequence wins for that app only', () {
      final cfg = const ChannelConfig(enabled: true).copyWith(
        appSequences: {'com.a': BuzzSequence(const [0, 300, 600])},
      );
      expect(cfg.sequenceForApp('com.a'), BuzzSequence(const [0, 300, 600]));
      expect(cfg.sequenceForApp('com.b'), cfg.effectiveSequence);
    });

    test('channel and per-app sequences round-trip through channel JSON', () {
      final cfg = const ChannelConfig(enabled: true).copyWith(
        buzzSequence: BuzzSequence(const [0, 400]),
        appSequences: {'com.a': BuzzSequence(const [0, 300, 600])},
      );
      final json =
          jsonDecode(jsonEncode(cfg.toJson())) as Map<String, Object?>;
      final back = ChannelConfig.fromJson(json, ChannelConfig.forChannel('apps'));
      expect(back.buzzSequence, BuzzSequence(const [0, 400]));
      expect(back.appSequences, {'com.a': BuzzSequence(const [0, 300, 600])});
    });

    test('channel JSON saved before 8D loads with no sequences', () {
      final back = ChannelConfig.fromJson(
          {'enabled': true}, ChannelConfig.forChannel('apps'));
      expect(back.buzzSequence, isNull);
      expect(back.appSequences, isEmpty);
    });

    test('an app post plays that app\'s sequence as one delivery', () async {
      final played = <BuzzSequence>[];
      final patterns = <List<int>>[];
      final relay = NotificationRelay(buzz: () async {}, isConnected: () => true);
      final controller = relay.debugController(
        policy: const {
          'enabled': true,
          'connected': true,
          'packages': ['com.a'],
          'staleAfterMs': 30000,
        },
        buzz: (p) async {
          patterns.add(p);
          return true;
        },
        phone: () async => true,
        nowMs: () => 1000000,
        playSequence: (s) async {
          played.add(s);
          return true;
        },
      );
      controller.putChannel(
        'apps',
        const ChannelConfig(enabled: true).copyWith(
          appSequences: {'com.a': BuzzSequence(const [0, 300, 600])},
        ),
      );
      final r = await controller.handleMetadata({
        'kind': 'post',
        'category': 'msg',
        'package': 'com.a',
        'keyHash': 'k1',
        'postTimeMs': 1000000,
      });
      expect(r.targets, ['band']);
      expect(played, [BuzzSequence(const [0, 300, 600])]);
      expect(patterns, isEmpty,
          reason: 'the sequence replaces the fixed one-buzz pattern');
    });
  });

  group('AppState plays the rule sequence (source guard)', () {
    test('_dispatchBandAlert band transport plays the rule\'s sequence', () {
      final src = File('lib/state/app_state.dart').readAsStringSync();
      final body = bodyOf(src, 'Future<AlertDeliveryOutcome> _dispatchBandAlert(');
      expect(body, isNotEmpty);
      // deliverBuzzSequence is playBuzzSequence's tri-state form (finding H):
      // the claim must survive a partial or unanswered delivery.
      expect(codeOnly(body), contains('deliverBuzzSequence('));
      expect(codeOnly(body), contains('buzzSequenceFor('));
    });

    test('the relay plays through playBuzzSequence', () {
      final src = File('lib/notify/notification_relay.dart').readAsStringSync();
      expect(codeOnly(src), contains('playBuzzSequence('));
    });
  });
}
