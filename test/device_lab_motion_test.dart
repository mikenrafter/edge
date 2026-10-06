// The Device lab's Motion tab: the IMU recorder's form, the Arm / "Double tap to
// begin" / recording / review flow, Save and Share, and the saved recordings.
// The recorder is real and fed fake packets; the store and share are fakes, so
// nothing touches the disk or the share sheet.
//
//   * Offered only when the lab is given a Motion panel (developer mode).
//   * Nothing is saved until "Save recording".
//   * Fits 360 pt at text scale 1.3.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/imu_recorder.dart';
import 'package:openstrap_edge/gestures/imu_recording.dart';
import 'package:openstrap_edge/gestures/imu_recording_store.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/state/imu_packet.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/motion_lab.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/imu_recording_fixtures.dart';

class _FakeStore implements ImuRecordingStore {
  final saved = <String, ImuRecording>{};
  final deleted = <String>[];
  int saves = 0;
  bool failSave = false;
  bool failDelete = false;

  String pathOf(String id) => '/docs/device_lab/imu/$id.jsonl';

  @override
  Future<SavedImuRecording> save(ImuRecording r) async {
    saves++;
    if (failSave) throw const FileSystemException('disk full');
    saved[r.meta.id] = r;
    return _summary(r);
  }

  SavedImuRecording _summary(ImuRecording r) => SavedImuRecording(
        id: r.meta.id,
        path: pathOf(r.meta.id),
        sizeBytes: 2048,
        kind: r.meta.kind,
        label: r.meta.label,
        status: r.status,
        createdAt: r.meta.createdAt,
        packetCount: r.packetCount,
        bandModel: r.meta.bandModel,
      );

  @override
  Future<List<SavedImuRecording>> list() async =>
      [for (final r in saved.values.toList().reversed) _summary(r)];

  @override
  Future<void> delete(String id) async {
    if (failDelete) throw const FileSystemException('busy');
    deleted.add(id);
    saved.remove(id);
  }

  @override
  Future<ImuRecording> load(String id) async => saved[id]!;

  @override
  Future<Directory> directory() => throw UnimplementedError();

  // Not used by these tests (the export has its own).
  @override
  Future<File> exportAll() => throw UnimplementedError();
}

StrapEvent _tap() => StrapEvent(
      eventId: 14,
      tsEpoch: 1790000000,
      receivedAt: DateTime.fromMillisecondsSinceEpoch(1790000000050, isUtc: true),
      hex: '',
      deviceId: 'band-a',
    );

class _Rig {
  _Rig({this.connected = true}) {
    recorder = ImuLabRecorder(
      packets: packets.stream,
      setStreamOwner: owner.add,
      playReadyCue: () => cues++,
      monotonicNow: () => mono,
      isConnected: () => connected,
      context: () => const ImuLabContext(
          bandModel: 'WHOOP MG', deviceId: 'band-a', appVersion: '0.10.0+67'),
      newId: () => 'imu-test-${++ids}',
    );
  }

  final packets = StreamController<ImuPacket>.broadcast(sync: true);
  final owner = <bool>[];
  final store = _FakeStore();
  final shared = <String>[];
  bool shareOk = true;
  int cues = 0;
  bool connected;
  int ids = 0;
  Duration mono = Duration.zero;
  late final ImuLabRecorder recorder;

  Future<bool> share(String path, Rect? origin) async {
    shared.add(path);
    return shareOk;
  }

  void packet(int ms,
      {int accel = 3, int gyro = 3, bool gap = false, int invalidGyro = 0}) {
    mono = Duration(milliseconds: ms);
    packets.add(labPacket(ms,
        accel: accel, gyro: gyro, gap: gap, invalidGyro: invalidGyro));
  }

  Widget lab({bool withMotion = true}) => DeviceLabView(
        ecgSupported: false,
        tapTools: false,
        motion: withMotion
            ? MotionLabPanel(
                recorder: recorder,
                store: store,
                share: share,
              )
            : null,
        initialTab: withMotion ? LabTab.motion : null,
      );
}

Future<void> _pump(WidgetTester t, Widget w,
    {double width = 390, double scale = 1}) async {
  t.view.physicalSize = Size(width * 3, 4800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: MaterialApp(theme: buildTheme(Brightness.light), home: w),
  ));
  await t.pumpAndSettle();
}

