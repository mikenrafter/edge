// WHOOP MG ECG — the lifecycle owner of one reading.
//
// Owns: the transport lease, the PREPARE/START/RESTART/CLEANUP sequence
// through [EcgTransport], the durable may-be-active guard, the pure reducer
// ([reduceEcg]) fed with live R17, the accepted window, the live-preview
// ring, the capture timeout, cancel/pause/link-loss/parse-failure exits, the
// durable save (before "completed" is ever shown), cleanup on EVERY exit,
// and the ordinary history sync request that follows.
//
// Single-flight: every public entry bumps an epoch, every continuation after
// an await re-checks it, and there is exactly ONE cleanup per capture.
// Frames are gated on the lease's link generation, on `_armed`, and are
// dropped while a RESTART list is in flight.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import 'ecg_cues.dart';
import 'ecg_guard_store.dart';
import 'ecg_models.dart';
import 'ecg_policy.dart';
import 'ecg_recovery.dart';
import 'ecg_result.dart';
import 'ecg_transport.dart';
import 'ecg_waveform_buffer.dart';

enum EcgCapturePhase {
  idle,
  incompatible,
  disconnected,
  busy,
  recovering,
  preparing,
  starting,
  waiting,
  active,
  contactLost,
  restarting,
  saving,
  cleaningUp,
  completed,
  unreadable,
  inconclusiveRetry,
  cancelled,
  failed,
}

/// What the capture screen renders. Immutable snapshot.
class EcgCaptureState {
  final EcgCapturePhase phase;
  final EcgWrist? wrist;
  final int progress;
  final int? liveHr;
  final int quality;
  final int interruptions;

  /// Why the phase is [EcgCapturePhase.busy] / [EcgCapturePhase.failed].
  final String? reason;

  /// The saved reading, once [EcgCapturePhase.completed].
  final String? readingId;

  /// The band's unreadable-reason mask for [EcgCapturePhase.unreadable].
  final int unreadableMask;

  /// True when a cleanup member failed: the durable guard is retained and
  /// the next connection retries the cleanup triplet.
  final bool cleanupIncomplete;

  /// What was saved, once something was: complete, a final inconclusive, or a
  /// partial (stopped by background/timeout). Null while capturing and when
  /// nothing was saved. RED stub (ecg-features): the controller never sets it.
  final EcgReadingStatus? result;

  /// The saved result's real metrics (see ecgMetricsOf), empty until saved.
  final List<EcgMetric> metrics;

  const EcgCaptureState({
    this.phase = EcgCapturePhase.idle,
    this.wrist,
    this.progress = 0,
    this.liveHr,
    this.quality = 0,
    this.interruptions = 0,
    this.reason,
    this.readingId,
    this.unreadableMask = 0,
    this.cleanupIncomplete = false,
    this.result,
    this.metrics = const [],
  });

  EcgCaptureState copyWith({
    EcgCapturePhase? phase,
    EcgWrist? wrist,
    int? progress,
    int? liveHr,
    bool clearLiveHr = false,
    int? quality,
    int? interruptions,
    String? reason,
    String? readingId,
    int? unreadableMask,
    bool? cleanupIncomplete,
    EcgReadingStatus? result,
    List<EcgMetric>? metrics,
  }) => EcgCaptureState(
    phase: phase ?? this.phase,
    wrist: wrist ?? this.wrist,
    progress: progress ?? this.progress,
    liveHr: clearLiveHr ? null : (liveHr ?? this.liveHr),
    quality: quality ?? this.quality,
    interruptions: interruptions ?? this.interruptions,
    reason: reason ?? this.reason,
    readingId: readingId ?? this.readingId,
    unreadableMask: unreadableMask ?? this.unreadableMask,
    cleanupIncomplete: cleanupIncomplete ?? this.cleanupIncomplete,
    result: result ?? this.result,
    metrics: metrics ?? this.metrics,
  );

  /// The phases in which the band may be generating: from the first ON
  /// write until cleanup finished.
  bool get capturing => switch (phase) {
    EcgCapturePhase.recovering ||
    EcgCapturePhase.preparing ||
    EcgCapturePhase.starting ||
    EcgCapturePhase.waiting ||
    EcgCapturePhase.active ||
    EcgCapturePhase.contactLost ||
    EcgCapturePhase.restarting ||
    EcgCapturePhase.saving ||
    EcgCapturePhase.cleaningUp => true,
    _ => false,
  };
}

