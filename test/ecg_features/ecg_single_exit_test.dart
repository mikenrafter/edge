// ECG features, round 2 (RED): one shared exit per capture.
//
// Every way a capture can end (the terminal packet, the app going to the
// background, the capture timeout, a dropped link, the wearer's cancel) goes
// through ONE completion. The first to arrive wins; the others wait for it and
// do nothing of their own. So:
//   * a result is saved once, under one id, and the published state carries it
//     (a background during a pending terminal save used to build a second
//     "partial" with the same id; the first save then went stale and the state
//     lost its result);
//   * cleanup runs once and FINISHES before the lease is released, on every
//     path (a second exit used to see cleanup "done", fail its own save and
//     release the lease while cleanup commands were still going out).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';

import 'ecg_controller_features_test.dart' show FRig;

int _count(FRig r, String call) => r.t.calls.where((c) => c == call).length;

void _expectCleanThenRelease(FRig r) {
  expect(_count(r, 'cleanup'), 1);
  expect(_count(r, 'release'), 1);
  expect(r.t.calls.indexOf('cleanup'), lessThan(r.t.calls.indexOf('release')),
      reason: 'cleanup finishes before the lease is released');
  expect(r.c.state.cleanupIncomplete, isFalse,
      reason: 'cleanup ran under a valid lease');
  expect(r.guard.active, isEmpty);
  expect(r.c.isCapturing, isFalse);
}

void _expectOneCompletedResult(FRig r) {
  expect(r.saved, hasLength(1), reason: 'saved exactly once');
  expect(r.saved.single.$1.status, EcgReadingStatus.completed);
  expect(r.c.state.phase, EcgCapturePhase.completed);
  expect(r.c.state.result, EcgReadingStatus.completed);
  expect(r.c.state.readingId, r.saved.single.$1.id);
}

Future<FRig> _terminalSavePending({
  Duration timeout = const Duration(seconds: 120),
}) async {
  final r = FRig(timeout: timeout)..holdSave = Completer<void>();
  await r.c.begin(EcgWrist.right);
  await r.record(12);
  await r.finishGood(seq: 100);
  expect(r.c.state.phase, EcgCapturePhase.saving, reason: 'save is pending');
  return r;
}

void main() {
  group('a terminal save is pending', () {
    test('the app is backgrounded: no second save, the result survives',
        () async {
      final r = await _terminalSavePending();
      final paused = r.c.onAppPaused();
      await r.settle();
      r.holdSave!.complete();
      await paused;
      await r.settle();
      await r.settle();
      _expectOneCompletedResult(r);
      _expectCleanThenRelease(r);
    });

    test('the wearer cancels: the reading is still saved and shown', () async {
      final r = await _terminalSavePending();
      final cancelled = r.c.cancel();
      await r.settle();
      r.holdSave!.complete();
      await cancelled;
      await r.settle();
      await r.settle();
      _expectOneCompletedResult(r);
      _expectCleanThenRelease(r);
    });

    test('the capture timeout fires meanwhile: no second save', () async {
      final r = FRig(timeout: const Duration(milliseconds: 60))
        ..holdSave = Completer<void>();
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      // The terminal arrives just before the timer would fire; the save is
      // held past it.
      await r.finishGood(seq: 100);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      r.holdSave!.complete();
      await r.settle();
      await r.settle();
      await r.settle();
      _expectOneCompletedResult(r);
      _expectCleanThenRelease(r);
    });
  });

  group('terminal cleanup is in flight', () {
    test('backgrounding then: no save, and the lease is NOT released until '
        'cleanup has finished', () async {
      final r = FRig();
      r.t.holdCleanup = Completer<void>();
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      await r.finishGood(seq: 100);
      expect(_count(r, 'cleanup'), 1);
      expect(_count(r, 'release'), 0);
      final paused = r.c.onAppPaused();
      await r.settle();
      await r.settle();
      expect(r.saved, hasLength(1), reason: 'no second save');
      expect(_count(r, 'release'), 0, reason: 'cleanup is still going');
      expect(r.t.current, isNotNull, reason: 'the lease is still held');
      r.t.holdCleanup!.complete();
      await paused;
      await r.settle();
      await r.settle();
      _expectOneCompletedResult(r);
      _expectCleanThenRelease(r);
    });
  });

  group('a partial exit is in flight', () {
    test('a second background and a cancel during its pending save: one '
        'partial, one cleanup', () async {
      final r = FRig()..holdSave = Completer<void>();
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      final first = r.c.onAppPaused();
      await r.settle();
      final second = r.c.onAppPaused();
      final third = r.c.cancel();
      await r.settle();
      r.holdSave!.complete();
      await Future.wait([first, second, third]);
      await r.settle();
      expect(r.saved, hasLength(1));
      expect(r.saved.single.$1.status, EcgReadingStatus.partial);
      expect(r.c.state.result, EcgReadingStatus.partial);
      expect(r.c.state.readingId, r.saved.single.$1.id);
      _expectCleanThenRelease(r);
    });

    test('a cancel and a second background during its cleanup: no duplicate '
        'save, no early release', () async {
      final r = FRig();
      r.t.holdCleanup = Completer<void>();
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      final first = r.c.onAppPaused();
      await r.settle();
      await r.settle();
      expect(r.saved, hasLength(1));
      expect(_count(r, 'release'), 0);
      final second = r.c.onAppPaused();
      final third = r.c.cancel();
      await r.settle();
      await r.settle();
      expect(r.saved, hasLength(1), reason: 'no duplicate partial');
      expect(_count(r, 'release'), 0, reason: 'cleanup has not finished');
      r.t.holdCleanup!.complete();
      await Future.wait([first, second, third]);
      await r.settle();
      expect(r.saved.single.$1.status, EcgReadingStatus.partial);
      _expectCleanThenRelease(r);
    });

    test('a timeout firing during a background exit adds nothing', () async {
      final r = FRig(timeout: const Duration(milliseconds: 60))
        ..holdSave = Completer<void>();
      await r.c.begin(EcgWrist.right);
      await r.record(12);
      final paused = r.c.onAppPaused();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      r.holdSave!.complete();
      await paused;
      await r.settle();
      expect(r.saved, hasLength(1));
      expect(r.c.state.reason, 'paused', reason: 'the first exit wins');
      _expectCleanThenRelease(r);
    });
  });

  group('after the one exit', () {
    test('a new reading can begin and complete (nothing stays latched)',
        () async {
      final r = await _terminalSavePending();
      final paused = r.c.onAppPaused();
      r.holdSave!.complete();
      await paused;
      await r.settle();
      r.holdSave = null;
      await r.c.begin(EcgWrist.right);
      await r.record(2, firstSeq: 300);
      await r.finishGood(seq: 310);
      expect(r.c.state.phase, EcgCapturePhase.completed);
      expect(r.saved, hasLength(2));
      expect(r.saved.first.$1.id, isNot(r.saved.last.$1.id));
    });

    test('cleanup precedes release on every ordinary exit', () async {
      for (final how in ['terminal', 'paused', 'cancel', 'linkdown']) {
        final r = FRig();
        await r.c.begin(EcgWrist.right);
        await r.record(12);
        switch (how) {
          case 'terminal':
            await r.finishGood(seq: 100);
          case 'paused':
            await r.c.onAppPaused();
          case 'cancel':
            await r.c.cancel();
          case 'linkdown':
            r.t.dropLink();
        }
        await r.settle();
        await r.settle();
        final calls = r.t.calls;
        expect(calls.indexOf('cleanup'), lessThan(calls.indexOf('release')),
            reason: how);
      }
    });
  });
}
