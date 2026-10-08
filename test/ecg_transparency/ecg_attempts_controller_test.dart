// Design 04 phase 1 (RED) - items 1 and 2, the controller half: every terminal
// window is SAVED before it is cleared (unreadable, first inconclusive,
// final), one HR source (averageHr) decides, and every new reading carries its
// provenance - mask_any (OR of the terminal mask and every accepted packet's
// mask, R1''), live HR, variability, firmware / app / table version, UTC
// offset - whether or not Keep waveform is on (R3).
//
// Over the scripted FakeTransport of test/ecg_controller_test.dart. Time is the
// controller's injected nowMs; nothing reads the real clock.
//
// ASSUMED: a saved unreadable / first-inconclusive attempt keeps today's
// status/category ("original status/category as-is": unreadable is status
// completed + category unreadable; a first inconclusive is status
// inconclusive); the capture state's readingId then names it (so its Details
// can be opened) and EcgCaptureState.outcome carries ecgOutcome of it; a save
// that fails on an attempt ends the capture `failed`/'save' like a failed final
// save does.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_controller.dart';
import 'package:openstrap_edge/ecg/ecg_guard_store.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_outcome.dart';
import 'package:openstrap_edge/ecg/ecg_policy.dart';

import '../ecg_controller_test.dart' show FakeTransport;
import 'support/cardio_fixtures.dart';

class CRig {
  final t = FakeTransport();
  final guard = MemoryEcgGuardStore();
  final saved = <(EcgReading, List<EcgAcceptedPacket>)>[];
  bool keep = false;
  bool failSave = false;
  var now = 1787823754000;
  String? firmware;
  String? appVersion;
  int? offsetMin;
  final offsetAsked = <int>[];
  late final EcgController c;

