// The band-gesture seam (8AJ seam 3), moved out of AppState with no behaviour
// change. It owns: the gesture dispatcher and the two tap-counting sessions it
// routes a double tap to (ECG sensor touches, repeated double taps), the
// gesture cues (their start / follow-up / confirm / failure deliveries and the
// customised patterns they read), the start-cue-before-ECG-start ordering, the
// pending tap count the dispatcher awaits, and the store of failed gestures.
//
// The dispatcher and both sessions are built in the constructor, as AppState's
// constructors built them before the engine existed. The cue set and the
// failures store are built on first use (the store reads Prefs when built).
//
// It does not own the settings object, the Device lab log, haptics, the alert
// dispatcher, the ECG controller or the BLE engine; they arrive as objects or
// callbacks, and so do the in-app actions (mark a moment, toggle a workout, log
// water) and the database / preference reads. It holds no reference to AppState.
// AppState keeps `_onLiveEvent` (which calls [handle]) and the ECG controller's
// frame fan-out (which calls [onEcgFrame]).
//
// Cues and the ECG stream are band writes through the haptics queue and the
// alert dispatcher; nothing here persists a live ECG packet (AGENTS invariants
// 14 and 15).
import 'dart:async';

import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import '../ecg/ecg_controller.dart';
import '../gestures/double_tap_repeat.dart';
import '../gestures/ecg_tap_begin.dart';
import '../gestures/ecg_tap_session.dart';
import '../gestures/gesture_dispatcher.dart';
import '../gestures/gesture_failures.dart';
import '../gestures/gesture_settings.dart';
import '../gestures/lab_log.dart';
import '../gestures/strap_event.dart';
import '../gestures/tap_names.dart';
import '../haptics/gesture_cues.dart';
import '../haptics/haptic_slots.dart'
    show decodeCueAssignments, resolveCuePatterns;
import '../haptics/haptics_service.dart';
import '../notify/alert_dispatcher.dart';
import '../notify/buzz_sequence.dart';
import '../haptics/pattern_store.dart' show HapticPatternStore;
import '../sync/sync_policy.dart' show ClockRef;

class GestureController {
  GestureController({
    required GestureSettings settings,
    required HapticsService haptics,
    required DeviceLabLog deviceLab,
    required AlertDispatcher Function() alertDispatcher,
    required EcgController Function() ecg,
    required bool Function() ecgSupported,
    required ClockRef? Function() clockRef,
    required void Function(String line) log,
    required GestureHandler onMarkMoment,
    required GestureHandler onWorkoutToggle,
    required GestureHandler onLogWater,
    required Future<void> Function(EcgGestureRecord record) recordEcgSession,
    required Future<HapticPatternStore> Function() loadPatterns,
    required String Function() readCueAssignments,
    required String Function() readFailures,
    required Future<void> Function(String json) writeFailures,
  })  : _settings = settings,
        _haptics = haptics,
        _deviceLab = deviceLab,
        _alertDispatcher = alertDispatcher,
        _ecg = ecg,
        _clockRef = clockRef,
        _loadPatterns = loadPatterns,
        _readCueAssignments = readCueAssignments,
        _readFailures = readFailures,
        _writeFailures = writeFailures,
        _recordEcgSession = recordEcgSession {
    _repeatTapSession = _newRepeatSession();
    _ecgTapSession = _newEcgSession();
    dispatcher = GestureDispatcher(
      settings: settings,
      log: log,
      onMarkMoment: onMarkMoment,
      onWorkoutToggle: onWorkoutToggle,
      onLogWater: onLogWater,
      ecgSupported: ecgSupported,
      onEcgTap: _ecgTapSession.start,
      onCountTaps: _countTaps,
      repeatSession: _repeatTapSession,
      onFailed: (e, kind, reason) {
        // The route's trace says nothing of a failed action: say it, so the
        // saved log tells the story.
        deviceLab.addStep('Gesture failed ($reason).');
        _recordGestureFailure(e, kind, reason);
      },
    );
  }

