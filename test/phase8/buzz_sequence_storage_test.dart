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

  group('BuzzSequence: the retired extended flag (8AC, removed in 8AF.6)', () {
    Map<String, Object?> old({bool? extended}) => {
          'offsetsMs': [0, 900],
          'durationsMs': [750, 80],
          'extended': ?extended,
        };

    test('old JSON with the flag on still parses and equals the same rhythm '
        'without it', () {
      final on = BuzzSequence.fromJson(jsonDecode(jsonEncode(old(extended: true))));
      final off = BuzzSequence.fromJson(jsonDecode(jsonEncode(old())));
      expect(on, off);
      expect(on.hashCode, off.hashCode);
      expect(on.durationsMs, [750, 80]);
    });

    test('it is never written: not for a rule that had it, not for a plain '
        'sequence', () {
      final on = BuzzSequence.fromJson(old(extended: true));
      expect((on.toJson() as Map).containsKey('extended'), isFalse);
      expect(on.toJson(), {
        'offsetsMs': [0, 900],
        'durationsMs': [750, 80],
      });
      expect(BuzzSequence(const [0, 300]).toJson(), [0, 300]);
    });

    test('old JSON without it round-trips byte-identical', () {
      for (final o in <Object>[
        [0, 300, 900],
        {
          'offsetsMs': [0, 900],
          'durationsMs': [750, 80],
        },
      ]) {
        final s = BuzzSequence.fromJson(jsonDecode(jsonEncode(o)));
        expect(jsonEncode(s.toJson()), jsonEncode(o), reason: '$o');
      }
    });

    test('an explicit extended: false in the map is dropped on write', () {
      final s = BuzzSequence.fromJson({
        'offsetsMs': [0, 300],
        'durationsMs': [100, 100],
        'extended': false,
      });
      // Holds make it the map form (all-zero holds would be the plain list).
      expect((s.toJson() as Map).containsKey('extended'), isFalse);
    });

    test('an AlertRule that carried it reads, and writes it no more', () {
      const base = AlertRule(
        id: 'water',
        kind: 'water',
        destinations: AlertRule.band,
        executionMode: AlertExecutionMode.phoneLive,
        channelPolicyId: 'water',
      );
      final r = base.copyWith(
          buzzSequence: BuzzSequence.fromJson({
        'offsetsMs': [0, 300],
        'durationsMs': [0, 0],
        'extended': true,
      }));
      final back = AlertRule.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(back.buzzSequence, BuzzSequence.fromJson(const [0, 300]));
      expect(jsonEncode(back.toJson()), isNot(contains('extended')));
    });
  });

  group('BuzzSequence notes, profile and baked plan (8AC)', () {
    final baked = [
      BakedStep(effects: const [47], loop: 1, delayMs: 0),
      BakedStep(effects: const [14], loop: 2, delayMs: 300),
    ];
    BuzzSequence full() => BuzzSequence(
          const [0, 625],
          durationsMs: const [500, 500],
          notes: 'N4mf R1 N4mf',
          profileId: 'whoop-5.0-mg',
          profileVersion: 1,
          bakedSteps: baked,
        );

    test('all absent by default and for old JSON', () {
      final s = BuzzSequence(const [0, 300]);
      expect(s.notes, isNull);
      expect(s.profileId, isNull);
      expect(s.profileVersion, isNull);
      expect(s.bakedSteps, isNull);
      final back = BuzzSequence.fromJson(const [0, 300]);
      expect(back.notes, isNull);
      expect(back.bakedSteps, isNull);
    });

    test('JSON: notes, profile and plan are written together, only when set',
        () {
      final json = full().toJson() as Map;
      expect(json['notes'], 'N4mf R1 N4mf');
      expect(json['profileId'], 'whoop-5.0-mg');
      expect(json['profileVersion'], 1);
      expect(json['plan'], [
        {'effects': [47], 'loop': 1, 'delayMs': 0},
        {'effects': [14], 'loop': 2, 'delayMs': 300},
      ]);
      final plain = BuzzSequence(const [0, 900], durationsMs: [750, 80]);
      final pj = plain.toJson() as Map;
      for (final k in ['notes', 'profileId', 'profileVersion', 'plan']) {
        expect(pj.containsKey(k), isFalse, reason: k);
      }
      expect(BuzzSequence(const [0, 300]).toJson(), [0, 300]);
    });

    test('JSON round-trips everything', () {
      {
        final s = full();
        final back =
            BuzzSequence.fromJson(jsonDecode(jsonEncode(s.toJson())));
        expect(back, s);
        expect(back.notes, 'N4mf R1 N4mf');
        expect(back.profileId, 'whoop-5.0-mg');
        expect(back.profileVersion, 1);
        expect(back.bakedSteps, baked);
        expect(back.durationsMs, [500, 500]);
      }
    });

    test('notes without a baked plan, and a plan without notes, both work',
        () {
      final notesOnly = BuzzSequence(const [0, 625],
          durationsMs: const [500, 500],
          notes: 'N4mf R1 N4mf',
          profileId: 'whoop-5.0-mg',
          profileVersion: 1);
      expect((notesOnly.toJson() as Map).containsKey('plan'), isFalse);
      expect(
          BuzzSequence.fromJson(jsonDecode(jsonEncode(notesOnly.toJson()))),
          notesOnly);
      final planOnly = BuzzSequence(const [0],
          profileId: 'whoop-5.0-mg', profileVersion: 1, bakedSteps: baked);
      final json = planOnly.toJson() as Map;
      expect(json.containsKey('plan'), isTrue);
      expect(json.containsKey('notes'), isFalse);
      expect(BuzzSequence.fromJson(jsonDecode(jsonEncode(json))), planOnly);
    });

    test('equality and hashCode include each field', () {
      expect(full(), full());
      expect(full().hashCode, full().hashCode);
      final base = full();
      final others = [
        BuzzSequence(const [0, 625],
            durationsMs: const [500, 500],
            notes: 'N4mf R2 N4mf',
            profileId: 'whoop-5.0-mg',
            profileVersion: 1,
            bakedSteps: baked),
        BuzzSequence(const [0, 625],
            durationsMs: const [500, 500],
            notes: 'N4mf R1 N4mf',
            profileId: 'other',
            profileVersion: 1,
            bakedSteps: baked),
        BuzzSequence(const [0, 625],
            durationsMs: const [500, 500],
            notes: 'N4mf R1 N4mf',
            profileId: 'whoop-5.0-mg',
            profileVersion: 2,
            bakedSteps: baked),
        BuzzSequence(const [0, 625],
            durationsMs: const [500, 500],
            notes: 'N4mf R1 N4mf',
            profileId: 'whoop-5.0-mg',
            profileVersion: 1,
            bakedSteps: [baked.first]),
        BuzzSequence(const [0, 625], durationsMs: const [500, 500]),
      ];
      for (final o in others) {
        expect(o, isNot(base));
        expect(o.hashCode, isNot(base.hashCode));
      }
      expect(BakedStep(effects: const [1, 2], loop: 1, delayMs: 5),
          BakedStep(effects: const [1, 2], loop: 1, delayMs: 5));
      expect(BakedStep(effects: const [1, 2], loop: 1, delayMs: 5),
          isNot(BakedStep(effects: const [1, 2], loop: 1, delayMs: 6)));
    });

    test('copyWith keeps them and can set them', () {
      final c = full().copyWith(patternId: 'p');
      expect(c.patternId, 'p');
      expect(c.notes, 'N4mf R1 N4mf');
      expect(c.profileId, 'whoop-5.0-mg');
      expect(c.profileVersion, 1);
      expect(c.bakedSteps, baked);
      final set = BuzzSequence(const [0]).copyWith(
        notes: 'N1mf',
        profileId: 'whoop-5.0-mg',
        profileVersion: 1,
        bakedSteps: baked,
      );
      expect(set.notes, 'N1mf');
      expect(set.bakedSteps, baked);
    });

    test('an AlertRule carries them through JSON', () {
      const base = AlertRule(
        id: 'water',
        kind: 'water',
        destinations: AlertRule.band,
        executionMode: AlertExecutionMode.phoneLive,
        channelPolicyId: 'water',
      );
      final r = base.copyWith(buzzSequence: full());
      final back = AlertRule.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(back.buzzSequence, full());
      expect(back.buzzSequence!.bakedSteps, baked);
    });

    Map<String, Object?> good() => {
          'offsetsMs': [0, 625],
          'durationsMs': [500, 500],
          'notes': 'N4mf R1 N4mf',
          'profileId': 'whoop-5.0-mg',
          'profileVersion': 1,
          'plan': [
            {'effects': [47], 'loop': 1, 'delayMs': 0},
          ],
        };

    test('the good map parses (the validation cases below start from it)', () {
      expect(BuzzSequence.fromJson(good()).notes, 'N4mf R1 N4mf');
    });

    test('fromJson rejects bad notes, profile and plan', () {
      final bad = <String, Object?>{
        'notes not a string': {...good(), 'notes': 3},
        'notes not parseable': {...good(), 'notes': 'banana'},
        'notes with a bad length': {...good(), 'notes': 'N5mf'},
        'profileId not a string': {...good(), 'profileId': 7},
        'profileVersion not an int': {...good(), 'profileVersion': '1'},
        'profileVersion a double': {...good(), 'profileVersion': 1.5},
        'plan not a list': {...good(), 'plan': 'x'},
        'plan entry not a map': {
          ...good(),
          'plan': [3],
        },
        'plan entry without effects': {
          ...good(),
          'plan': [
            {'loop': 1, 'delayMs': 0},
          ],
        },
        'plan effects not ints': {
          ...good(),
          'plan': [
            {'effects': ['a'], 'loop': 1, 'delayMs': 0},
          ],
        },
        'plan effects empty': {
          ...good(),
          'plan': [
            {'effects': <int>[], 'loop': 1, 'delayMs': 0},
          ],
        },
        'plan loop not an int': {
          ...good(),
          'plan': [
            {'effects': [1], 'loop': 'a', 'delayMs': 0},
          ],
        },
        'plan loop zero': {
          ...good(),
          'plan': [
            {'effects': [1], 'loop': 0, 'delayMs': 0},
          ],
        },
        'plan delay negative': {
          ...good(),
          'plan': [
            {'effects': [1], 'loop': 1, 'delayMs': -1},
          ],
        },
        'plan delay missing': {
          ...good(),
          'plan': [
            {'effects': [1], 'loop': 1},
          ],
        },
        'plan empty': {...good(), 'plan': <Object>[]},
      };
      for (final e in bad.entries) {
        expect(() => BuzzSequence.fromJson(e.value),
            throwsA(isA<FormatException>()),
            reason: e.key);
      }
    });

    test('a rule with a bad plan fails to read instead of dropping it', () {
      expect(() => BuzzSequence.fromJson({...good(), 'plan': 'x'}),
          throwsFormatException);
    });
  });

  group('AppState plays the rule sequence (source guard)', () {
    test('_dispatchBandAlert band transport plays the rule\'s sequence', () {
      final src = File('lib/state/app_state.dart').readAsStringSync();
      final body = bodyOf(src, 'Future<AlertDeliveryOutcome> _dispatchBandAlert(');
      expect(body, isNotEmpty);
      // deliverBuzzSequence is playBuzzSequence's tri-state form (finding H):
      // the claim must survive a partial or unanswered delivery.
      expect(
          codeOnly(body),
          anyOf(contains('deliverBuzzSequence('),
              contains('haptics.deliver(')),
          reason: '8AC: on a MG band the same tri-state delivery is the '
              'compiled-plan helper');
      expect(codeOnly(body), contains('buzzSequenceFor('));
    });

    test('the relay plays through playBuzzSequence', () {
      final src = File('lib/notify/notification_relay.dart').readAsStringSync();
      expect(codeOnly(src), contains('playBuzzSequence('));
    });
  });
}