  CRig({bool providers = false}) {
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
      nowMs: () => now,
      keepWaveform: () => keep,
      firmwareVersion: providers ? () => firmware : null,
      appVersion: providers ? () => appVersion : null,
      utcOffsetMin: providers
          ? (ms) {
              offsetAsked.add(ms);
              return offsetMin;
            }
          : null,
    );
  }

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// [n] accepted contact packets, each carrying [unreadable] as its own mask.
  Future<void> record(int n, {int firstSeq = 1, int unreadable = 0, int liveHr = 70}) async {
    for (var i = 0; i < n; i++) {
      t.emitFrame(r17(seq: firstSeq + i, liveHr: liveHr, unreadable: unreadable));
    }
    await settle();
  }

  Future<void> terminal({
    int seq = 100,
    int result = 1,
    int avgHr = 77,
    int liveHr = 78,
    int unreadable = 0,
    int? variability,
  }) async {
    t.emitFrame(r17Terminal(
      seq: seq,
      result: result,
      avgHr: avgHr,
      liveHr: liveHr,
      unreadable: unreadable,
      variability: variability,
    ));
    await settle();
    await settle();
  }

  EcgReading get last => saved.last.$1;
  void dispose() => c.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('every terminal window is saved before it is cleared', () {
    test('an unreadable terminal (result 2) is saved as an attempt: category '
        'unreadable, status completed, its window kept, its mask kept',
        () async {
      final r = CRig()..keep = true;
      await r.c.begin(EcgWrist.right);
      await r.record(3);
      await r.terminal(result: 2, avgHr: 0, liveHr: 0, unreadable: 0x02);
      expect(r.saved, hasLength(1), reason: 'saved, not dropped');
      final (reading, packets) = r.saved.single;
      expect(reading.category, EcgCategory.unreadable);
      expect(reading.status, EcgReadingStatus.completed);
      expect(reading.resultCode, 2);
      expect(reading.unreadableMask, 0x02);
      expect(packets.length, greaterThanOrEqualTo(3));
      expect(packets.length * 100, reading.sampleCount,
          reason: 'the saved window IS the accepted window');
      expect(r.c.state.phase, EcgCapturePhase.unreadable);
      expect(r.c.state.unreadableMask, 0x02);
      expect(r.c.state.readingId, reading.id);
      expect(r.c.state.outcome?.kind, EcgOutcomeKind.notReadable);
      r.dispose();
    });

    test('a first inconclusive (result 6) is saved before the retry is '
        'offered: status inconclusive', () async {
      final r = CRig()..keep = true;
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 6, avgHr: 70);
      expect(r.saved, hasLength(1));
      expect(r.last.status, EcgReadingStatus.inconclusive);
      expect(r.last.category, EcgCategory.inconclusive);
      expect(r.saved.single.$2, isNotEmpty);
      expect(r.c.state.phase, EcgCapturePhase.inconclusiveRetry);
      expect(r.c.state.readingId, r.last.id);
      r.dispose();
    });

    test('a first terminal with result 6 and a noise mask offers the retry but '
        'its outcome is Not readable with the noise reason (what the screen '
        'must show)', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 6, avgHr: 70, unreadable: 0x02);
      expect(r.c.state.phase, EcgCapturePhase.inconclusiveRetry);
      expect(r.c.state.outcome?.kind, EcgOutcomeKind.notReadable);
      expect(
        [for (final x in r.c.state.outcome!.reasons) x.id],
        contains(EcgReasonId.significantNoise),
      );
      r.dispose();
    });

    test('with Keep waveform OFF an attempt is still saved, with no packets '
        'but its derived statistics', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(3);
      await r.terminal(result: 2, avgHr: 0, liveHr: 0, unreadable: 0x01);
      expect(r.saved, hasLength(1));
      expect(r.saved.single.$2, isEmpty);
      expect(r.last.sampleCount, greaterThan(0));
      expect(r.last.minUv, isNotNull);
      r.dispose();
    });

    test('retry after an inconclusive: BOTH are saved, in order, the second '
        'starting after the first ended', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(seq: 50, result: 6);
      r.now += 60000;
      await r.c.retry();
      await r.record(2, firstSeq: 60);
      r.now += 30000;
      await r.terminal(seq: 99, result: 1, avgHr: 77);
      expect(r.saved, hasLength(2));
      expect(r.saved[0].$1.status, EcgReadingStatus.inconclusive);
      expect(r.saved[1].$1.status, EcgReadingStatus.completed);
      expect(r.saved[1].$1.id, isNot(r.saved[0].$1.id));
      expect(r.saved[1].$1.startTs, greaterThanOrEqualTo(r.saved[0].$1.endTs));
      expect(r.c.state.phase, EcgCapturePhase.completed);
      r.dispose();
    });

    test('a second inconclusive (the retry is final) is saved too: three '
        'terminals, three readings', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(1);
      await r.terminal(seq: 50, result: 6);
      r.now += 60000;
      await r.c.retry();
      await r.record(1, firstSeq: 60);
      r.now += 30000;
      await r.terminal(seq: 99, result: 6);
      expect(r.saved.map((s) => s.$1.status), [
        EcgReadingStatus.inconclusive,
        EcgReadingStatus.inconclusive,
      ]);
      expect(r.c.state.phase, EcgCapturePhase.completed,
          reason: 'a final inconclusive ends as today');
      r.dispose();
    });

    test('unreadable, then a good reading: two attempts saved', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(seq: 50, result: 2, avgHr: 0, liveHr: 0, unreadable: 0x04);
      r.now += 45000;
      await r.c.begin(EcgWrist.right);
      await r.record(2, firstSeq: 70);
      r.now += 30000;
      await r.terminal(seq: 99, result: 1, avgHr: 77);
      expect(r.saved.map((s) => s.$1.category), [
        EcgCategory.unreadable,
        EcgCategory.sinusRhythm,
      ]);
      r.dispose();
    });

    test('retry DECLINED: the first inconclusive stays saved and nothing else '
        'is written', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 6);
      await r.c.cancel();
      await r.settle();
      expect(r.saved, hasLength(1));
      expect(r.c.state.phase, EcgCapturePhase.inconclusiveRetry);
      r.dispose();
    });

    test('a repeated terminal (the band re-sends it) saves once - unreadable '
        'and retry-offer alike', () async {
      for (final result in [2, 6]) {
        final r = CRig();
        await r.c.begin(EcgWrist.right);
        await r.record(2);
        r.t.emitFrame(r17Terminal(seq: 100, result: result, avgHr: 0, liveHr: 0));
        r.t.emitFrame(r17Terminal(seq: 101, result: result, avgHr: 0, liveHr: 0));
        await r.settle();
        r.t.emitFrame(r17Terminal(seq: 102, result: result, avgHr: 0, liveHr: 0));
        await r.settle();
        expect(r.saved, hasLength(1), reason: 'result $result');
        r.dispose();
      }
    });

    test('a failed save of an attempt still stops the band, releases the '
        'lease and ends `failed`/save (AGENTS 4.3): no wedge', () async {
      final r = CRig()..failSave = true;
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 2, avgHr: 0, liveHr: 0, unreadable: 0x02);
      expect(r.saved, isEmpty);
      expect(r.c.state.phase, EcgCapturePhase.failed);
      expect(r.c.state.reason, 'save');
      expect(r.t.calls, contains('cleanup'));
      expect(r.t.calls, contains('release'));
      expect(await r.guard.isActive('MG-SERIAL'), isFalse);
      expect(r.c.isCapturing, isFalse);
      r.dispose();
    });

    test('the attempt is saved BEFORE the band is stopped and before the '
        'phase leaves `saving`', () async {
      final order = <String>[];
      final t = FakeTransport();
      late EcgController c;
      c = EcgController(
        transport: t,
        guard: MemoryEcgGuardStore(),
        save: (r, p) async => order.add('save:${c.state.phase.name}'),
        busyReason: () => null,
        holdScreen: (o) async {},
        releaseScreen: (o) async {},
        nowMs: () => 1787823754000,
      );
      await c.begin(EcgWrist.right);
      t.emitFrame(r17(seq: 1));
      t.emitFrame(r17Terminal(seq: 9, result: 2, avgHr: 0, liveHr: 0));
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(order, ['save:saving']);
      expect(t.calls.where((x) => x == 'cleanup'), hasLength(1));
      c.dispose();
    });
  });

  group('one HR source: averageHr decides (live HR never does)', () {
    test('result 1, average 120, live 70 -> NOT a regular rhythm: an unreadable '
        'attempt (today the live path says completed and the saved row says '
        'unreadable)', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 1, avgHr: 120, liveHr: 70);
      expect(r.c.state.phase, EcgCapturePhase.unreadable);
      expect(r.last.category, EcgCategory.unreadable);
      expect(r.last.avgHr, 120);
      r.dispose();
    });

    test('result 1, average 77, live 120 -> completed regular, whatever the '
        'live rate says', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 1, avgHr: 77, liveHr: 120);
      expect(r.c.state.phase, EcgCapturePhase.completed);
      expect(r.last.category, EcgCategory.sinusRhythm);
      expect(r.last.liveHr, 120, reason: 'stored, shown in Details, never decides');
      r.dispose();
    });

    test('result 3 with no average rate is unreadable, not "low heart rate"',
        () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 3, avgHr: 0, liveHr: 40);
      expect(r.c.state.phase, EcgCapturePhase.unreadable);
      expect(r.last.category, EcgCategory.unreadable);
      expect(r.last.avgHr, isNull, reason: 'none is stored as NULL');
      r.dispose();
    });
  });

  group('the band mask overrides a regular verdict (owner answer 1)', () {
    test('result 1 / 77 bpm with the noise bit on the TERMINAL: saved as the '
        'band reported it, shown as not readable', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 1, avgHr: 77, unreadable: 0x02);
      expect(r.last.category, EcgCategory.sinusRhythm,
          reason: 'the raw band category is preserved');
      expect(r.last.unreadableMask, 0x02);
      expect(r.last.maskAny, 0x02);
      expect(ecgOutcome(r.last).kind, EcgOutcomeKind.notReadable);
      expect(r.c.state.outcome?.kind, EcgOutcomeKind.notReadable);
      r.dispose();
    });

    test('a noise bit on an ACCEPTED PACKET mid-window (terminal clean) also '
        'makes it not readable, with Keep waveform off', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(1);
      await r.record(1, firstSeq: 2, unreadable: 0x02);
      await r.record(1, firstSeq: 3);
      await r.terminal(result: 1, avgHr: 77, unreadable: 0);
      expect(r.saved.single.$2, isEmpty);
      expect(r.last.maskAny, 0x02);
      expect(r.last.unreadableMask, 0);
      expect(ecgOutcome(r.last).kind, EcgOutcomeKind.notReadable);
      r.dispose();
    });

    test('mask_any is the OR of the terminal mask and every accepted packet',
        () async {
      final r = CRig()..keep = true;
      await r.c.begin(EcgWrist.right);
      await r.record(1, unreadable: 0x02);
      await r.record(1, firstSeq: 2, unreadable: 0x04);
      await r.terminal(result: 1, avgHr: 77, unreadable: 0x01);
      expect(r.last.maskAny, 0x07);
      expect(r.last.unreadableMask, 0x01);
      r.dispose();
    });

    test('bits 4-7 are carried into mask_any like any other', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2, unreadable: 0x10);
      await r.terminal(result: 1, avgHr: 77);
      expect(r.last.maskAny, 0x10);
      expect(ecgOutcome(r.last).reasons,
          [const EcgReason(EcgReasonId.unknownBandReasonBit, 4)]);
      r.dispose();
    });

    test('a window that is CLEARED (contact lost) forgets the masks it saw: '
        'only the final accepted window counts', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2, unreadable: 0x08);
      r.t.emitFrame(r17(seq: 3, presence: false)); // contact lost: window cleared
      await r.settle();
      await r.record(2, firstSeq: 10); // a clean window
      await r.terminal(result: 1, avgHr: 77);
      expect(r.last.maskAny, 0);
      expect(ecgOutcome(r.last).kind, EcgOutcomeKind.bandResult);
      r.dispose();
    });

    test('packets that were never accepted (no contact yet) do not count',
        () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      r.t.emitFrame(r17(seq: 1, presence: false, unreadable: 0x02));
      r.t.emitFrame(r17(seq: 2, progress: 0, unreadable: 0x02));
      await r.settle();
      await r.record(2, firstSeq: 3);
      await r.terminal(result: 1, avgHr: 77);
      expect(r.last.maskAny, 0);
      r.dispose();
    });

    test('a clean capture stores mask_any 0 (a measured zero, not NULL)',
        () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 1, avgHr: 77);
      expect(r.last.maskAny, 0);
      r.dispose();
    });
  });

  group('provenance on every new reading (R3) - Keep waveform on AND off', () {
    for (final keep in [true, false]) {
      test('live HR, variability, table version round-trip (keep waveform '
          '$keep)', () async {
        final r = CRig()..keep = keep;
        await r.c.begin(EcgWrist.right);
        await r.record(2);
        await r.terminal(result: 1, avgHr: 77, liveHr: 81, variability: 1234);
        expect(r.last.liveHr, 81);
        expect(r.last.variabilityRaw, 1234);
        expect(r.last.captureTableVersion, kEcgOutcomeTableVersion);
        expect(r.last.maskAny, 0);
        r.dispose();
      });
    }

    test('the 0xffff variability sentinel is NULL, never 65535; a live HR of '
        '0 ("none") is NULL', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 1, avgHr: 77, liveHr: 0, variability: null);
      expect(r.last.variabilityRaw, isNull);
      expect(r.last.liveHr, isNull);
      r.dispose();
    });

    test('a measured variability of 0 stays 0', () async {
      final r = CRig();
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 1, avgHr: 77, variability: 0);
      expect(r.last.variabilityRaw, 0);
      r.dispose();
    });

    test('firmware, app version and UTC offset come from the injected '
        'providers; the offset is asked for the window start', () async {
      final r = CRig(providers: true)
        ..firmware = '5.2.1'
        ..appVersion = '9.9.9+99'
        ..offsetMin = -420;
      await r.c.begin(EcgWrist.right);
      r.now = 1787823800000;
      await r.record(2);
      r.now = 1787823830000;
      await r.terminal(result: 1, avgHr: 77);
      expect(r.last.firmwareVersion, '5.2.1');
      expect(r.last.captureAppVersion, '9.9.9+99');
      expect(r.last.startOffsetMin, -420);
      expect(r.offsetAsked, contains(1787823800000),
          reason: 'the offset in force when the window opened');
      r.dispose();
    });

    test('providers that know nothing store NULL (not recorded), never a '
        'guess: no providers, or providers returning null', () async {
      for (final providers in [false, true]) {
        final r = CRig(providers: providers); // providers return null
        await r.c.begin(EcgWrist.right);
        await r.record(2);
        await r.terminal(result: 1, avgHr: 77);
        expect(r.last.firmwareVersion, isNull, reason: 'providers=$providers');
        expect(r.last.captureAppVersion, isNull);
        expect(r.last.startOffsetMin, isNull);
        expect(r.last.captureTableVersion, kEcgOutcomeTableVersion,
            reason: 'the table version is known by construction');
        r.dispose();
      }
    });

    test('an unreadable attempt carries the same provenance', () async {
      final r = CRig(providers: true)
        ..firmware = '5.2.1'
        ..appVersion = '9.9.9+99'
        ..offsetMin = 60;
      await r.c.begin(EcgWrist.right);
      await r.record(2);
      await r.terminal(result: 2, avgHr: 0, liveHr: 0, unreadable: 0x02, variability: 7);
      expect(r.last.firmwareVersion, '5.2.1');
      expect(r.last.captureAppVersion, '9.9.9+99');
      expect(r.last.variabilityRaw, 7);
      expect(r.last.maskAny, 0x02);
      r.dispose();
    });

    test('a PARTIAL reading carries provenance and the masks seen so far',
        () async {
      final r = CRig(providers: true)
        ..firmware = '5.2.1'
        ..appVersion = '9.9.9+99'
        ..offsetMin = 0;
      await r.c.begin(EcgWrist.right);
      await r.record(3, unreadable: 0x04);
      await r.c.onAppPaused();
      await r.settle();
      expect(r.saved, hasLength(1));
      expect(r.last.status, EcgReadingStatus.partial);
      expect(r.last.maskAny, 0x04);
      expect(r.last.firmwareVersion, '5.2.1');
      expect(r.last.captureAppVersion, '9.9.9+99');
      expect(r.last.startOffsetMin, 0);
      expect(r.last.captureTableVersion, kEcgOutcomeTableVersion);
      r.dispose();
    });
  });

  group('the reducer hands the window over before clearing it (R2\'\')', () {
    EcgReducerState run(List<dynamic> frames, EcgReducerState s,
        List<EcgEffect> effects) {
      for (final f in frames) {
        final step = reduceEcg(s, f);
        s = step.state;
        effects.addAll(step.effects);
      }
      return s;
    }

    for (final (name, result, avg, live) in [
      ('unreadable', 2, 0, 0),
      ('first inconclusive', 6, 70, 70),
    ]) {
      test('the $name terminal outcome carries the window it ended, terminal '
          'packet included', () {
        final effects = <EcgEffect>[];
        run([
          for (var i = 1; i <= 3; i++) r17(seq: i),
          r17Terminal(seq: 9, result: result, avgHr: avg, liveHr: live),
        ], const EcgReducerState.initial(), effects);
        final t = effects.whereType<EcgTerminal>().single.outcome;
        expect(t.window, hasLength(4));
        expect(t.window.last.sequence, 9);
      });
    }

    test('the terminal kind is decided by averageHr', () {
      final effects = <EcgEffect>[];
      run([
        r17(seq: 1),
        r17Terminal(seq: 2, result: 1, avgHr: 120, liveHr: 70),
      ], const EcgReducerState.initial(), effects);
      expect(effects.whereType<EcgTerminal>().single.outcome.kind,
          EcgTerminalKind.unreadable);
    });
  });
}