typedef EcgSave =
    Future<void> Function(EcgReading reading, List<EcgAcceptedPacket> packets);

class EcgController extends ChangeNotifier {
  final EcgTransport transport;
  final EcgGuardStore guard;
  final EcgSave save;

  /// A reason the app is busy with another live feature (workout, breathing
  /// session), or null when ECG may start.
  final String? Function() busyReason;
  final Future<void> Function(String owner) holdScreen;
  final Future<void> Function(String owner) releaseScreen;
  final void Function(String) log;
  final Duration captureTimeout;
  final int Function() nowMs;

  /// Whether the accepted waveform is kept with a saved reading (the wearer's
  /// "Keep waveform" choice; default false). When false the controller hands
  /// [save] NO packets: only the derived metrics and quality are stored. Read
  /// when the result is saved.
  final bool Function() keepWaveform;

  /// Plays the ECG haptic cue [slotKey] (`ecg.*`, see EcgCueTracker). Never
  /// called for a gesture-owned (`persist: false`) capture, whose cues are the
  /// gesture ones. A cue that throws is logged and ignored.
  final void Function(String slotKey)? onCue;

  static const String screenOwner = 'ecg';

  /// Every live packet that passes the armed gate, before the reducer sees it.
  /// A tap on the stream for a consumer that only reads (the Device lab's
  /// touch counter); it must not throw and is never awaited.
  void Function(LabradorR17 r17)? onFrame;

  EcgController({
    required this.transport,
    required this.guard,
    required this.save,
    required this.busyReason,
    required this.holdScreen,
    required this.releaseScreen,
    void Function(String)? log,
    this.captureTimeout = const Duration(seconds: 120),
    int Function()? nowMs,
    bool Function()? keepWaveform,
    this.onCue,
  }) : keepWaveform = keepWaveform ?? (() => false),
       log = log ?? ((_) {}),
       nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  EcgCaptureState _state = const EcgCaptureState();
  EcgCaptureState get state => _state;

  /// The live-preview ring (RAM only) and its repaint coalescer.
  final EcgWaveformBuffer live = EcgWaveformBuffer();
  final EcgPreviewScheduler preview = EcgPreviewScheduler();

  int _epoch = 0;
  EcgLeaseHandle? _lease;
  int _gen = -1;
  String? _serial;
  EcgWrist? _wrist;
  bool _armed = false;
  bool _restartInFlight = false;
  bool _cleanupDone = false;
  bool _disposed = false;
  bool _screenHeld = false;
  bool _persist = true;
  void Function(String line)? _trace;
  bool _restartNoted = false;
  int _retriesUsed = 0;
  int? _windowStartMs;
  EcgReducerState _reducer = const EcgReducerState.initial();
  StreamSubscription<EcgTransportEvent>? _sub;
  Timer? _timer;
  final EcgCueTracker _cues = EcgCueTracker();

  /// The one completion of the current capture (see [_exitOnce]). Reset by
  /// [begin].
  Future<void>? _exiting;

  /// "Keep waveform" as it was when this capture began. It decides both whether
  /// PREPARE asks the band for its raw save and whether the accepted window is
  /// handed to [save]; taking it once keeps the two in step.
  bool _keep = false;

  // What the accepted window's packets carried, for a partial result: the
  // live heart rates (the band sends 0 for "none") and the last quality. They
  // restart with the window (EcgClear).
  int _hrSum = 0;
  int _hrN = 0;
  int _lastQuality = 0;

  bool get isCapturing => _lease != null;

  /// Changes on every [begin] and every cancel, so a consumer that started a
  /// capture can later tell it is still THAT capture (the tap-counting gesture
  /// stops a late start it began, never an ECG the user began since).
  int get captureEpoch => _epoch;

  @visibleForTesting
  EcgReducerState get reducerState => _reducer;

  // A capture that ends after dispose (its cleanup was still running) must
  // still finish: notifying a disposed notifier throws in debug and would end
  // the exit path before the lease is released.
  void _set(EcgCaptureState s) {
    _state = s;
    if (!_disposed) notifyListeners();
    _cue(s);
  }

