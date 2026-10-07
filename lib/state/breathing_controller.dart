// The guided-breathing half of the workout seam, moved out of
// AppState with no behaviour change. It owns the breathing session and the
// quiet windows either side of it: the flags, the pattern / target / start
// time, the last coherence result and error, the RR frame buffer the live
// router fills, the 20 s coherence recompute, the history read, the phase and
// completion cues, and the Live Activity stop-button hand-off.
//
// It is a separate controller from the workout because it shares no state with
// it: a workout and a breathing session only meet through the host's "live
// session active" predicates, which read the flags here and on the workout.
//
// It does not own the live-frame router (AppState hands each RR-bearing frame
// to [tapFrame]), the live-stream owner set (it nudges through `nudgeLive`),
// the BLE engine, the repository or the alert dispatcher; they arrive as
// callbacks. It holds no reference to AppState. The breathing Live Activity,
// the widget flag and the database are static services, called directly as
// before.
//
// RAM only except the banked session row and its two window RMSSDs: nothing
// here persists a live frame (AGENTS invariant 14).
import 'dart:async';


import '../data/db.dart';
import '../data/local_repository.dart';
import '../haptics/builtin_patterns.dart'
    show kBreathDoneKey, kBreathExhaleKey, kBreathHoldKey, kBreathInhaleKey;
import '../live/breathing_live_activity.dart';
import '../notify/alert_dispatcher.dart';
import '../stress/breath_phases.dart';
import '../widget/widget_service.dart';

class BreathingController {
  BreathingController({
    required bool Function() isConnected,
    required Future<void> Function() reconcileLiveStreams,
    required void Function() nudgeLive,
    required LocalRepository? Function() repo,
    required Future<AlertDeliveryOutcome> Function(String ruleId,
            {int? pattern})
        dispatchBandAlert,
    required void Function() notify,
    Future<bool> Function(String slotKey, {required bool skipIfBusy})? playCue,
    DateTime Function()? now,
  })  : _playCue = playCue,
        _now = now ?? DateTime.now,
        _isConnected = isConnected,
        _reconcileLiveStreams = reconcileLiveStreams,
        _nudgeLive = nudgeLive,
        _repo = repo,
        _dispatchBandAlert = dispatchBandAlert,
        _notify = notify;

  final bool Function() _isConnected;
  final Future<void> Function() _reconcileLiveStreams;
  final void Function() _nudgeLive;
  final LocalRepository? Function() _repo;
  final Future<AlertDeliveryOutcome> Function(String ruleId, {int? pattern})
      _dispatchBandAlert;
  final void Function() _notify;

  /// The wall clock the session's start, end and banked length are read from.
  final DateTime Function() _now;

  /// Plays breathing cue slot [slotKey] (see haptic_slots.dart) as one
  /// dispatcher delivery and answers true, or answers false when the slot has
  /// nothing of its own to play (a 4.0 with no pattern assigned), in which
  /// case the per-phase buzz below plays. With [skipIfBusy] a cue that would
  /// start while the band is still playing something is dropped, not queued
  /// behind it. Null: every cue is the per-phase buzz.
  final Future<bool> Function(String slotKey, {required bool skipIfBusy})?
      _playCue;

  // ── guided-breathing cardiac coherence ──────────────────────────────────────
  // User taps "begin breathing session": enable live RR-bearing streams,
  // collect frames continuously in _breathingFrames (tapped from _onLiveFrame),
  // and periodically recompute McCraty & Zayas
  // 2014 coherence over the FULL accumulated series so far — not a sliding
  // window, so the score stabilizes as more clean data comes in rather than
  // jittering on a short recent slice. Replaces the screen's old
  // Random()-fabricated score. Ephemeral — nothing persisted.
  static const Duration _breathingRecomputeInterval = Duration(seconds: 20);
  bool breathingActive = false;

  /// The pattern the running session is pacing to. Coherence is only computed
  /// for a pattern that claims a resonance frequency — see
  /// [BreathPattern.coherenceRated].
  BreathPattern breathingPattern = kBreathPatterns.first;

  /// When the running session started, for the persisted history row.
  DateTime? _breathingStartedAt;

  /// When the running session began, for a view that mounts mid-session.
  DateTime? get breathingStartedAt => _breathingStartedAt;

  /// What the running session was asked to run for, or null for an open one.
  Duration? get breathingTarget => _breathingTarget;

