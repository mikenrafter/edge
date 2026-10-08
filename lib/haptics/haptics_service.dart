// The one owner of band haptic delivery.
//
// AppState used to hold the band queue, its command ledger, the band's "ended"
// signal and the delivery helpers, which made them testable only by reading
// its source. HapticsService owns them and takes the band as a
// [BandHapticsPort], so a test can drive the real delivery path against a fake
// or virtual band.
//
// Every band haptic job (a rule's rhythm, a single buzz, a tap ack, a preview,
// the ECG count buzzes) still goes through [runJob], and is still only entered
// from inside an AlertDispatcher delivery (AGENTS.md: buzzes only via
// AlertDispatcher and the band queue). The service builds no dispatcher and
// never decides whether an alert may play; it only plays one.
//
// No Flutter, no BLE: the engine reaches it through the port, and time comes
// from package:clock.

import 'dart:async';

import 'package:clock/clock.dart';

import '../gestures/pattern_transcript.dart' show PatternEntrySession;
import '../gestures/strap_event.dart';
import '../notify/buzz_sequence.dart';
import 'band_queue.dart';
import 'haptic_compiler.dart' show maxRuntimeFor;
import 'haptic_player.dart';
import 'haptic_profile.dart';

/// What the haptics service needs from the connected band. Implemented over
/// the BLE engine in production (BleEngineHapticsPort) and by a virtual band
/// in tests.
abstract class BandHapticsPort {
  bool get isConnected;

  /// The connected band's generation ('gen4', 'gen5'), null when unknown.
  String? get generation;

  /// One buzz of the band; [holdMs] is the hold the rhythm asked for.
  Future<bool> buzzBand({int holdMs = 0});

  /// One compiled Maverick command: [effects] looped [loop] times.
  Future<bool> buzzMaverickPattern(List<int> effects, int loop);
}

class HapticsService {
  HapticsService({
    required this.port,
    required bool Function() allowLong,
    DateTime Function()? now,
    void Function(String line)? log,
    BandCommandLedger? ledger,
    int Function()? commandLimit,
    DateTime Function()? planningNow,
  })  : _allowLong = allowLong,
        _now = now ?? (() => clock.now()),
        ledger = ledger ?? BandCommandLedger(limit: commandLimit) {
    _queue = BandHapticQueue(
      ledger: this.ledger,
      waitEnded: _ended.wait,
      onWrite: _ended.reset,
      log: log,
      minGap: () => Duration(milliseconds: profile?.minVibrationGapMs ?? 0),
      onBusyChanged: (b) => onBusyChanged?.call(b),
      planningNow: planningNow,
    );
  }

  /// Called with true when a band job starts and false when the band is free of
  /// it: the app is playing a pattern. AppState reads this to tell its own
  /// playback ending from the alarm stopping.
  void Function(bool busy)? onBusyChanged;

  /// A band job is running or settling right now.
  bool get playing => _queue.busy;

  final BandHapticsPort port;
  final bool Function() _allowLong;
  final DateTime Function() _now;

  /// The rolling command limit we hold the band to (30 in 2 minutes unless the
  /// developer changed it; our own precaution, see [BandCommandLedger]), one
  /// for every band haptic job and the lab's probes.
  final BandCommandLedger ledger;

  // The band's live "ended" event (100), fed from [onBandEvent].
  final BandEndedSignal _ended = BandEndedSignal();

  late final BandHapticQueue _queue;

  /// The haptic vocabulary of the connected band (null: none measured, today's
  /// per-tap buzz). Read at every delivery, so a band that connects later or
  /// is swapped is followed.
  HapticDeviceProfile? get profile =>
      HapticDeviceProfile.forGeneration(port.generation);

  /// The runtime cap for compiled band haptics: 10 s unless the user allowed
  /// long sequences. Read at every delivery.
  Duration? get maxRuntime => maxRuntimeFor(allowLong: _allowLong());

  /// Commands that may still be sent now under the rolling limit.
  int get commandsLeft => ledger.commandsLeft(_now());

  /// Jobs waiting for the band, including the one playing.
  int get pending => _queue.pending;

  /// Completes when the band has finished everything queued so far: each job
  /// delivered, its playback ended and the minimum gap after it passed (see
  /// [BandHapticQueue.whenIdle]). The moment a gesture's next window may open
  /// after a cue. Never throws.
  Future<void> whenIdle() => _queue.whenIdle();

  /// Run [work] so every band job it queues belongs to gesture [gestureId]: a
  /// gesture's haptics are never played late, and once its first one has
  /// started the rest play whatever the command limit holds (see
  /// [BandHapticQueue.asGesture]).
  T asGesture<T>(String gestureId, T Function() work,
          {bool started = false}) =>
      _queue.asGesture(gestureId, work, started: started);

  /// Run [work] so its band jobs are alarm jobs: never held for the command
  /// window (waking the wearer outranks our own precaution), every write still
  /// counted in the ledger. Only the snooze's re-alarm. See
  /// [BandHapticQueue.asAlarm].
  T asAlarm<T>(T Function() work) => _queue.asAlarm(work);

  /// Run [work] so its band jobs are dropped when [wanted] turns false before
  /// they start. See [BandHapticQueue.asWanted].
  T asWanted<T>(bool Function() wanted, T Function() work) =>
      _queue.asWanted(wanted, work);

  /// Run [work], handing [onQueued] the "band is free of it" future of every
  /// job it queues. See [BandHapticQueue.asObserved].
  T asObserved<T>(void Function(Future<void> over) onQueued, T Function() work) =>
      _queue.asObserved(onQueued, work);

