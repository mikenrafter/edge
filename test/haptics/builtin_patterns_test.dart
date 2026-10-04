// 8AF.6 sections B, G.1 and G.2 (red first): the built-in (system) patterns.
//
// Three gesture cues (start, follow-up, confirm) and, since 8AI, the ten
// presets are stored beside the user's patterns (the per-alert built-ins of
// 8AF.6 are gone: an alert slot's default is one of the presets, see
// test/fix8ai/g4_presets_test.dart). They cannot be renamed or deleted; the
// cues can be customised and put back (Reset to default), the presets are
// read-only. The hub lists them under "Your patterns" and "Presets"; the
// picker lists "Your patterns", a divider, then "Built in".
//
// Contracts these tests pin that the spec leaves open:
//  - `SavedHapticPattern.system` (bool) and `.systemKey` (String?) are read
//    through `dynamic`, so a missing member fails its own test and the file
//    still compiles. A user pattern has system false and a null systemKey.
//  - Seeding happens on SettingsRepository.read() and .patterns() (which
//    HapticPatternStore.load() wraps), and again inside an update, so a draft
//    taken before anything was loaded already holds the built-ins.
//  - A built-in's sequence carries its own id as patternId, the baked plan for
//    the WHOOP MG profile (profileId whoop-5.0-mg) AND the taps rhythm, so a
//    4.0 band plays today's rhythm.
//  - gesture.start is the one-command `pair` plan (effects 47, 152), gesture
//    .followUp is the fastest single (effect 14, buzz14) and gesture.confirm is
//    buzz47 (effect 47). Their notes are never re-picked by the caller.
//  - alert.<ruleId> is BuzzSequence.defaultFor(its alertRuleOrder index) as
//    `*` (any loudness) notes with rhythm priority: every note one sixteenth
//    (the taps have no hold), the rests the original gaps. NOT re-voiced with
//    the fastest single. The rules wake, alarm and nativeAlarm get none.
//    alarmLatchFailed and alarmNightCheck are left open by the spec: neither
//    required nor forbidden here.
//  - `HapticPatternStore.resetToDefault(id)` puts a built-in's sequence back
//    to its seeded default (and refuses a user pattern).
//  - A built-in's name is taken: a user cannot add a pattern with it.
//  - Rename and delete of a built-in throw from the store (any exception).
//  - HapticsSettingsView and showPatternPicker keep today's parameters; a
//    built-in is told apart by `.system`. The hub's section headers are the
//    texts "Your patterns" and "Built in"; the divider between them is a
//    widget keyed `built-in-divider`; the built-in sheet adds the row
//    "Reset to default" (key `haptic-action-reset`) and has no Rename or
//    Delete. A built-in row carries a lock icon or the text "Built in".
//  - Wiring the Reset row to the store (onReset on the view) is a green-phase
//    detail; here the row's presence and the absence of Rename/Delete are
//    pinned, and the store method is tested directly.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart' show builtInDefault;
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/profile/pattern_picker.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phase8/support/sections.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

bool _sys(SavedHapticPattern p) => (p as dynamic).system as bool;
String? _key(SavedHapticPattern p) => (p as dynamic).systemKey as String?;

// 'gesture' plays nothing of its own (8AI.3): the three gesture cues do.
const _alarmish = {'alarm', 'nativeAlarm', 'wake', 'gesture'};
const _open = {'alarmLatchFailed', 'alarmNightCheck'};

final List<String> _alertRules = [
  for (final id in NotificationPrefs.alertRuleOrder)
    if (!_alarmish.contains(id) && !_open.contains(id)) id,
];

SettingsRepository get _repo => SettingsRepository.instance;

// Lenient on purpose: before the member exists this reads as "no built-ins",
// so the UI tests fail on their own expectation rather than a NoSuchMethodError
// thrown out of a runAsync.
bool _isSys(SavedHapticPattern p) {
  try {
    return _sys(p);
  } on NoSuchMethodError {
    return false;
  }
}

Future<List<SavedHapticPattern>> _builtIns() async => [
      for (final p in (await _repo.read()).patterns)
        if (_isSys(p)) p,
    ];

SavedHapticPattern _byKey(List<SavedHapticPattern> all, String key) =>
    all.firstWhere((p) => _key(p) == key,
        orElse: () => throw TestFailure('no built-in with systemKey $key'));

List<PatternEntry> _entries(BuzzSequence s) =>
    PatternTranscript.parseCode(s.notes!).entries;