  /// What the session was SUPPOSED to run for, or null for an open one.
  ///
  /// Held because the banked duration is otherwise wall-clock: the screen's
  /// ticker is muted while the app is suspended, so a two-minute session
  /// backgrounded at 0:30 and resumed forty minutes later stopped on resume
  /// and banked a forty-minute session, with a coherence score drawn mostly
  /// from unpaced breathing. One backgrounded session would poison the trend
  /// this history exists to build.
  Duration? _breathingTarget;
  Map<String, dynamic>?
  breathingResult; // last {ok, ratio, score, peak_hz, n_beats, confidence, tier, note}
  String? breathingError;
  final List<String> _breathingFrames = [];
  Timer? _breathingRecomputeTimer;

  // ── MIND-06 · the quiet windows either side of the paced block ─────────────
  //
  // The lifecycle, not the statistics, is what blocked this. The live streams
  // were enabled by [startBreathingSession] and torn down by
  // [stopBreathingSession], and the frame buffer was cleared at start — so the
  // two minutes BEFORE the pacing had no streams and the two minutes AFTER it
  // had neither streams nor a buffer. A window therefore brackets the session
  // rather than living inside it: it owns the stream enable, survives the
  // paced block's start and stop, and hands the buffer over at each boundary.
  //
  // Only the two quiet windows are stored. The paced block's own RMSSD is not
  // computed here and has nowhere to go — see `lib/stress/session_effect.dart`.

  /// True while a quiet window is capturing outside the paced block.
  bool breathingWindowOpen = false;

  /// The frames of the PRE window, taken at the moment pacing began.
  List<String>? _preWindowFrames;

  /// The banked row the windows belong to, or null when the paced block was
  /// too short to bank one (in which case the windows have nothing to attach
  /// to and are dropped).
  int? _windowRowStartedAt;

  /// Open the quiet window: HR stream on, frames buffering, no pacing yet.
  /// The window is an HR owner in its own right (see [LiveStreamController.owners]), so the
  /// paced block's stop cannot turn off a stream the post window still reads.
  Future<void> openBreathingWindow() async {
    if (breathingWindowOpen || breathingActive) return;
    if (!_isConnected()) {
      breathingError = 'Connect your band first.';
      _notify();
      return;
    }
    breathingWindowOpen = true;
    _preWindowFrames = null;
    _windowRowStartedAt = null;
    _breathingFrames.clear();
    _notify();
    try {
      await _reconcileLiveStreams();
    } catch (_) {
      /* best-effort; we still collect whatever arrives */
    }
  }

  /// Close the window, measure both quiet stretches and attach them to the
  /// banked session. Safe to call when no window is open.
  ///
  /// RMSSD comes from the SAME seam the live spot-check uses, so the two
  /// windows are cleaned and estimated identically — a pre window scored one
  /// way and a post window another would produce a difference that is entirely
  /// method.
  Future<void> closeBreathingWindow() async {
    if (!breathingWindowOpen) return;
    breathingWindowOpen = false;
    final post = List<String>.from(_breathingFrames);
    final pre = _preWindowFrames;
    final row = _windowRowStartedAt;
    _preWindowFrames = null;
    _windowRowStartedAt = null;
    _breathingFrames.clear();
    _nudgeLive(); // the window's HR ownership ends here
    _notify();
    if (row == null || pre == null) return;
    final before = await _windowRmssd(pre);
    final after = await _windowRmssd(post);
    // Nothing readable either side is not a measurement — leave both columns
    // NULL rather than writing a row the paired test would then have to drop.
    if (before == null && after == null) return;
    try {
      await LocalDb.updateBreathingWindows(
        startedAt: row,
        preRmssd: before,
        postRmssd: after,
      );
    } catch (_) {
      /* best-effort; a lost window is one dropped pair, not a broken session */
    }
  }

  Future<double?> _windowRmssd(List<String> frames) async {
    final r = _repo();
    if (r == null || frames.isEmpty) return null;
    try {
      final res = await r.spotCheck(frames);
      return res['ok'] == true ? (res['rmssd'] as num?)?.toDouble() : null;
    } catch (_) {
      return null;
    }
  }