  /// Run [work] with jobs that start now or are rejected. Used for phase cues,
  /// where a late vibration would describe the wrong phase.
  T asImmediate<T>(T Function() work) => _queue.asImmediate(work);

  /// Run [body] alone on the band: after what is playing and ahead of waiting
  /// alerts, with no haptic write from any other job while it runs. The ECG
  /// stream start goes through here, so its commands never meet a vibration
  /// (the band drops or delays a command written while it plays). Null when
  /// the band could not be had. [body]'s own error is rethrown.
  Future<T?> runExclusive<T>(Future<T> Function() body) async {
    T? out;
    await _queue.runLab(() async => out = await body());
    return out;
  }

  /// The one door to the queue: a job of [commands] band commands that must
  /// answer within [timeout] once it starts. Every command is written through
  /// the job's token, which counts it when it happens and refuses it once the
  /// job has timed out. The band is held for [settle] after the last command
  /// (its ended event or that long; one buzz's playback by default).
  Future<BuzzDelivery> runJob(
    int commands,
    Future<BuzzDelivery> Function(BandJobToken job) job, {
    Duration? timeout,
    Duration settle = kBandBuzzPlayback,
  }) =>
      _queue.run(
        job,
        commands: commands,
        timeout: timeout ?? Duration(seconds: 5 + 2 * commands),
        settle: settle,
      );

  // Commands written and waiting to learn when they started: oldest first.
  final List<_StartWatch> _watching = [];

  /// How long after a write the band's own event 60 still counts as that
  /// command's start.
  static const Duration startWindow = Duration(seconds: 1);

  void _watchStart(int command, void Function(HapticPlayStart) onStart) {
    final wrote = _now();
    final w = _StartWatch(command, onStart);
    w.timer = Timer(startWindow, () {
      _watching.remove(w);
      onStart(HapticPlayStart(
        command,
        wrote.add(
          Duration(milliseconds: PatternEntrySession.defaultLeadMs),
        ),
        measured: false,
      ));
    });
    _watching.add(w);
  }

  /// The one delivery of a rule's rhythm to the band, for every call site (the
  /// dispatcher's two sequence transports, a preview, a rule alert and the
  /// notification relay): in the band queue, as compiled commands on a band
  /// with a haptic profile, else as per-tap buzzes. With [onStart] each
  /// compiled command also reports when it started playing: the band's live
  /// event 60 if it arrives within [startWindow] of the write, else the write
  /// time plus the default Bluetooth lead (per-tap buzzes report nothing).
  ///
  /// [onFirstWrite] is called once, when the band has ACCEPTED the delivery's
  /// first compiled command (the wearer starts to feel it). A delivery with no
  /// compiled commands (a band with no haptic profile plays per-tap buzzes)
  /// never calls it; the caller takes a delivery that returns complete as
  /// accepted.
  Future<BuzzDelivery> deliver(
    BuzzSequence s, {
    void Function(HapticPlayStart)? onStart,
    void Function()? onFirstWrite,
  }) => deliverBandSequenceQueued(
        _queue,
        s,
        profile: profile,
        buzz: () => port.buzzBand(),
        buzzForDuration: buzzForDuration,
        writePattern: port.buzzMaverickPattern,
        waitEnded: _ended.wait,
        isConnected: () => port.isConnected,
        maxRuntime: maxRuntime,
        onWritten: onStart == null && onFirstWrite == null
            ? null
            : (i) {
                if (i == 0) onFirstWrite?.call();
                if (onStart != null) _watchStart(i, onStart);
              },
      );

  /// How long a delivery of [s] may take on the connected band.
  Duration sequenceTimeout(BuzzSequence s) =>
      bandSequenceTimeout(s, profile, maxRuntime: maxRuntime);

  /// One band buzz held for [holdMs]. Only ever called from inside a queued
  /// delivery (or the relay's queue job).
  Future<bool> buzzForDuration(int holdMs) => port.buzzBand(holdMs: holdMs);

  /// Feed the band's live events. A live "ended" event (100) releases the next
  /// compiled command and the next queued job; a late one (the band delivers
  /// old events in bursts) must not.
  void onBandEvent(StrapEvent e) {
    if (e.eventId == 100 && e.isLive) _ended.signal();
    if (e.eventId == 60 && e.isLive && _watching.isNotEmpty) {
      final w = _watching.removeAt(0);
      w.timer?.cancel();
      w.onStart(HapticPlayStart(w.command, e.receivedAt, measured: true));
    }
  }

  // Lab mode: the Device lab's probes play alone, ahead of waiting
  // alerts, and while the lab screen is open real alerts are held.

  bool get labOpen => _queue.labOpen;

  void beginLab() => _queue.beginLab();

  void endLab() => _queue.endLab();

  /// A quiet window (plain jobs held, not dropped): see
  /// [BandHapticQueue.beginQuiet].
  void beginQuiet() => _queue.beginQuiet();
  void endQuiet() => _queue.endQuiet();
  bool get quietOpen => _queue.quietOpen;
  void expectQuiet(DateTime? startsAt) => _queue.expectQuiet(startsAt);

  Future<bool> runLab(Future<void> Function() body) => _queue.runLab(body);

  /// With the Device lab open, the touch counter's and the gestures' buzzes are
  /// what the lab exercises: they are lab jobs in the band queue, not held
  /// like a real alert.
  Future<T> asLabWork<T>(Future<T> Function() work) =>
      _queue.labOpen ? _queue.asLab(work) : work();
}

// One written command waiting for its event 60 (or the window's end).
class _StartWatch {
  _StartWatch(this.command, this.onStart);
  final int command;
  final void Function(HapticPlayStart) onStart;
  Timer? timer;
}
