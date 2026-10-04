// The live-stream seam (8AJ seam 2), moved out of AppState with no behaviour
// change. It owns: the live-stream owner set the engine reads (who wants HR /
// IMU right now), the developer's live feed flag, the mounted live-HR view
// count, the movement-sampling window flag, and the helpers that feed decoded
// live frames into the Live devices buffer (RR stamping included).
//
// It does not own the buffer (AppState constructs `liveStreams` and hands it
// in), the live HR trace, the live-frame router (`AppState._onLiveFrame` also
// drives the pedometer, coverage and the breathing frames), or the BLE engine;
// the engine calls and the host state it reads arrive as callbacks. It holds no
// reference to AppState and no timers or subscriptions, so it has no dispose.
//
// RAM only (AGENTS invariant 14): nothing here persists a live sample.
import 'dart:async';

import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

import '../ble/ble_state.dart' show LiveStreamOwners;
import '../ble/live_step_runs.dart';
import '../data/db.dart';
import 'live_stream_buffer.dart';

class LiveStreamController {
  LiveStreamController({
    required LiveStreamBuffer buffer,
    required bool Function() isBackground,
    required String? Function() activeWorkoutType,
    required bool Function() breathing,
    required Future<void> Function() reconcile,
    required Future<void> Function() clearRadioFallbackAndReconcile,
    required void Function() notify,
  })  : _buffer = buffer,
        _isBackground = isBackground,
        _activeWorkoutType = activeWorkoutType,
        _breathing = breathing,
        _reconcile = reconcile,
        _clearRadioFallbackAndReconcile = clearRadioFallbackAndReconcile,
        _notify = notify;

  final LiveStreamBuffer _buffer;
  final bool Function() _isBackground;

  // The active workout's type label, or null when no workout is running.
  final String? Function() _activeWorkoutType;

  // A breathing session or its pre/post quiet window is open.
  final bool Function() _breathing;
  final Future<void> Function() _reconcile;
  final Future<void> Function() _clearRadioFallbackAndReconcile;
  final void Function() _notify;

  // ── live HR / IMU ownership (#287) ──────────────────────────────────────────
  //
  // A foreground connection used to be an implicit request for both the
  // realtime-HR stream and the 100 Hz IMU stream, and every feature that
  // needed one re-armed the whole bundle and tried to remember whether it was
  // the one that had turned it on. The engine now owns the streams through a
  // serialized desired-vs-applied reconciler; this side only says WHO wants
  // WHAT ([owners]) and nudges it whenever an owner changes.
  //
  // Policy (gen5; `desiredLiveStreams` in ble_state.dart):
  //   HR  ← a mounted live-HR view, any workout, a breathing session or
  //         window. iOS background is NOT an owner any more: the 1 Hz stream
  //         was held there purely to keep the suspended process schedulable
  //         (~86,400 wakes/day, most of a day's battery). The band's own
  //         HIGH_FREQ_SYNC prompt is the wake source now — see
  //         BandPromptPolicy and _refreshHighFreqWakeWindow.
  //   IMU ← a gait workout in the FOREGROUND, a bounded movement-sampling
  //         window, or the passive strap-step opt-in (off).
  //   An ordinary foreground connection owns nothing on gen5: the on-chip daily
  //   counter is the step fallback and the phone can supply windowed steps.
  //   Backgrounded with no owner is fully OFF on both platforms — on Android
  //   the EdgeTracking foreground service keeps the process alive without any
  //   inbound stream, on iOS the band's prompt wakes it; the 1 Hz stream with
  //   no consumer was ~86,400 wakes a day either way. Liveness
  //   is covered by the keep-alive's forced battery poll
  //   (kNoStreamPollSilenceSeconds) and the resume paths judge freshness by
  //   the no-stream bar. `state.wristOn`/`liveHr` simply stop updating while
  //   nothing owns HR.
  // gen4 keeps its previous behaviour: a foreground connection owns HR plus
  // the R10/R11 + IMU + optical bundle (see `LiveStreamOwners.foreground`).

  /// Screens showing the live BPM that are mounted right now.
  int _liveHrViewers = 0;

  /// A screen that displays the live heart rate is on screen: own the HR
  /// stream while it is. Pair with [releaseLiveHrView] in `dispose`.
  void retainLiveHrView() {
    _liveHrViewers++;
    nudge();
  }

  void releaseLiveHrView() {
    if (_liveHrViewers > 0) _liveHrViewers--;
    nudge();
  }

