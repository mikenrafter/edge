// 8AE.5 P2: the settings repository (lib/settings/settings_repository.dart).
//
// One typed seam over SharedPreferences with four sections: the alert prefs
// (NotificationPrefs), the relay channels (ChannelConfig per channel, with
// appSequences), the named haptic patterns, and the plain app prefs. One
// serialized `update` applies edits to any of them, persists them together or
// not at all, then tells the change stream.
//
// What these tests pin:
//   - the stored keys and JSON are byte-identical to what the old per-owner
//     save paths wrote (no migration);
//   - an update that touches several sections lands in one piece, with one
//     change event;
//   - an update whose later section fails to encode, or whose write is
//     refused, leaves nothing half-written;
//   - concurrent updates are serialized, so a read-modify-write never loses
//     the other one's change;
//   - the pattern propagation of 8AD is one update over alerts, channels and
//     patterns;
//   - the relay hears the change stream (quiet hours, channels) without any
//     screen telling it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
// A test-only import, as in test/off_lookup_test.dart: the store seam is how a
// refused write is made to happen.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

final BuzzSequence _taps = BuzzSequence([0, 500, 1000]);
final BuzzSequence _tapsB = BuzzSequence([0, 800]);

/// A channel whose encoding fails: the "later section throws" case.
class _BoomChannel extends ChannelConfig {
  const _BoomChannel() : super(enabled: true);
  @override
  Map<String, Object?> toJson() => throw StateError('encode failed');
}

/// A store that refuses one key, as a full or locked platform would.
class _RefusingStore extends InMemorySharedPreferencesStore {
  _RefusingStore(this.refuse) : super.empty();
  final String refuse;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.$refuse') return false;
    return super.setValue(valueType, key, value);
  }
}

Future<Map<String, Object?>> _raw() async {
  final sp = await SharedPreferences.getInstance();
  await sp.reload();
  return {for (final k in sp.getKeys().toList()..sort()) k: sp.get(k)};
}

NotificationPrefs _alerts() => const NotificationPrefs(
  quietStartMin: 1300,
  waterEnabled: true,
  batteryAlertPct: 25,
).withAlertRule({
  'id': 'water',
  'destinations': 2,
  'buzzSequence': _taps.copyWith(patternId: 'p1').toJson(),
});

Map<String, ChannelConfig> _channels() {
  final snap = _taps.copyWith(patternId: 'p1');
  return {
    'apps': ChannelConfig(
      enabled: true,
      buzzSequence: snap,
      appSequences: {'com.x': snap},
    ),
    'alarms': const ChannelConfig(
      overrideQuietHours: true,
      quietStartMinute: 60,
      quietEndMinute: 120,
    ),
    'calls': const ChannelConfig(),
  };
}

HapticPatternStore _store() => HapticPatternStore.decode(
  jsonEncode([
    SavedHapticPattern(
      id: 'p1',
      name: 'Calm',
      sequence: _taps.copyWith(patternId: 'p1'),
    ).toJson(),
  ]),
);

// What the old save paths wrote for the fixtures above, captured from the code
// before the repository existed (NotificationPrefs.save, HapticPatternStore
// .save and the relay's channel persistence).
const _goldenChannels =
    '{"apps":{"enabled":true,"matchHaptics":false,"fallbackPattern":[0,400,100,400],'
    '"quietStartMinute":null,"quietEndMinute":null,"overrideQuietHours":false,'
    '"allowDuringDnd":false,"includeVibrate":true,"includeSilent":false,'
    '"phoneFallback":false,"buzzSequence":{"offsetsMs":[0,500,1000],'
    '"durationsMs":[0,0,0],"patternId":"p1"},"appSequences":{"com.x":'
    '{"offsetsMs":[0,500,1000],"durationsMs":[0,0,0],"patternId":"p1"}}},'
    '"alarms":{"enabled":false,"matchHaptics":false,"fallbackPattern":[0,400,100,400],'
    '"quietStartMinute":60,"quietEndMinute":120,"overrideQuietHours":true,'
    '"allowDuringDnd":false,"includeVibrate":true,"includeSilent":false,'
    '"phoneFallback":false},"calls":{"enabled":false,"matchHaptics":false,'
    '"fallbackPattern":[0,400,100,400],"quietStartMinute":null,'
    '"quietEndMinute":null,"overrideQuietHours":false,"allowDuringDnd":false,'
    '"includeVibrate":true,"includeSilent":false,"phoneFallback":false}}';