  // The haptic cue this state calls for, if any. Never for a gesture-owned
  // capture (its cues are the gesture ones) and never able to break an exit.
  void _cue(EcgCaptureState s) {
    final play = onCue;
    if (!_persist || _disposed || play == null) return;
    final slot = _cues.observe(s);
    if (slot == null) return;
    try {
      play(slot);
    } catch (e) {
      log('[ECG] cue $slot failed: $e');
    }
  }

  bool _stale(int epoch) => _epoch != epoch || _lease == null;

  void _note(String line) {
    try {
      _trace?.call(line);
    } catch (_) {}
  }

  /// Start a reading on [wrist]. Every precondition failure lands in a
  /// terminal phase with a reason; nothing is written to the band before
  /// the durable guard is acknowledged.
  ///
  /// [persist] false is for a consumer that only reads the live stream (the
  /// tap-counting gesture): whatever terminal the band reaches, nothing is
  /// saved, no sync is requested and the capture ends `cancelled`/`gesture`.
  /// The reading's own rules also stand down, because lifting a finger is the
  /// gesture, not a fault: contact lost three times does not end the capture,
  /// and the explicit RESTART a reading sends when the band's S2 state drops
  /// is not sent (a restart stops forwarding packets while it runs, and makes
  /// the band start its signal over). Both are reported through [trace].
  /// It is set per begin, so it can never outlive the capture it was for.
  ///
  /// [trace] gets one line per start stage with the time it took (Device lab).
  Future<void> begin(
    EcgWrist wrist, {
    bool persist = true,
    void Function(String line)? trace,
  }) async {
    if (_disposed || _lease != null) return; // single-flight
    final epoch = ++_epoch;
    _persist = persist;
    _trace = trace;
    _restartNoted = false;
    _cues.reset();
    _hrSum = 0;
    _hrN = 0;
    _lastQuality = 0;
    final clock = Stopwatch()..start();
    var lastMs = 0;
    void stage(String what) {
      final now = clock.elapsedMilliseconds;
      _note('ECG start: $what (+${now - lastMs} ms, $now ms in).');
      lastMs = now;
    }

    live.clear();
    preview.markDirty();
    if (!transport.isReady) {
      _set(EcgCaptureState(phase: EcgCapturePhase.disconnected, wrist: wrist));
      return;
    }
    if (!transport.isMaverick) {
      _set(EcgCaptureState(phase: EcgCapturePhase.incompatible, wrist: wrist));
      return;
    }
    final busy = busyReason();
    if (busy != null) {
      _set(
        EcgCaptureState(
          phase: EcgCapturePhase.busy,
          wrist: wrist,
          reason: busy,
        ),
      );
      return;
    }
    final serial = transport.serial;
    if (serial == null || serial.isEmpty) {
      _set(
        EcgCaptureState(
          phase: EcgCapturePhase.failed,
          wrist: wrist,
          reason: 'no_serial',
        ),
      );
      return;
    }
    final lease = transport.acquire();
    if (lease == null) {
      _set(
        EcgCaptureState(
          phase: EcgCapturePhase.busy,
          wrist: wrist,
          reason: 'transport',
        ),
      );
      return;
    }
    _lease = lease;
    _gen = lease.linkGeneration;
    _serial = serial;
    _wrist = wrist;
    _cleanupDone = false;
    _exiting = null;
    _keep = keepWaveform();
    _armed = false;
    _restartInFlight = false;
    _windowStartMs = null;
    final retries = _retriesUsed;
    _retriesUsed = 0;
    _reducer = EcgReducerState.initial(retriesUsed: retries);
    _set(EcgCaptureState(phase: EcgCapturePhase.preparing, wrist: wrist));
    try {
      await guard.setWrist(serial, wrist);
      stage('wrist saved');
      if (await guard.isActive(serial)) {
        _set(_state.copyWith(phase: EcgCapturePhase.recovering));
        final r = await ecgRecoverRetainedGuard(
          guard: guard,
          serial: serial,
          cleanup: () => transport.cleanup(lease),
          log: log,
        );
        if (_stale(epoch)) return;
        if (r == EcgRecoveryOutcome.retained) {
          await _finish(epoch, EcgCapturePhase.failed, reason: 'recovery');
          return;
        }
        _set(_state.copyWith(phase: EcgCapturePhase.preparing));
      }
      stage('guard checked');
      await transport.cancelHistory(lease);
      if (_stale(epoch)) return;
      stage('history sync paused');
      // The durable guard goes down BEFORE the first ON write and is
      // acknowledged; a write that did not land does not get a band enabled.
      if (!await guard.setActive(serial)) {
        await _finish(epoch, EcgCapturePhase.failed, reason: 'guard');
        return;
      }
      if (_stale(epoch)) return;
      stage('guard set');
      // Subscribe BEFORE any generation write: the first post-START packet
      // can arrive at the write/response boundary.
      _sub ??= transport.events.listen(_onEvent);
      // A reading asks the band to keep the raw recording only if the wearer
      // keeps the waveform; the tap-counting gesture keeps its raw save (its
      // packets are tagged as gesture contact when history delivers them).
      final prep = await transport.prepare(
        lease,
        wrist,
        rawSave: _persist ? _keep : true,
      );
      if (_stale(epoch)) return;
      stage('prepare answered (${prep.allSucceeded ? 'accepted' : 'refused'})');
      if (!prep.allSucceeded) {
        log('[ECG] PREPARE not accepted: $prep');
        await _finish(epoch, EcgCapturePhase.failed, reason: 'prepare');
        return;
      }
      _armed = true;
      _set(_state.copyWith(phase: EcgCapturePhase.starting));
      _screenHeld = true;
      await holdScreen(screenOwner);
      final st = await transport.start(lease);
      if (_stale(epoch)) return;
      stage('start answered (${st.allSucceeded ? 'accepted' : 'refused'})');
      if (!st.allSucceeded) {
        log('[ECG] START not accepted: $st');
        _armed = false;
        await _finish(epoch, EcgCapturePhase.failed, reason: 'start');
        return;
      }
      _timer = Timer(captureTimeout, () {
        unawaited(
          _finishWithPartial(epoch, EcgCapturePhase.failed, 'timeout'),
        );
      });
      if (_state.phase == EcgCapturePhase.starting) {
        _set(_state.copyWith(phase: EcgCapturePhase.waiting));
      }
    } catch (e, st) {
      log('[ECG] begin failed: $e\n$st');
      if (!_stale(epoch)) {
        await _finish(epoch, EcgCapturePhase.failed, reason: 'error');
      }
    }
  }