  /// Begin a guided-breathing session. Requires a connected band.
  Future<void> startBreathingSession({
    BreathPattern? pattern,
    Duration? target,
  }) async {
    if (breathingActive) return;
    if (!_isConnected()) {
      breathingError = 'Connect your band first.';
      _notify();
      return;
    }
    breathingPattern = pattern ?? breathingPattern;
    _breathingTarget = target;
    breathingActive = true;
    breathingResult = null;
    breathingError = null;
    // MIND-06 — hand the pre window over before the buffer is reused for the
    // paced block. The clear is still right; what was missing is that the
    // frames it throws away are the "before" measurement.
    if (breathingWindowOpen) {
      _preWindowFrames = List<String>.from(_breathingFrames);
    }
    _breathingFrames.clear();
    final startedAt = _now();
    _breathingStartedAt = startedAt;
    _notify();
    unawaited(BreathingLiveActivity.start(startedAt: startedAt));
    try {
      // The session is an HR owner (see [LiveStreamController.owners]); the engine's
      // reconciler serialises this against any in-flight transition, e.g. a
      // background downgrade still writing when a band double-tap starts the
      // session — the exact race that used to leave the session without its
      // stream.
      await _reconcileLiveStreams();
    } catch (_) {
      /* best-effort; we still collect whatever arrives */
    }
    _breathingRecomputeTimer?.cancel();
    _breathingRecomputeTimer = Timer.periodic(_breathingRecomputeInterval, (_) {
      unawaited(_recomputeBreathingCoherence());
    });
  }

  /// End the guided-breathing session and bank it.
  ///
  /// A session shorter than a minute is NOT recorded. Opening the screen and
  /// closing it again is not a breathing session, and a history full of
  /// 4-second entries would bury the real ones.
  Future<void> stopBreathingSession() async {
    if (!breathingActive) return;
    _breathingRecomputeTimer?.cancel();
    _breathingRecomputeTimer = null;
    breathingActive = false;
    _nudgeLive(); // the session's HR ownership ends; an open window keeps it
    unawaited(BreathingLiveActivity.end());

    final started = _breathingStartedAt;
    final target = _breathingTarget;
    _breathingStartedAt = null;
    _breathingTarget = null;
    if (started != null) {
      final ended = _now();
      var seconds = ended.difference(started).inSeconds;
      // Clamped to what was asked for. Overshoot is always suspension, never
      // extra breathing — the pacer stops the moment the app leaves the
      // foreground, so any second past the target was spent doing something
      // else.
      if (target != null && seconds > target.inSeconds) {
        seconds = target.inSeconds;
      }
      if (seconds >= 60) {
        final res = breathingResult;
        final scored = res != null && res['ok'] == true;
        // Null unless the pattern is one a coherence score means something
        // for AND the estimator actually produced one.
        final rated = breathingPattern.coherenceRated && scored;
        final put = LocalDb.putBreathingSession(
          startedAt: started.millisecondsSinceEpoch,
          endedAt: ended.millisecondsSinceEpoch,
          pattern: breathingPattern.key,
          seconds: seconds,
          coherence: rated ? (res['score'] as num?)?.toDouble() : null,
          confidence: rated ? (res['confidence'] as num?)?.toDouble() : null,
        );
        if (breathingWindowOpen) {
          // AWAITED only here: the post window's UPDATE lands on this row, and
          // an UPDATE that overtakes its own INSERT writes nothing and reports
          // success. Everywhere else the insert stays off the stop path.
          _windowRowStartedAt = started.millisecondsSinceEpoch;
          await put;
        } else {
          unawaited(put);
        }
      }
    }
    // MIND-06 — the post window starts here and reads the same buffer, so the
    // paced block's frames have to go. They are not part of either quiet
    // window and RMSSD over them would be the RSA artefact this feature exists
    // to avoid reporting.
    if (breathingWindowOpen) _breathingFrames.clear();
    _notify();
  }

  /// Past sessions, newest first.
  Future<List<Map<String, dynamic>>> breathingHistory({int limit = 30}) =>
      LocalDb.breathingSessions(limit: limit);

  /// The cue slot and the 4.0's per-phase buzz pattern for [kind]. The one
  /// mapping: the Bedtime session plays its cues through it too.
  static (String slot, int pattern) cueFor(BreathPhaseKind kind) =>
      switch (kind) {
        BreathPhaseKind.inhale || BreathPhaseKind.work => (kBreathInhaleKey, 1),
        BreathPhaseKind.exhale || BreathPhaseKind.rest => (kBreathExhaleKey, 0),
        BreathPhaseKind.holdIn ||
        BreathPhaseKind.holdOut =>
          (kBreathHoldKey, 2),
      };

  /// Buzz the strap at a breathing or interval phase boundary.
  ///
  /// Distinct cues per phase so it is legible without looking: the slots
  /// `breath.inhale|exhale|hold` (an interval's work plays the inhale cue, its
  /// rest the exhale cue, both holds the hold cue), each the wearer's pattern
  /// or a built-in of the band's own vocabulary. A band the slots do not
  /// reach (a 4.0, nothing assigned) keeps its per-tap buzzes: a longer buzz
  /// to breathe in, a shorter one to breathe out, a double for a hold. Never
  /// throws and never awaits the caller: this fires from a frame callback, and
  /// a momentary disconnect must not interrupt the session or stall the
  /// animation. A cue that would start while the band still plays the last is
  /// skipped, not queued: a phase shorter than its cue gets no cue rather than
  /// one that arrives late and overlaps the next.
  void buzzBreathPhase(BreathPhaseKind kind) {
    if (!_isConnected()) return;
    final (slot, pattern) = cueFor(kind);
    unawaited(_cue(slot, skipIfBusy: true, legacy: () =>
        _dispatchBandAlert('breath', pattern: pattern)));
  }

