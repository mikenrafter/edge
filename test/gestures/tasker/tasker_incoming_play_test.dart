// Tasker -> band: an incoming `tasker_play` call on the
// `openstrap/tasker` method channel plays a haptic SLOT or a PATTERN on the
// band. The native side (TaskerReceiver.kt, device-tested by hand) forwards
// the intent's extras as the call's arguments: {slot: 1..6 | "<slot key>"} or
// {pattern: "<pattern id>"}; the parse is pinned in tasker_play_request_test.
//
// Pinned here, over the real AppState (the GestureRig's fake gen5 link and its
// sqflite_ffi database), with the writes that reach the radio as the witness:
//   * slot by number (1..6) and by key, pattern by id: the band is written
//     exactly what the same sequence writes when played directly;
//   * a slot the wearer re-assigned plays the wearer's pattern;
//   * an unknown slot or pattern is ignored and logged ("[tasker] ... ignored"
//     in the app log), never played, never thrown;
//   * "Tasker connection" off (Prefs.taskerConnection): nothing plays;
//   * it is a normal, non-gesture job of the band queue: serialised in call
//     order and held by the haptic budget (no gesture exemption, so a spent
//     budget makes it WAIT in the queue, where a gesture would be dropped).
//
// The expected writes are measured on the same rig, by playing the same
// sequence straight through `app.haptics.deliver`, so no vibration bytes are
// hard-coded here.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/settings/settings_repository.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show Cmd;

import '../../support/app_state_gesture_harness.dart';

const _db = 'tasker_incoming_play.db';
const _channel = MethodChannel('openstrap/tasker');

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The haptic commands that reached the radio, as `opcode:body`.
List<String> _haptic(GestureRig r) => [
      for (final w in r.writes)
        if (w.opcode == Cmd.runHapticPatternMaverick ||
            w.opcode == Cmd.runHapticsPattern)
          '${w.opcode}:${_hex(w.body)}',
    ];

/// What the native receiver does: hand the app a method call and wait for the
/// handler to answer.
Future<void> _fromTasker(String method, Object? args) {
  final done = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    _channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
    (_) {
      if (!done.isCompleted) done.complete();
    },
  );
  return done.future.timeout(const Duration(seconds: 5));
}

/// The commands [seq] writes when played straight through the haptics
/// service, measured once on [r] (and cleared).
Future<List<String>> _measure(GestureRig r, BuzzSequence seq) async {
  r.writes.clear();
  await r.app.haptics.deliver(seq);
  await r.app.haptics.whenIdle();
  final out = _haptic(r);
  r.writes.clear();
  return out;
}

/// Wait for [want] haptic commands, then a moment more for any extra ones.
Future<List<String>> _played(GestureRig r, int want) async {
  await until(() => _haptic(r).length >= want,
      within: const Duration(seconds: 6), what: '$want haptic commands');
  await settleMs(150);
  return _haptic(r);
}

/// Save [code] as the wearer's own pattern, return it.
Future<String> _savePattern(String name, String code) async {
  final store = await SettingsRepository.instance.patterns();
  final p = store.add(
    name,
    tapsFromNotes(PatternTranscript.parseCode(code).entries, unitMs: _mg.unitMs)
        .copyWith(notes: code, profileId: _mg.id, profileVersion: _mg.version),
  );
  await store.save();
  return p.id;
}

