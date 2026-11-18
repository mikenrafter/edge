// Owns the gesture dispatcher, repeated-double-tap session, cues and failures.
import 'dart:async';

import '../gestures/double_tap_repeat.dart';
import '../gestures/gesture_dispatcher.dart';
import '../gestures/gesture_failures.dart';
import '../gestures/gesture_settings.dart';
import '../gestures/lab_log.dart';
import '../gestures/strap_event.dart';
import '../gestures/time_buzz.dart';
import '../haptics/gesture_cues.dart';
import '../haptics/haptic_slots.dart'
    show decodeCueAssignments, resolveCuePatterns;
import '../haptics/haptics_service.dart';
import '../notify/alert_dispatcher.dart';
import '../notify/alert_rule.dart';
import '../notify/buzz_sequence.dart';
import '../haptics/pattern_store.dart' show HapticPatternStore;

// Cues inside a gesture the wearer started always play (owner m88).
const AlertRule kGestureCueRule = AlertRule(
  id: 'gesture_cue',
  kind: 'gesture',
  destinations: AlertRule.band,
  executionMode: AlertExecutionMode.phoneLive,
  historicalReplay: AlertHistoricalReplay.liveOnly,
  fallback: AlertFallback.none,
  staleAfter: kLiveEventWindow,
  channelPolicyId: 'gesture',
);

class GestureController {
  GestureController({
    required GestureSettings settings,
    required HapticsService haptics,
    required DeviceLabLog deviceLab,
    required AlertDispatcher Function() alertDispatcher,
    required void Function(String line) log,
    required GestureHandler onMarkMoment,
    required GestureHandler onWorkoutToggle,
    SlotActionHandler? onSlotAction,
    required Future<HapticPatternStore> Function() loadPatterns,
    required String Function() readCueAssignments,
    required String Function() readFailures,
    required Future<void> Function(String json) writeFailures,
    bool Function()? labHold,
    DateTime Function()? now,
  })  : _settings = settings,
        _log = log,
        _haptics = haptics,
        _deviceLab = deviceLab,
        _alertDispatcher = alertDispatcher,
        _loadPatterns = loadPatterns,
        _readCueAssignments = readCueAssignments,
        _readFailures = readFailures,
        _writeFailures = writeFailures {
    _repeatTapSession = _newRepeatSession();
    dispatcher = GestureDispatcher(
      settings: settings,
      log: log,
      onMarkMoment: onMarkMoment,
      onWorkoutToggle: onWorkoutToggle,
      onSlotAction: onSlotAction,
      onTellTime: _tellTime,
      now: now,
      repeatSession: _repeatTapSession,
      onFailed: (e, kind, reason) {
        // The route's trace says nothing of a failed action: say it, so the
        // saved log tells the story.
        deviceLab.addStep('Gesture failed ($reason).');
        _recordGestureFailure(e, kind, reason);
      },
      labHold: labHold,
      // A gesture whose haptics cannot play is not acted on: no action without
      // its confirming buzz. Read at every live double tap.
      hapticsAvailable: () => haptics.commandsLeft > 0,
    );
  }

  final GestureSettings _settings;
  final void Function(String line) _log;
  final HapticsService _haptics;
  final DeviceLabLog _deviceLab;
  final AlertDispatcher Function() _alertDispatcher;
  final Future<HapticPatternStore> Function() _loadPatterns;
  final String Function() _readCueAssignments;
  final String Function() _readFailures;
  final Future<void> Function(String json) _writeFailures;

  late final GestureDispatcher dispatcher;
  late final DoubleTapRepeatSession _repeatTapSession;

  bool _disposed = false;