  /// The whole session is over, as opposed to one phase of it.
  ///
  /// Its own cue (`breath.done`) rather than a repeat of the phase cue:
  /// repeated `runHapticsPattern` frames serialize on the BLE write chain and
  /// arrive milliseconds apart, re-triggering the firmware's haptic engine
  /// while it is still playing, so N of them are felt as one, and the user
  /// cannot tell "round over" from "session over". Never skipped: nothing
  /// follows it, so it waits for the band instead.
  void buzzSessionComplete() {
    if (!_isConnected()) return;
    unawaited(_cue(kBreathDoneKey, skipIfBusy: false, legacy: () =>
        _dispatchBandAlert('breath', pattern: 4)));
  }

  // The slot's cue, else [legacy]. With no slot hook the legacy call is made
  // before the first await, as it always was.
  Future<void> _cue(
    String slot, {
    required bool skipIfBusy,
    required Future<Object?> Function() legacy,
  }) async {
    final play = _playCue;
    if (play != null) {
      try {
        if (await play(slot, skipIfBusy: skipIfBusy)) return;
      } catch (_) {
        /* a slot that cannot play leaves the cue to the per-tap buzz */
      }
    }
    await legacy();
  }

  Future<void> _recomputeBreathingCoherence() async {
    if (!breathingActive || _repo() == null) return;
    final frames = List<String>.from(_breathingFrames);
    if (frames.isEmpty) return;
    try {
      final res = await _repo()!.breathingCoherence(
        frames,
        // The pattern's own paced frequency, not a constant — box breathing at
        // 3.75 breaths/min scored against a 5.5 breaths/min target would read
        // as incoherent no matter how well it was done.
        pacedHz: breathingPattern.pacedHz,
      );
      if (!breathingActive) return; // session ended while we awaited
      breathingResult = res;
      _notify();
      final score = res['ok'] == true ? (res['score'] as num?)?.toDouble() : null;
      unawaited(BreathingLiveActivity.update(coherenceScore: score));
    } catch (_) {
      /* best-effort; keep the last good result on screen rather than erroring */
    }
  }

  /// One RR-bearing live frame from the host's router (0x28 compact HR, 0x2B
  /// R10). Kept only while a session or a quiet window is open, and bounded.
  /// Cleared at each session start.
  void tapFrame(String hex) {
    if (breathingActive || breathingWindowOpen) {
      if (_breathingFrames.length < 8000) _breathingFrames.add(hex);
    }
  }

  /// Same idea as the workout's Live Activity Finish button, for the breathing
  /// session's own Live Activity stop button (EndBreathingIntent sets
  /// `end_breathing_session` — a separate flag so the two Live Activities'
  /// stop buttons never collide). Call on app resume.
  Future<void> maybeStopBreathingFromLiveActivity() async {
    // Consume FIRST, the same latch fix the workout's has: a stop tapped on a
    // Live Activity that outlived the app must not stay latched on disk.
    final asked = await WidgetService.consumeEndBreathingFlag();
    if (!asked) return;
    if (breathingActive) await stopBreathingSession();
    // Ending from the Live Activity ends the whole thing, quiet windows
    // included — otherwise the streams stay on with no screen left to close
    // them, which is the leak `PopScope` was added to the screen to fix.
    await closeBreathingWindow();
  }

  /// Cancel the recompute timer. The session itself is not ended: that is
  /// today's AppState.dispose behaviour, pinned by the breathing controller tests and
  /// tracked as a follow-up.
  void dispose() {
    _breathingRecomputeTimer?.cancel();
    _breathingRecomputeTimer = null;
  }

  // Test seams. They carry no @visibleForTesting here because AppState's own
  // delegates (which keep the annotation) forward to them; only tests and those
  // delegates may use them.

  /// Arm the recompute timer so a test can prove [dispose] cancels it.
  void debugArmTimer() {
    _breathingRecomputeTimer ??=
        Timer.periodic(_breathingRecomputeInterval, (_) {});
  }

  /// The buffered RR frames.
  List<String> get debugFrames => List.unmodifiable(_breathingFrames);
}