int _ignoredLines(GestureRig r) => r.app.logLines
    .where((l) => l.contains('[tasker]') && l.contains('ignored'))
    .length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    BleEngine.resetBandClaimForTest();
    await deriveDbSetUp(_db);
    await resetGesturePrefs();
    Prefs.setBool(Prefs.taskerConnection, true);
    Prefs.setHapticCommandLimit(60);
    // The clock is not the subject: quiet hours would hold a play at night.
    await (await NotificationPrefs.load()).copyWith(quietEnabled: false).save();
  });
  tearDown(() async {
    await settleMs(400); // the rig's device-row and haptic-ack writes
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    BleEngine.resetBandClaimForTest();
    await deriveDbTearDown(_db);
  });

  Future<GestureRig> rig() async {
    final r = GestureRig(mg: false);
    addTearDown(r.dispose);
    r.app.taskerBridge; // registers the method channel handler
    return r;
  }

  group('a slot by number plays that slot\'s pattern', () {
    for (var n = 1; n <= 6; n++) {
      test('slot $n plays $n pulses', () async {
        final r = await rig();
        final want = await _measure(r, builtInDefault('tasker.$n')!.sequence);
        expect(want, isNotEmpty);
        await _fromTasker('tasker_play', {'slot': n});
        expect(await _played(r, want.length), want);
      });
    }

    test('slots 1 and 3 are not the same vibration', () async {
      final r = await rig();
      final one = await _measure(r, builtInDefault('tasker.1')!.sequence);
      final three = await _measure(r, builtInDefault('tasker.3')!.sequence);
      expect(one, isNot(three));
    });

    test('the number may arrive as a string (Tasker variables are text)',
        () async {
      final r = await rig();
      final want = await _measure(r, builtInDefault('tasker.4')!.sequence);
      await _fromTasker('tasker_play', {'slot': '4'});
      expect(await _played(r, want.length), want);
    });
  });

  group('a slot by key', () {
    test('tasker.5 is slot 5', () async {
      final r = await rig();
      final want = await _measure(r, builtInDefault('tasker.5')!.sequence);
      await _fromTasker('tasker_play', {'slot': 'tasker.5'});
      expect(await _played(r, want.length), want);
    });

    test('another cue slot (breath.done) plays that slot\'s pattern',
        () async {
      final r = await rig();
      final want = await _measure(r, builtInDefault(kBreathDoneKey)!.sequence);
      await _fromTasker('tasker_play', {'slot': kBreathDoneKey});
      expect(await _played(r, want.length), want);
    });
  });

  group('a slot the wearer re-assigned', () {
    test('plays the wearer\'s pattern; the other slots keep their pulses',
        () async {
      final id = await _savePattern('Long one', 'N8ff');
      Prefs.setString(
          Prefs.hapticsCueAssign, encodeCueAssignments({'tasker.2': id}));
      final r = await rig();
      final store = await SettingsRepository.instance.patterns();
      final mine = store.byId(id)!.sequence;
      final wantMine = await _measure(r, mine);
      final wantDefault2 =
          await _measure(r, builtInDefault('tasker.2')!.sequence);
      final wantOne = await _measure(r, builtInDefault('tasker.1')!.sequence);
      expect(wantMine, isNot(wantDefault2), reason: 'a visible difference');

      await _fromTasker('tasker_play', {'slot': 2});
      expect(await _played(r, wantMine.length), wantMine);

      r.writes.clear();
      await r.app.haptics.whenIdle();
      await _fromTasker('tasker_play', {'slot': 1});
      expect(await _played(r, wantOne.length), wantOne);
    });

    test('a slot assigned a pattern that is gone plays its built-in',
        () async {
      Prefs.setString(Prefs.hapticsCueAssign,
          encodeCueAssignments({'tasker.3': 'no-such-pattern'}));
      final r = await rig();
      final want = await _measure(r, builtInDefault('tasker.3')!.sequence);
      await _fromTasker('tasker_play', {'slot': 3});
      expect(await _played(r, want.length), want);
    });
  });

  group('a pattern by id', () {
    test('a built-in preset plays as itself', () async {
      final r = await rig();
      final want =
          await _measure(r, builtInDefault('preset.three_pulses')!.sequence);
      await _fromTasker(
          'tasker_play', {'pattern': systemPatternId('preset.three_pulses')});
      expect(await _played(r, want.length), want);
    });

    test('a pattern of the wearer\'s own plays as itself', () async {
      final id = await _savePattern('Mine', 'N8ff');
      final r = await rig();
      final store = await SettingsRepository.instance.patterns();
      final want = await _measure(r, store.byId(id)!.sequence);
      await _fromTasker('tasker_play', {'pattern': id});
      expect(await _played(r, want.length), want);
    });
  });

  group('unknown requests are ignored and logged', () {
    test('an unknown slot number or key, an unknown pattern id, an empty call',
        () async {
      final r = await rig();
      var logged = _ignoredLines(r);
      for (final args in <Object?>[
        {'slot': 7},
        {'slot': 0},
        {'slot': 'tasker.9'},
        {'slot': 'nope'},
        {'pattern': 'no-such-pattern'},
        <String, Object>{},
        null,
      ]) {
        await _fromTasker('tasker_play', args);
        await settleMs(100);
        expect(_haptic(r), isEmpty, reason: '$args played something');
        expect(_ignoredLines(r), logged + 1,
            reason: '$args should add one "[tasker] ... ignored" line');
        logged++;
      }
    });

    test('an ignored request does not break the next good one', () async {
      final r = await rig();
      final want = await _measure(r, builtInDefault('tasker.2')!.sequence);
      await _fromTasker('tasker_play', {'slot': 99});
      await _fromTasker('tasker_play', {'slot': 2});
      expect(await _played(r, want.length), want);
    });
  });

  group('"Tasker connection" gates it', () {
    test('off: a slot and a pattern both do nothing', () async {
      final r = await rig();
      Prefs.setBool(Prefs.taskerConnection, false);
      await _fromTasker('tasker_play', {'slot': 3});
      await _fromTasker(
          'tasker_play', {'pattern': systemPatternId('preset.sos')});
      await settleMs(300);
      expect(_haptic(r), isEmpty);
      expect(r.app.haptics.pending, 0, reason: 'nothing was even queued');
    });

    test('switched back on, the next request plays', () async {
      final r = await rig();
      final want = await _measure(r, builtInDefault('tasker.3')!.sequence);
      Prefs.setBool(Prefs.taskerConnection, false);
      await _fromTasker('tasker_play', {'slot': 3});
      await settleMs(200);
      expect(_haptic(r), isEmpty);
      Prefs.setBool(Prefs.taskerConnection, true);
      await _fromTasker('tasker_play', {'slot': 3});
      expect(await _played(r, want.length), want);
    });

    // INFERRED from "Tasker connection off disables the Tasker controls", not
    // stated: the older numbered BUZZ_STRAP path is part of the integration.
    // Drop this one if the owner wants it left ungated.
    test('off: the older buzz_strap (a numbered pattern) does nothing too',
        () async {
      final r = await rig();
      Prefs.setBool(Prefs.taskerConnection, false);
      await _fromTasker('buzz_strap', {'pattern': 1});
      await settleMs(300);
      expect(_haptic(r), isEmpty);
      expect(r.app.haptics.pending, 0);
    });
  });

  group('it is a normal job of the band queue, not a gesture', () {
    test('two requests in a row play in the order they came, whole',
        () async {
      final r = await rig();
      final a = await _measure(r, builtInDefault('tasker.1')!.sequence);
      final b = await _measure(r, builtInDefault('tasker.3')!.sequence);
      await _fromTasker('tasker_play', {'slot': 1});
      await _fromTasker('tasker_play', {'slot': 3});
      expect(await _played(r, a.length + b.length), [...a, ...b]);
    });

    test('the haptic budget applies: with the window spent the play WAITS '
        'in the queue (a gesture would be dropped), and writes nothing now',
        () async {
      final r = await rig();
      final ledger = r.app.haptics.ledger;
      ledger.record(r.app.haptics.commandsLeft, DateTime.now());
      expect(r.app.haptics.commandsLeft, 0);
      await _fromTasker('tasker_play', {'slot': 3});
      await settleMs(400);
      expect(_haptic(r), isEmpty, reason: 'no gesture exemption');
      expect(r.app.haptics.pending, 1,
          reason: 'held by the budget as a plain job, not dropped');
    });

    test('a pattern by id is held by the budget the same way', () async {
      final r = await rig();
      r.app.haptics.ledger
          .record(r.app.haptics.commandsLeft, DateTime.now());
      await _fromTasker(
          'tasker_play', {'pattern': systemPatternId('preset.two_pulses')});
      await settleMs(400);
      expect(_haptic(r), isEmpty);
      expect(r.app.haptics.pending, 1);
    });
  });
}