BuzzSequence _mine() => BuzzSequence(
      const [0, 625],
      durationsMs: const [500, 500],
      notes: 'N4mf R1 N4mf',
      profileId: _mg.id,
      profileVersion: _mg.version,
      bakedSteps: [
        BakedStep(effects: const [47], loop: 1, delayMs: 0),
        BakedStep(effects: const [14], loop: 1, delayMs: 300),
      ],
    );

Future<SavedHapticPattern> _addMine(String name) async {
  late SavedHapticPattern p;
  await _repo.update(
    (d) => p = d.patterns.add(name, _mine()),
    sections: {SettingsSection.patterns},
  );
  return p;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('seeding', () {
    test('a fresh store holds the gesture and breathing cue built-ins and '
        'the ten presets, and none per alert rule', () async {
      final all = await _builtIns();
      final keys = [for (final p in all) _key(p)];
      expect(keys.toSet(), hasLength(keys.length), reason: 'no duplicates');
      for (final k in [
        'gesture.start',
        'gesture.followUp',
        'gesture.confirm',
        'breath.inhale',
        'breath.exhale',
        'breath.hold',
        'breath.done',
      ]) {
        expect(keys, contains(k));
      }
      expect(keys.where((k) => k!.startsWith('preset.')), hasLength(10));
      for (final id in NotificationPrefs.alertRuleOrder) {
        expect(keys, isNot(contains('alert.$id')),
            reason: 'an alert slot plays a preset, it is not a built-in');
      }
      for (final k in keys) {
        expect(
            k!.startsWith('preset.') ||
                k.startsWith('gesture.') ||
                k.startsWith('breath.'),
            isTrue,
            reason: 'unexpected systemKey $k');
      }
    });

    test('a user pattern is not system and has no systemKey', () async {
      final mine = await _addMine('Mine');
      expect(_sys(mine), isFalse);
      expect(_key(mine), isNull);
    });

    test('every built-in refers to itself and is named', () async {
      final built = await _builtIns();
      expect(built, isNotEmpty);
      for (final p in built) {
        expect(p.sequence.patternId, p.id, reason: _key(p));
        expect(p.name, isNotEmpty);
      }
    });

    test('reading again changes nothing: same ids, same bytes, no '
        'duplicates', () async {
      final first = await _repo.read();
      final second = await _repo.read();
      final viaStore = await HapticPatternStore.load();
      String enc(List<SavedHapticPattern> ps) =>
          jsonEncode([for (final p in ps) p.toJson()]);
      expect(enc(second.patterns), enc(first.patterns));
      expect(enc(viaStore.list), enc(first.patterns));
      final built = [for (final p in first.patterns) if (_isSys(p)) p];
      expect(built, isNotEmpty);
      expect({for (final p in built) p.id}, hasLength(built.length));
      expect({for (final p in built) _key(p)}, hasLength(built.length));
    });

    test('a user pattern saved beside them survives, and so do they after a '
        'reorder of the stored list', () async {
      final mine = await _addMine('Mine');
      final before = await _builtIns();
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(HapticPatternStore.prefsKey)!;
      final list = (jsonDecode(raw) as List).reversed.toList();
      await sp.setString(HapticPatternStore.prefsKey, jsonEncode(list));
      final snap = await _repo.read();
      final after = [for (final p in snap.patterns) if (_sys(p)) p];
      expect([for (final p in after) _key(p)]..sort(),
          [for (final p in before) _key(p)]..sort());
      expect(snap.patterns.where((p) => p.id == mine.id), hasLength(1));
      expect(snap.patterns.where((p) => !_sys(p)), hasLength(1));
    });

    test('a store written before 8AF.6 (no system fields) reads with its '
        'user patterns intact and the built-ins added', () async {
      SharedPreferences.setMockInitialValues({
        HapticPatternStore.prefsKey: jsonEncode([
          {
            'id': 'u1',
            'name': 'Mine',
            'sequence': [0, 500],
          },
        ]),
      });
      final snap = await _repo.read();
      final mine = snap.patterns.firstWhere((p) => p.id == 'u1');
      expect(_sys(mine), isFalse);
      expect(mine.name, 'Mine');
      expect(snap.patterns.where(_sys), isNotEmpty);
    });

    test('JSON is additive: a user pattern writes the old three keys, a '
        'built-in survives encode and decode', () async {
      final mine = await _addMine('Mine');
      expect((mine.toJson() as Map).keys.toSet(), {'id', 'name', 'sequence'});
      final store = await HapticPatternStore.load();
      final again = HapticPatternStore.decode(store.encode());
      final built = [for (final p in store.list) if (_sys(p)) p];
      expect(built, isNotEmpty);
      for (final p in built) {
        final q = again.byId(p.id)!;
        expect(_sys(q), isTrue, reason: _key(p));
        expect(_key(q), _key(p));
        expect(q.sequence, p.sequence);
        expect(q.name, p.name);
      }
      expect(_sys(again.byId(mine.id)!), isFalse);
    });
  });

  group('the gesture built-ins are the fastest vocabulary', () {
    test('gesture.start is the pair, one command', () async {
      final p = _byKey(await _builtIns(), 'gesture.start');
      expect(p.sequence.profileId, _mg.id);
      expect(p.sequence.bakedSteps, [
        BakedStep(effects: const [47, 152], loop: 1, delayMs: 0),
      ]);
      expect(p.sequence.notes, isNotNull);
    });

    test('gesture.followUp is one buzz14, a single note', () async {
      final p = _byKey(await _builtIns(), 'gesture.followUp');
      expect(p.sequence.profileId, _mg.id);
      expect(p.sequence.bakedSteps, [
        BakedStep(effects: const [14], loop: 1, delayMs: 0),
      ]);
      final es = _entries(p.sequence);
      expect(es.where((e) => e.note), hasLength(1));
      expect(es.where((e) => !e.note), isEmpty);
    });

    test('gesture.followUp is what the profile calls the fastest single',
        () async {
      final fastest = (_mg as dynamic).fastestSingle() as HapticPhrase;
      final p = _byKey(await _builtIns(), 'gesture.followUp');
      expect(p.sequence.bakedSteps, [
        BakedStep(effects: fastest.effects, loop: fastest.loop, delayMs: 0),
      ]);
    });

    test('gesture.confirm is buzz47, one single note, stronger than the '
        'follow-up', () async {
      final all = await _builtIns();
      final p = _byKey(all, 'gesture.confirm');
      expect(p.sequence.profileId, _mg.id);
      expect(p.sequence.bakedSteps, [
        BakedStep(effects: const [47], loop: 1, delayMs: 0),
      ]);
      expect(_entries(p.sequence).where((e) => e.note), hasLength(1));
      expect(p.sequence.bakedSteps, isNot(
          _byKey(all, 'gesture.followUp').sequence.bakedSteps));
    });

    test('they play on a 4.0 band as valid taps (no profile needed)',
        () async {
      for (final k in ['gesture.start', 'gesture.followUp', 'gesture.confirm']) {
        final s = _byKey(await _builtIns(), k).sequence;
        expect(s.length, greaterThanOrEqualTo(1), reason: k);
        expect(s.offsetsMs.first, 0, reason: k);
      }
    });
  });

  group('an alert slot plays a preset until the wearer picks another', () {
    test('every alert rule with a default has one, a preset carrying its own '
        'id', () async {
      final all = await _builtIns();
      for (final id in _alertRules) {
        final spec = builtInDefault('alert.$id');
        expect(spec, isNotNull, reason: id);
        final stored = all.firstWhere((p) => p.name == spec!.name,
            orElse: () => throw TestFailure('preset ${spec!.name} not seeded'));
        expect(_key(stored), startsWith('preset.'), reason: id);
        expect(spec!.sequence.patternId, stored.id, reason: id);
        expect(spec.sequence.profileId, _mg.id, reason: id);
        expect(spec.sequence.bakedSteps, isNotEmpty, reason: id);
      }
    });

    test('the store hands the slot its preset by the slot key', () async {
      final store = await HapticPatternStore.load();
      for (final id in _alertRules) {
        expect(store.bySystemKey('alert.$id')?.name,
            builtInDefault('alert.$id')?.name,
            reason: id);
      }
      expect(store.bySystemKey('alert.wake'), isNull);
    });

    test('the zone alert has a default (the HR zone alert is a full alert, '
        '8AF.6 G.3)', () {
      expect(builtInDefault('alert.zone'), isNotNull);
    });

    test('the per-alert built-ins a store holds from before the presets: one '
        'still on its old rhythm gives way, one the wearer changed stays',
        () async {
      final untouched = BuzzSequence.defaultFor(
          NotificationPrefs.alertRuleOrder.indexOf('health'));
      SharedPreferences.setMockInitialValues({
        HapticPatternStore.prefsKey: jsonEncode([
          // health: still its seeded rhythm (a single sixteenth note).
          {
            'id': 'sys.alert.health',
            'name': 'Health alert',
            'systemKey': 'alert.health',
            'sequence': untouched
                .copyWith(notes: 'N1*', patternId: 'sys.alert.health')
                .toJson(),
          },
          // water: the wearer rewrote it.
          {
            'id': 'sys.alert.water',
            'name': 'Water alert',
            'systemKey': 'alert.water',
            'sequence': _mine().copyWith(patternId: 'sys.alert.water').toJson(),
          },
        ]),
      });
      final all = (await _repo.read()).patterns;
      expect(all.where((p) => p.id == 'sys.alert.health'), isEmpty);
      final kept = all.firstWhere((p) => p.id == 'sys.alert.water');
      expect(kept.sequence.notes, 'N4mf R1 N4mf');
      final store = await HapticPatternStore.load();
      expect(store.bySystemKey('alert.health')?.name,
          builtInDefault('alert.health')?.name);
      expect(store.bySystemKey('alert.water')?.id, 'sys.alert.water');
    });
  });

  group('built-ins cannot be renamed or deleted, and can be customised',
      () {
    test('the store refuses rename and delete of a built-in', () async {
      final store = await HapticPatternStore.load();
      final p = store.list.firstWhere(_sys);
      expect(() => store.rename(p.id, 'Something else'), throwsA(anything));
      expect(() => store.delete(p.id), throwsA(anything));
      expect(store.byId(p.id)!.name, p.name);
    });

    test('an update that deletes one throws and writes nothing', () async {
      final p = (await _builtIns()).first;
      final before = jsonEncode([
        for (final q in (await _repo.read()).patterns) q.toJson(),
      ]);
      await expectLater(
        _repo.update((d) => d.patterns.delete(p.id),
            sections: {SettingsSection.patterns}),
        throwsA(anything),
      );
      final after = jsonEncode([
        for (final q in (await _repo.read()).patterns) q.toJson(),
      ]);
      expect(after, before);
    });

    test('a user cannot take a built-in\'s name', () async {
      final p = (await _builtIns()).first;
      await expectLater(
        _repo.update((d) => d.patterns.add(p.name, _mine()),
            sections: {SettingsSection.patterns}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a user pattern still renames and deletes (unchanged)', () async {
      final mine = await _addMine('Mine');
      await _repo.update((d) => d.patterns.rename(mine.id, 'Yours'),
          sections: {SettingsSection.patterns});
      expect((await HapticPatternStore.load()).byId(mine.id)!.name, 'Yours');
      await _repo.update((d) => d.patterns.delete(mine.id),
          sections: {SettingsSection.patterns});
      expect((await HapticPatternStore.load()).byId(mine.id), isNull);
    });

    test('replace customises a built-in and the change survives a reload '
        '(the seed does not overwrite it)', () async {
      final p = _byKey(await _builtIns(), 'gesture.confirm');
      final custom = _mine();
      await _repo.update((d) => d.patterns.replace(p.id, custom),
          sections: {SettingsSection.patterns});
      final again = _byKey(await _builtIns(), 'gesture.confirm');
      expect(again.id, p.id);
      expect(again.name, p.name);
      expect(_sys(again), isTrue);
      expect(_key(again), 'gesture.confirm');
      expect(again.sequence.notes, 'N4mf R1 N4mf');
      expect(again.sequence.patternId, p.id);
    });

    test('Reset to default restores the seeded sequence', () async {
      final p = _byKey(await _builtIns(), 'gesture.confirm');
      await _repo.update((d) => d.patterns.replace(p.id, _mine()),
          sections: {SettingsSection.patterns});
      await _repo.update(
          (d) => (d.patterns as dynamic).resetToDefault(p.id),
          sections: {SettingsSection.patterns});
      final again = _byKey(await _builtIns(), 'gesture.confirm');
      expect(again.sequence, p.sequence);
      expect(again.id, p.id);
    });

    test('Reset to default refuses a user pattern', () async {
      final mine = await _addMine('Mine');
      final store = await HapticPatternStore.load();
      expect(() => (store as dynamic).resetToDefault(mine.id),
          throwsA(predicate((e) => e is! NoSuchMethodError)));
    });
  });

  group('the hub: Your patterns, then Presets', () {
    Widget hub(
      List<SavedHapticPattern> patterns, {
      HapticDeviceProfile? profile,
      List<BuzzSequence>? played,
    }) =>
        HapticsSettingsView(
          patterns: patterns,
          usageOf: (_) => 0,
          profile: profile,
          allowLong: false,
          devMode: false,
          commandsLeft: 30,
          queued: 0,
          bandConnected: true,
          onPlay: (s) async {
            played?.add(s);
            return true;
          },
          onBuzz: () {},
          onAllowLong: (_) {},
          onAdd: (n, s) {},
          onReplace: (id, s) {},
          onRename: (id, n) {},
          onDelete: (_) {},
          onDeviceLab: () {},
        );

    Future<(List<SavedHapticPattern>, List<SavedHapticPattern>)> mixed(
        WidgetTester t) async {
      late List<SavedHapticPattern> built;
      late List<SavedHapticPattern> mine;
      await t.runAsync(() async {
        mine = [await _addMine('Morning'), await _addMine('Evening')];
        built = await _builtIns();
      });
      expect(built, isNotEmpty, reason: 'the built-ins are seeded');
      return (built, mine);
    }

    double top(WidgetTester t, Finder f) => t.getTopLeft(f.first).dy;

    testWidgets('the Your patterns and Presets accordions and their rows sit '
        'in that order', (t) async {
      final (built, mine) = await mixed(t);
      // The view is handed one list, the user's patterns and the built-ins
      // interleaved, and splits it itself.
      await pumpTall(t, hub([built.first, ...mine, ...built.skip(1)],
          profile: _mg));
      final yours = top(t, section('Your patterns'));
      final presets = top(t, section('Presets'));
      expect(yours, lessThan(presets));
      for (final p in mine) {
        final y = top(t, find.byKey(ValueKey('haptic-pattern:${p.id}')));
        expect(y, greaterThan(yours), reason: p.name);
        expect(y, lessThan(presets), reason: p.name);
      }
      for (final p in built) {
        final y = top(t, find.byKey(ValueKey('haptic-pattern:${p.id}')));
        expect(y, greaterThan(presets), reason: '${_key(p)}');
      }
    });

    testWidgets('"Your patterns" is shown even when you have none, with '
        'the built-ins below it', (t) async {
      final (built, _) = await mixed(t);
      // A fresh store: the two patterns _addMine made are not in this list.
      await pumpTall(t, hub(built, profile: _mg));
      expect(top(t, section('Your patterns')),
          lessThan(top(t, section('Presets'))));
    });

    testWidgets('a built-in row says so (a lock or "Built in") and a user '
        'row does not', (t) async {
      final (built, mine) = await mixed(t);
      await pumpTall(t, hub([...mine, ...built], profile: _mg));
      Finder tagIn(SavedHapticPattern p) {
        final row = find.byKey(ValueKey('haptic-pattern:${p.id}'));
        return find.descendant(
          of: row,
          matching: find.byWidgetPredicate((w) =>
              (w is Icon && w.icon == LucideIcons.lock) ||
              (w is Text && w.data == 'Built in')),
        );
      }

      for (final p in built) {
        expect(tagIn(p), findsWidgets, reason: '${_key(p)}');
      }
      for (final p in mine) {
        expect(tagIn(p), findsNothing, reason: p.name);
      }
    });

    testWidgets('a built-in\'s sheet: Preview, Edit notes, Re-record and '
        'Reset to default; no Rename, no Delete', (t) async {
      final (built, _) = await mixed(t);
      final p = _byKey(built, 'gesture.followUp');
      final played = <BuzzSequence>[];
      await pumpTall(t, hub([...built], profile: _mg, played: played));
      await t.tap(find.byKey(ValueKey('haptic-pattern:${p.id}')));
      await t.pumpAndSettle();
      final sheet = find.byKey(const ValueKey('haptic-pattern-sheet'));
      expect(sheet, findsOneWidget);
      for (final k in [
        'haptic-action-preview',
        'haptic-action-edit',
        'haptic-action-rerecord',
        'haptic-action-reset',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.descendant(of: sheet, matching: find.text('Reset to default')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('haptic-action-rename')), findsNothing);
      expect(find.byKey(const ValueKey('haptic-action-delete')), findsNothing);
      expect(find.descendant(of: sheet, matching: find.text('Rename')),
          findsNothing);
      expect(find.descendant(of: sheet, matching: find.text('Delete')),
          findsNothing);
      await t.tap(find.byKey(const ValueKey('haptic-action-preview')));
      await t.pumpAndSettle();
      expect(played, [p.sequence]);
    });

    testWidgets('without a profile the built-in sheet has no Edit notes but '
        'still has Reset to default', (t) async {
      final (built, _) = await mixed(t);
      final p = _byKey(built, 'gesture.start');
      await pumpTall(t, hub(built));
      await t.tap(find.byKey(ValueKey('haptic-pattern:${p.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('haptic-action-edit')), findsNothing);
      expect(find.byKey(const ValueKey('haptic-action-rerecord')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('haptic-action-reset')), findsOneWidget);
    });

    testWidgets('a user pattern\'s sheet keeps Rename and Delete and has no '
        'Reset', (t) async {
      final (built, mine) = await mixed(t);
      await pumpTall(t, hub([...mine, ...built], profile: _mg));
      await t.tap(find.byKey(ValueKey('haptic-pattern:${mine.first.id}')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('haptic-action-rename')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('haptic-action-delete')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('haptic-action-reset')), findsNothing);
    });
  });

  group('the picker: Default on top, then Your patterns, a divider, Built in',
      () {
    late List<BuzzSequence> chosen;
    late int defaults;

    Future<void> open(
      WidgetTester t,
      List<SavedHapticPattern> patterns, {
      BuzzSequence? current,
    }) async {
      chosen = [];
      defaults = 0;
      t.view.physicalSize = const Size(1170, 30000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showPatternPicker(
                  c,
                  patterns: patterns,
                  current: current,
                  profile: _mg,
                  bandConnected: true,
                  onPlay: (_) async => true,
                  onDefault: () => defaults++,
                  onChoose: chosen.add,
                  onSaveNew: (name, s) async => SavedHapticPattern(
                    id: 'n1',
                    name: name,
                    sequence: s.copyWith(patternId: 'n1'),
                  ),
                ),
                child: const Text('open picker'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open picker'));
      await t.pumpAndSettle();
    }

    double top(WidgetTester t, Finder f) => t.getTopLeft(f.first).dy;

    testWidgets('the order down the sheet', (t) async {
      late List<SavedHapticPattern> built;
      late List<SavedHapticPattern> mine;
      await t.runAsync(() async {
        mine = [await _addMine('Morning'), await _addMine('Evening')];
        built = await _builtIns();
      });
      expect(built, isNotEmpty);
      await open(t, [built.first, ...mine, ...built.skip(1)]);
      final def = top(t, find.byKey(const ValueKey('pattern-picker-default')));
      final yours = top(t, find.text('Your patterns'));
      final divider = top(t, find.byKey(const ValueKey('built-in-divider')));
      final builtIn = top(t, find.text('Built in'));
      expect(def, lessThan(yours), reason: 'Default stays at the very top');
      for (final p in mine) {
        final y = top(t, find.byKey(ValueKey('pattern-picker-row:${p.id}')));
        expect(y, greaterThan(yours), reason: p.name);
        expect(y, lessThan(divider), reason: p.name);
      }
      expect(divider, lessThan(builtIn));
      for (final p in built) {
        final y = top(t, find.byKey(ValueKey('pattern-picker-row:${p.id}')));
        expect(y, greaterThan(builtIn), reason: '${_key(p)}');
      }
    });

    testWidgets('choosing a built-in row selects it as a snapshot of itself',
        (t) async {
      late List<SavedHapticPattern> built;
      await t.runAsync(() async => built = await _builtIns());
      expect(built, isNotEmpty);
      final p = _byKey(built, 'gesture.confirm');
      await open(t, built);
      await t.tap(find.byKey(ValueKey('pattern-picker-row:${p.id}')));
      await t.pumpAndSettle();
      expect(chosen, hasLength(1));
      expect(chosen.single.patternId, p.id);
      expect(chosen.single.bakedSteps, p.sequence.bakedSteps);
    });

    testWidgets('the Default row still selects Default', (t) async {
      late List<SavedHapticPattern> built;
      await t.runAsync(() async => built = await _builtIns());
      await open(t, built);
      await t.tap(find.byKey(const ValueKey('pattern-picker-default')));
      await t.pumpAndSettle();
      expect(defaults, 1);
      expect(chosen, isEmpty);
    });
  });
}