  /// After a first-attempt inconclusive result: one more reading, with the
  /// retry budget spent so a second inconclusive is final.
  Future<void> retry() async {
    if (_lease != null || _state.phase != EcgCapturePhase.inconclusiveRetry) {
      return;
    }
    final wrist = _wrist;
    if (wrist == null) return;
    _retriesUsed = 1;
    await begin(wrist);
  }

  /// Back / explicit cancel. Cleans up; the band stops generating.
  Future<void> cancel() async {
    if (_lease == null || _disposed) return;
    final running = _exiting;
    if (running != null) return running; // the capture is already ending
    final epoch = ++_epoch;
    await _finish(epoch, EcgCapturePhase.cancelled, reason: 'cancelled');
  }

  /// The app went to the background mid-capture — the capture stops (the
  /// official screen stops on ON_PAUSE too) and what was recorded is saved as
  /// a partial reading ([_finishWithPartial]).
  Future<void> onAppPaused() async {
    if (_lease == null || _disposed) return;
    final running = _exiting;
    if (running != null) return running; // the capture is already ending
    final epoch = ++_epoch;
    await _finishWithPartial(epoch, EcgCapturePhase.cancelled, 'paused');
  }

  /// Awaited teardown for the owner (AppState shutdown, tests).
  Future<void> shutdown() async {
    await cancel();
    await _sub?.cancel();
    _sub = null;
  }

