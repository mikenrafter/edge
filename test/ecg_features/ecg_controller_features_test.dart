// ECG features, phase 1 (RED): the controller side of the ECG features.
//
//  * haptic cues: which slot `onCue` gets for each end state, after the band
//    is stopped; none for a gesture-owned capture (those play the gesture
//    cues); a throwing cue never wedges the exit path (AGENTS.md 4.3);
//  * the waveform policy: the controller hands `save` NO packets unless the
//    wearer keeps the waveform (read at save time); derived stats always;
//  * background / timeout: stop and save what was recorded as `partial`, with
//    metrics only if there was enough signal (kEcgPartialMinSamples), nothing
//    saved if there was no accepted window, never for a gesture capture or a
//    wearer's own cancel;
//  * the saved result's state and metrics on the published state.
//
// Reuses the scripted transport and frame builders of
// test/ecg_controller_test.dart (importing a test file runs none of its tests).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/ecg/ecg_guard_store.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_result.dart';
import 'package:openstrap_edge/ecg/ecg_transport.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';

import '../ecg_controller_test.dart' show FakeTransport, frame, terminal;

/// One cue as the controller played it, with what had already happened.
typedef Cue = ({String slot, List<String> calls, int saved});

class FRig {
  final t = FakeTransport();
  final guard = MemoryEcgGuardStore();
  final saved = <(EcgReading, List<EcgAcceptedPacket>)>[];
  final cues = <Cue>[];
  bool keep = false;
  bool failSave = false;
  bool throwingCue = false;
  var now = 1787823754000;
  late final EcgController c;

  FRig({Duration timeout = const Duration(seconds: 120)}) {
    c = EcgController(
      transport: t,
      guard: guard,
      save: (r, p) async {
        if (failSave) throw StateError('disk full');
        saved.add((r, p));
      },
      busyReason: () => null,
      holdScreen: (o) async {},
      releaseScreen: (o) async {},
      captureTimeout: timeout,
      nowMs: () => now,
      keepWaveform: () => keep,
      onCue: (slot) {
        cues.add((slot: slot, calls: List.of(t.calls), saved: saved.length));
        if (throwingCue) throw StateError('band queue is down');
      },
    );
  }

  List<String> get slots => [for (final x in cues) x.slot];

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  /// Contact frames: [n] accepted packets of 100 samples (10 s per 10), HR 70,
  /// band quality 2.
  Future<void> record(int n, {int firstSeq = 1}) async {
    for (var i = 0; i < n; i++) {
      t.emitFrame(frame(seq: firstSeq + i, progress: 3, liveHr: 70));
    }
    await settle();
  }

  Future<void> finishGood({int seq = 100, int result = 1, int avgHr = 77}) async {
    t.emitFrame(terminal(seq: seq, result: result, avgHr: avgHr));
    await settle();
    await settle();
  }

  void dispose() => c.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('haptic cues', () {
    test('a good reading: started when contact is made, complete once the '
        'result is saved AND the band is stopped', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      expect(r.slots, isEmpty, reason: 'waiting for contact is silent');
      await r.record(2);
      expect(r.slots, [kEcgStartedKey]);
      await r.finishGood();
      expect(r.slots, [kEcgStartedKey, kEcgCompleteKey]);
      final done = r.cues.last;
      expect(done.saved, 1, reason: 'saved before the cue');
      expect(done.calls, contains('cleanup'), reason: 'band stopped before the cue');
      expect(r.c.state.phase, EcgCapturePhase.completed);
    });

    test('a first inconclusive asks for another reading: its own cue; the '
        'retry then ends inconclusive with the plain inconclusive cue',
        () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(1);
      await r.finishGood(seq: 50, result: 6);
      expect(r.c.state.phase, EcgCapturePhase.inconclusiveRetry);
      expect(r.slots, [kEcgStartedKey, kEcgInconclusiveRetryKey]);
      await r.c.retry();
      await r.record(1, firstSeq: 60);
      await r.finishGood(seq: 70, result: 6);
      expect(r.c.state.phase, EcgCapturePhase.completed);
      expect(r.slots, [
        kEcgStartedKey,
        kEcgInconclusiveRetryKey,
        kEcgStartedKey,
        kEcgInconclusiveKey,
      ]);
      expect(r.saved.single.$1.status, EcgReadingStatus.inconclusive);
    });

