// A REAL AppState on a gen5 fake link for the main-alarm snooze safety tests.
//
// Sol's review of the snooze branch (alarm-snooze-sol-review-2026-10-07.md)
// criticised the AppState tests for replacing playback and the confirmation
// probe. Nothing is replaced here:
//
//  * events travel the engine's own frame path (an EVENT frame handed to
//    `debugProcessImmediateFrame`), so HAPTICS_TERMINATED(100) reaches the
//    engine's hook with the cause the engine decoded, and every event also
//    reaches `AppState._onLiveEvent` the way the radio delivers it;
//  * the engine's clock IS the test clock, so the phone-clock receipt time of
//    an event and the strap's own stamp can be told apart (a stop delivered
//    minutes after it happened, a replayed tap);
//  * the snooze's haptics go out through the real AlertDispatcher, the real
//    band queue and the real HapticsService, and land as writes on the fake
//    link. Like the real band, the link answers EVERY haptic write with its own
//    HAPTICS_TERMINATED(100) `expired` (that is how our own playback ends);
//  * the snooze store is the real wake_meta store and the confirmed-wake probe
//    is the real DbWakeConfirmationStore (a real sqflite_ffi database).
//
// The one hand-made wire is [wireTermination]: AppState.forTesting does not set
// the engine's termination hook (the production constructor does), so the rig
// does. If the hook's shape changes, this is the one place to follow it.

import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_edge/alarm/snooze/snooze_schedule.dart';
import 'package:openstrap_edge/alarm/snooze/snooze_settings.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart' show DeviceState;
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/ble_haptics_port.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptics_service.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/sync/paired_device.dart' show PairedDevice;
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../support/wake_fakes.dart' show TestClock;

/// One ENTER/EXIT_HIGH_FREQ_SYNC the app asked of the band.
typedef PromptCall = ({
  bool enabled,
  int intervalSeconds,
  String reason,
  DateTime? until,
});

/// What the fake band does when a haptic write ends.
enum AutoEnd {
  /// Nothing: the queue waits out the pattern's playback time.
  none,

  /// The band's ended event reaches the haptics queue only (so a scenario that
  /// is not about our own playback is not disturbed by it).
  queueOnly,

  /// The band's own HAPTICS_TERMINATED `expired` travels the engine path like
  /// any other event: the app hears its own playback end, as on a real band.
  real,
}

/// A gen5 engine on the test clock that records every band-prompt request and
/// refuses (and records) anything that would arm or disable the native alarm.
class SnoozeBandEngine extends BleEngine {
  SnoozeBandEngine({
    required DateTime Function() clock,
    required EventSink onEvent,
    void Function(DeviceState)? onState,
  }) : super(
          onRecord: (_, _) async {},
          onState: onState ?? (_) {},
          clock: clock,
          onEvent: onEvent,
        );

  final List<String> armCalls = [];
  final List<PromptCall> prompts = [];

  /// The wearer's own "cancel the alarm" (Cancel-all): a snooze must never
  /// disable the native alarm, but the wearer may. When true, [disableAlarm]
  /// is recorded in [userDisables] instead of throwing.
  bool allowUserDisable = false;
  final List<String> userDisables = [];

  @override
  Future<void> applyHighFreqWakeWindow({
    required bool enabled,
    required DateTime? targetWake,
    Duration duration = const Duration(seconds: 7200),
    int intervalSeconds = 180,
    String reason = 'wake_window',
  }) {
    prompts.add((
      enabled: enabled && targetWake != null,
      intervalSeconds: intervalSeconds,
      reason: reason,
      until: targetWake,
    ));
    return super.applyHighFreqWakeWindow(
      enabled: enabled,
      targetWake: targetWake,
      duration: duration,
      intervalSeconds: intervalSeconds,
      reason: reason,
    );
  }

  @override
  Future<DateTime?> setAlarm(DateTime when,
      {int index = 0, List<int>? haptics}) async {
    armCalls.add('setAlarm');
    throw StateError('a snooze must never arm the native alarm');
  }

  @override
  Future<void> disableAlarm({int? id}) async {
    if (allowUserDisable) {
      userDisables.add('disableAlarm');
      return;
    }
    armCalls.add('disableAlarm');
    throw StateError('a snooze must never disable the native alarm');
  }