  final GestureSettings _settings;
  final HapticsService _haptics;
  final DeviceLabLog _deviceLab;
  final AlertDispatcher Function() _alertDispatcher;
  final EcgController Function() _ecg;
  final ClockRef? Function() _clockRef;
  final Future<HapticPatternStore> Function() _loadPatterns;
  final String Function() _readCueAssignments;
  final String Function() _readFailures;
  final Future<void> Function(String json) _writeFailures;
  final Future<void> Function(EcgGestureRecord record) _recordEcgSession;

  // Today nothing stops the sessions, the dispatcher, the failures store or the
  // lab log when AppState is disposed (a gesture in flight outlives it, and
  // seam3_lifecycle_test pins that). Tracked as a follow-up; this controller
  // has no dispose until that is decided.

  late final GestureDispatcher dispatcher;
  late final DoubleTapRepeatSession _repeatTapSession;
  late final EcgTapSession _ecgTapSession;

  /// Hand one live strap event to the dispatcher; never throws.
  Future<List<GestureOutcome>> handle(StrapEvent e) => dispatcher.handle(e);

  /// The ECG controller's frame hook: a live packet for the touch counter.
  void onEcgFrame(LabradorR17 r) => _ecgTapSession.onFrame(r);

  /// A gesture holds the ECG stream (the Device lab's "ECG is busy" test).
  bool get ecgTapActive => _ecgTapSession.active;

  /// 8AK: the gestures that failed to activate, newest first, kept across
  /// restarts. Home shows the newest undismissed one; Settings lists them all.
  /// Built on first use, after Prefs is loaded.
  late final GestureFailureStore failures = GestureFailureStore(
    read: _readFailures,
    write: _writeFailures,
  );

  /// Keep one failed gesture with the Device lab's log as it stands (the trace,
  /// not the raw ECG packets: those would crowd it out of the record). Never
  /// throws.
  void _recordGestureFailure(
      StrapEvent tap, GestureFailureKind kind, String reason) {
    try {
      failures.record(
        kind: kind,
        reason: reason,
        gestureId: gestureFailureId(tap),
        log: _deviceLab.toPlainText(withPackets: false),
      );
    } catch (_) {}
  }

  /// The slower multi-tap method: more firmware double taps inside a window.
  /// Needs no ECG, so any band can use it.
  DoubleTapRepeatSession _newRepeatSession() => DoubleTapRepeatSession(
        maxTaps: () => _settings.repeatTapMax,
        window: () => _settings.repeatTapWindow,
        // The same cues as the ECG route (8AK): the start cue once, one
        // follow-up per further double tap, the confirm at the end; each window
        // opens only after its cue was played.
        startBuzz: _ecgTapStartBuzz,
        buzz: (id) => _ecgTapBuzz(1, id),
        confirmBuzz: _ecgTapConfirmBuzz,
        bandIdle: _haptics.whenIdle,
        step: _deviceLab.addStep,
        onStarted: (tap, settings) => _deviceLab.beginSession(
            method: 'More double taps',
            settings: settings,
            tapAt: tap.receivedAt),
        onFinished: (count) {
          _deviceLab.endSession(count: count);
          if (_settings.repeatTapsLab) {
            _deviceLab.addStep('Result: $count taps. This is a draft; no '
                'action was run.');
          }
        },
      );