    test('the band could not read it: failed', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(1);
      await r.finishGood(seq: 50, result: 0);
      expect(r.c.state.phase, EcgCapturePhase.unreadable);
      expect(r.slots, [kEcgStartedKey, kEcgFailedKey]);
    });

    test('the link drops mid-reading: failed', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      r.t.dropLink();
      await r.settle();
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.failed);
      expect(r.slots, [kEcgStartedKey, kEcgFailedKey]);
    });

    test('the band refuses PREPARE: failed, and no "started" for a reading '
        'that never began', () async {
      final r = FRig();
      r.t.prepareResult = EcgCommandListResult(const [
        EcgMemberOutcome('selectWrist', written: true, succeeded: false),
      ]);
      await r.c.begin(EcgWrist.right);
      expect(r.c.state.phase, EcgCapturePhase.failed);
      expect(r.slots, [kEcgFailedKey]);
    });

    test('the wearer cancels: silent apart from the started cue already '
        'played', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.c.cancel();
      expect(r.slots, [kEcgStartedKey]);
    });

    test('not connected / not an MG / busy: nothing happened on the band, '
        'silent', () async {
      final r = FRig();
      r.t.ready = false;
      await r.c.begin(EcgWrist.right);
      r.t.ready = true;
      r.t.maverick = false;
      await r.c.begin(EcgWrist.right);
      expect(r.slots, isEmpty);
    });

    test('S.O.S.: a cleanup that did not finish (the band may still be '
        'recording) plays ecg.attention instead of the outcome cue', () async {
      final r = FRig();
      r.t.cleanupResult = EcgCommandListResult(const [
        EcgMemberOutcome('generationStop', written: true, succeeded: true),
        EcgMemberOutcome('filteredOff', written: true, succeeded: false),
        EcgMemberOutcome('rawSaveOff', written: true, succeeded: true),
      ]);
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.finishGood();
      expect(r.c.state.cleanupIncomplete, isTrue);
      expect(r.slots, [kEcgStartedKey, kEcgAttentionKey]);
    });

    test('S.O.S.: a retained guard that cannot be cleared on begin (recovery) '
        'plays ecg.attention', () async {
      final r = FRig();
      r.guard.active.add('MG-SERIAL');
      r.t.cleanupResult = EcgCommandListResult(const [
        EcgMemberOutcome('generationStop', written: true, succeeded: false),
        EcgMemberOutcome('filteredOff', written: true, succeeded: true),
        EcgMemberOutcome('rawSaveOff', written: true, succeeded: true),
      ]);
      await r.c.begin(EcgWrist.right);
      expect(r.c.state.reason, 'recovery');
      expect(r.slots, [kEcgAttentionKey]);
    });

    test('S.O.S. is not an outcome: a result of any kind, cleanly finished, '
        'never plays it', () async {
      for (final result in [1, 3, 4, 5, 6, 0]) {
        final r = FRig();
        await r.c.begin(EcgWrist.right);
        await r.record(1);
        await r.finishGood(seq: 50, result: result, avgHr: 120);
        if (result == 6) await r.c.cancel(); // the retry offer is left open
        expect(r.slots, isNotEmpty, reason: 'result $result plays an outcome cue');
        expect(r.slots, isNot(contains(kEcgAttentionKey)), reason: 'result $result');
        r.dispose();
      }
    });

    test('a gesture-owned capture (persist: false) plays NO ECG cue: its cues '
        'are the gesture ones', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right, persist: false);
      await r.record(2);
      await r.finishGood(); // a long touch can reach a terminal
      expect(r.c.state.phase, EcgCapturePhase.cancelled);
      expect(r.cues, isEmpty);
    });

    test('a gesture-owned capture that fails to start plays no ECG cue either',
        () async {
      final r = FRig();
      r.t.prepareResult = EcgCommandListResult(const [
        EcgMemberOutcome('selectWrist', written: true, succeeded: false),
      ]);
      await r.c.begin(EcgWrist.right, persist: false);
      expect(r.cues, isEmpty);
    });

    test('a cue callback that throws never wedges the exit path: the reading '
        'is saved, cleanup ran once, the lease is free and a new reading can '
        'begin', () async {
      final r = FRig()..throwingCue = true;
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.finishGood();
      expect(r.cues, isNotEmpty, reason: 'the cue WAS attempted (and threw)');
      expect(r.c.state.phase, EcgCapturePhase.completed);
      expect(r.saved, hasLength(1));
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
      expect(r.c.isCapturing, isFalse);
      expect(r.t.current, isNull);
      await r.c.begin(EcgWrist.right);
      expect(r.c.state.phase, EcgCapturePhase.waiting);
    });
  });

  group('the waveform is kept only when the wearer says so', () {
    test('by default save() is handed NO packets, but the derived statistics '
        'and metrics are all there', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2, firstSeq: 2);
      await r.finishGood(seq: 4, avgHr: 77);
      final (reading, packets) = r.saved.single;
      expect(packets, isEmpty, reason: 'no waveform unless kept');
      expect(reading.sampleCount, 300);
      expect(reading.minUv, isNotNull);
      expect(reading.maxUv, isNotNull);
      expect(reading.rmsUv, isNotNull);
      expect(reading.avgHr, 77);
      expect(reading.quality, isNotNull);
    });

    test('with "Keep waveform" on, save() gets the accepted window, in order',
        () async {
      final r = FRig()..keep = true;
      await r.c.begin(EcgWrist.right);
      await r.record(2, firstSeq: 2);
      await r.finishGood(seq: 4);
      expect(r.saved.single.$2.map((p) => p.sequence), [2, 3, 4]);
    });

    test('the choice is read when the result is SAVED, so switching it on '
        'during the reading counts', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2, firstSeq: 2);
      r.keep = true;
      await r.finishGood(seq: 4);
      expect(r.saved.single.$2, hasLength(3));
    });

    test('the live preview ring is never what is saved: a finished reading '
        'with the waveform off leaves no packet anywhere', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(5);
      expect(r.c.live.length, greaterThan(0), reason: 'RAM-only preview');
      await r.finishGood();
      expect(r.saved.single.$2, isEmpty);
    });
  });

  group('the published result', () {
    test('a complete reading reports its state and real metrics', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.finishGood(avgHr: 77);
      final s = r.c.state;
      expect(s.phase, EcgCapturePhase.completed);
      expect(s.result, EcgReadingStatus.completed);
      expect(s.readingId, r.saved.single.$1.id);
      final byKey = {for (final m in s.metrics) m.key: m};
      expect(byKey['avgHr']!.value, 77);
      expect(byKey['avgHr']!.display, '77 bpm');
      expect(byKey.containsKey('rmssd'), isFalse);
      expect(byKey.containsKey('sdnn'), isFalse);
    });

    test('nothing is published as a result while capturing', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      expect(r.c.state.result, isNull);
      expect(r.c.state.metrics, isEmpty);
    });
  });

  group('background and timeout save what was recorded as partial', () {
    test('the app is backgrounded with 12 s of signal: stop, save a partial '
        'with its metrics', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      r.now += 12000;
      await r.c.onAppPaused();
      await r.settle();
      expect(r.saved, hasLength(1));
      final (reading, packets) = r.saved.single;
      expect(reading.status, EcgReadingStatus.partial);
      expect(reading.stopReason, 'paused');
      expect(reading.resultCode, 0, reason: 'the band never gave a result');
      expect(reading.category, EcgCategory.inconclusive);
      expect(reading.sampleCount, 1200);
      expect(reading.avgHr, 70);
      expect(reading.quality, 2);
      expect(reading.endTs, r.now ~/ 1000);
      expect(reading.endTs, greaterThan(reading.startTs));
      expect(packets, isEmpty, reason: 'waveform off by default');
      // The band was stopped exactly once and everything is released.
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
      expect(r.guard.active, isEmpty);
      expect(r.c.isCapturing, isFalse);
      // What the page is told.
      final s = r.c.state;
      expect(s.phase, EcgCapturePhase.cancelled);
      expect(s.reason, 'paused');
      expect(s.result, EcgReadingStatus.partial);
      expect(s.readingId, reading.id);
      expect({for (final m in s.metrics) m.key: m.value}, {'avgHr': 70, 'quality': 2});
      expect(r.slots, [kEcgStartedKey, kEcgFailedKey]);
    });

    test('with the waveform kept, a partial keeps its accepted window too',
        () async {
      final r = FRig()..keep = true;
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      await r.c.onAppPaused();
      await r.settle();
      expect(r.saved.single.$2, hasLength(12));
    });

    test('only 9 s of signal (under the minimum): the partial is saved but '
        'its metrics are null, never a guess', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(9);
      await r.c.onAppPaused();
      await r.settle();
      final reading = r.saved.single.$1;
      expect(reading.status, EcgReadingStatus.partial);
      expect(reading.sampleCount, 900);
      expect(reading.sampleCount, lessThan(kEcgPartialMinSamples));
      expect(reading.avgHr, isNull);
      expect(reading.quality, isNull);
      final byKey = {for (final m in r.c.state.metrics) m.key: m};
      expect(byKey.values.every((m) => m.value == null), isTrue);
      expect(byKey.values.every((m) => m.display == '—'), isTrue);
    });

    test('exactly the minimum (10 s) is enough for metrics', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(10);
      await r.c.onAppPaused();
      await r.settle();
      expect(r.saved.single.$1.sampleCount, kEcgPartialMinSamples);
      expect(r.saved.single.$1.avgHr, 70);
    });

    test('the capture times out mid-recording: failed (timeout) with the '
        'partial saved', () async {
      final r = FRig(timeout: const Duration(milliseconds: 60));
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await r.settle();
      expect(r.c.state.phase, EcgCapturePhase.failed);
      expect(r.c.state.reason, 'timeout');
      expect(r.c.state.result, EcgReadingStatus.partial);
      final reading = r.saved.single.$1;
      expect(reading.status, EcgReadingStatus.partial);
      expect(reading.stopReason, 'timeout');
      expect(reading.avgHr, 70);
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
      expect(r.slots, [kEcgStartedKey, kEcgFailedKey]);
    });

    test('backgrounded before any contact: there is nothing recorded, so '
        'nothing is saved', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.c.onAppPaused();
      await r.settle();
      expect(r.saved, isEmpty);
      expect(r.c.state.phase, EcgCapturePhase.cancelled);
      expect(r.c.state.result, isNull);
      expect(r.c.state.readingId, isNull);
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
    });

    test('contact lost just before the stop: the reducer cleared the window, '
        'so there is no accepted signal and nothing is saved', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      r.t.emitFrame(frame(seq: 13, presence: false, progress: 0));
      await r.settle();
      await r.c.onAppPaused();
      await r.settle();
      expect(r.saved, isEmpty);
    });

    test('the wearer\'s own cancel saves nothing: that is a decision, not a '
        'loss', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      await r.c.cancel();
      await r.settle();
      expect(r.saved, isEmpty);
      expect(r.c.state.result, isNull);
    });

    test('a gesture-owned capture saves nothing on pause, ever (AGENTS.md '
        'invariant 14)', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right, persist: false);
      await r.record(12);
      await r.c.onAppPaused();
      await r.settle();
      expect(r.saved, isEmpty);
      expect(r.c.state.result, isNull);
    });

    test('a failing partial save still stops the band and frees everything '
        '(no sticky flag), with no readingId', () async {
      final r = FRig()..failSave = true;
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      await r.c.onAppPaused();
      await r.settle();
      expect(r.t.calls.where((c) => c == 'cleanup'), hasLength(1));
      expect(r.c.isCapturing, isFalse);
      expect(r.t.current, isNull);
      expect(r.guard.active, isEmpty);
      expect(r.c.state.readingId, isNull);
      expect(r.c.state.result, isNull);
      r.failSave = false;
      await r.c.begin(EcgWrist.right);
      expect(r.c.state.phase, EcgCapturePhase.waiting,
          reason: 'a new reading can begin');
    });

    test('after a partial, a new reading begins and completes normally '
        '(every latch was reset)', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      await r.c.onAppPaused();
      await r.settle();
      expect(r.saved.single.$1.status, EcgReadingStatus.partial);
      await r.c.begin(EcgWrist.right);
      await r.record(2, firstSeq: 200);
      await r.finishGood(seq: 210);
      expect(r.c.state.phase, EcgCapturePhase.completed);
      expect(r.saved, hasLength(2));
      expect(r.saved.last.$1.status, EcgReadingStatus.completed);
      expect(r.saved.first.$1.id, isNot(r.saved.last.$1.id));
    });
  });
}
