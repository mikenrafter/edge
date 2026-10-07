// BreathPacer over the REAL BreathingController (RED): the pieces the fake
// host cannot show. Cues reach the controller's normal breath-cue seam
// (dispatchBandAlert 'breath' with the per-phase pattern 1 inhale / 0 exhale /
// 2 hold, 4 for the end), a session of a minute or more is banked once by the
// existing rule (>= 60 s, clamped to the target), a shorter one is not, and
// `pacedByBand` is cleared by the controller itself on every stop path, not
// only by the pacer. Time is a fake clock shared by the controller and the
// pacer; the banked row is the real LocalDb over sqflite_ffi.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/gestures/breath_gesture.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/state/breathing_controller.dart';
import 'package:openstrap_edge/stress/breath_phases.dart';

import '../../support/app_state_workout_harness.dart';
import '../../support/breath_pacer_fakes.dart';

const _db = 'breath_pacer_controller.db';

class _Rig {
  _Rig({this.connected = true}) {
    controller = BreathingController(
      isConnected: () => connected,
      reconcileLiveStreams: () async {},
      nudgeLive: () {},
      repo: () => repo,
      dispatchBandAlert: (rule, {pattern}) async {
        cues.add((rule, pattern));
        return const AlertDeliveryOutcome([], 'test');
      },
      notify: () {},
      now: time.read,
    );
    pacer = BreathPacer(controller, now: time.read, timer: time.timer);
  }

  final time = FakeTime();
  bool connected;
  LocalRepository? repo = BreathRepo();
  late final BreathingController controller;
  late final BreathPacer pacer;
  final cues = <(String, int?)>[];

  Future<void> start(String key, Duration d) =>
      pacer.start(pattern: kBreathPatternsByKey[key]!, duration: d);

  List<int?> get patterns => [for (final c in cues) c.$2];
}

// The insert is not awaited on the stop path; this read queues behind it.
Future<List<Map<String, dynamic>>> _rows() => LocalDb.breathingSessions();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlatformSpies spies;
  setUp(() async {
    await deriveDbSetUp(_db);
    spies = PlatformSpies();
  });
  tearDown(() async {
    // A banked row's insert is not awaited on the stop path; a read queues
    // behind it, so once the read answers the insert has landed.
    await LocalDb.breathingSessions();
    spies.dispose();
    await deriveDbTearDown(_db);
  });

  test('a 1 minute resonance session: 12 phase cues (inhale 1 / exhale 0), '
      'the end cue 4, and exactly one banked row of 60 s', () async {
    final r = _Rig();
    await r.start('resonance', const Duration(minutes: 1));
    expect(r.controller.breathingActive, isTrue);
    expect(r.controller.pacedByBand, isTrue);
    await r.time.advance(const Duration(minutes: 1));
    expect(r.patterns, [for (var i = 0; i < 12; i++) i.isEven ? 1 : 0, 4]);
    expect(r.cues.every((c) => c.$1 == 'breath'), isTrue);
    expect(r.controller.breathingActive, isFalse);
    expect(r.controller.pacedByBand, isFalse);
    final rows = await _rows();
    expect(rows, hasLength(1));
    expect(rows.single['pattern'], 'resonance');
    expect(rows.single['seconds'], 60);
  });

  test('box: the hold phases use the hold cue (2)', () async {
    final r = _Rig();
    await r.start('box', const Duration(minutes: 1));
    await r.time.advance(const Duration(minutes: 1));
    expect(r.patterns.take(8), [1, 2, 0, 2, 1, 2, 0, 2]);
    expect(r.patterns.last, 4);
  });

  test('stopped at 90 s of a 3 minute session: banked once at 90 s, with no '
      'end cue and no cue afterwards', () async {
    final r = _Rig();
    await r.start('resonance', const Duration(minutes: 3));
    await r.time.advance(const Duration(seconds: 90));
    final before = r.cues.length;
    await r.pacer.stop();
    await r.time.advance(const Duration(minutes: 5));
    expect(r.cues, hasLength(before));
    expect(r.patterns.contains(4), isFalse);
    final rows = await _rows();
    expect(rows, hasLength(1));
    expect(rows.single['seconds'], 90);
    expect(r.controller.pacedByBand, isFalse);
  });

  test('stopped under a minute is not banked (the existing rule)', () async {
    final r = _Rig();
    await r.start('resonance', const Duration(minutes: 3));
    await r.time.advance(const Duration(seconds: 30));
    await r.pacer.stop();
    expect(await _rows(), isEmpty);
    expect(r.controller.breathingActive, isFalse);
  });

  test('the controller clears pacedByBand on any stop, not only the pacer\'s: '
      'the screen\'s End session or the Live Activity must not leave the '
      'screen muted for the next session', () async {
    final r = _Rig();
    await r.start('resonance', const Duration(minutes: 3));
    expect(r.controller.pacedByBand, isTrue);
    await r.controller.stopBreathingSession(); // not through the pacer
    expect(r.controller.pacedByBand, isFalse);
    final cues = r.cues.length;
    await r.time.advance(const Duration(minutes: 5));
    expect(r.cues, hasLength(cues), reason: 'the pacer saw the session end');
    expect(r.pacer.running, isFalse);
    expect(r.time.pending, 0);
  });

  test('the band is not connected: start throws, no session, no flag, no '
      'timer', () async {
    final r = _Rig(connected: false);
    await expectLater(
        r.start('resonance', const Duration(minutes: 1)), throwsStateError);
    expect(r.controller.breathingActive, isFalse);
    expect(r.controller.pacedByBand, isFalse);
    expect(r.time.pending, 0);
    expect(r.cues, isEmpty);
  });

  test('the link drops mid-session: the pacer ends it cue-less and banks it '
      'once', () async {
    final r = _Rig();
    await r.start('resonance', const Duration(minutes: 3));
    await r.time.advance(const Duration(seconds: 70));
    r.connected = false;
    await r.pacer.onDisconnect();
    await r.time.advance(const Duration(minutes: 5));
    expect(r.patterns.contains(4), isFalse);
    expect(r.controller.breathingActive, isFalse);
    expect(r.controller.pacedByBand, isFalse);
    final rows = await _rows();
    expect(rows, hasLength(1));
    expect(rows.single['seconds'], 70);
  });
}
