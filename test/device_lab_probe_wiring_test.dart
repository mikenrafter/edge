// The hardware probes' wiring in AppState, driven through the real
// AppState over the gesture rig (a real engine on a fake MG link, a
// real LocalDb). A probe that is not fed live band events or live ECG packets
// measures nothing, and a probe buzz that skips the dispatcher breaks the
// one-band-buzz-path rule (test/source_invariant_guards_test.dart covers the
// general rule; these pin the probe's own call sites). A dispatcher delivery
// leaves a durable claim keyed by the rule and event id, which is what tells a
// delivery apart from a direct engine write here.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart' show AlarmPayloads;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart' show ProbeKind;
import 'package:openstrap_protocol/openstrap_protocol.dart';

import 'support/app_state_gesture_harness.dart';

const _db = 'hardware_probe_wiring_guard.db';

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
  Future<GestureRig> newRig() async {
    channel = ActionChannel();
    addTearDown(channel.dispose);
    final rig = GestureRig();
    addTearDown(rig.dispose);
    await rig.measureCues();
    return rig;
  }

  /// The dispatcher claims left so far, as [rule, eventId, target].
  Future<List<List<Object?>>> claims() async {
    final rows = await (await LocalDb.instance).query('notif_fired');
    return [
      for (final r in rows)
        if ((r['key'] as String).startsWith('alert:'))
          (jsonDecode((r['key'] as String).substring(6)) as List).cast<Object?>(),
    ];
  }

  bool isPatternWrite(GWrite w) => w.opcode == Cmd.runHapticPatternMaverick;

  test('the probe buzz is a dispatcher delivery that hears the band reply',
      () async {
    final rig = await newRig();
    final replies = <String?>[];
    final sent = await rig.app.hardwareProbes
        .sendBuzz((status, ms) => replies.add(status));
    expect(sent, isTrue);
    expect(rig.writes.where(isPatternWrite), hasLength(1));
    final c = (await claims()).where((c) => c[0] == 'hardware_probe').toList();
    expect(c, hasLength(1), reason: 'delivered through alertDispatcher.dispatch');
    expect((c.single[1] as String), startsWith('probe:'));
    expect(c.single[2], 'band');
    await until(() => replies.isNotEmpty);
    expect(replies, hasLength(1), reason: 'the band reply is passed through');
  });

  test('the probe pattern is a dispatcher delivery that hears the band reply',
      () async {
    final rig = await newRig();
    final replies = <String?>[];
    final sent = await rig.app.hardwareProbes
        .sendPattern(const [47, 152], 2, (status, ms) => replies.add(status));
    expect(sent, isTrue);
    final writes = rig.writes.where(isPatternWrite).toList();
    expect(writes, hasLength(1));
    final want = AlarmPayloads.gen5MaverickPattern(const [47, 152], loop: 2);
    expect(writes.single.body.take(want.length), want,
        reason: 'the effects and the loop are passed through');
    final c = (await claims()).where((c) => c[0] == 'hardware_probe').toList();
    expect(c, hasLength(1), reason: 'delivered through alertDispatcher.dispatch');
    expect(c.single[2], 'band');
    await until(() => replies.isNotEmpty);
    expect(replies, hasLength(1));
  });

  test('a live band event reaches the open probe', () async {
    final rig = await newRig();
    final probes = rig.app.hardwareProbes;
    await probes.openPattern();
    expect(probes.running, ProbeKind.pattern);

    // The band's "ended" after a write, through the engine's live event path.
    void bandEnded() {
      final now = DateTime.now();
      final inner = Uint8List(12);
      final v = ByteData.sublistView(inner);
      inner[0] = PacketType.event;
      inner[1] = 0x09;
      v.setUint16(2, 100, Endian.little);
      v.setUint32(4, now.millisecondsSinceEpoch ~/ 1000, Endian.little);
      v.setUint16(8, (now.millisecondsSinceEpoch % 1000) * 32768 ~/ 1000,
          Endian.little);
      rig.engine.debugProcessImmediateFrame(Frame(inner, true, true));
    }

    final play = probes.playPattern();
    var answered = 0;
    await until(() {
      final writes = rig.writes.where(isPatternWrite).length;
      if (writes > answered) {
        answered = writes;
        bandEnded();
      }
      return answered > 0 && !probes.patternPlaying;
    });
    await play;
    expect(rig.app.deviceLab.toPlainText(withPackets: false),
        contains(RegExp(r'band events 100 at \+\d+')),
        reason: 'the probe recorded the event the engine delivered');
    probes.stop();
  });

  test('the ECG onFrame fan-out feeds the probe', () async {
    final rig = await newRig();
    await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
    final probes = rig.app.hardwareProbes;
    final run = probes.runEcg();
    await until(() => probes.running == ProbeKind.ecg);

    // Packets are fed until the stream is armed and the probe takes one.
    var sec = 1000;
    await until(() {
      rig.feedEcg(presencePacket(sec++, presence: true, contact: true));
      return rig.app.deviceLab
          .toPlainText(withPackets: true)
          .contains('tag=ECG touch probe');
    });
    expect(
        rig.app.deviceLab.toPlainText(withPackets: true), contains('tag=ECG touch probe'));

    probes.stop();
    await run;
    expect(probes.running, isNull);
  });

  test('the ECG onFrame fan-out feeds the tap session', () async {
    final rig = await newRig();
    await rig.app.ecg.guard.setWrist(kSerial, EcgWrist.left);
    await mapActions(rig.app, [3]);
    rig.doubleTap();
    await until(() => rig.app.ecg.isCapturing);
    await feedEcgOpening(rig.feedEcg);
    await until(() => channel.performed.isNotEmpty,
        within: const Duration(seconds: 8));
    expect(channel.performed, ['media_next'],
        reason: 'the packets reached the session, which counted 3');
    await until(() => labCount(rig, 'Final count') > 0);
  });

  // The ECG failure buzz is the "Gesture failed" cue (default:
  // one long command looped twice), played through the same dispatcher
  // delivery as every other gesture cue.
  test('a failed ECG tap session plays the Gesture failed cue through the '
      'dispatcher', () async {
    final rig = await newRig();
    await mapActions(rig.app, [2, 3]);
    // No wrist remembered: the session cannot start the stream and fails.
    rig.doubleTap();
    await until(() => rig.cues.contains('failed'),
        within: const Duration(seconds: 8));
    expect(rig.cues, contains('failed'));
    final c = await claims();
    expect(c.any((c) => c[0] != 'hardware_probe' && c[2] == 'band'), isTrue,
        reason: 'the failure cue is a dispatcher delivery');
  });
}