const _goldenPatterns =
    '[{"id":"p1","name":"Calm","sequence":{"offsetsMs":[0,500,1000],'
    '"durationsMs":[0,0,0],"patternId":"p1"}}]';
const _goldenMirrors = <String, Object>{
  'notif_alarm_latch_failed': true,
  'notif_alarm_night_check': true,
  'notif_auto_detect': true,
  'notif_battery_pct': 25,
  'notif_checkin': false,
  'notif_critical_override': true,
  'notif_device': true,
  'notif_health': true,
  'notif_meds': false,
  'notif_movement': false,
  'notif_quiet_enabled': true,
  'notif_quiet_end': 420,
  'notif_quiet_start': 1300,
  'notif_recovery': true,
  'notif_relay_enabled': false,
  'notif_reminders': true,
  'notif_stepgoal': true,
  'notif_water': true,
  'notif_water_interval': 120,
  'notif_winddown': false,
  'workout.zone_alert_enabled': false,
};

NotificationRelay _relay() => NotificationRelay(
  buzz: () async {},
  isConnected: () => true,
  debugSupported: false,
);

/// Lets queued microtasks and the store's own futures finish.
Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  // NotificationRelay.dispose touches WidgetsBinding.
  TestWidgetsFlutterBinding.ensureInitialized();
  final repo = SettingsRepository.instance;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('stored form', () {
    test('keys and JSON are byte-identical to the old save paths', () async {
      await repo.update((d) {
        d.alerts = _alerts();
        d.channels = _channels();
        d.patterns = _store();
      });
      final raw = await _raw();
      expect(raw['notif_alert_rules_v1'], jsonEncode(_alerts().toJson()));
      expect(raw['notif_relay_channels'], _goldenChannels);
      expect(raw['haptic_patterns_v1'], _goldenPatterns);
      for (final e in _goldenMirrors.entries) {
        expect(raw[e.key], e.value, reason: e.key);
      }
      // No key the old paths did not write.
      expect(raw.keys.toSet(), {
        'notif_alert_rules_v1',
        'notif_relay_channels',
        'haptic_patterns_v1',
        ..._goldenMirrors.keys,
      });
    });

    test('the legacy wrappers write the same bytes as the repository', () async {
      await repo.update((d) {
        d.alerts = _alerts();
        d.channels = _channels();
        d.patterns = _store();
      });
      final viaRepo = await _raw();

      SharedPreferences.setMockInitialValues({});
      await _alerts().save();
      final store = _store();
      await store.save();
      final relay = _relay();
      for (final e in _channels().entries) {
        relay.controller.putChannel(e.key, e.value);
      }
      await _settle();
      expect(await _raw(), viaRepo);
    });

    test('a stored legacy-key state reads as the old load did', () async {
      SharedPreferences.setMockInitialValues({
        'notif_quiet_start': 21 * 60,
        'notif_water': true,
        'notif_relay_enabled': true,
      });
      final viaRepo = await repo.alerts();
      expect(viaRepo.quietStartMin, 21 * 60);
      expect(viaRepo.waterEnabled, isTrue);
      expect(viaRepo.alertRule('relay').enabled, isTrue);
      // The once-only migration blob is written, as NotificationPrefs.load did.
      expect((await _raw())['notif_alert_rules_v1'], isNotNull);
      final again = await NotificationPrefs.load();
      expect(jsonEncode(again.toJson()), jsonEncode(viaRepo.toJson()));
    });
  });

  group('read', () {
    test('an empty store reads as defaults, in the relay channel order', () async {
      final s = await repo.read();
      expect(s.channels.keys.toList(), relayChannels);
      expect(s.channels['apps']!.enabled, isTrue);
      expect(s.channels['alarms']!.enabled, isFalse);
      expect(s.patterns, isEmpty);
    });

    test('the snapshot is immutable', () async {
      await repo.update((d) {
        d.channels = _channels();
        d.patterns = _store();
      }, sections: {SettingsSection.channels, SettingsSection.patterns});
      final s = await repo.read();
      expect(() => s.channels['apps'] = const ChannelConfig(), throwsUnsupportedError);
      expect(() => s.patterns.clear(), throwsUnsupportedError);
      expect(s.channels['apps']!.appSequences['com.x']!.patternId, 'p1');
      expect(s.patterns.single.name, 'Calm');
    });

    test('unreadable stored channels read as defaults, not a throw', () async {
      SharedPreferences.setMockInitialValues({
        'notif_relay_channels': '{not json',
        'haptic_patterns_v1': '{not json',
      });
      final s = await repo.read();
      expect(s.channels['apps']!.enabled, isTrue);
      expect(s.patterns, isEmpty);
    });
  });

  group('update: atomic across sections', () {
    test('every section lands together and one event names them', () async {
      final events = <SettingsChange>[];
      final sub = repo.changes.listen(events.add);
      addTearDown(sub.cancel);

      await repo.update((d) {
        d.alerts = _alerts();
        d.channels = _channels();
        d.patterns = _store();
        d.setBool('haptics_allow_long_sequences', true);
        d.setInt('workout.zone_alert_target_zone', 4);
      });
      await _settle();

      final raw = await _raw();
      expect(raw['notif_relay_channels'], _goldenChannels);
      expect(raw['haptic_patterns_v1'], _goldenPatterns);
      expect(raw['notif_water'], true);
      expect(raw['haptics_allow_long_sequences'], true);
      expect(raw['workout.zone_alert_target_zone'], 4);
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.alerts, isNotNull);
      // 'calls' equals its default, so only apps and alarms differ from it.
      expect(e.channels!.keys.toSet(), {'apps', 'alarms'});
      expect(e.patterns!.single.id, 'p1');
      expect(e.appPrefs['haptics_allow_long_sequences'], true);
    });

    test('a later section failing to encode persists nothing', () async {
      SharedPreferences.setMockInitialValues({'notif_water': false});
      // Reading the alerts runs their once-only legacy migration; that is not
      // part of the update under test.
      await repo.alerts();
      final before = await _raw();
      final events = <SettingsChange>[];
      final sub = repo.changes.listen(events.add);
      addTearDown(sub.cancel);

      await expectLater(
        repo.update((d) {
          d.alerts = _alerts(); // encodes fine and comes first
          d.patterns = _store(); // fine too
          d.setBool('haptics_allow_long_sequences', true);
          d.channels = {'apps': const _BoomChannel()}; // throws on encode
        }),
        throwsA(isA<StateError>()),
      );
      await _settle();

      expect(await _raw(), before);
      expect(events, isEmpty);
    });

    test('a refused write rolls back what was already written', () async {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = _RefusingStore(
        'notif_relay_channels',
      );
      await repo.alerts(); // the once-only migration, not under test
      final before = await _raw();
      // The alerts and the pattern store are written before the channels key.
      await expectLater(
        repo.update((d) {
          d.alerts = _alerts();
          d.patterns = _store();
          d.channels = _channels();
        }),
        throwsA(isA<StateError>()),
      );
      expect(await _raw(), before);
    });

    test('a failed update does not wedge the queue', () async {
      await expectLater(
        repo.update((d) => d.channels = {'apps': const _BoomChannel()}),
        throwsA(isA<StateError>()),
      );
      await repo.update((d) => d.channels = _channels());
      expect((await _raw())['notif_relay_channels'], _goldenChannels);
    });

    test('an edit that throws persists nothing and is rethrown', () async {
      await repo.alerts(); // the once-only migration, not under test
      final before = await _raw();
      await expectLater(
        repo.update((d) {
          d.alerts = _alerts();
          throw ArgumentError('no');
        }),
        throwsArgumentError,
      );
      expect(await _raw(), before);
    });

    test('only the declared sections are loaded and written', () async {
      await repo.update(
        (d) => d.channels = _channels(),
        sections: {SettingsSection.channels},
      );
      final raw = await _raw();
      expect(raw.keys, ['notif_relay_channels']);
    });

    test('touching an undeclared section is a StateError', () async {
      await expectLater(
        repo.update((d) => d.alerts, sections: {SettingsSection.channels}),
        throwsA(isA<StateError>()),
      );
    });

    test('an update that changes nothing writes and announces nothing', () async {
      await repo.update((d) {
        d.channels = _channels();
        d.patterns = _store();
      }, sections: {SettingsSection.channels, SettingsSection.patterns});
      final before = await _raw();
      final events = <SettingsChange>[];
      final sub = repo.changes.listen(events.add);
      addTearDown(sub.cancel);
      await repo.update((d) {
        d.channels = _channels(); // same values
      }, sections: {SettingsSection.channels});
      await _settle();
      expect(events, isEmpty);
      expect(await _raw(), before);
    });
  });

  group('update: serialized', () {
    test('concurrent read-modify-writes both land', () async {
      await repo.update((d) => d.alerts = const NotificationPrefs());
      await Future.wait(<Future<Object?>>[
        for (var i = 0; i < 5; i++)
          repo.update(
            (d) => d.alerts = d.alerts.copyWith(
              waterIntervalMin: d.alerts.waterIntervalMin + 10,
            ),
            sections: {SettingsSection.alerts},
          ),
      ]);
      expect((await repo.alerts()).waterIntervalMin, 120 + 50);
    });

    test('a read queued behind an update sees it', () async {
      final write = repo.update((d) => d.channels = _channels(),
          sections: {SettingsSection.channels});
      final read = repo.read();
      await write;
      expect((await read).channels['apps']!.buzzSequence!.patternId, 'p1');
    });

    test('the legacy wrappers share the queue with update', () async {
      await Future.wait(<Future<Object?>>[
        repo.update(
          (d) => d.alerts = d.alerts.copyWith(waterIntervalMin: 90),
          sections: {SettingsSection.alerts},
        ),
        const NotificationPrefs(waterIntervalMin: 200).save(),
        NotificationPrefs.load(),
      ]);
      // Queue order: update, then the wrapper's save, then the load.
      expect((await repo.alerts()).waterIntervalMin, 200);
    });
  });

  group('change stream', () {
    test('a NotificationPrefs.save is announced with what was written', () async {
      final events = <SettingsChange>[];
      final sub = repo.changes.listen(events.add);
      addTearDown(sub.cancel);
      await const NotificationPrefs(quietStartMin: 1234).save();
      await _settle();
      expect(events, hasLength(1));
      expect(events.single.alerts!.quietStartMin, 1234);
      expect(events.single.channels, isNull);
      expect(events.single.patterns, isNull);
    });

    test('the origin of an update travels with its event', () async {
      final events = <SettingsChange>[];
      final sub = repo.changes.listen(events.add);
      addTearDown(sub.cancel);
      final me = Object();
      await repo.update(
        (d) => d.channels = _channels(),
        sections: {SettingsSection.channels},
        origin: me,
      );
      await _settle();
      expect(identical(events.single.origin, me), isTrue);
    });

    test('only the channels that changed are in the event', () async {
      await repo.update(
        (d) => d.channels = _channels(),
        sections: {SettingsSection.channels},
      );
      final events = <SettingsChange>[];
      final sub = repo.changes.listen(events.add);
      addTearDown(sub.cancel);
      await repo.update((d) {
        d.channels = {
          ...d.channels,
          'calls': const ChannelConfig(enabled: true),
        };
      }, sections: {SettingsSection.channels});
      await _settle();
      expect(events.single.channels!.keys, ['calls']);
    });
  });

  group('relay hears the stream', () {
    test('global quiet hours reach the decision policy without bootstrap',
        () async {
      final r = _relay();
      addTearDown(r.dispose);
      await const NotificationPrefs(
        quietEnabled: true,
        quietStartMin: 21 * 60,
        quietEndMin: 6 * 60,
      ).save();
      await _settle();
      final p = r.debugPolicy(const {});
      expect(p['quietEnabled'], true);
      expect(p['quietStartMin'], 21 * 60);
      expect(p['quietEndMin'], 6 * 60);
    });

    test('channels written by an update reach the live controller', () async {
      final r = _relay();
      addTearDown(r.dispose);
      var notified = 0;
      r.addListener(() => notified++);
      await repo.update(
        (d) => d.channels = {
          ...d.channels,
          'alarms': const ChannelConfig(enabled: true, overrideQuietHours: true),
        },
        sections: {SettingsSection.channels},
      );
      await _settle();
      expect(r.controller.channels['alarms']!.enabled, isTrue);
      expect(r.controller.channels['alarms']!.overrideQuietHours, isTrue);
      expect(notified, greaterThan(0));
    });

    test('an update never reverts a channel it did not change', () async {
      final r = _relay();
      addTearDown(r.dispose);
      // The relay has a change of its own that is not stored yet.
      r.controller.channels['calls'] = const ChannelConfig(enabled: true);
      await repo.update(
        (d) => d.channels = {
          ...d.channels,
          'alarms': const ChannelConfig(enabled: true),
        },
        sections: {SettingsSection.channels},
        origin: Object(),
      );
      await _settle();
      expect(r.controller.channels['calls']!.enabled, isTrue);
      expect(r.controller.channels['alarms']!.enabled, isTrue);
    });

    test('the relay persists its own channel change through the repository',
        () async {
      final r = _relay();
      addTearDown(r.dispose);
      final events = <SettingsChange>[];
      final sub = repo.changes.listen(events.add);
      addTearDown(sub.cancel);
      r.controller.putChannel('apps', _channels()['apps']!);
      await _settle();
      expect((await repo.read()).channels['apps']!.appSequences.keys, ['com.x']);
      expect(events, isNotEmpty);
      expect(events.first.origin, isNotNull);
    });
  });

  group('pattern propagation is one update', () {
    Future<void> seed() => repo.update((d) {
      d.alerts = _alerts();
      d.channels = _channels();
      d.patterns = _store();
    });

    test('replace rewrites rules, channels, app sequences and the store',
        () async {
      await seed();
      final events = <SettingsChange>[];
      final sub = repo.changes.listen(events.add);
      addTearDown(sub.cancel);

      await repo.update((d) {
        d.patterns.replace('p1', _tapsB);
        d.propagatePattern('p1', replacement: d.patterns.byId('p1')!.sequence);
      });
      await _settle();

      expect(events, hasLength(1));
      final s = await repo.read();
      final want = _tapsB.copyWith(patternId: 'p1').toJson();
      expect(s.alerts.alertRule('water').buzzSequence!.toJson(), want);
      expect(s.channels['apps']!.buzzSequence!.toJson(), want);
      expect(s.channels['apps']!.appSequences['com.x']!.toJson(), want);
      expect(s.patterns.single.sequence.toJson(), want);
      expect(s.patternUsage('p1'), 3);
    });

    test('delete keeps each rhythm and drops the id, in the same write',
        () async {
      await seed();
      await repo.update((d) {
        d.patterns.delete('p1');
        d.propagatePattern('p1');
      });
      final s = await repo.read();
      expect(s.patterns, isEmpty);
      expect(s.alerts.alertRule('water').buzzSequence!.offsetsMs, [0, 500, 1000]);
      expect(s.alerts.alertRule('water').buzzSequence!.patternId, isNull);
      expect(s.channels['apps']!.buzzSequence!.patternId, isNull);
      expect(s.channels['apps']!.appSequences['com.x']!.patternId, isNull);
      expect(s.patternUsage('p1'), 0);
    });

    test('a failing section leaves rules, channels and patterns as they were',
        () async {
      await seed();
      final before = await _raw();
      await expectLater(
        repo.update((d) {
          d.patterns.replace('p1', _tapsB);
          d.propagatePattern('p1', replacement: d.patterns.byId('p1')!.sequence);
          d.channels = {...d.channels, 'calls': const _BoomChannel()};
        }),
        throwsA(isA<StateError>()),
      );
      expect(await _raw(), before);
    });

    test('a bad rename throws out of the edit and writes nothing', () async {
      await seed();
      final before = await _raw();
      await expectLater(
        repo.update((d) {
          d.patterns.rename('p1', '   ');
          d.propagatePattern('p1', replacement: d.patterns.byId('p1')!.sequence);
        }),
        throwsArgumentError,
      );
      expect(await _raw(), before);
    });

    test('a pattern nothing uses writes the store alone', () async {
      await repo.update((d) => d.patterns = _store(),
          sections: {SettingsSection.patterns});
      final r = await _raw();
      final before = Map.of(r)..remove('haptic_patterns_v1');
      await repo.update((d) {
        d.patterns.add('Other', _tapsB);
        d.propagatePattern('p1', replacement: d.patterns.byId('p1')!.sequence);
      });
      final after = await _raw();
      expect(jsonDecode(after['haptic_patterns_v1']! as String), hasLength(2));
      // Alerts blob now exists (the update loaded it), channels did not change.
      expect(after.containsKey('notif_relay_channels'), isFalse);
      expect(before.keys.every((k) => after.containsKey(k)), isTrue);
    });
  });

  group('app prefs', () {
    test('typed setters write through the same update and roll back with it',
        () async {
      SharedPreferences.setMockInitialValues({'ui.shell_tab': 2});
      await repo.alerts(); // the once-only migration, not under test
      final before = await _raw();
      await expectLater(
        repo.update((d) {
          d.setBool('haptics_allow_long_sequences', true);
          d.setString('backup.cadence', 'weekly');
          d.channels = {'apps': const _BoomChannel()};
        }),
        throwsA(isA<StateError>()),
      );
      expect(await _raw(), before);
      await repo.update((d) {
        d.setBool('haptics_allow_long_sequences', true);
        d.setString('backup.cadence', 'weekly');
      }, sections: {});
      final raw = await _raw();
      expect(raw['haptics_allow_long_sequences'], true);
      expect(raw['backup.cadence'], 'weekly');
      expect(raw['ui.shell_tab'], 2);
    });
  });

  // AGENTS.md 4.7: one write path, so a screen cannot grow a second one. These
  // read the source on purpose; the behaviour is pinned above.
  group('one write path (source guard)', () {
    final files = [
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart')) f,
    ];
    List<String> users(Pattern needle) => [
      for (final f in files)
        if (f.readAsStringSync().contains(needle)) f.path,
    ];

    test('the three stored keys are spelled in one writer each', () {
      expect(users("'notif_relay_channels'"), [
        'lib/settings/settings_repository.dart',
      ]);
      expect(users("'haptic_patterns_v1'"), ['lib/haptics/pattern_store.dart']);
      expect(users("'notif_alert_rules_v1'"), [
        'lib/notify/notification_prefs.dart',
      ]);
    });

    test('no screen or scheduler loads the pattern store by hand', () {
      expect(users('HapticPatternStore.load('), isEmpty);
    });

    test('propagatePattern is called by the repository alone', () {
      final callers = users(RegExp(r'(?<![.\w])propagatePattern\('));
      expect(
        callers.toSet(),
        {'lib/haptics/pattern_store.dart', 'lib/settings/settings_repository.dart'},
      );
    });

    test('NotificationPrefs.onSaved is gone', () {
      expect(users('onSaved'), isNot(contains('lib/notify/notification_prefs.dart')));
      expect(users('NotificationPrefs.onSaved'), isEmpty);
    });
  });
}
