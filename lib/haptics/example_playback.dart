// Example playback: the plan behind a section's "Play example sequence", the
// one cancellation owner per running example, and the phone-pulse scheduler.
//
// Owner of the mutable state: each running example owns one [HapticCancel].
// Stop, a newer example and the page being closed cancel it; the band queue
// (HapticsService.deliverExample) and the phone (playPhonePulses) both look at
// it before every write, so nothing queued or scheduled outlives the example.

import 'dart:async';


import '../notify/buzz_sequence.dart';
import 'band_queue.dart' show BandStop;
import 'phone_vibration.dart';
import 'haptic_slots.dart' show kHapticSlotSections;

/// One cancellation owner per example. Work started inside [run] can find it
/// again with [current], across awaits, without threading it through every
/// seam between the view and the band or phone.
class HapticCancel implements BandStop {
  static const Symbol _zoneKey = #openstrapHapticCancel;

  bool _cancelled = false;
  final Completer<void> _done = Completer<void>();

  bool get cancelled => _cancelled;

  @override
  bool get stopRequested => _cancelled;

  /// Completes when [cancel] is called; lets a wait end at once.
  Future<void> get whenCancelled => _done.future;

  /// Idempotent.
  void cancel() {
    _cancelled = true;
    if (!_done.isCompleted) _done.complete();
  }

  /// The owner of the example this code runs under, if any.
  static HapticCancel? get current {
    final v = Zone.current[_zoneKey];
    return v is HapticCancel ? v : null;
  }

  T run<T>(T Function() work) =>
      runZoned(work, zoneValues: <Object?, Object?>{_zoneKey: this});
}

/// Hears that the band took a cue.
abstract class PlaybackListener {
  void playbackStarted();
}

/// What an example runs on: which pattern a slot plays, how a cue is played
/// and how a pause is waited out (a fake clock in tests), and where the
/// highlight goes. Interfaces, not closures, so every call is a resolved one.
abstract class ExampleStage {
  BuzzSequence? sequenceOf(String slotKey);

  /// Plays one cue; false when nothing could be played (ends the example).
  Future<bool> play(String slotKey, BuzzSequence seq);
  Future<void> wait(Duration d);

  /// The cue now playing, null when none is.
  void playing(String? slotKey);
}

/// What the phone's pulses run on.
abstract class PulseDriver {
  Future<void> vibrate(Duration hold);
  Future<void> wait(Duration d);

  /// Stopped or switched off: no further pulse may start.
  bool get halted;
}

/// The phone seam of the Haptics page: play a pattern, and the "also play on
/// the phone" switch.
abstract class PhoneHaptics {
  Future<void> vibrate(BuzzSequence s);
  void setAlso(bool on);
}

/// The band side of an example cue, as the Haptics page uses it: play it
/// (outside the courtesy limit, cancellable) and wait out a pause.
abstract class ExamplePlayer {
  Future<bool> play(BuzzSequence s);
  Future<void> wait(Duration d);
}

/// One cue's playback, as the band reports it. The runner creates one per cue
/// and runs the player under it; the band path says when the wearer starts to
/// feel the cue ([started]) and when the band is free of it ([endWhen]).
class HapticPlayback {
  HapticPlayback(this._listener);
  static const Symbol _zoneKey = #openstrapHapticPlayback;
  final PlaybackListener _listener;
  bool _expects = false, _started = false;
  Future<void>? _over;

  /// The player will call [started]: the runner must not guess.
  void expectStart() => _expects = true;
  bool get expectsStart => _expects;
  bool get hasStarted => _started;

  /// Idempotent.
  void started() {
    if (_started) return;
    _started = true;
    _listener.playbackStarted();
  }

  /// The band is free of this cue when [over] completes.
  void endWhen(Future<void> over) => _over = over;
  Future<void>? get over => _over;

  static HapticPlayback? get current {
    final v = Zone.current[_zoneKey];
    return v is HapticPlayback ? v : null;
  }

  T run<T>(T Function() work) =>
      runZoned(work, zoneValues: <Object?, Object?>{_zoneKey: this});
}

/// One cue of an example: its slot, and the pause before it plays (after the
/// previous cue has finished playing). The pause is the length of the phase
/// the cue announces, not of any pattern.
class ExampleStep {
  const ExampleStep(this.slotKey, this.gapBeforeMs);
  final String slotKey;
  final int gapBeforeMs;
}

/// A breathing phase.
const int kBreathPhaseGapMs = 4000;

/// The ECG reading takes about this long between "started" and its outcome.
const int kEcgRecordingGapMs = 30000;

/// A gesture's follow-up and outcome come a moment after the previous cue.
const int kGestureStepGapMs = 1500;

/// What the wearer does between an ECG outcome and the retry cue.
const int kEcgRetryGapMs = 3000;

/// Set apart: where one short example ends and the next begins.
const int kExampleBranchGapMs = 3000;