  /// 8L: counts ECG-sensor touches after a live double tap.
  EcgTapSession _newEcgSession() => EcgTapSession(
        beginStream: _beginEcgForTap,
        // 8AN fast mode: the same start; it leaves out the raw-save by asking
        // the session which mode the gesture in flight runs.
        beginFastStream: _beginEcgForTap,
        tapMode: () => _settings.ecgTapMode,
        startBuzz: _ecgTapStartBuzz,
        endStream: () async {
          try {
            await _ecg().cancel();
          } catch (_) {}
        },
        isStreamAlive: () => _ecg().isCapturing,
        buzz: _ecgTapBuzz,
        confirmBuzz: _ecgTapConfirmBuzz,
        bandIdle: _haptics.whenIdle,
        failBuzz: _ecgTapFailBuzz,
        onFailed: (tap, reason) =>
            _recordGestureFailure(tap, GestureFailureKind.ecg, reason),
        maxTaps: () => _settings.ecgTapMax,
        thresholds: () => _settings.ecgTapThresholds,
        onStarted: (tap, settings) => _deviceLab.beginSession(
            method: 'ECG sensor touches',
            settings: settings,
            tapAt: tap.receivedAt),
        onFinished: (count, reason) {
          // Release the dispatcher first: a throw from the lab log below must
          // not leave the tap's action chain awaiting a count that never comes.
          final waiting = _tapCount;
          _tapCount = null;
          if (waiting != null && !waiting.isCompleted) waiting.complete(count);
          final lab = _settings.ecgOnDoubleTap;
          _deviceLab.addStep(count != null
              ? 'Result: ${ecgTapCountName(count)}.${lab ? ' This is a draft; no action was run.' : ''}'
              : 'Result: abandoned ($reason). No action was run.');
          _deviceLab.endSession(count: count, reason: reason);
        },
        step: _deviceLab.addStep,
        // 8V: every packet, raw, for the lab's replay export (RAM only).
        onPacket: _deviceLab.addPacket,
        // 8V: in the lab, watch the sensor for 3 s after the count is decided.
        postRoll: () => _settings.ecgOnDoubleTap
            ? const Duration(seconds: 3)
            : Duration.zero,
        // 8N: the stream makes the band save raw ECG that history sync delivers
        // later; keep the interval (no samples) so it is labelled gesture
        // contact.
        recordSession: (r) async {
          await _recordEcgSession(r);
        },
        strapNow: () {
          final ref = _clockRef();
          if (ref == null) return null;
          // strap = wall - (wall - device) at the correlation instant.
          return DateTime.now().millisecondsSinceEpoch ~/ 1000 - ref.driftSec;
        },
      );

  /// The gesture the dispatcher is waiting on (outside the lab), completed by
  /// the session's onFinished. Cleared on every exit.
  Completer<int?>? _tapCount;

  /// [GestureDispatcher.onCountTaps]: run the session for this tap and wait for
  /// its final count (null = abandoned). One gesture at a time: a second double
  /// tap while one is counting is ignored. Throws when the stream did not start.
  Future<int?> _countTaps(StrapEvent e) async {
    if (_ecgTapSession.active) return null;
    final done = _tapCount = Completer<int?>();
    try {
      await _ecgTapSession.start(e);
    } catch (_) {
      _tapCount = null;
      rethrow;
    }
    return done.future;
  }

  /// Start the ECG stream for a tap through the existing controller. The wrist
  /// is the one remembered from a normal ECG reading; without it the lab says
  /// so instead of guessing which electrode the AFE should read.
  ///
  /// The gesture's generation is checked after every await (finding G): the
  /// session abandons a slow start after its begin timeout, but Future.timeout
  /// does not cancel this work, so a late start would otherwise switch the
  /// band's ECG on for a gesture that is gone.
  ///
  /// 8AK: the band seems to answer a command written while it vibrates late or
  /// not at all (the 2026-10-04 lab log: four of five starts refused at
  /// PREPARE, a second buzz reply landing in the middle of it). So the start cue
  /// is written first, the start waits for that write, and then PREPARE and
  /// START run as one exclusive job of the band queue: after the cue has
  /// played, ahead of waiting alerts, with no haptic write of any other job
  /// until they are done.
  Future<bool> _beginEcgForTap() async {
    final gen = _ecgTapSession.generation; // set before this is called
    await _startCueWritten();
    final started = await _haptics.runExclusive(() => beginEcgForTap(
          isCurrent: () =>
              _ecgTapSession.active && _ecgTapSession.generation == gen,
          isCapturing: () => _ecg().isCapturing,
          lookupWrist: () async {
            final serial = _ecg().transport.serial;
            return serial == null ? null : await _ecg().guard.wrist(serial);
          },
          // persist: false: a long touch can reach a normal terminal, and a
          // gesture must never leave an ECG reading behind (invariant 14).
          begin: (wrist) => _ecg().begin(wrist,
              persist: false,
              rawSave: !_ecgTapSession.fast,
              trace: _deviceLab.addStep),
          captureEpoch: () => _ecg().captureEpoch,
          cancel: () => _ecg().cancel(),
          note: _deviceLab.addStep,
        ).timeout(const Duration(seconds: 30)));
    return started ?? false;
  }