  /// Stop the repeat window before disposing the haptics owner.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    dispatcher.dispose();
    _repeatTapSession.dispose();
  }

  /// Hand one live strap event to the dispatcher; never throws.
  Future<List<GestureOutcome>> handle(StrapEvent e) => _disposed
      ? Future<List<GestureOutcome>>.value(const [])
      : dispatcher.handle(e);

  /// The gestures that failed to activate, newest first, kept across
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

  /// Tell the time: [elements] played on the band as ONE gesture. The chunks of
  /// [toBuzzChunks] are queued one after another under the tap's own gesture
  /// id, inside a single dispatcher delivery, so the band queue treats them as
  /// one gesture: the first needs room in the haptic budget when its turn
  /// comes (else nothing is written and the action fails), and once it has
  /// started every later chunk plays whatever the window holds. Each chunk is
  /// queued only when the one before it is done and keeps the silence that
  /// fell between them as its lead (after the previous playback ended).
  ///
  /// Completes as soon as the band accepted the first write, not when the last
  /// buzz ends (a 12 PM time plays ~20 s, past the dispatcher's action timeout);
  /// throws when the band took no part of it (the budget had no room, not
  /// connected, every write refused), so the claim goes back and the
  /// failure is recorded. A later chunk that fails cannot undo what was felt;
  /// it is logged.
  Future<void> _tellTime(StrapEvent e, List<TimeBuzzElement> elements) async {
    if (_disposed) return;
    final chunks = toBuzzChunks(elements, _haptics.profile);
    if (chunks.isEmpty) throw StateError('tell_time: nothing to play');
    // An unset RTC gives every tap one identity; receipt time keeps the
    // second time from being swallowed by the first one's claim.
    final id = '${e.plausible ? e.identity : '${e.identity}:'
        '${e.receivedAt.microsecondsSinceEpoch}'}:time';
    var need = const Duration(seconds: 10);
    for (final c in chunks) {
      need += _haptics.sequenceTimeout(c.sequence) +
          Duration(milliseconds: c.waitBeforeMs + 2000);
    }
    final started = Completer<bool>();
    void began(bool ok) {
      if (!started.isCompleted) started.complete(ok);
    }

    final delivery = _haptics.asGesture(
        id,
        () => _haptics.asLabWork(() => _alertDispatcher().dispatch(
              kGestureCueRule,
              eventId: id,
              sourceTime: DateTime.now(),
              historical: false,
              bandTimeout: need,
              bandDelivery: () async {
                for (var i = 0; i < chunks.length; i++) {
                  if (_disposed) return i == 0 ? BuzzDelivery.rejected : BuzzDelivery.partial;
                  final r = await _haptics.deliver(
                    chunks[i].sequence,
                    lead: Duration(milliseconds: chunks[i].waitBeforeMs),
                    onFirstWrite: i == 0 ? () => began(true) : null,
                  );
                  if (r != BuzzDelivery.complete) {
                    return i == 0 && r == BuzzDelivery.rejected
                        ? BuzzDelivery.rejected
                        : BuzzDelivery.partial;
                  }
                }
                return BuzzDelivery.complete;
              },
            )));
    final rest = delivery.then<void>((r) {
      // Never started (not connected, suppressed, claimed): the action failed.
      began(false);
      if (!r.targets.contains('band')) {
        _log('[gesture] tell_time: delivery ended: ${r.suppressionReason ?? 'not played'}');
      }
    }, onError: (Object err) {
      began(false);
      _log('[gesture] tell_time: delivery failed: $err');
    });
    if (!await started.future) {
      await rest;
      throw StateError('the band took no part of the time');
    }
    unawaited(rest);
  }

  /// The slower multi-tap method: more firmware double taps inside a window.
  DoubleTapRepeatSession _newRepeatSession() => DoubleTapRepeatSession(
        maxTaps: () => _settings.repeatTapMax,
        window: () => _settings.repeatTapWindow,
        // The start cue once, one
        // follow-up per further double tap, the confirm at the end; each window
        // opens only after its cue was played.
        startBuzz: _tapStartBuzz,
        buzz: (id) => _tapFollowUpBuzz(id),
        confirmBuzz: _tapConfirmBuzz,
        bandIdle: _haptics.whenIdle,
        step: _deviceLab.addStep,
        onStarted: (tap, settings) => _deviceLab.beginSession(
            method: 'More double taps',
            settings: settings,
            tapAt: tap.receivedAt),
        onFinished: (count) {
          _deviceLab.endSession(count: count);
          if (_settings.repeatTapsLab) {
            _deviceLab.addStep('Result: $count taps. No action was run.');
          }
        },
      );

  /// One gesture cue as a dispatcher delivery (live-only band alert, own event
  /// id, never a straight engine write): [play] is the cue, in its own job of
  /// the band queue. The wearer's cue assignments are read inside the delivery,
  /// beside the dispatcher's own claim steps rather than ahead of them, so
  /// a cue is not held up reading them.
  Future<bool> _gestureCue(
    String eventId,
    Future<BuzzDelivery> Function() play,
  ) async {
    if (_disposed) return false;
    final now = DateTime.now();
    final loaded = loadCues();
    // Every cue of one gesture shares its base id: the queue plays them all
    // once the first has started, and never plays one late.
    final r = await _haptics.asGesture(
        _gestureIdOf(eventId),
        () => _haptics.asLabWork(() => _alertDispatcher().dispatch(
              kGestureCueRule,
              eventId: eventId,
              sourceTime: now,
              historical: false,
              bandTimeout: const Duration(seconds: 10),
              bandDelivery: () async {
                await loaded;
                if (_disposed) return BuzzDelivery.rejected;
                return play();
              },
            )));
    return r.targets.contains('band');
  }

  static String _gestureIdOf(String eventId) {
    final at = eventId.lastIndexOf(':rep:');
    return at > 0 ? eventId.substring(0, at) : eventId;
  }

  Future<bool> _tapStartBuzz(String eventId) =>
      _gestureCue(eventId, cues.start);

  Future<bool> _tapFollowUpBuzz(String eventId) =>
      _gestureCue(eventId, cues.followUp);

  /// The "gyro ready" cue, once, when the IMU stream turns usable. The same
  /// dispatcher delivery as the other cues (live-only, own event id), so a
  /// Device lab recording and the future motion gestures buzz the same way.
  Future<bool> readyCue(String eventId) => _gestureCue(eventId, cues.ready);

  /// The confirm cue of a counted gesture, once, when it ends.
  Future<bool> _tapConfirmBuzz(String eventId) =>
      _gestureCue(eventId, cues.confirm);

  // The wearer's customised gesture cues, read just before a cue plays so
  // GestureCues can take them synchronously. A cue that cannot be read plays
  // its built-in default.
  Map<String, BuzzSequence> _cuePatterns = const {};

  // The cue slots the wearer put a stored pattern on (as of the last read).
  Set<String> _cueAssigned = const {};

  /// Whether the wearer assigned a pattern to cue slot [key], as of the last
  /// [loadCues]. A 4.0 uses this to keep its own per-phase buzzes for the
  /// breathing slots nobody assigned.
  bool cueAssigned(String key) => _cueAssigned.contains(key);

  /// Re-read the wearer's cue assignments and patterns. Never throws.
  Future<void> loadCues() async {
    try {
      final store = await _loadPatterns();
      // A pattern the wearer put on a cue wins over the cue's built-in.
      final given = decodeCueAssignments(_readCueAssignments());
      _cuePatterns = resolveCuePatterns(store, given);
      _cueAssigned = {
        for (final e in given.entries)
          if (store.byId(e.value) != null) e.key,
      };
    } catch (_) {}
  }

  late final GestureCues cues =
      GestureCues(haptics: _haptics, patternFor: (k) => _cuePatterns[k]);
}