  /// A bounded movement-reminder sampling window is open (IMU-only owner).
  ///
  /// There is NO scheduler yet, and enabling the movement-reminder preference
  /// must not hold the IMU stream: sampling only inside bounded windows cannot
  /// prove that movement did not happen between them, so a standing owner
  /// would let the reminder claim an uninterrupted stillness it never
  /// observed. A separately validated scheduler that can account for the gaps
  /// is the only thing that should call this.
  void setMovementSamplingWindow(bool active) {
    if (_movementSampling == active) return;
    _movementSampling = active;
    nudge();
  }

  bool _movementSampling = false;

  /// The developer's "Start live feed" on the Live devices screen is on.
  /// RAM only: never a preference, so a restart never re-arms the flood.
  bool _developerLiveFeed = false;

  /// Whether the feed is on for [deviceId]. Only the band (the primary id) has
  /// one: a paired sensor's streams are already on while it is connected.
  bool isLiveFeedOn(String deviceId) =>
      deviceId == LocalDb.kPrimaryDeviceId && _developerLiveFeed;

  /// Turn the band's realtime streams on so the Live devices screen has
  /// something to draw: an explicit owner of both streams, on gen4 and gen5.
  /// The engine's reconciler stays the only writer. An explicit foreground
  /// action, so it also clears the sticky marginal-radio fallback (otherwise a
  /// latched fallback would leave HR only). Idempotent.
  Future<void> startLiveFeed(String deviceId) async {
    if (deviceId != LocalDb.kPrimaryDeviceId) return;
    if (!_developerLiveFeed) {
      _developerLiveFeed = true;
      _notify();
    }
    await _clearRadioFallbackAndReconcile();
  }

  /// Release the developer owner and let the reconciler turn the streams off.
  /// The owner is cleared BEFORE the first await, so a band that refuses (or
  /// throws on) the disable writes, or a caller that never awaits this (a
  /// screen's dispose), cannot leave the flag set; the engine's keep-alive
  /// retries the writes. gen4's own foreground owner keeps its streams on.
  /// Stop without Start writes nothing.
  Future<void> stopLiveFeed(String deviceId) async {
    if (deviceId != LocalDb.kPrimaryDeviceId || !_developerLiveFeed) return;
    _developerLiveFeed = false;
    _notify();
    await _reconcile();
  }

  /// Passive strap-step collection: OFF by default on gen5 (#287 decision 1).
  /// A future explicit opt-in requests IMU through this same owner.
  static const bool _passiveStrapSteps = false;

  LiveStreamOwners owners() {
    final type = _activeWorkoutType();
    final background = _isBackground();
    return LiveStreamOwners(
      // A route is not disposed when the app backgrounds, so a mounted
      // live-HR page must not keep the stream on behind a locked screen.
      visibleLiveHrView: !background && _liveHrViewers > 0,
      activeWorkout: type != null,
      foregroundGaitWorkout:
          type != null && !background && isGaitStepType(type),
      breathing: _breathing(),
      movementSampling: _movementSampling,
      passiveStrapSteps: _passiveStrapSteps,
      foreground: !background,
      // Like a mounted live-HR view, not held behind a locked screen.
      developerLiveFeed: !background && _developerLiveFeed,
    );
  }

  /// An owner input changed: let the engine converge. Fire-and-forget; the
  /// engine reads [owners] inside its own loop, and its keep-alive tick
  /// heals a nudge that was missed.
  void nudge() => unawaited(_reconcile());

  // ── feeding the Live devices buffer (RAM only, invariant 14) ───────────────

  /// Decoded fields that already have their own stream (or are a time or type
  /// tag, not a reading) and so are not repeated under their raw name.
  /// `hr_precise` is the HR byte as a double.
  static const _liveNamedElsewhere = {
    'rec_type',
    'packet_type',
    'ts_epoch',
    'ts_subsec',
    'counter',
    'hr',
    'hr_precise',
  };

  /// The same reading the live-HR trace took, for the Live devices graph: the
  /// band's and every paired sensor's beats arrive through AppState's one
  /// append path, so this is the one tap for the 'hr' stream.
  void bufferLiveHr(String deviceId, int at, int hr) {
    _buffer.add(deviceId, 'hr',
        DateTime.fromMillisecondsSinceEpoch(at), hr.toDouble());
  }

