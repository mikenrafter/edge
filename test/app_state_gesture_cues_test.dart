// Gesture area: the wearer's gesture cues. AppState reads the
// stored cue patterns (_loadGestureCues) just before a cue plays, so a change
// made on the Haptics screen takes effect at the next gesture without a
// restart; a cue that cannot be read plays its built-in. Observed on the
// band's own writes (the fake link), through a real double tap.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/haptics/pattern_store.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_state_gesture_harness.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

BuzzSequence _fromNotes(String code) => tapsFromNotes(
      PatternTranscript.parseCode(code).entries,
      unitMs: _mg.unitMs,
    ).copyWith(notes: code, profileId: _mg.id, profileVersion: _mg.version);

/// Save [code] as the wearer's own pattern and put it on cue [slot].
Future<void> _assign(String slot, String name, String code) async {
  final store = await SettingsRepository.instance.patterns();
  final p = store.add(name, _fromNotes(code));
  await store.save();
  Prefs.setString(
      Prefs.hapticsCueAssign, encodeCueAssignments({slot: p.id}));
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Every body the band was written, in order (a customised cue may be several
/// commands).
List<String> _bodies(GestureRig rig) =>
    [for (final w in rig.writes) _hex(w.body)];

const _db = 'app_state_gesture_cues.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
    await resetGesturePrefs();
  });
  tearDown(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });

  late ActionChannel channel;
  late List<String> order;
  late Map<String, String> defaults; // cue name -> body hex on this band

  Future<GestureRig> newRig() async {
    order = <String>[];
    channel = ActionChannel(order: order);
    addTearDown(channel.dispose);
    final rig = GestureRig(mg: false, order: order);
    addTearDown(rig.dispose);
    await rig.measureCues();
    defaults = {
      for (final c in const ['start', 'followUp', 'confirm', 'failed'])
        c: rig.defaultCueBody(c)!,
    };
    return rig;
  }

  group('cues are read just before they play', () {
    test('a change made after the app built its cues is not heard by a cue '
        'played directly, but the next gesture picks it up', () async {
      final rig = await newRig();
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      await _assign(kGestureConfirmKey, 'Slow', 'N4* R2 N4*');

      await rig.app.gestureCues.confirm();
      expect(_hex(rig.writes.last.body), defaults['confirm'],
          reason: 'nothing has re-read the store yet');
      rig.writes.clear();

      rig.doubleTap(); // the tap ack plays the confirm cue
      await until(() => rig.writes.isNotEmpty);
      await settleMs(600);
      final ack = _bodies(rig);
      expect(ack, isNot([defaults['confirm']]),
          reason: 'the assigned pattern plays');

      rig.writes.clear();
      await rig.app.gestureCues.confirm();
      expect(_bodies(rig), ack,
          reason: 'the cache now holds the assigned pattern');
    });

    test('the assignment is followed both ways: back to the built-in when '
        'it is removed', () async {
      final rig = await newRig();
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      await _assign(kGestureConfirmKey, 'Slow', 'N4* R2 N4*');
      rig.doubleTap();
      await until(() => rig.writes.isNotEmpty);
      await settleMs(600);
      expect(_bodies(rig), isNot([defaults['confirm']]));

      Prefs.setString(Prefs.hapticsCueAssign, '');
      await settleMs(1100); // a distinct strap second for the next tap
      rig.writes.clear();
      rig.doubleTap();
      await until(() => rig.writes.isNotEmpty);
      await settleMs(300);
      // With no assignment the store's own (seeded) confirm pattern plays,
      // which is the built-in default.
      expect(_bodies(rig), [defaults['confirm']]);
    });

    test('a counted gesture reads the start cue itself before it plays '
        '(no ack path involved)', () async {
      final rig = await newRig();
      await mapActions(rig.app, [2, 3]);
      await rig.app.gestureSettings.setRepeatTapWindowMs(1000);
      await _assign(kGestureStartKey, 'Pair slow', 'N8* R4 N8*');
      rig.doubleTap();
      await until(() => rig.writes.isNotEmpty);
      expect(_hex(rig.writes.first.body), isNot(defaults['start']),
          reason: 'the opening cue is the assigned one');
      await until(() => rig.cues.contains('confirm'),
          within: const Duration(seconds: 8));
      await until(() => channel.performed.isNotEmpty);
      await settleMs(200);
      expect(_hex(rig.writes.last.body), defaults['confirm'],
          reason: 'the confirm cue was not assigned: built-in');
    });
  });

  group('a cue that cannot be read plays its built-in', () {
    test('garbage in the pattern store', () async {
      SharedPreferences.setMockInitialValues(
          {HapticPatternStore.prefsKey: 'not json at all'});
      final rig = await newRig();
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      rig.doubleTap();
      await until(() => rig.writes.isNotEmpty);
      await settleMs(300);
      expect(_bodies(rig), [defaults['confirm']]);
    });

    test('an assignment naming a pattern that does not exist', () async {
      final rig = await newRig();
      await rig.app.gestureSettings
          .setDoubleTapActions({DeviceAction.mediaPlayPause});
      Prefs.setString(Prefs.hapticsCueAssign,
          encodeCueAssignments({kGestureConfirmKey: 'no-such-pattern'}));
      rig.doubleTap();
      await until(() => rig.writes.isNotEmpty);
      await settleMs(300);
      expect(_bodies(rig), [defaults['confirm']]);
    });
  });

  test('GestureCues is one object over the app\'s haptics service for the '
      'whole lifetime', () async {
    final rig = await newRig();
    final cues = rig.app.gestureCues;
    expect(identical(rig.app.gestureCues, cues), isTrue);
    expect(identical(cues.haptics, rig.app.haptics), isTrue);
    await rig.app.gestureSettings
        .setDoubleTapActions({DeviceAction.mediaPlayPause});
    rig.doubleTap();
    await until(() => rig.writes.isNotEmpty);
    expect(identical(rig.app.gestureCues, cues), isTrue);
  });
}
