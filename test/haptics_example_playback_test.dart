// Example playback, below the widgets (Sol round 1, findings 1-3):
//  1. one cancellation owner per example; Stop, a newer start and dispose stop
//     the band queue and the phone, through the REAL band queue;
//  2. phone pulses are scheduled against elapsed time (a hold does not shift
//     the next pulse), and stop/pref are checked before every pulse;
//  3. explicit phase/branch gaps, separate from the patterns' own lengths.
// Time is fake (fake_async); nothing sleeps.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/example_playback.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

class _Port implements BandHapticsPort {
  _Port(this.async);
  final FakeAsync async;
  final patterns = <String>[];
  void Function(int index)? onPattern;
  @override
  bool get isConnected => true;
  @override
  String? get generation => 'gen5';
  @override
  Future<bool> buzzBand({int holdMs = 0}) async => true;
  final at = <Duration>[];
  @override
  Future<bool> buzzMaverickPattern(List<int> effects, int loop) async {
    at.add(async.elapsed);
    patterns.add('$effects x$loop');
    onPattern?.call(patterns.length - 1);
    return true;
  }
}

BuzzSequence _two() => BuzzSequence(const [0],
    durationsMs: const [500],
    profileId: _mg.id,
    profileVersion: _mg.version,
    bakedSteps: [
      BakedStep(effects: const [47], loop: 1, delayMs: 0),
      BakedStep(effects: const [14], loop: 1, delayMs: 0),
    ]);

BuzzSequence _one(int effect) => BuzzSequence(const [0],
    durationsMs: const [500],
    profileId: _mg.id,
    profileVersion: _mg.version,
    bakedSteps: [BakedStep(effects: [effect], loop: 1, delayMs: 0)]);

HapticsService _svc(_Port p) =>
    HapticsService(port: p, allowLong: () => false);

BuzzSequence _slotSeq(String key, {int ms = 500}) =>
    BuzzSequence(const [0], durationsMs: [ms], patternId: key);

class _Listener implements PlaybackListener {
  _Listener(this.fn);
  final void Function() fn;
  @override
  void playbackStarted() => fn();
}

class _Stage implements ExampleStage {
  _Stage({
    this.seq,
    required this.onPlay,
    required this.onWait,
    this.onPlaying,
  });
  final BuzzSequence? Function(String)? seq;
  final Future<bool> Function(String, BuzzSequence) onPlay;
  final Future<void> Function(Duration) onWait;
  final void Function(String?)? onPlaying;
  @override
  BuzzSequence? sequenceOf(String k) => seq == null ? _slotSeq(k) : seq!(k);
  @override
  Future<bool> play(String k, BuzzSequence s) => onPlay(k, s);
  @override
  Future<void> wait(Duration d) => onWait(d);
  @override
  void playing(String? k) => onPlaying?.call(k);
}

class _Pulses implements PulseDriver {
  _Pulses(this.onVibrate, this.onWait, {this.stopWhen});
  final Future<void> Function(Duration) onVibrate, onWait;
  final bool Function()? stopWhen;
  @override
  Future<void> vibrate(Duration hold) => onVibrate(hold);
  @override
  Future<void> wait(Duration d) => onWait(d);
  @override
  bool get halted => stopWhen?.call() ?? false;
}