  /// Everything else a live frame carries, into the Live devices buffer (RAM
  /// only, invariant 14): gyro axes, R11's two raw channels, the MG's filtered
  /// ECG with the band's own HR and quality, and any other numeric field the
  /// decoder names, under that name. Fixed unit scales only; a field the
  /// packet did not carry adds no stream. A frame that does not decode adds
  /// nothing.
  void bufferLiveExtras(int pt, String hex) {
    try {
      final bytes = proto.hexToBytes(hex);
      final rec = bytes.length > 1 ? bytes[1] : -1;
      if (pt == 0x2B) {
        final g5 = proto.parseGen5ImuBuffer(bytes);
        final r10 = g5 == null && rec == 10 ? proto.decodeR10Imu(hex) : null;
        final gyro = g5 != null
            ? [g5.gyroXdps, g5.gyroYdps, g5.gyroZdps]
            : r10 != null
                ? [r10.gyroX, r10.gyroY, r10.gyroZ]
                : null;
        if (gyro != null) {
          _bufferLiveSeries('gyro_x', gyro[0], 10);
          _bufferLiveSeries('gyro_y', gyro[1], 10);
          _bufferLiveSeries('gyro_z', gyro[2], 10);
        }
        if (rec == 11) {
          // Meaning unconfirmed (protocol R11Raw): raw channels, ~50 Hz each.
          final r11 = proto.decodeR11Raw(hex);
          if (r11 != null) {
            _bufferLiveSeries('r11_ch1', r11.channelA, 20);
            _bufferLiveSeries('r11_ch2', r11.channelB, 20);
          }
        }
        final r17 = rec == proto.LabradorR17.revision
            ? proto.LabradorR17.parse(bytes)
            : null;
        if (r17 != null) {
          _bufferLiveSeries('ecg_uv', r17.samples, 10); // 100 Hz, µV
          _bufferLiveSeries('ecg_quality', [r17.quality], 10);
          // 0 is "no reading", not a heart rate.
          if (r17.liveHr > 0) _bufferLiveSeries('ecg_band_hr', [r17.liveHr], 10);
        }
      }
      final fields = proto
          .decodeFrame(proto.Frame(bytes, true, true))
          .fields;
      final now = DateTime.now();
      for (final MapEntry(:key, :value) in fields.entries) {
        if (value is num && !_liveNamedElsewhere.contains(key)) {
          _buffer.add(LocalDb.kPrimaryDeviceId, key, now, value.toDouble());
        }
      }
    } catch (_) {
      // Debug view only: a frame that will not decode is simply not drawn.
    }
  }

  /// [values] into the Live devices buffer under [key], oldest first, the
  /// newest stamped now and each earlier one [stepMs] before the next.
  void _bufferLiveSeries(String key, List<num> values, int stepMs) {
    final n = values.length;
    final end = DateTime.now();
    for (var i = 0; i < n; i++) {
      _buffer.add(LocalDb.kPrimaryDeviceId, key,
          end.subtract(Duration(milliseconds: (n - 1 - i) * stepMs)),
          values[i].toDouble());
    }
  }

  /// Beat intervals of one live frame into the Live devices buffer (RAM only).
  /// Each beat gets its own time, after the last one stored ([stampLiveBeats]);
  /// stamped from arrival alone, a batched frame's earlier beats were refused
  /// as late and the graph drew holes while beats were coming in.
  DateTime? _lastRrAt;
  void bufferLiveRr(String hex) {
    final rr = proto.realtimeRr(hex)?.rrMs;
    if (rr == null || rr.isEmpty) return;
    final at = stampLiveBeats(DateTime.now(), rr, after: _lastRrAt);
    for (var i = 0; i < rr.length; i++) {
      if (_buffer.add(LocalDb.kPrimaryDeviceId, 'rr', at[i], rr[i].toDouble())) {
        _lastRrAt = at[i];
      }
    }
  }

  /// One live IMU frame's accel samples (100 Hz) into the Live devices buffer.
  /// Per-axis when the decoder gave axes, otherwise the magnitude only. The
  /// decoder returns the axes as raw int16 counts (only `mags` is in g), so
  /// they are scaled to g here: 1/4096 g per count on both families.
  void bufferLiveImu(proto.ImuFrame f) {
    final n = f.mags.length;
    if (n == 0) return;
    final axes = {'accel_x': f.xs, 'accel_y': f.ys, 'accel_z': f.zs};
    if (axes.values.every((a) => a != null && a.length == n)) {
      for (final MapEntry(:key, :value) in axes.entries) {
        _bufferLiveSeries(
            key, [for (final v in value!) v * proto.kGen5AccelScaleG], 10);
      }
    } else {
      _bufferLiveSeries('accel_mag', f.mags, 10);
    }
  }
}
