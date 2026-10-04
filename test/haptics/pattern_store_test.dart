// 8AD (A) — the named pattern store.
//
// A saved pattern is a BuzzSequence with a name and a stable id. A rule that
// picked one holds a SNAPSHOT of it with BuzzSequence.patternId set, so
// delivery never looks the store up. Editing or deleting a stored pattern
// rewrites the snapshots in every place a sequence is stored (AGENTS.md 4.7):
// (1) NotificationPrefs alert rules, (2) ChannelConfig.buzzSequence and
// (3) ChannelConfig.appSequences of the relay.
//
// API chosen for this phase (lib/haptics/pattern_store.dart):
//
//   class SavedHapticPattern {
//     SavedHapticPattern({required String id, required String name,
//         required BuzzSequence sequence});   // trims name; ArgumentError
//                                             // when empty or over 40 chars
//     final String id; final String name; final BuzzSequence sequence;
//     Object toJson();  // {'id','name','sequence'}
//     factory SavedHapticPattern.fromJson(Object? json); // FormatException
//   }
//
//   class HapticPatternStore {
//     static const String prefsKey = 'haptic_patterns_v1';
//     static Future<HapticPatternStore> load();  // serialized like
//                                                // NotificationPrefs; bad data
//                                                // gives an empty / shorter store
//     Future<void> save();                       // serialized, writes the list
//     List<SavedHapticPattern> get list;         // ordered by name, ignoring case
//     SavedHapticPattern? byId(String id);
//     SavedHapticPattern add(String name, BuzzSequence sequence);
//                               // new id; stored sequence has patternId = id
//     void rename(String id, String name);   // ArgumentError on bad / duplicate
//     void replace(String id, BuzzSequence sequence); // stamps patternId = id
//     void delete(String id);
//   }
//   The mutators change the store in memory; save() persists.
//
//   class PatternPropagation { final NotificationPrefs prefs;
//                              final Map<String, ChannelConfig> channels; }
//   PatternPropagation propagatePattern(String patternId,
//       {required NotificationPrefs prefs,
//        required Map<String, ChannelConfig> channels,
//        BuzzSequence? replacement});
//     replacement != null: every snapshot with that patternId becomes the
//       replacement (stamped with patternId);
//     replacement == null (delete): every snapshot keeps its rhythm and loses
//       patternId.
//   int patternUsageCount(String patternId,
//       {required NotificationPrefs prefs,
//        required Map<String, ChannelConfig> channels});
//     one per alert rule, per channel sequence and per app sequence.
//
//   BuzzSequence gets `String? patternId` (constructor, copyWith, JSON key
//   'patternId' only when set, ==/hashCode).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:shared_preferences/shared_preferences.dart';

final BuzzSequence _taps = BuzzSequence([0, 500, 1000]);
final BuzzSequence _tapsB = BuzzSequence([0, 800]);

BuzzSequence _notes() => BuzzSequence(
  [0],
  notes: 'N4ff R4 N4ff',
  profileId: 'whoop-5.0-mg',
  profileVersion: 1,
  bakedSteps: [
    BakedStep(effects: [47], loop: 1, delayMs: 0),
    BakedStep(effects: [47], loop: 1, delayMs: 300),
  ],
);

Map<String, Object?> _rule(String id, BuzzSequence? s) => {
  'id': id,
  'destinations': 2,
  if (s != null) 'buzzSequence': s.toJson(),
};

NotificationPrefs _prefsWith(Map<String, BuzzSequence?> rules) {
  var p = const NotificationPrefs();
  for (final e in rules.entries) {
    p = p.withAlertRule(_rule(e.key, e.value));
  }
  return p;
}

Map<String, ChannelConfig> _channels({
  BuzzSequence? apps,
  Map<String, BuzzSequence> perApp = const {},
  BuzzSequence? alarms,
  BuzzSequence? calls,
}) => {
  'apps': ChannelConfig(
    enabled: true,
    buzzSequence: apps,
    appSequences: perApp,
  ),
  'alarms': ChannelConfig(enabled: true, buzzSequence: alarms),
  'calls': ChannelConfig(buzzSequence: calls),
};