void main() {
  group('1. one cancellation owner, through the real band queue', () {
    test('Stop while the example waits in a quiet window: dismissing the '
        'window plays nothing', () {
      fakeAsync((async) {
        final port = _Port(async);
        final svc = _svc(port)..beginQuiet();
        final cancel = HapticCancel();
        BuzzDelivery? out;
        cancel
            .run(() => svc.deliverExample(_two(), cancel: cancel))
            .then((v) => out = v);
        async.flushMicrotasks();
        expect(port.patterns, isEmpty, reason: 'held by the quiet window');
        cancel.cancel();
        svc.endQuiet();
        async.elapse(const Duration(seconds: 30));
        expect(port.patterns, isEmpty, reason: 'played after Stop');
        expect(out, BuzzDelivery.rejected);
      });
    });

    test('Stop between the commands of a multi-command pattern: the rest is '
        'not written', () {
      fakeAsync((async) {
        final port = _Port(async);
        final svc = _svc(port);
        final cancel = HapticCancel();
        port.onPattern = (i) {
          if (i == 0) cancel.cancel();
        };
        cancel.run(() => svc.deliverExample(_two(), cancel: cancel));
        async.elapse(const Duration(seconds: 30));
        expect(port.patterns, ['[47] x1']);
      });
    });

    test('a newer start replaces the older: only the latest example plays',
        () {
      fakeAsync((async) {
        final port = _Port(async);
        final svc = _svc(port);
        // The band is busy with an ordinary job, so both examples wait.
        svc.deliver(_one(1));
        async.flushMicrotasks();
        final a = HapticCancel(), b = HapticCancel();
        BuzzDelivery? ra, rb;
        a.run(() => svc.deliverExample(_one(2), cancel: a)).then((v) => ra = v);
        a.cancel(); // the newer start cancels the older owner
        b.run(() => svc.deliverExample(_one(3), cancel: b)).then((v) => rb = v);
        async.elapse(const Duration(seconds: 30));
        expect(port.patterns, ['[1] x1', '[3] x1']);
        expect(ra, BuzzDelivery.rejected);
        expect(rb, BuzzDelivery.complete);
      });
    });

    test('after Stop the cap exemption is gone: an ordinary job still waits '
        'for room', () {
      fakeAsync((async) {
        final port = _Port(async);
        final svc = _svc(port);
        final cancel = HapticCancel();
        cancel.run(() => svc.deliverExample(_one(5), cancel: cancel));
        async.elapse(const Duration(seconds: 5));
        cancel.cancel();
        svc.ledger.record(30, DateTime.now());
        svc.deliver(_one(6));
        async.elapse(const Duration(seconds: 5));
        expect(port.patterns, ['[5] x1'], reason: 'ordinary job ignored the cap');
      });
    });
  });

  group('highlight and gaps follow the band, through the real queue', () {
    test('a cue queued behind another is not started until the band takes it, '
        'and it is over after it was delivered', () {
      fakeAsync((async) {
        final port = _Port(async);
        final svc = _svc(port);
        svc.deliver(_two()); // the band is busy
        async.flushMicrotasks();
        final cancel = HapticCancel();
        Duration? startedAt, deliveredAt, overAt;
        final pb = HapticPlayback(_Listener(() => startedAt = async.elapsed));
        svc.deliverExample(_one(7), cancel: cancel, playback: pb).then((_) {
          deliveredAt = async.elapsed;
          pb.over?.then((_) => overAt = async.elapsed);
        });
        async.elapse(const Duration(milliseconds: 100));
        expect(startedAt, isNull, reason: 'highlighted while still queued');
        async.elapse(const Duration(seconds: 60));
        expect(startedAt, isNotNull);
        expect(port.patterns.last, '[7] x1');
        expect(port.at.last, startedAt, reason: 'start = the first write');
        expect(deliveredAt, isNotNull);
        expect(pb.over, isNotNull, reason: 'no playback-end signal');
        expect(overAt, isNotNull);
        expect(overAt!, greaterThan(deliveredAt!),
            reason: 'the cue is still playing when delivery returns');
      });
    });

    test('a cue dropped by Stop never reports a start', () {
      fakeAsync((async) {
        final port = _Port(async);
        final svc = _svc(port);
        svc.deliver(_two());
        async.flushMicrotasks();
        final cancel = HapticCancel();
        var started = false;
        final pb = HapticPlayback(_Listener(() => started = true));
        svc.deliverExample(_one(7), cancel: cancel, playback: pb);
        cancel.cancel();
        async.elapse(const Duration(seconds: 60));
        expect(started, isFalse);
      });
    });

    test('the example waits for the band: highlight on at the start, off at '
        'the end, and the next gap only after', () async {
      final seen = <String?>[];
      final order = <String>[];
      final overGate = Completer<void>();
      HapticPlayback? pb;
      var plays = 0;
      final f = runHapticExample(
          sectionId: 'breathing',
          stage: _Stage(
            onPlay: (k, s) async {
              if (plays++ > 0) return true; // only the first cue is observed
              pb = HapticPlayback.current!..expectStart();
              pb!.endWhen(overGate.future);
              order.add('delivered');
              return true;
            },
            onWait: (d) async => order.add('gap'),
            onPlaying: (k) {
              seen.add(k);
              order.add('hl:$k');
            },
          ),
          cancel: HapticCancel());
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty, reason: 'delivered is not started');
      pb!.started();
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['breath.inhale']);
      expect(order, ['delivered', 'hl:breath.inhale']);
      overGate.complete();
      await f;
      expect(order.take(4), ['delivered', 'hl:breath.inhale', 'hl:null', 'gap']);
    });
  });

  group('2. phone pulses follow elapsed time', () {
    // A fake clock: wait advances virtual time; vibrate stamps it.
    late int now;
    late List<int> at;
    Future<void> wait(Duration d) async => now += d.inMilliseconds;
    final holds = <Duration>[];
    setUp(() {
      now = 0;
      at = [];
      holds.clear();
    });

    _Pulses drv({bool Function()? stopWhen, void Function(Duration)? onV}) =>
        _Pulses((h) async {
          at.add(now);
          holds.add(h);
          onV?.call(h);
        }, wait, stopWhen: stopWhen);

    test('a hold does not pull the next pulse closer', () async {
      await playPhonePulses(
          BuzzSequence(const [0, 1000], durationsMs: const [800, 0]),
          driver: drv());
      expect(at, [0, 1000]);
    });

    test('the pattern ends when its last hold ends', () async {
      await playPhonePulses(
          BuzzSequence(const [0, 1000], durationsMs: const [800, 300]),
          driver: drv());
      expect(at, [0, 1000]);
      expect(now, 1300);
    });

    test('each pulse vibrates for its own hold', () async {
      await playPhonePulses(
          BuzzSequence(const [0, 1000, 2500], durationsMs: const [800, 120, 0]),
          driver: drv());
      expect(holds, [
        const Duration(milliseconds: 800),
        const Duration(milliseconds: 120),
        Duration.zero,
      ]);
    });

    test('stop or the pref being off is checked before every pulse',
        () async {
      var halted = false;
      await playPhonePulses(
          BuzzSequence(const [0, 500, 1000], durationsMs: const [10, 10, 10]),
          driver: drv(stopWhen: () => halted, onV: (_) => halted = true));
      expect(at, [0]);
    });
  });

  group('3. phases and branches have their own gaps', () {
    late List<String> events;
    late List<Duration> waits;
    late Completer<void> gate;
    Future<bool> play(String k, BuzzSequence s) async {
      events.add('play:$k');
      return true;
    }

    Future<void> wait(Duration d) async {
      waits.add(d);
      events.add('wait');
    }

    setUp(() {
      events = [];
      waits = [];
      gate = Completer<void>();
    });

    Future<void> run(String section,
        {BuzzSequence? Function(String)? sequenceOf, HapticCancel? cancel}) =>
        runHapticExample(
            sectionId: section,
            stage: _Stage(seq: sequenceOf, onPlay: play, onWait: wait),
            cancel: cancel ?? HapticCancel());

    test('only the four sequence sections have an example', () {
      for (final s in kHapticSlotSections) {
        final has = {'gestures', 'ecg', 'breathing', 'alarm'}.contains(s.id);
        expect(exampleBranches(s.id).isNotEmpty, has, reason: s.id);
      }
    });

    test('breathing: inhale, hold, exhale, hold with a phase interval between '
        'each, whatever the cue lengths are', () async {
      await run('breathing');
      expect([for (final e in events) if (e.startsWith('play:')) e],
          ['play:breath.inhale', 'play:breath.hold', 'play:breath.exhale',
           'play:breath.hold']);
      expect(waits, hasLength(3));
      expect(waits.every((d) => d >= const Duration(seconds: 2)), isTrue,
          reason: 'a phase lasts seconds, not the cue\'s own length');
      // The gaps do not change with the length of the cue patterns.
      final first = [...waits];
      waits.clear();
      events.clear();
      await run('breathing', sequenceOf: (k) => _slotSeq(k, ms: 3000));
      expect(waits, first);
    });

    test('gestures: two short examples, the separation longer than a step gap',
        () async {
      await run('gestures');
      final plays = [for (final e in events) if (e.startsWith('play:')) e];
      expect(plays, [
        'play:gesture.start', 'play:gesture.followUp', 'play:gesture.confirm',
        'play:gesture.start', 'play:gesture.followUp', 'play:gesture.failed',
      ]);
      // waits: start->followUp, followUp->confirm, [branch], start->..., ...
      expect(waits, hasLength(5));
      final inner = [waits[0], waits[1], waits[3], waits[4]];
      expect(waits[2], greaterThan(inner.reduce((a, b) => a > b ? a : b)),
          reason: 'branches are separate examples, set apart');
      expect(inner.every((d) => d > Duration.zero), isTrue);
    });

    test('ECG: a recording gap sits between started and its outcome', () async {
      await run('ecg');
      final plays = [for (final e in events) if (e.startsWith('play:')) e];
      expect(plays, [
        'play:ecg.started', 'play:ecg.complete',
        'play:ecg.started', 'play:ecg.inconclusive',
        'play:ecg.inconclusiveRetry',
      ]);
      expect(waits.first, greaterThanOrEqualTo(const Duration(seconds: 10)),
          reason: 'the reading takes a while');
    });

    test('alarm: every cue is its own short example', () async {
      await run('alarm');
      final plays = [for (final e in events) if (e.startsWith('play:')) e];
      expect(plays.length, 4);
      expect(waits, hasLength(3));
    });

    test('the highlight is on exactly while a cue plays', () async {
      final seen = <String?>[];
      Future<bool> slowPlay(String k, BuzzSequence s) async {
        events.add('play:$k');
        await gate.future;
        return true;
      }

      final f = runHapticExample(
          sectionId: 'breathing',
          stage: _Stage(onPlay: slowPlay, onWait: wait, onPlaying: seen.add),
          cancel: HapticCancel());
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['breath.inhale']);
      gate.complete();
      await f;
      expect(seen, [
        'breath.inhale', null, 'breath.hold', null, 'breath.exhale', null,
        'breath.hold', null,
      ]);
    });

    test('Stop during a gap ends the run at once', () async {
      final cancel = HapticCancel();
      final never = Completer<void>();
      var done = false;
      final f = runHapticExample(
          sectionId: 'breathing',
          stage: _Stage(onPlay: play, onWait: (d) => never.future),
          cancel: cancel).then((_) => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      cancel.cancel();
      await f;
      expect(done, isTrue);
      expect(events, ['play:breath.inhale'], reason: 'nothing after Stop');
    });
  });
}