Finder _key(String k) => find.byKey(ValueKey(k));

Future<void> _tapKey(WidgetTester t, String k) async {
  await t.ensureVisible(_key(k));
  await t.tap(_key(k));
  await t.pumpAndSettle();
}

Future<void> _fill(WidgetTester t, {String label = 'rotate out'}) async {
  await t.enterText(find.descendant(of: _key('motion-label'), matching: find.byType(TextField)), label);
  await _tapKey(t, 'motion-wrist:left');
  await t.pumpAndSettle();
}

bool _armEnabled(WidgetTester t) =>
    t.widget<BigButton>(_key('motion-arm')).onTap != null;

/// Leave nothing running: drop the panel (which cancels), then the recorder.
Future<void> _end(WidgetTester t, _Rig rig) async {
  await t.pumpWidget(const SizedBox());
  rig.recorder.dispose();
}

Future<void> _armAndRecord(WidgetTester t, _Rig rig) async {
  await _fill(t);
  await _tapKey(t, 'motion-arm');
  rig.recorder.onBandEvent(_tap());
  await t.pump();
  rig.packet(1000);
  rig.packet(2000, gap: true);
  await t.pump();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() async {
    await (await SharedPreferences.getInstance()).clear();
  });

  group('the tab', () {
    testWidgets('offered only when the lab is given a Motion panel', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab(withMotion: false));
      expect(find.byKey(const ValueKey('device-lab-tab:motion')), findsNothing);
      expect(find.text('Record motion'), findsNothing);
      await _end(t, rig);
    });

    testWidgets('sits between Probes and Live, with its id', (t) async {
      expect([for (final x in LabTab.values) x.id],
          ['taps', 'probes', 'motion', 'live', 'logs']);
      expect(LabTab.motion.label, 'Motion');
      final rig = _Rig();
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: false,
            probes: const SizedBox(height: 10),
            live: const SizedBox(height: 10),
            motion: MotionLabPanel(
                recorder: rig.recorder, store: rig.store, share: rig.share),
          ));
      expect(t.widget<SubTabs>(find.byType(SubTabs)).items,
          ['Taps', 'Probes', 'Motion', 'Live', 'Logs']);
      await _end(t, rig);
    });
  });

  group('the form', () {
    testWidgets('kind, label, wrist, mounting, posture, environment, duration',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      expect(find.text('Record motion'), findsOneWidget);
      for (final k in ['action', 'ambient', 'unintendedTap']) {
        expect(_key('motion-kind:$k'), findsOneWidget);
      }
      expect(_key('motion-label'), findsOneWidget);
      expect(_key('motion-mounting'), findsOneWidget);
      expect(_key('motion-wrist:left'), findsOneWidget);
      expect(_key('motion-wrist:right'), findsOneWidget);
      expect(_key('motion-posture:sitting'), findsOneWidget);
      expect(_key('motion-env:car'), findsOneWidget);
      expect(find.text('5 s'), findsOneWidget);
      expect(_key('motion-arm'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('duration follows the kind: 5 s action, 30 s ambient, 5 s tap',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _tapKey(t, 'motion-kind:ambient');
      expect(find.text('30 s'), findsOneWidget);
      await _tapKey(t, 'motion-kind:action');
      expect(find.text('5 s'), findsOneWidget);
      await _tapKey(t, 'motion-kind:unintendedTap');
      expect(find.text('5 s'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('the duration steps by 5 s within 5 to the recorder limit',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _tapKey(t, 'motion-duration:+');
      expect(find.text('10 s'), findsOneWidget);
      await _tapKey(t, 'motion-duration:-');
      await _tapKey(t, 'motion-duration:-');
      expect(find.text('5 s'), findsOneWidget, reason: 'never below 5 s');
      for (var i = 0; i < 40; i++) {
        await t.tap(_key('motion-duration:+'));
        await t.pump();
      }
      expect(find.text('${ImuLabRecorder.maxDuration.inSeconds} s'),
          findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('a duration the wearer set is kept when the kind changes',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _tapKey(t, 'motion-duration:+');
      await _tapKey(t, 'motion-kind:ambient');
      expect(find.text('10 s'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('Arm needs a label and a wrist, and says so', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      expect(_armEnabled(t), isFalse);
      expect(find.textContaining('Enter a label and choose the wrist'),
          findsOneWidget);
      await t.enterText(
          find.descendant(of: _key('motion-label'), matching: find.byType(TextField)),
          'rotate');
      await t.pumpAndSettle();
      expect(_armEnabled(t), isFalse, reason: 'still no wrist');
      await _tapKey(t, 'motion-wrist:right');
      expect(_armEnabled(t), isTrue);
      expect(find.textContaining('Enter a label and choose the wrist'),
          findsNothing);
      await _end(t, rig);
    });

    testWidgets('a blank label does not arm', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _fill(t, label: '   ');
      expect(_armEnabled(t), isFalse);
      await _end(t, rig);
    });
  });

  group('arming and recording', () {
    testWidgets('Arm hands the recorder what was entered and waits for a tap',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _tapKey(t, 'motion-kind:ambient');
      await t.enterText(
          find.descendant(of: _key('motion-label'), matching: find.byType(TextField)),
          'walking');
      await t.enterText(
          find.descendant(of: _key('motion-mounting'), matching: find.byType(TextField)),
          'logo to elbow');
      await _tapKey(t, 'motion-wrist:right');
      await _tapKey(t, 'motion-posture:standing');
      await _tapKey(t, 'motion-env:plane');
      await _tapKey(t, 'motion-arm');
      final s = rig.recorder.setup!;
      expect(rig.recorder.phase, ImuLabPhase.armed);
      expect(s.kind, ImuRecordingKind.ambient);
      expect(s.label, 'walking');
      expect(s.wrist, ImuWrist.right);
      expect(s.mounting, 'logo to elbow');
      expect(s.posture, 'Standing');
      expect(s.environment, 'Plane');
      expect(s.duration, const Duration(seconds: 30));
      expect(find.text('Double tap to begin'), findsOneWidget);
      expect(find.textContaining('paused'), findsWidgets);
      expect(rig.owner, isEmpty, reason: 'no stream until the tap');
      await _end(t, rig);
    });

    testWidgets('Cancel while armed goes back to the form', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _fill(t);
      await _tapKey(t, 'motion-arm');
      await _tapKey(t, 'motion-cancel');
      expect(rig.recorder.phase, ImuLabPhase.idle);
      expect(find.text('Double tap to begin'), findsNothing);
      expect(_key('motion-arm'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('the tap shows the stream starting; the first packet, '
        'recording with its count and time', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _fill(t);
      await _tapKey(t, 'motion-arm');
      rig.recorder.onBandEvent(_tap());
      await t.pump();
      expect(find.text('Waiting for motion data…'), findsOneWidget);
      expect(find.text('Double tap to begin'), findsNothing);
      rig.packet(1000);
      rig.packet(3500);
      await t.pump();
      expect(find.text('Recording 2 of 5 s'), findsOneWidget);
      expect(find.text('2 packets'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('waits on "Waiting for motion data…" while the gyro is '
        'invalid, then says "Go — move now" with one buzz', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _fill(t);
      await _tapKey(t, 'motion-arm');
      rig.recorder.onBandEvent(_tap());
      await t.pump();
      expect(find.text('Waiting for motion data…'), findsOneWidget);
      expect(find.text('Go — move now'), findsNothing);
      rig.packet(1300, invalidGyro: 3); // data is flowing but not usable
      await t.pump();
      expect(find.text('Waiting for motion data…'), findsOneWidget);
      expect(find.text('Go — move now'), findsNothing);
      expect(_key('motion-cancel'), findsOneWidget);
      expect(_key('motion-mark'), findsNothing,
          reason: 'there is nothing to mark motion against yet');
      expect(rig.cues, 0);
      rig.packet(2300);
      await t.pump();
      expect(find.text('Go — move now'), findsOneWidget);
      expect(find.text('Waiting for motion data…'), findsNothing);
      expect(rig.cues, 1);
      expect(_key('motion-mark'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('data that never becomes valid: no Go, no buzz, a clear '
        'message, and nothing saved', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _fill(t);
      await _tapKey(t, 'motion-arm');
      rig.recorder.onBandEvent(_tap());
      rig.packet(1300, invalidGyro: 3);
      await t.pump();
      await t.pump(const Duration(seconds: 11));
      expect(find.text('Go — move now'), findsNothing);
      expect(rig.cues, 0);
      expect(find.text('Gyro never became valid'), findsOneWidget);
      expect(find.textContaining('invalid'), findsWidgets);
      expect(rig.store.saves, 0);
      expect(rig.store.saved, isEmpty);
      await _end(t, rig);
    });

    testWidgets('Mark motion start / end toggles and lands as markers',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _fill(t);
      await _tapKey(t, 'motion-arm');
      rig.recorder.onBandEvent(_tap());
      rig.packet(1000);
      await t.pump();
      expect(find.text('Mark motion start'), findsOneWidget);
      await _tapKey(t, 'motion-mark');
      expect(find.text('Mark motion end'), findsOneWidget);
      expect(rig.recorder.motionOpen, isTrue);
      await _tapKey(t, 'motion-mark');
      expect(find.text('Mark motion start'), findsOneWidget);
      await _tapKey(t, 'motion-stop');
      final kinds = rig.recorder.recording!.markers.map((m) => m.kind);
      expect(kinds, contains(ImuMarkerKind.motionStart));
      expect(kinds, contains(ImuMarkerKind.motionEnd));
      await _end(t, rig);
    });

    testWidgets('Stop shows the review: figures and the partial label',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _armAndRecord(t, rig);
      await _tapKey(t, 'motion-stop');
      expect(find.text('Partial recording'), findsOneWidget);
      expect(find.text('Stopped early'), findsOneWidget);
      expect(find.text('Packets: 2'), findsOneWidget);
      expect(find.text('Length: 1.0 s'), findsOneWidget);
      expect(find.textContaining('Gaps: 1'), findsOneWidget);
      expect(find.textContaining('Partial blocks: 2'), findsOneWidget);
      expect(_key('motion-save'), findsOneWidget);
      expect(_key('motion-discard'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('a recording that ran its duration is not called partial',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _fill(t);
      await _tapKey(t, 'motion-arm');
      rig.recorder.onBandEvent(_tap());
      rig.packet(1000);
      await t.pump();
      await t.pump(const Duration(seconds: 6));
      expect(find.text('Recording finished'), findsOneWidget);
      expect(find.text('Partial recording'), findsNothing);
      expect(find.text('Completed'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('a stream that never started says no packets arrived',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _fill(t);
      await _tapKey(t, 'motion-arm');
      rig.recorder.onBandEvent(_tap());
      await t.pump();
      await t.pump(const Duration(seconds: 11));
      expect(find.text('No packets arrived'), findsOneWidget);
      expect(find.text('Packets: 0'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('an unclosed motion mark is called out', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _armAndRecord(t, rig);
      await _tapKey(t, 'motion-mark');
      await _tapKey(t, 'motion-stop');
      expect(find.textContaining('never closed'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('a disconnect during the capture shows as such', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _armAndRecord(t, rig);
      rig.recorder.onDisconnected();
      await t.pump();
      expect(find.text('Band disconnected'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('arming without a band says so and stays on the form',
        (t) async {
      final rig = _Rig(connected: false);
      await _pump(t, rig.lab());
      await _fill(t);
      await _tapKey(t, 'motion-arm');
      expect(find.text('Connect the band first.'), findsOneWidget);
      expect(_key('motion-arm'), findsOneWidget);
      await _end(t, rig);
    });
  });

  group('save and discard', () {
    testWidgets('nothing is saved until Save recording', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _armAndRecord(t, rig);
      await _tapKey(t, 'motion-stop');
      expect(rig.store.saves, 0, reason: 'a finished recording is only in RAM');
      await _tapKey(t, 'motion-discard');
      expect(rig.store.saves, 0);
      expect(rig.recorder.phase, ImuLabPhase.idle);
      expect(find.text('Saved recordings'), findsOneWidget);
      expect(find.text('No saved recordings yet.'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('Save writes once, says where, lists it, and offers Share',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _armAndRecord(t, rig);
      await _tapKey(t, 'motion-stop');
      await _tapKey(t, 'motion-save');
      expect(rig.store.saves, 1);
      expect(rig.store.saved.keys, ['imu-test-1']);
      expect(find.text('Saved to device_lab/imu/imu-test-1.jsonl'),
          findsOneWidget);
      expect(_key('motion-share'), findsOneWidget);
      expect(find.text('rotate out'), findsOneWidget, reason: 'in the list');
      expect(_key('motion-saved-delete:imu-test-1'), findsOneWidget);
      // Saving twice is not offered.
      expect(_key('motion-save'), findsNothing);
      await _end(t, rig);
    });

    testWidgets('a save that fails keeps the capture and lets the wearer retry',
        (t) async {
      final rig = _Rig();
      rig.store.failSave = true;
      await _pump(t, rig.lab());
      await _armAndRecord(t, rig);
      await _tapKey(t, 'motion-stop');
      await _tapKey(t, 'motion-save');
      expect(find.textContaining('Could not save the recording'),
          findsOneWidget);
      expect(rig.recorder.recording, isNotNull);
      expect(_key('motion-save'), findsOneWidget);
      expect(find.text('No saved recordings yet.'), findsOneWidget);
      rig.store.failSave = false;
      await _tapKey(t, 'motion-save');
      expect(rig.store.saved, hasLength(1));
      expect(find.textContaining('Could not save the recording'), findsNothing);
      await _end(t, rig);
    });

    testWidgets('Share hands the saved path to the share seam; a failed share '
        'is not a failed save', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _armAndRecord(t, rig);
      await _tapKey(t, 'motion-stop');
      await _tapKey(t, 'motion-save');
      await _tapKey(t, 'motion-share');
      expect(rig.shared, ['/docs/device_lab/imu/imu-test-1.jsonl']);
      rig.shareOk = false;
      await _tapKey(t, 'motion-share');
      expect(find.text('Could not open the share sheet. The file is still saved.'),
          findsOneWidget);
      expect(rig.store.saved, hasLength(1));
      await _end(t, rig);
    });

    testWidgets('Done after saving clears the review', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _armAndRecord(t, rig);
      await _tapKey(t, 'motion-stop');
      await _tapKey(t, 'motion-save');
      await _tapKey(t, 'motion-done');
      expect(rig.recorder.phase, ImuLabPhase.idle);
      expect(_key('motion-arm'), findsOneWidget);
      expect(_key('motion-saved-delete:imu-test-1'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('the review survives leaving the tab and coming back',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _armAndRecord(t, rig);
      await _tapKey(t, 'motion-stop');
      await t.pumpWidget(const SizedBox());
      await _pump(t, rig.lab());
      expect(find.text('Packets: 2'), findsOneWidget);
      expect(rig.store.saves, 0);
      await _end(t, rig);
    });
  });

  group('saved recordings', () {
    Future<_Rig> withSaved(WidgetTester t, {int n = 2}) async {
      final rig = _Rig();
      for (var i = 0; i < n; i++) {
        await rig.store.save(ImuRecording(
          meta: labMeta(id: 'old-$i', label: 'take $i'),
          status: ImuRecordingStatus.completed,
          packets: [labPacket(1000), labPacket(2000)],
          markers: const [],
        ));
      }
      rig.store.saves = 0;
      await _pump(t, rig.lab());
      return rig;
    }

    testWidgets('each row names the recording and what is in it', (t) async {
      final rig = await withSaved(t);
      expect(find.text('take 0'), findsOneWidget);
      expect(find.text('take 1'), findsOneWidget);
      expect(find.textContaining('Action'), findsWidgets);
      expect(find.textContaining('2 packets'), findsWidgets);
      expect(_key('motion-saved-share:old-0'), findsOneWidget);
      expect(_key('motion-saved-delete:old-0'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('Delete asks first; keeping it deletes nothing', (t) async {
      final rig = await withSaved(t);
      await _tapKey(t, 'motion-saved-delete:old-0');
      expect(find.text('Delete this recording?'), findsOneWidget);
      await t.tap(find.text('Keep it'));
      await t.pumpAndSettle();
      expect(rig.store.deleted, isEmpty);
      expect(find.text('take 0'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('confirming deletes the file and the row', (t) async {
      final rig = await withSaved(t);
      await _tapKey(t, 'motion-saved-delete:old-0');
      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      expect(rig.store.deleted, ['old-0']);
      expect(find.text('take 0'), findsNothing);
      expect(find.text('take 1'), findsOneWidget);
      expect(_key('motion-saved-delete:old-0'), findsNothing);
      await _end(t, rig);
    });

    testWidgets('a delete that fails says so and keeps the row', (t) async {
      final rig = await withSaved(t);
      rig.store.failDelete = true;
      await _tapKey(t, 'motion-saved-delete:old-0');
      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      expect(find.textContaining('Could not delete'), findsOneWidget);
      expect(find.text('take 0'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('a saved row shares its own file', (t) async {
      final rig = await withSaved(t);
      await _tapKey(t, 'motion-saved-share:old-1');
      expect(rig.shared, ['/docs/device_lab/imu/old-1.jsonl']);
      await _end(t, rig);
    });

    testWidgets('an unreadable file is listed by its name and can be deleted',
        (t) async {
      final rig = _Rig();
      rig.store.saved.clear();
      final broken = _BrokenListStore(rig.store);
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: false,
            tapTools: false,
            motion: MotionLabPanel(
                recorder: rig.recorder, store: broken, share: rig.share),
            initialTab: LabTab.motion,
          ));
      expect(find.text('broken-file'), findsOneWidget);
      expect(find.textContaining('unreadable'), findsOneWidget);
      expect(_key('motion-saved-delete:broken-file'), findsOneWidget);
      await _end(t, rig);
    });

    testWidgets('a list that cannot be read says so', (t) async {
      final rig = _Rig();
      await _pump(
          t,
          DeviceLabView(
            ecgSupported: false,
            tapTools: false,
            motion: MotionLabPanel(
                recorder: rig.recorder, store: _ThrowingListStore(), share: rig.share),
            initialTab: LabTab.motion,
          ));
      expect(find.textContaining('Could not read the saved recordings'),
          findsOneWidget);
      await _end(t, rig);
    });
  });

  group('leaving', () {
    testWidgets('closing the tab while armed cancels it', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _fill(t);
      await _tapKey(t, 'motion-arm');
      await t.pumpWidget(const SizedBox());
      expect(rig.recorder.phase, ImuLabPhase.idle);
      expect(rig.recorder.holdsActions, isFalse);
      rig.recorder.dispose();
    });

    testWidgets('closing the tab while recording releases the stream',
        (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab());
      await _fill(t);
      await _tapKey(t, 'motion-arm');
      rig.recorder.onBandEvent(_tap());
      rig.packet(1000);
      await t.pump();
      expect(rig.owner, [true]);
      await t.pumpWidget(const SizedBox());
      expect(rig.owner, [true, false]);
      expect(rig.recorder.phase, ImuLabPhase.idle);
      rig.recorder.dispose();
    });
  });

  group('fits a 360 pt phone at text scale 1.3', () {
    Future<void> check(WidgetTester t, _Rig rig) async {
      expect(t.takeException(), isNull);
      await _end(t, rig);
    }

    testWidgets('form', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab(), width: 360, scale: 1.3);
      await _fill(t, label: 'a long label that wraps onto more than one line');
      await check(t, rig);
    });

    testWidgets('armed and starting', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab(), width: 360, scale: 1.3);
      await _fill(t);
      await _tapKey(t, 'motion-arm');
      expect(t.takeException(), isNull);
      rig.recorder.onBandEvent(_tap());
      await t.pump();
      await check(t, rig);
    });

    testWidgets('recording', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab(), width: 360, scale: 1.3);
      await _armAndRecord(t, rig);
      await check(t, rig);
    });

    testWidgets('review and saved list', (t) async {
      final rig = _Rig();
      await _pump(t, rig.lab(), width: 360, scale: 1.3);
      await _armAndRecord(t, rig);
      await _tapKey(t, 'motion-stop');
      expect(t.takeException(), isNull);
      await _tapKey(t, 'motion-save');
      await _tapKey(t, 'motion-share');
      await check(t, rig);
    });
  });
}

class _BrokenListStore extends _FakeStore {
  _BrokenListStore(this.inner);
  final _FakeStore inner;

  @override
  Future<List<SavedImuRecording>> list() async => const [
        SavedImuRecording(
            id: 'broken-file', path: '/docs/device_lab/imu/broken-file.jsonl', sizeBytes: 12),
      ];
}

class _ThrowingListStore extends _FakeStore {
  @override
  Future<List<SavedImuRecording>> list() async =>
      throw const FileSystemException('denied');
}