  /// A capture still holding the band at dispose gets its one cleanup now (the
  /// owner cannot await it): the stop is written and the lease and screen hold
  /// are released without notifying. One already cleaning up carries on alone.
  @override
  void dispose() {
    _disposed = true;
    if (_lease != null && _exiting == null) {
      unawaited(
        _finish(++_epoch, EcgCapturePhase.cancelled, reason: 'disposed')
            .catchError((Object _) {}),
      );
    }
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(EcgTransportEvent e) {
    if (e.linkGeneration != _gen || _lease == null) return;
    final epoch = _epoch;
    switch (e) {
      case EcgTransportLinkDown():
        unawaited(
          _finishWithPartial(epoch, EcgCapturePhase.failed, 'disconnected'),
        );
      case EcgTransportMalformed():
        if (_armed) {
          unawaited(
            _finish(epoch, EcgCapturePhase.failed, reason: 'malformed'),
          );
        }
      case EcgTransportFrame():
        _onFrame(epoch, e);
    }
  }

  void _onFrame(int epoch, EcgTransportFrame e) {
    if (!_armed || _restartInFlight) return;
    final r17 = e.r17;
    try {
      onFrame?.call(r17);
    } catch (err) {
      log('[ECG] frame listener failed: $err');
    }
    // The live preview shows real samples from the moment the pipeline is
    // armed (zeros before contact); only the accepted window is ever saved.
    live.push(r17.samples);
    preview.markDirty();
    final before = _reducer;
    final step = reduceEcg(before, r17);
    _reducer = step.state;
    if (before.accepted.isEmpty && step.state.accepted.isNotEmpty) {
      _windowStartMs = nowMs();
    }
    var next = _state.copyWith(
      progress: r17.progress == 255 ? _state.progress : r17.progress,
      liveHr: r17.liveHr > 0 ? r17.liveHr : null,
      clearLiveHr: r17.liveHr == 0,
      quality: r17.quality,
      interruptions: step.state.interruptions,
    );
    switch (step.state.phase) {
      case EcgPhase.waiting:
        if (_state.phase != EcgCapturePhase.starting) {
          next = next.copyWith(phase: EcgCapturePhase.waiting);
        }
      case EcgPhase.active:
        next = next.copyWith(phase: EcgCapturePhase.active);
      case EcgPhase.contactLost:
        next = next.copyWith(phase: EcgCapturePhase.contactLost);
      case EcgPhase.done:
        break;
    }
    _set(next);
    for (final effect in step.effects) {
      switch (effect) {
        case EcgAppend(:final packet):
          if (packet.liveHr > 0) {
            _hrSum += packet.liveHr;
            _hrN++;
          }
          if (packet.quality > 0) _lastQuality = packet.quality;
        case EcgClear():
          _hrSum = 0;
          _hrN = 0;
          _lastQuality = 0;
        case EcgAppendPlaceholder():
          break;
        case EcgSendRestart():
          if (_persist) {
            unawaited(_restart(epoch));
          } else if (!_restartNoted) {
            // Once per capture: the packet lines show the S2 state each time.
            _restartNoted = true;
            _note('ECG: the band\'s S2 state dropped with contact on; a '
                'reading would send RESTART here, the gesture does not.');
          }
        case EcgFail(:final reason):
          if (!_persist && reason == 'interruptions') {
            _note('ECG: contact lost ${_reducer.interruptions} times; a '
                'reading would give up here, the gesture keeps streaming.');
          } else {
            unawaited(_finish(epoch, EcgCapturePhase.failed, reason: reason));
          }
        case EcgTerminal(:final outcome):
          unawaited(_handleTerminal(epoch, outcome));
      }
    }
  }

  Future<void> _restart(int epoch) async {
    final lease = _lease;
    if (lease == null || _restartInFlight) return;
    _restartInFlight = true;
    _set(_state.copyWith(phase: EcgCapturePhase.restarting));
    final res = await transport.restart(lease);
    if (_stale(epoch) || !identical(_lease, lease)) return;
    if (!res.allSucceeded) {
      log('[ECG] RESTART not accepted: $res');
      await _finish(epoch, EcgCapturePhase.failed, reason: 'restart');
      return;
    }
    _restartInFlight = false;
    _set(_state.copyWith(phase: EcgCapturePhase.active));
  }

  Future<void> _handleTerminal(int epoch, EcgTerminalOutcome outcome) =>
      _exitOnce(epoch, () async {
        _armed = false;
        _timer?.cancel();
        if (!_persist) {
          await _teardown(epoch, EcgCapturePhase.cancelled, reason: 'gesture');
          return;
        }
        switch (outcome.kind) {
          case EcgTerminalKind.unreadable:
            await _teardown(
              epoch,
              EcgCapturePhase.unreadable,
              unreadableMask: outcome.unreadableMask,
            );
          case EcgTerminalKind.inconclusiveOfferRetry:
            await _teardown(epoch, EcgCapturePhase.inconclusiveRetry);
          case EcgTerminalKind.completed:
          case EcgTerminalKind.inconclusiveFinal:
            _set(_state.copyWith(phase: EcgCapturePhase.saving));
            final packets = List<EcgAcceptedPacket>.from(_reducer.accepted);
            final reading = _buildReading(outcome, packets);
            try {
              await save(reading, _keep ? packets : const []);
            } catch (e) {
              log('[ECG] save failed: $e');
              await _teardown(epoch, EcgCapturePhase.failed, reason: 'save');
              return;
            }
            await _teardown(
              epoch,
              EcgCapturePhase.completed,
              readingId: reading.id,
              result: reading.status,
              metrics: ecgMetricsOf(reading),
            );
            // With the raw save on, the band kept the recording; ordinary
            // incremental history brings it back through the normal safe path.
            try {
              await transport.requestSync();
            } catch (e) {
              log('[ECG] post-reading sync request failed: $e');
            }
        }
      });

  /// THE one exit of a capture. Whatever ends it first (the terminal packet,
  /// the capture timeout, a dropped link, the app going to the background, the
  /// wearer's cancel, a failed start) runs [run]; every later attempt gets the
  /// same future and does nothing of its own. So a result is saved once, the
  /// cleanup runs once, and the lease is released only after that cleanup has
  /// finished. Called synchronously from each entry, before any await, so two
  /// entries in the same turn cannot both pass.
  Future<void> _exitOnce(int epoch, Future<void> Function() run) {
    final running = _exiting;
    if (running != null) return running;
    if (_lease == null || _epoch != epoch) return Future<void>.value();
    return _exiting = run().catchError((Object e, StackTrace st) {
      log('[ECG] exit failed: $e\n$st');
    });
  }

  /// Stop the capture and, if there is an accepted window, save it as a
  /// [EcgReadingStatus.partial] reading before the exit completes. [phase] and
  /// [reason] are what the capture ends as (background: cancelled/'paused',
  /// timeout and link loss: failed). Nothing is saved for a gesture-owned
  /// capture, or when no signal was accepted (nothing was recorded); metrics are
  /// kept only from [kEcgPartialMinSamples] samples. A save that fails still
  /// ends the capture the same way, with no reading.
  Future<void> _finishWithPartial(
    int epoch,
    EcgCapturePhase phase,
    String reason,
  ) => _exitOnce(epoch, () async {
    _armed = false;
    _timer?.cancel();
    final packets = List<EcgAcceptedPacket>.from(_reducer.accepted);
    final reading = _persist ? _buildPartial(packets, reason) : null;
    if (reading == null) {
      await _teardown(epoch, phase, reason: reason);
      return;
    }
    _set(_state.copyWith(phase: EcgCapturePhase.saving));
    try {
      await save(reading, _keep ? packets : const []);
    } catch (e) {
      log('[ECG] partial save failed: $e');
      await _teardown(epoch, phase, reason: reason);
      return;
    }
    await _teardown(
      epoch,
      phase,
      reason: reason,
      readingId: reading.id,
      result: reading.status,
      metrics: ecgMetricsOf(reading),
    );
  });

  EcgReading? _buildPartial(List<EcgAcceptedPacket> packets, String reason) {
    final real = packets.where((p) => !p.placeholder);
    if (real.isEmpty) return null;
    final now = nowMs();
    final startMs = _windowStartMs ?? now;
    final stats = EcgWindowStats.of(packets);
    // Metrics only from enough signal; the heart rate is the mean of the
    // band's live rate over the window, never a guess.
    final enough = stats.sampleCount >= kEcgPartialMinSamples;
    return EcgReading(
      id: ecgReadingId(
        startEpochMs: startMs,
        terminalStrapS: real.last.strapSeconds,
      ),
      deviceId: '',
      wrist: _wrist ?? EcgWrist.right,
      startTs: startMs ~/ 1000,
      endTs: now ~/ 1000,
      strapTerminalTs: null,
      strapTerminalSubsec: null,
      resultCode: 0,
      category: EcgCategory.inconclusive,
      avgHr: enough && _hrN > 0 ? (_hrSum / _hrN).round() : null,
      quality: enough && _lastQuality > 0 ? _lastQuality : null,
      unreadableMask: 0,
      interruptions: _reducer.interruptions,
      sampleCount: stats.sampleCount,
      minUv: stats.minUv,
      maxUv: stats.maxUv,
      rmsUv: stats.rmsUv,
      missingSegments: stats.missingSegments,
      status: EcgReadingStatus.partial,
      notes: null,
      createdAt: now,
      stopReason: reason,
    );
  }

  EcgReading _buildReading(
    EcgTerminalOutcome outcome,
    List<EcgAcceptedPacket> packets,
  ) {
    final now = nowMs();
    final startMs = _windowStartMs ?? now;
    final stats = EcgWindowStats.of(packets);
    final t = outcome.terminal;
    return EcgReading(
      id: ecgReadingId(startEpochMs: startMs, terminalStrapS: t.strapSeconds),
      deviceId: '',
      wrist: _wrist ?? EcgWrist.right,
      startTs: startMs ~/ 1000,
      endTs: now ~/ 1000,
      strapTerminalTs: t.strapSeconds,
      strapTerminalSubsec: t.subseconds,
      resultCode: t.result,
      category: outcome.persistedCategory,
      avgHr: t.averageHr > 0 ? t.averageHr : null,
      quality: t.quality,
      unreadableMask: t.unreadable.raw,
      interruptions: _reducer.interruptions,
      sampleCount: stats.sampleCount,
      minUv: stats.minUv,
      maxUv: stats.maxUv,
      rmsUv: stats.rmsUv,
      missingSegments: stats.missingSegments,
      status: outcome.kind == EcgTerminalKind.inconclusiveFinal
          ? EcgReadingStatus.inconclusive
          : EcgReadingStatus.completed,
      notes: null,
      createdAt: now,
    );
  }

  /// End the capture with no result to save: the guarded form of [_teardown]
  /// (see [_exitOnce]).
  Future<void> _finish(
    int epoch,
    EcgCapturePhase phase, {
    String? reason,
    String? readingId,
    int? unreadableMask,
    EcgReadingStatus? result,
    List<EcgMetric>? metrics,
  }) => _exitOnce(
    epoch,
    () => _teardown(
      epoch,
      phase,
      reason: reason,
      readingId: readingId,
      unreadableMask: unreadableMask,
      result: result,
      metrics: metrics,
    ),
  );

  /// The teardown, run only inside [_exitOnce]'s one completion. Cleanup runs
  /// once, the screen hold and the lease are released AFTER it has finished,
  /// and the final phase is set only after that, so a "completed" never
  /// precedes a stopped band.
  Future<void> _teardown(
    int epoch,
    EcgCapturePhase phase, {
    String? reason,
    String? readingId,
    int? unreadableMask,
    EcgReadingStatus? result,
    List<EcgMetric>? metrics,
  }) async {
    final lease = _lease;
    if (lease == null || _epoch != epoch) return;
    _armed = false;
    _restartInFlight = false;
    _timer?.cancel();
    _timer = null;
    var incomplete = false;
    if (!_cleanupDone) {
      _cleanupDone = true;
      _set(_state.copyWith(phase: EcgCapturePhase.cleaningUp, reason: reason));
      final res = await transport.cleanup(lease);
      final serial = _serial;
      if (res.allSucceeded && serial != null) {
        if (!await guard.clear(serial)) {
          log('[ECG] guard clear was not acknowledged — retained.');
          incomplete = true;
        }
      } else {
        log('[ECG] cleanup incomplete ($res) — guard retained.');
        incomplete = true;
      }
    }
    if (_screenHeld) {
      _screenHeld = false;
      await releaseScreen(screenOwner);
    }
    transport.release(lease);
    if (identical(_lease, lease)) _lease = null;
    _set(
      _state.copyWith(
        phase: phase,
        reason: reason,
        readingId: readingId,
        unreadableMask: unreadableMask,
        cleanupIncomplete: incomplete,
        result: result,
        metrics: metrics,
      ),
    );
  }
}
