// 8AE.5 P1: the one owner of band haptic delivery.
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

import 'package:clock/clock.dart';

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
  })  : _allowLong = allowLong,
        _now = now ?? (() => clock.now()),
        ledger = ledger ?? BandCommandLedger() {
    _queue = BandHapticQueue(
      ledger: this.ledger,
      waitEnded: _ended.wait,
      onWrite: _ended.reset,
      log: log,
    );
  }

  final BandHapticsPort port;
  final bool Function() _allowLong;
  final DateTime Function() _now;

  /// The band's rolling command limit (30 in 2 minutes), one for every band
  /// haptic job and the lab's probes.
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

  /// The one delivery of a rule's rhythm to the band, for every call site (the
  /// dispatcher's two sequence transports, a preview, a rule alert and the
  /// notification relay): in the band queue, as compiled commands on a band
  /// with a haptic profile, else as per-tap buzzes.
  Future<BuzzDelivery> deliver(BuzzSequence s) => deliverBandSequenceQueued(
        _queue,
        s,
        profile: profile,
        buzz: () => port.buzzBand(),
        buzzForDuration: buzzForDuration,
        writePattern: port.buzzMaverickPattern,
        waitEnded: _ended.wait,
        isConnected: () => port.isConnected,
        maxRuntime: maxRuntime,
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
  }

  // Lab mode (8AF): the Device lab's probes play alone, ahead of waiting
  // alerts, and while the lab screen is open real alerts are held.

  bool get labOpen => _queue.labOpen;

  void beginLab() => _queue.beginLab();

  void endLab() => _queue.endLab();

  Future<bool> runLab(Future<void> Function() body) => _queue.runLab(body);

  /// With the Device lab open, the touch counter's and the gestures' buzzes are
  /// what the lab exercises: they are lab jobs in the band queue, not held
  /// like a real alert.
  Future<T> asLabWork<T>(Future<T> Function() work) =>
      _queue.labOpen ? _queue.asLab(work) : work();
}