/// The examples of a section, each a short sequence on its own (a success and
/// a failure are never one sequence). Empty for a section with no example.
List<List<ExampleStep>> exampleBranches(String sectionId) =>
    switch (sectionId) {
      'gestures' => const [
          [
            ExampleStep('gesture.start', 0),
            ExampleStep('gesture.followUp', kGestureStepGapMs),
            ExampleStep('gesture.confirm', kGestureStepGapMs),
          ],
          [
            ExampleStep('gesture.start', 0),
            ExampleStep('gesture.followUp', kGestureStepGapMs),
            ExampleStep('gesture.failed', kGestureStepGapMs),
          ],
        ],
      'ecg' => const [
          [
            ExampleStep('ecg.started', 0),
            ExampleStep('ecg.complete', kEcgRecordingGapMs),
          ],
          [
            ExampleStep('ecg.started', 0),
            ExampleStep('ecg.inconclusive', kEcgRecordingGapMs),
            ExampleStep('ecg.inconclusiveRetry', kEcgRetryGapMs),
          ],
        ],
      'breathing' => const [
          [
            ExampleStep('breath.inhale', 0),
            ExampleStep('breath.hold', kBreathPhaseGapMs),
            ExampleStep('breath.exhale', kBreathPhaseGapMs),
            ExampleStep('breath.hold', kBreathPhaseGapMs),
          ],
        ],
      'alarm' => [
          for (final s
              in kHapticSlotSections.firstWhere((s) => s.id == 'alarm').slots)
            [ExampleStep(s.key, 0)],
        ],
      _ => const [],
    };

class _Highlight implements PlaybackListener {
  _Highlight(this.stage, this.cancel, this.slotKey);
  final ExampleStage stage;
  final HapticCancel cancel;
  final String slotKey;
  @override
  void playbackStarted() {
    if (!cancel.cancelled) stage.playing(slotKey);
  }
}

/// Plays [sectionId]'s example on [stage]: cue by cue, the pauses from
/// [exampleBranches]. [ExampleStage.play] returns false when nothing could be
/// played, which ends the example. Stops as soon as [cancel] is cancelled,
/// also in the middle of a pause or a cue.
Future<void> runHapticExample({
  required String sectionId,
  required ExampleStage stage,
  required HapticCancel cancel,
}) async {
  final branches = exampleBranches(sectionId);
  for (var b = 0; b < branches.length; b++) {
    for (var i = 0; i < branches[b].length; i++) {
      final step = branches[b][i];
      final gap = i > 0
          ? step.gapBeforeMs
          : (b > 0 ? kExampleBranchGapMs : 0);
      if (cancel.cancelled) return;
      if (gap > 0) {
        await Future.any<void>([
          stage.wait(Duration(milliseconds: gap)),
          cancel.whenCancelled,
        ]);
        if (cancel.cancelled) return;
      }
      final seq = stage.sequenceOf(step.slotKey);
      if (seq == null) continue;
      // The highlight follows the band: from the moment it takes the cue until
      // it is free of it (a cue is delivered before it has finished playing),
      // and the next pause starts only then. A player that does not report the
      // band (a phone-only cue, a test) is highlighted for as long as its own
      // future runs.
      final playback = HapticPlayback(_Highlight(stage, cancel, step.slotKey));
      try {
        final delivered = playback.run(
            () => stage.play(step.slotKey, seq.copyWith(patternId: step.slotKey)));
        if (!playback.expectsStart) playback.started();
        final ok = await Future.any<bool>(
            [delivered, cancel.whenCancelled.then((_) => false)]);
        if (cancel.cancelled || !ok) return;
        final over = playback.over;
        if (over != null) {
          await Future.any<void>([over, cancel.whenCancelled]);
        }
      } finally {
        stage.playing(null);
      }
      if (cancel.cancelled) return;
    }
  }
}

class _SystemPulses implements PulseDriver {
  _SystemPulses(this.owner);
  final HapticCancel? owner;
  @override
  Future<void> vibrate(Duration hold) => vibratePhoneFor(hold, cancel: owner);
  @override
  Future<void> wait(Duration d) => Future<void>.delayed(d);
  @override
  bool get halted => owner?.cancelled ?? false;
}

/// Plays [sequence] on the phone: one buzz at each tap's start offset, timed
/// against the pattern's own clock (a hold does not move the next tap closer),
/// and the call ends when the last hold would. [PulseDriver.halted] is asked
/// before every pulse. Each pulse vibrates for its own hold.
Future<void> playPhonePulses(BuzzSequence sequence, {PulseDriver? driver}) async {
  final d = driver ?? _SystemPulses(HapticCancel.current);
  var at = 0; // where we are on the pattern's clock, ms
  var end = 0;
  for (var i = 0; i < sequence.length; i++) {
    final start = sequence.offsetsMs[i];
    final stopAt = start + sequence.durationsMs[i];
    if (stopAt > end) end = stopAt;
    if (d.halted) return;
    if (start > at) {
      await d.wait(Duration(milliseconds: start - at));
      at = start;
      if (d.halted) return;
    }
    await d.vibrate(Duration(milliseconds: sequence.durationsMs[i]));
  }
  if (end > at && !d.halted) await d.wait(Duration(milliseconds: end - at));
}