  @override
  Future<AlarmSlotWrite> setAlarmSlot(DateTime when,
      {required int slot}) async {
    armCalls.add('setAlarmSlot');
    throw StateError('a snooze must never arm an alarm slot');
  }

  @override
  Future<bool> clearAlarmSlot({required int slot}) async {
    armCalls.add('clearAlarmSlot');
    throw StateError('a snooze must never clear an alarm slot');
  }
}

Decoded _ack(int seq, int opcode) => Decoded('cmd_response', {
      'opcode': opcode,
      'req_seq': seq,
      'cmd_status': CommandAwaiter.statusSuccess,
    });

/// One event's frame body (what `parseEvent` reads).
Uint8List eventInner(int id, List<int> body,
    {required int ts, int sub = 0}) {
  final inner = Uint8List(12 + body.length);
  inner[0] = PacketType.event;
  inner[1] = 0x07;
  final v = ByteData.sublistView(inner);
  v.setUint16(2, id, Endian.little);
  v.setUint32(4, ts, Endian.little);
  v.setUint16(8, sub, Endian.little);
  v.setUint16(10, body.length, Endian.little);
  inner.setRange(12, inner.length, body);
  return inner;
}

int secOf(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

bool _isHaptic(int op) =>
    op == Cmd.runHapticPatternMaverick || op == Cmd.runHapticsPattern;

/// What a haptic write was, by its body.
enum Played { snoozeConfirm, dismissConfirm, cancelled, reAlarm, other }

/// The command sequence each snooze delivery writes on this band, measured
/// once. Single commands are shared between slots (they are made of the same
/// notes), so a delivery is recognised by its whole sequence.
final List<(Played, List<String>)> _known = [];

class SnoozeBandRig {
  SnoozeBandRig({
    DateTime? start,
    TestClock? clock,
    String generation = 'gen5',
    this.autoEnd = AutoEnd.queueOnly,
    this.autoEndLimit = 60,
    bool unlimitedBudget = false,
    bool wireState = false,
  })  : clock = clock ??
            TestClock(DateTime.fromMillisecondsSinceEpoch(
                (start ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 *
                    1000)),
        band = generation == 'gen5' ? BandProfile.gen5 : BandProfile.gen4 {
    engine = SnoozeBandEngine(
      clock: this.clock.call,
      onEvent: (e) => app.debugOnLiveEvent(e),
      // Production's own state callback (connection changes, the lot) when
      // asked: the default rig swallows engine state, as before.
      onState: wireState
          ? (s) => app.debugFeedEngineState(LocalDb.kPrimaryDeviceId, s)
          : null,
    );
    app = AppState.forTesting(
      engine: engine,
      // The measuring rig plays far more than the band's 30-per-2-minutes
      // budget; every scenario rig keeps the real one.
      haptics: unlimitedBudget
          ? HapticsService(
              port: BleEngineHapticsPort(() => engine),
              allowLong: () => false,
              commandLimit: () => 100000)
          : null,
    );
    app.debugBackground = false;
    app.debugWakeClock = this.clock.call;
    engine.debugInstallFakeLink(
      band: band,
      listening: true,
      onWrite: _onWrite,
    );
    app.paired = PairedDevice('AA:BB:CC:DD:EE:FF', '5AM0000000');
    engine.state.generation = generation;
    engine.state.connection = 'connected';
    wireTermination();
  }

  /// A rig with the database open and the stores warm, so the first event of a
  /// scenario is not slowed by a cold start (which `settle` would mistake for
  /// quiet).
  ///
  /// Snooze is OPT-IN (round 3, design A): [snooze] true switches it on, as the
  /// wearer does in the alarm settings; null leaves the settings untouched (a
  /// user who never opened them: the default). [settings] are extra fields for
  /// the same JSON (`requiredTaps`, `minutes`, ...). The contract used here is
  /// the settings JSON key `enabled`, so these tests need no new constructor.
  static Future<SnoozeBandRig> open({
    DateTime? start,
    TestClock? clock,
    String generation = 'gen5',
    AutoEnd autoEnd = AutoEnd.queueOnly,
    int autoEndLimit = 60,
    bool? snooze = true,
    Map<String, Object?> settings = const {},
    bool wireState = false,
  }) async {
    await LocalDb.instance;
    await NotificationPrefs.load();
    await const DbSnoozeStore().loadState();
    final rig = SnoozeBandRig(
        start: start,
        clock: clock,
        generation: generation,
        autoEnd: autoEnd,
        autoEndLimit: autoEndLimit,
        wireState: wireState);
    if (snooze != null || settings.isNotEmpty) {
      await rig.app.setSnoozeSettings(SnoozeSettings.fromJson({
        ...rig.app.snoozeSettings.toJson(),
        ...settings,
        'enabled': ?snooze,
      }));
    }
    return rig;
  }

  final TestClock clock;
  final BandProfile band;

  /// Every haptic write is followed by the band's own HAPTICS_TERMINATED
  /// `expired`, up to [autoEndLimit] of them (a runaway guard for the tests
  /// that reproduce a feedback loop).
  final AutoEnd autoEnd;
  final int autoEndLimit;
  int _ended = 0;

  late final SnoozeBandEngine engine;
  late final AppState app;
  bool _disposed = false;

  /// Every command that reached the radio.
  final List<({int opcode, List<int> body})> writes = [];

  /// The only hand-made wire (see the file header).
  void wireTermination() {
    engine.onHapticsTerminated = (cause, at, bandAt) {
      app
          .debugOnHapticsTerminated(cause, at: at, bandAt: bandAt)
          .catchError((Object _) {});
    };
  }

  /// The band refuses every write (the link dropped under a queued job).
  bool failWrites = false;

  Future<bool> _onWrite(Uint8List frame) async {
    if (failWrites) return false;
    final inner = parseFrame(frame, profile: band)!.inner;
    final w = (opcode: inner[2], body: inner.sublist(3));
    writes.add(w);
    engine.debugAbsorbDecoded(_ack(inner[1], inner[2]));
    if (_isHaptic(w.opcode)) {
      if (autoEnd != AutoEnd.none && _ended < autoEndLimit) {
        _ended++;
        Timer(const Duration(milliseconds: 2), () {
          if (!_disposed) endPlayback();
        });
      }
    }
    return true;
  }

  /// The haptic writes so far, grouped into deliveries by matching the
  /// measured sequences (longest first); anything else is [Played.other].
  List<Played> get deliveries {
    final bodies = [
      for (final w in writes)
        if (_isHaptic(w.opcode)) _hex(w.body),
    ];
    final known = [..._known]..sort((a, b) => b.$2.length - a.$2.length);
    final out = <Played>[];
    var i = 0;
    while (i < bodies.length) {
      var matched = false;
      for (final (kind, seq) in known) {
        if (i + seq.length > bodies.length) continue;
        var ok = true;
        for (var j = 0; j < seq.length && ok; j++) {
          ok = bodies[i + j] == seq[j];
        }
        if (ok) {
          out.add(kind);
          i += seq.length;
          matched = true;
          break;
        }
      }
      if (!matched) {
        out.add(Played.other);
        i++;
      }
    }
    return out;
  }

  // ── what the band tells the app ─────────────────────────────────────────────

  /// The native alarm fires: EXECUTED(57), stamped [stamp] by the strap.
  Future<void> fire({DateTime? stamp}) async {
    engine.debugProcessImmediateFrame(Frame(
        eventInner(57, const [], ts: secOf(stamp ?? clock.now)), true, true));
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }

  /// HAPTICS_TERMINATED(100) with [code], stamped [stamp] by the strap and
  /// received now (the engine's clock). Empty [body] is an event with no cause
  /// bytes (what a gen4 strap sends, as far as the protocol decodes).
  Future<void> terminate(int code,
      {DateTime? stamp, bool noBody = false, bool quick = false}) async {
    engine.debugProcessImmediateFrame(Frame(
        eventInner(100, noBody ? const [] : [1, code],
            ts: stamp == null ? secOf(clock.now) : secOf(stamp)),
        true,
        true));
    // [quick]: a queue that is held on purpose (budget) never settles.
    await (quick
        ? Future<void>.delayed(const Duration(milliseconds: 150))
        : settle());
  }

  /// The strap's RTC runs [ahead] of the phone's (negative: behind), as the
  /// engine learned from a GET_CLOCK reply: [BleEngine.clockRef] then reads
  /// `driftSec == -ahead`, and a strap stamp S is phone time `S - ahead`. Strap
  /// stamps in a scenario are written `phoneInstant + ahead`.
  void strapRunsAhead(Duration ahead) {
    final wall = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    engine.debugAbsorbDecoded(
        Decoded('cmd_response', {'clock_epoch': wall + ahead.inSeconds}));
  }

  /// The band reports that something we played ended.
  void endPlayback() {
    if (autoEnd == AutoEnd.queueOnly) {
      app.haptics.onBandEvent(StrapEvent(
          eventId: 100,
          tsEpoch: secOf(clock.now),
          receivedAt: clock.now,
          hex: '',
          deviceId: ''));
      return;
    }
    engine.debugProcessImmediateFrame(Frame(
        eventInner(100, [1, HapticsTermination.expired], ts: secOf(clock.now)),
        true,
        true));
  }

  int _tapSeq = 0;
  int _lastTapSec = 0;
  int _lastTapSub = 0;

  /// One band double tap (event 14), stamped [stamp] by the strap and received
  /// now. Every call is a distinct tap (its own sub-second) unless [resend]:
  /// the same event delivered again.
  ///
  /// [sub] pins the sub-second (an event's identity is its stamp and
  /// sub-second): the same event again on a restarted rig.
  Future<void> tap(
      {DateTime? stamp,
      bool resend = false,
      bool quick = false,
      int? sub}) async {
    final sec = resend ? _lastTapSec : secOf(stamp ?? clock.now);
    if (!resend) _tapSeq++;
    final subsec = sub ?? (resend ? _lastTapSub : 100 + 37 * _tapSeq);
    _lastTapSec = sec;
    _lastTapSub = subsec;
    engine.debugProcessImmediateFrame(
        Frame(eventInner(14, const [], ts: sec, sub: subsec), true, true));
    // [quick]: a queue that is held on purpose never settles.
    await (quick
        ? Future<void>.delayed(const Duration(milliseconds: 150))
        : settle());
  }

  /// Wait until nothing is playing and nothing has been written for a moment.
  Future<void> settle() async {
    var quietFor = 0;
    var last = writes.length;
    for (var i = 0; i < 160 && quietFor < 16; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final busy = app.haptics.pending > 0 || writes.length != last;
      last = writes.length;
      quietFor = busy ? 0 : quietFor + 1;
    }
  }

  // ── reading it back ─────────────────────────────────────────────────────────

  int count(Played p) => deliveries.where((x) => x == p).length;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    app.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    BleEngine.resetBandClaimForTest();
  }

  /// Measure the bodies of the four snooze slots on a gen5 band (once per
  /// process; needs the test database and Prefs set up).
  static Future<void> measure() async {
    if (_known.isNotEmpty) return;
    final probe = SnoozeBandRig(
        autoEnd: AutoEnd.queueOnly,
        autoEndLimit: 100000,
        unlimitedBudget: true);
    final found = <(Played, List<String>)>[];
    Future<void> record(Played kind, Future<Object?> Function() play) async {
      final before = probe.writes.length;
      await play();
      await probe.settle();
      found.add((
        kind,
        [
          for (final w in probe.writes.skip(before))
            if (_isHaptic(w.opcode)) _hex(w.body),
        ],
      ));
    }

    await record(Played.snoozeConfirm,
        () => probe.app.gestureCues.slot(kAlarmSnoozeConfirmKey));
    await record(Played.dismissConfirm,
        () => probe.app.gestureCues.slot(kAlarmDismissConfirmKey));
    await record(Played.cancelled,
        () => probe.app.gestureCues.slot(kAlarmSnoozeCancelledKey));
    for (var k = 1; k <= 6; k++) {
      await record(
          Played.reAlarm,
          () => probe.app.haptics.deliver(alarmSequenceFromNotes(
              const SnoozeSchedule(cap: 20).reAlarmCode(k),
              id: systemPatternId(kAlarmReAlarmKey))));
    }
    await probe.dispose();
    _known.addAll(found);
  }
}