/// The user-made patterns: the built-ins (8AF.6) are seeded beside them.
List<SavedHapticPattern> _mine(HapticPatternStore s) => [
  for (final p in s.list)
    if (!p.system) p,
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('BuzzSequence.patternId', () {
    test('a sequence without one has none and its JSON is unchanged', () {
      expect(_taps.patternId, isNull);
      expect(jsonEncode(_taps.toJson()), '[0,500,1000]');
      expect(
        jsonEncode(BuzzSequence([0, 600], durationsMs: [100, 100]).toJson()),
        '{"offsetsMs":[0,600],"durationsMs":[100,100]}',
      );
      expect(
        jsonEncode(BuzzSequence.fromJson({
          'offsetsMs': [0, 500],
          'durationsMs': [0, 0],
          'extended': true,
        }).toJson()),
        '[0,500]', // the old flag is read and no longer written
      );
      expect(
        jsonEncode(_notes().toJson()),
        '{"offsetsMs":[0],"durationsMs":[0],"notes":"N4ff R4 N4ff",'
        '"profileId":"whoop-5.0-mg","profileVersion":1,'
        '"plan":[{"effects":[47],"loop":1,"delayMs":0},'
        '{"effects":[47],"loop":1,"delayMs":300}]}',
      );
    });

    test('the constructor and copyWith take it', () {
      expect(BuzzSequence([0, 500], patternId: 'abc').patternId, 'abc');
      final s = _taps.copyWith(patternId: 'abc');
      expect(s.patternId, 'abc');
      expect(s.offsetsMs, _taps.offsetsMs);
      // copyWith keeps it when not given.
      expect(s.copyWith(profileId: 'x').patternId, 'abc');
    });

    test('JSON carries it only when set, and a plain taps list becomes a map',
        () {
      final json = _taps.copyWith(patternId: 'abc').toJson();
      expect(json, isA<Map>());
      expect((json as Map)['patternId'], 'abc');
      expect(_notes().copyWith(patternId: 'abc').toJson(), containsPair(
        'patternId',
        'abc',
      ));
      expect(
        (_notes().toJson() as Map).containsKey('patternId'),
        isFalse,
      );
    });

    test('round trips through JSON text', () {
      for (final s in [
        _taps.copyWith(patternId: 'p1'),
        _notes().copyWith(patternId: 'p2'),
        BuzzSequence([0, 600], durationsMs: [100, 100], patternId: 'p3'),
      ]) {
        final back = BuzzSequence.fromJson(jsonDecode(jsonEncode(s.toJson())));
        expect(back, s);
        expect(back.patternId, s.patternId);
      }
    });

    test('old JSON (no patternId) loads with none', () {
      expect(BuzzSequence.fromJson([0, 500]).patternId, isNull);
      expect(
        BuzzSequence.fromJson({
          'offsetsMs': [0, 500],
          'durationsMs': [0, 0],
          'extended': true,
        }).patternId,
        isNull,
      );
    });

    test('a patternId that is not a string is a FormatException', () {
      expect(
        () => BuzzSequence.fromJson({
          'offsetsMs': [0],
          'durationsMs': [0],
          'patternId': 5,
        }),
        throwsFormatException,
      );
    });

    test('equality and hashCode include it', () {
      final a = _taps.copyWith(patternId: 'x');
      final b = _taps.copyWith(patternId: 'x');
      final c = _taps.copyWith(patternId: 'y');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot(_taps));
      expect(a.hashCode, isNot(_taps.hashCode));
    });
  });

  group('SavedHapticPattern', () {
    SavedHapticPattern make({String id = 'id1', String name = 'Calm'}) =>
        SavedHapticPattern(id: id, name: name, sequence: _taps);

    test('keeps id, name and sequence', () {
      final p = make();
      expect(p.id, 'id1');
      expect(p.name, 'Calm');
      expect(p.sequence, _taps);
    });

    test('trims the name', () {
      expect(make(name: '  Calm  ').name, 'Calm');
    });

    test('a name of 1 to 40 characters is fine', () {
      expect(make(name: 'a').name, 'a');
      expect(make(name: 'a' * 40).name, 'a' * 40);
    });

    test('an empty, blank or over-long name is an ArgumentError', () {
      expect(() => make(name: ''), throwsArgumentError);
      expect(() => make(name: '   '), throwsArgumentError);
      expect(() => make(name: 'a' * 41), throwsArgumentError);
      // 40 after trimming is fine, 41 is not.
      expect(() => make(name: '  ${'a' * 41}  '), throwsArgumentError);
    });

    test('an empty id is an ArgumentError', () {
      expect(() => make(id: ''), throwsArgumentError);
    });

    test('JSON round trip, with notes and a baked plan', () {
      for (final seq in [_taps, _notes()]) {
        final p = SavedHapticPattern(id: 'k', name: 'N', sequence: seq);
        final json = jsonDecode(jsonEncode(p.toJson()));
        expect(json, isA<Map>());
        expect(json['id'], 'k');
        expect(json['name'], 'N');
        expect(json.containsKey('sequence'), isTrue);
        final back = SavedHapticPattern.fromJson(json);
        expect(back.id, 'k');
        expect(back.name, 'N');
        expect(back.sequence, seq);
      }
    });

    test('fromJson rejects a bad shape with a FormatException', () {
      for (final bad in <Object?>[
        null,
        5,
        'x',
        <Object?>[],
        {'name': 'a', 'sequence': [0]},
        {'id': 'a', 'sequence': [0]},
        {'id': 'a', 'name': 'a'},
        {'id': 'a', 'name': '', 'sequence': [0]},
        {'id': 'a', 'name': 'a', 'sequence': 'nope'},
        {'id': 3, 'name': 'a', 'sequence': [0]},
      ]) {
        expect(
          () => SavedHapticPattern.fromJson(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  group('HapticPatternStore', () {
    test('the key is haptic_patterns_v1', () {
      expect(HapticPatternStore.prefsKey, 'haptic_patterns_v1');
    });

    test('a fresh store has no patterns of your own (the built-ins are seeded)', () async {
      final s = await HapticPatternStore.load();
      expect(_mine(s), isEmpty);
      expect(s.byId('nope'), isNull);
    });

    test('add gives a new id, stamps patternId, and returns the pattern',
        () async {
      final s = await HapticPatternStore.load();
      final a = s.add('Calm', _taps);
      final b = s.add('Alert', _tapsB);
      expect(a.id, isNotEmpty);
      expect(b.id, isNotEmpty);
      expect(a.id, isNot(b.id));
      expect(a.name, 'Calm');
      expect(a.sequence.patternId, a.id);
      expect(a.sequence.offsetsMs, _taps.offsetsMs);
      expect(s.byId(a.id)!.sequence, a.sequence);
    });

    test('list is ordered by name, ignoring case', () async {
      final s = await HapticPatternStore.load();
      s.add('banana', _taps);
      s.add('Apple', _taps);
      s.add('cherry', _taps);
      s.add('Banjo', _taps);
      expect([for (final p in _mine(s)) p.name], [
        'Apple',
        'banana',
        'Banjo',
        'cherry',
      ]);
    });

    test('names are unique ignoring case, and trimmed', () async {
      final s = await HapticPatternStore.load();
      s.add('Calm', _taps);
      expect(() => s.add('calm', _tapsB), throwsArgumentError);
      expect(() => s.add('  CALM ', _tapsB), throwsArgumentError);
      expect(() => s.add('', _tapsB), throwsArgumentError);
      expect(() => s.add('a' * 41, _tapsB), throwsArgumentError);
      expect(_mine(s), hasLength(1));
    });

    test('rename changes the name only, keeps id and sequence', () async {
      final s = await HapticPatternStore.load();
      final a = s.add('Calm', _taps);
      s.add('Alert', _tapsB);
      s.rename(a.id, 'Zen');
      final r = s.byId(a.id)!;
      expect(r.name, 'Zen');
      expect(r.sequence, a.sequence);
      expect([for (final p in _mine(s)) p.name], ['Alert', 'Zen']);
    });

    test('rename to its own name in another case is allowed; to a taken '
        'name or a bad one is an ArgumentError', () async {
      final s = await HapticPatternStore.load();
      final a = s.add('Calm', _taps);
      s.add('Alert', _tapsB);
      s.rename(a.id, 'CALM');
      expect(s.byId(a.id)!.name, 'CALM');
      expect(() => s.rename(a.id, 'alert'), throwsArgumentError);
      expect(() => s.rename(a.id, ' '), throwsArgumentError);
      expect(s.byId(a.id)!.name, 'CALM');
    });

    test('rename, replace and delete of an unknown id throw ArgumentError',
        () async {
      final s = await HapticPatternStore.load();
      expect(() => s.rename('nope', 'x'), throwsArgumentError);
      expect(() => s.replace('nope', _taps), throwsArgumentError);
      expect(() => s.delete('nope'), throwsArgumentError);
    });

    test('replace swaps the sequence, keeps id and name, stamps patternId',
        () async {
      final s = await HapticPatternStore.load();
      final a = s.add('Calm', _taps);
      s.replace(a.id, _notes());
      final r = s.byId(a.id)!;
      expect(r.name, 'Calm');
      expect(r.id, a.id);
      expect(r.sequence.notes, 'N4ff R4 N4ff');
      expect(r.sequence.bakedSteps, hasLength(2));
      expect(r.sequence.patternId, a.id);
    });

    test('delete removes it', () async {
      final s = await HapticPatternStore.load();
      final a = s.add('Calm', _taps);
      final b = s.add('Alert', _tapsB);
      s.delete(a.id);
      expect(s.byId(a.id), isNull);
      expect([for (final p in _mine(s)) p.id], [b.id]);
      // The name is free again.
      s.add('Calm', _taps);
      expect(_mine(s), hasLength(2));
    });

    test('save then load gives the same patterns', () async {
      final s = await HapticPatternStore.load();
      final a = s.add('Calm', _taps);
      final b = s.add('Notes', _notes());
      await s.save();
      final again = await HapticPatternStore.load();
      expect([for (final p in _mine(again)) p.id], [for (final p in _mine(s)) p.id]);
      expect(again.byId(a.id)!.name, 'Calm');
      expect(again.byId(a.id)!.sequence, a.sequence);
      expect(again.byId(b.id)!.sequence, b.sequence);
      expect(again.byId(b.id)!.sequence.bakedSteps, hasLength(2));
    });

    test('unsaved changes are not persisted', () async {
      final s = await HapticPatternStore.load();
      s.add('Calm', _taps);
      expect(_mine(await HapticPatternStore.load()), isEmpty);
    });

    test('the stored value is a JSON list under haptic_patterns_v1',
        () async {
      final s = await HapticPatternStore.load();
      final a = s.add('Calm', _taps);
      await s.save();
      final raw = (await SharedPreferences.getInstance()).getString(
        'haptic_patterns_v1',
      );
      expect(raw, isNotNull);
      // The built-ins are stored beside it; look at the user's own entry.
      final list = [
        for (final e in jsonDecode(raw!) as List)
          if ((e as Map)['systemKey'] == null) e,
      ];
      expect(list, hasLength(1));
      expect(list.single['id'], a.id);
      expect(list.single['name'], 'Calm');
    });

    test('a store written by hand loads', () async {
      SharedPreferences.setMockInitialValues({
        'haptic_patterns_v1': jsonEncode([
          {'id': 'h1', 'name': 'Hand', 'sequence': [0, 700]},
        ]),
      });
      final s = await HapticPatternStore.load();
      expect(s.byId('h1')!.name, 'Hand');
      expect(s.byId('h1')!.sequence.offsetsMs, [0, 700]);
    });

    test('unreadable data never throws: not JSON gives an empty store, a bad '
        'entry is dropped and the good ones stay', () async {
      SharedPreferences.setMockInitialValues({
        'haptic_patterns_v1': 'this is not json',
      });
      expect(_mine(await HapticPatternStore.load()), isEmpty);

      SharedPreferences.setMockInitialValues({
        'haptic_patterns_v1': jsonEncode({'not': 'a list'}),
      });
      expect(_mine(await HapticPatternStore.load()), isEmpty);

      SharedPreferences.setMockInitialValues({
        'haptic_patterns_v1': jsonEncode([
          {'id': 'ok', 'name': 'Fine', 'sequence': [0, 500]},
          {'id': 'bad', 'name': '', 'sequence': [0, 500]},
          {'id': 'bad2', 'name': 'X', 'sequence': 'nope'},
          7,
        ]),
      });
      final s = await HapticPatternStore.load();
      expect([for (final p in _mine(s)) p.id], ['ok']);
    });

    test('concurrent saves and loads do not lose or corrupt data', () async {
      final s = await HapticPatternStore.load();
      final a = s.add('Calm', _taps);
      await Future.wait([
        s.save(),
        s.save(),
        HapticPatternStore.load(),
        s.save(),
      ]);
      final again = await HapticPatternStore.load();
      expect(again.byId(a.id)!.name, 'Calm');
      expect(_mine(again), hasLength(1));
    });
  });

  group('propagation: alert rules (place 1)', () {
    test('replacing rewrites every rule holding the patternId', () {
      final snapA = _taps.copyWith(patternId: 'p1');
      final snapB = _tapsB.copyWith(patternId: 'p2');
      final prefs = _prefsWith({
        'water': snapA,
        'meds': snapA,
        'health': snapB,
        'movement': _taps, // same rhythm, picked by hand: no patternId
        'device': null, // default rhythm
      });
      final out = propagatePattern(
        'p1',
        prefs: prefs,
        channels: const {},
        replacement: _notes(),
      );
      for (final id in ['water', 'meds']) {
        final s = out.prefs.alertRule(id).buzzSequence!;
        expect(s.patternId, 'p1', reason: id);
        expect(s.notes, 'N4ff R4 N4ff', reason: id);
        expect(s.bakedSteps, hasLength(2), reason: id);
        expect(s, _notes().copyWith(patternId: 'p1'), reason: id);
      }
      // Others are untouched.
      expect(out.prefs.alertRule('health').buzzSequence, snapB);
      expect(out.prefs.alertRule('movement').buzzSequence, _taps);
      expect(out.prefs.alertRule('movement').buzzSequence!.patternId, isNull);
      expect(out.prefs.alertRule('device').buzzSequence, isNull);
    });

    test('the rest of a rewritten rule is kept', () {
      final snap = _taps.copyWith(patternId: 'p1');
      final prefs = _prefsWith({'water': snap});
      final before = prefs.alertRule('water');
      final out = propagatePattern(
        'p1',
        prefs: prefs,
        channels: const {},
        replacement: _tapsB,
      );
      final after = out.prefs.alertRule('water');
      expect(after.id, before.id);
      expect(after.destinations, before.destinations);
      expect(after.enabled, before.enabled);
      expect(after.executionMode, before.executionMode);
      expect(after.staleAfter, before.staleAfter);
      expect(after.buzzSequence!.offsetsMs, _tapsB.offsetsMs);
    });

    test('a replacement without patternId is stamped with it', () {
      final prefs = _prefsWith({'water': _taps.copyWith(patternId: 'p1')});
      final out = propagatePattern(
        'p1',
        prefs: prefs,
        channels: const {},
        replacement: _tapsB,
      );
      expect(out.prefs.alertRule('water').buzzSequence!.patternId, 'p1');
    });

    test('delete keeps the rhythm and drops the patternId', () {
      final snap = _notes().copyWith(patternId: 'p1');
      final prefs = _prefsWith({'water': snap, 'meds': _tapsB});
      final out = propagatePattern('p1', prefs: prefs, channels: const {});
      final s = out.prefs.alertRule('water').buzzSequence!;
      expect(s.patternId, isNull);
      expect(s, _notes());
      expect(s.notes, 'N4ff R4 N4ff');
      expect(s.bakedSteps, hasLength(2));
      expect(s.profileId, 'whoop-5.0-mg');
      expect(out.prefs.alertRule('meds').buzzSequence, _tapsB);
    });

    test('the result survives saving and loading the prefs', () async {
      final prefs = _prefsWith({'water': _taps.copyWith(patternId: 'p1')});
      await prefs.save();
      final loaded = await NotificationPrefs.load();
      expect(loaded.alertRule('water').buzzSequence!.patternId, 'p1');

      final out = propagatePattern(
        'p1',
        prefs: loaded,
        channels: const {},
        replacement: _notes(),
      );
      await out.prefs.save();
      final again = await NotificationPrefs.load();
      expect(again.alertRule('water').buzzSequence!.notes, 'N4ff R4 N4ff');
      expect(again.alertRule('water').buzzSequence!.patternId, 'p1');
      expect(again.buzzSequenceFor('water').patternId, 'p1');
    });

    test('an AlertRule keeps patternId through its own JSON', () {
      final prefs = _prefsWith({'water': _taps.copyWith(patternId: 'p1')});
      final json = prefs.alertRule('water').toJson();
      final again = const NotificationPrefs().withAlertRule(json);
      expect(again.alertRule('water').buzzSequence!.patternId, 'p1');
    });
  });

  group('propagation: relay channel sequence (place 2)', () {
    test('replacing rewrites each channel holding the patternId', () {
      final snap = _taps.copyWith(patternId: 'p1');
      final other = _tapsB.copyWith(patternId: 'p2');
      final channels = _channels(apps: snap, alarms: snap, calls: other);
      final out = propagatePattern(
        'p1',
        prefs: const NotificationPrefs(),
        channels: channels,
        replacement: _notes(),
      );
      final want = _notes().copyWith(patternId: 'p1');
      expect(out.channels['apps']!.buzzSequence, want);
      expect(out.channels['alarms']!.buzzSequence, want);
      expect(out.channels['calls']!.buzzSequence, other);
    });

    test('a channel with no sequence stays without one; other fields kept',
        () {
      final snap = _taps.copyWith(patternId: 'p1');
      final channels = {
        'apps': ChannelConfig(
          enabled: true,
          matchHaptics: true,
          allowDuringDnd: true,
          quietStartMinute: 60,
          quietEndMinute: 120,
          buzzSequence: snap,
        ),
        'alarms': const ChannelConfig(enabled: true),
        'calls': const ChannelConfig(),
      };
      final out = propagatePattern(
        'p1',
        prefs: const NotificationPrefs(),
        channels: channels,
        replacement: _tapsB,
      );
      expect(out.channels['alarms']!.buzzSequence, isNull);
      expect(out.channels['calls']!.buzzSequence, isNull);
      final apps = out.channels['apps']!;
      expect(apps.buzzSequence!.offsetsMs, _tapsB.offsetsMs);
      expect(apps.enabled, isTrue);
      expect(apps.matchHaptics, isTrue);
      expect(apps.allowDuringDnd, isTrue);
      expect(apps.quietStartMinute, 60);
      expect(apps.quietEndMinute, 120);
      expect(out.channels.keys.toSet(), {'apps', 'alarms', 'calls'});
    });

    test('delete keeps the channel rhythm and drops the patternId', () {
      final snap = _notes().copyWith(patternId: 'p1');
      final out = propagatePattern(
        'p1',
        prefs: const NotificationPrefs(),
        channels: _channels(alarms: snap),
      );
      final s = out.channels['alarms']!.buzzSequence!;
      expect(s.patternId, isNull);
      expect(s.notes, 'N4ff R4 N4ff');
      expect(s, _notes());
    });

    test('the channel config keeps patternId through its JSON', () {
      final cfg = ChannelConfig(
        buzzSequence: _taps.copyWith(patternId: 'p1'),
        appSequences: {'com.a': _tapsB.copyWith(patternId: 'p2')},
      );
      final back = ChannelConfig.fromJson(
        jsonDecode(jsonEncode(cfg.toJson())) as Map<String, Object?>,
        const ChannelConfig(),
      );
      expect(back.buzzSequence!.patternId, 'p1');
      expect(back.appSequences['com.a']!.patternId, 'p2');
    });
  });

  group('propagation: per-app sequences (place 3)', () {
    test('replacing rewrites each app holding the patternId only', () {
      final snap = _taps.copyWith(patternId: 'p1');
      final other = _tapsB.copyWith(patternId: 'p2');
      final channels = _channels(
        perApp: {'com.a': snap, 'com.b': other, 'com.c': _taps, 'com.d': snap},
      );
      final out = propagatePattern(
        'p1',
        prefs: const NotificationPrefs(),
        channels: channels,
        replacement: _notes(),
      );
      final apps = out.channels['apps']!.appSequences;
      final want = _notes().copyWith(patternId: 'p1');
      expect(apps['com.a'], want);
      expect(apps['com.d'], want);
      expect(apps['com.b'], other);
      expect(apps['com.c'], _taps);
      expect(apps.keys.toSet(), {'com.a', 'com.b', 'com.c', 'com.d'});
    });

    test('an app sequence is rewritten even when the channel holds a '
        'different one', () {
      final channels = _channels(
        apps: _tapsB.copyWith(patternId: 'p2'),
        perApp: {'com.a': _taps.copyWith(patternId: 'p1')},
      );
      final out = propagatePattern(
        'p1',
        prefs: const NotificationPrefs(),
        channels: channels,
        replacement: _notes(),
      );
      expect(out.channels['apps']!.buzzSequence!.patternId, 'p2');
      expect(out.channels['apps']!.appSequences['com.a']!.notes,
          'N4ff R4 N4ff');
    });

    test('delete keeps each app rhythm and drops the patternId', () {
      final snap = _notes().copyWith(patternId: 'p1');
      final out = propagatePattern(
        'p1',
        prefs: const NotificationPrefs(),
        channels: _channels(perApp: {'com.a': snap, 'com.b': _tapsB}),
      );
      final apps = out.channels['apps']!.appSequences;
      expect(apps['com.a']!.patternId, isNull);
      expect(apps['com.a']!.notes, 'N4ff R4 N4ff');
      expect(apps['com.b'], _tapsB);
    });

    test('sequenceForApp reads the rewritten snapshot', () {
      final channels = _channels(
        perApp: {'com.a': _taps.copyWith(patternId: 'p1')},
      );
      final out = propagatePattern(
        'p1',
        prefs: const NotificationPrefs(),
        channels: channels,
        replacement: _tapsB,
      );
      expect(
        out.channels['apps']!.sequenceForApp('com.a').offsetsMs,
        _tapsB.offsetsMs,
      );
    });
  });

  group('propagation: all three at once', () {
    final snap = _taps.copyWith(patternId: 'p1');

    test('one call rewrites rules, channels and apps together', () {
      final out = propagatePattern(
        'p1',
        prefs: _prefsWith({'water': snap}),
        channels: _channels(apps: snap, perApp: {'com.a': snap}, calls: snap),
        replacement: _notes(),
      );
      final want = _notes().copyWith(patternId: 'p1');
      expect(out.prefs.alertRule('water').buzzSequence, want);
      expect(out.channels['apps']!.buzzSequence, want);
      expect(out.channels['apps']!.appSequences['com.a'], want);
      expect(out.channels['calls']!.buzzSequence, want);
    });

    test('delete detaches all of them; usage then reads zero', () {
      final prefs = _prefsWith({'water': snap});
      final channels = _channels(apps: snap, perApp: {'com.a': snap});
      final out = propagatePattern('p1', prefs: prefs, channels: channels);
      expect(out.prefs.alertRule('water').buzzSequence!.patternId, isNull);
      expect(out.channels['apps']!.buzzSequence!.patternId, isNull);
      expect(out.channels['apps']!.appSequences['com.a']!.patternId, isNull);
      expect(
        patternUsageCount('p1', prefs: out.prefs, channels: out.channels),
        0,
      );
    });

    test('a pattern in no place changes nothing', () {
      final prefs = _prefsWith({'water': _tapsB.copyWith(patternId: 'p2')});
      final channels = _channels(apps: _taps, perApp: {'com.a': _taps});
      final out = propagatePattern(
        'p1',
        prefs: prefs,
        channels: channels,
        replacement: _notes(),
      );
      expect(out.prefs.alertRule('water').buzzSequence,
          _tapsB.copyWith(patternId: 'p2'));
      expect(out.channels['apps']!.buzzSequence, _taps);
      expect(out.channels['apps']!.appSequences['com.a'], _taps);
    });

    test('running it twice with the same replacement changes nothing more',
        () {
      final prefs = _prefsWith({'water': snap});
      final channels = _channels(apps: snap, perApp: {'com.a': snap});
      final once = propagatePattern(
        'p1',
        prefs: prefs,
        channels: channels,
        replacement: _notes(),
      );
      final twice = propagatePattern(
        'p1',
        prefs: once.prefs,
        channels: once.channels,
        replacement: _notes(),
      );
      expect(twice.prefs.alertRule('water').buzzSequence,
          once.prefs.alertRule('water').buzzSequence);
      expect(twice.channels['apps']!.buzzSequence,
          once.channels['apps']!.buzzSequence);
      expect(twice.channels['apps']!.appSequences,
          once.channels['apps']!.appSequences);
    });

    test('the inputs are not mutated', () {
      final prefs = _prefsWith({'water': snap});
      final channels = _channels(apps: snap, perApp: {'com.a': snap});
      propagatePattern('p1', prefs: prefs, channels: channels);
      expect(prefs.alertRule('water').buzzSequence, snap);
      expect(channels['apps']!.buzzSequence, snap);
      expect(channels['apps']!.appSequences['com.a'], snap);
    });
  });

  group('usageCount', () {
    final snap = _taps.copyWith(patternId: 'p1');

    test('zero when nothing holds it', () {
      expect(
        patternUsageCount(
          'p1',
          prefs: const NotificationPrefs(),
          channels: _channels(),
        ),
        0,
      );
      expect(
        patternUsageCount('p1', prefs: const NotificationPrefs(), channels: const {}),
        0,
      );
    });

    test('counts alert rules', () {
      expect(
        patternUsageCount(
          'p1',
          prefs: _prefsWith({'water': snap, 'meds': snap, 'health': _taps}),
          channels: const {},
        ),
        2,
      );
    });

    test('counts channel sequences', () {
      expect(
        patternUsageCount(
          'p1',
          prefs: const NotificationPrefs(),
          channels: _channels(apps: snap, alarms: snap, calls: _taps),
        ),
        2,
      );
    });

    test('counts per-app sequences', () {
      expect(
        patternUsageCount(
          'p1',
          prefs: const NotificationPrefs(),
          channels: _channels(
            perApp: {'com.a': snap, 'com.b': snap, 'com.c': _tapsB},
          ),
        ),
        2,
      );
    });

    test('adds the three places up and ignores other patterns', () {
      final other = _tapsB.copyWith(patternId: 'p2');
      final prefs = _prefsWith({'water': snap, 'meds': other});
      final channels = _channels(
        apps: snap,
        perApp: {'com.a': snap, 'com.b': other},
        calls: other,
      );
      expect(patternUsageCount('p1', prefs: prefs, channels: channels), 3);
      expect(patternUsageCount('p2', prefs: prefs, channels: channels), 3);
      expect(patternUsageCount('p3', prefs: prefs, channels: channels), 0);
    });
  });

  group('every storage place is covered (AGENTS.md 4.7)', () {
    test('propagation reads each place a BuzzSequence is stored', () {
      // The source guard: a new field holding a BuzzSequence must be added
      // to propagatePattern. This lists every one found today.
      final places = <String>[];
      final prefsSrc = _read('lib/notify/notification_prefs.dart');
      final ruleSrc = _read('lib/notify/alert_rule.dart');
      final relaySrc = _read('lib/notify/notification_relay.dart');
      if (RegExp(r'final BuzzSequence\? buzzSequence;').hasMatch(ruleSrc)) {
        places.add('AlertRule.buzzSequence');
      }
      if (RegExp(r'final BuzzSequence\? buzzSequence;').hasMatch(relaySrc)) {
        places.add('ChannelConfig.buzzSequence');
      }
      if (RegExp(r'Map<String, BuzzSequence> appSequences')
          .hasMatch(relaySrc)) {
        places.add('ChannelConfig.appSequences');
      }
      expect(places, [
        'AlertRule.buzzSequence',
        'ChannelConfig.buzzSequence',
        'ChannelConfig.appSequences',
      ]);
      expect(prefsSrc, contains('alertRules'));
      final store = _read('lib/haptics/pattern_store.dart');
      expect(store, contains('buzzSequence'));
      expect(store, contains('appSequences'));
      expect(store, contains('alertRules'));
    });
  });
}

String _read(String path) => File(path).readAsStringSync();