  // The start cue of the gesture in flight, for [_startCueWritten].
  Future<bool>? _startCueSent;

  /// Wait (at most 3 s) for the start cue's write, so it is the first thing the
  /// band gets. Never throws; no cue, or one that failed, is no wait.
  Future<void> _startCueWritten() async {
    final cue = _startCueSent;
    _startCueSent = null;
    if (cue == null) return;
    try {
      await cue.timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// One gesture cue as a dispatcher delivery (live-only band alert, own event
  /// id, never a straight engine write): [play] is the cue, in its own job of
  /// the band queue. The wearer's cue assignments are read inside the delivery,
  /// beside the dispatcher's own claim steps rather than ahead of them (8AI), so
  /// a cue is not held up reading them.
  Future<bool> _gestureCue(
    String eventId,
    Future<BuzzDelivery> Function() play,
  ) async {
    final now = DateTime.now();
    final loaded = loadCues();
    final r = await _haptics.asLabWork(() => _alertDispatcher().dispatch(
          kEcgTapRule,
          eventId: eventId,
          sourceTime: now,
          historical: false,
          bandTimeout: const Duration(seconds: 10),
          bandDelivery: () async {
            await loaded;
            return play();
          },
        ));
    return r.targets.contains('band');
  }

  /// 8AI: the gesture-start cue, sent the moment the double tap is accepted;
  /// the session fires it without waiting and starts the ECG stream at once.
  Future<bool> _ecgTapStartBuzz(String eventId) =>
      _startCueSent = _gestureCue(eventId, cues.start);

  /// One follow-up cue per count increment (3, 4, 5), queued as soon as the
  /// touch is seen: never the start cue again, never a recount. [pulses] is
  /// always 1.
  Future<bool> _ecgTapBuzz(int pulses, String eventId) =>
      _gestureCue(eventId, cues.followUp);

  /// The confirm cue of a counted gesture, once, when it ends.
  Future<bool> _ecgTapConfirmBuzz(String eventId) =>
      _gestureCue(eventId, cues.confirm);

  /// The failure cue of an abandoned gesture, "Gesture failed" (8AK): the
  /// wearer's assigned pattern, else the built-in (today's long failure buzz).
  /// One path with the other cues, so the dispatcher's claim and deadline steps
  /// apply.
  Future<bool> _ecgTapFailBuzz(String eventId) =>
      _gestureCue(eventId, cues.failed);

  // The wearer's customised gesture cues, read just before a cue plays so
  // GestureCues can take them synchronously. A cue that cannot be read plays
  // its built-in default.
  Map<String, BuzzSequence> _cuePatterns = const {};

  /// Re-read the wearer's cue assignments and patterns. Never throws.
  Future<void> loadCues() async {
    try {
      final store = await _loadPatterns();
      // A pattern the wearer put on a cue (8AI) wins over the cue's built-in.
      _cuePatterns = resolveCuePatterns(
        store,
        decodeCueAssignments(_readCueAssignments()),
      );
    } catch (_) {}
  }

  late final GestureCues cues =
      GestureCues(haptics: _haptics, patternFor: (k) => _cuePatterns[k]);
}
