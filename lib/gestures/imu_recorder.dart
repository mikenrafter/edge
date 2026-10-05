// imu_recorder.dart — the Device lab's bounded IMU recorder.
//
// The wearer fills in what they are about to record and presses Arm. The next
// live double tap begins the recording: the recorder starts listening to the
// live IMU packet stream, then asks for the stream through the one ownership
// seam ([setStreamOwner], the `imuLab` owner of LiveStreamOwners). It never
// writes a band command itself. It records packets as received, the tap and
// stream-request markers, the first packet, and the wearer's own motion marks,
// and it ends when the duration after the first packet runs out, the packet
// limit is hit, the wearer stops it, the band disconnects, or the lab closes.
// However it ends, it lets go of the stream first.
//
// While armed, starting or recording, normal double-tap actions are suspended
// ([holdsActions], read by the gesture dispatcher), so the opening tap and any
// tap during the capture run nothing.
//
// The capture lives in RAM until the wearer saves it (ImuRecordingStore). This
// class has no file access and writes nothing (invariant 14: live high-rate
// data is never persisted on its own).
import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../state/imu_packet.dart';
import 'imu_recording.dart';
import 'imu_timing.dart';
import 'lab_log.dart';
import 'strap_event.dart';

/// What the wearer entered before arming.
class ImuLabSetup {
  const ImuLabSetup({
    required this.kind,
    required this.duration,
    this.label = '',
    this.wrist,
    this.mounting = '',
    this.posture = '',
    this.environment = '',
  });

  /// A setup whose duration is whole [seconds] (what a form has).
  ImuLabSetup.seconds({
    required this.kind,
    required int seconds,
    this.label = '',
    this.wrist,
    this.mounting = '',
    this.posture = '',
    this.environment = '',
  }) : duration = Duration(seconds: seconds);

  final ImuRecordingKind kind;

  /// How long to record once the first packet arrives.
  final Duration duration;
  final String label;
  final ImuWrist? wrist;
  final String mounting;
  final String posture;
  final String environment;

  /// 5 s for an action or an unintended tap, 30 s for an ambient baseline.
  static Duration defaultDuration(ImuRecordingKind kind) =>
      kind == ImuRecordingKind.ambient
          ? const Duration(seconds: 30)
          : const Duration(seconds: 5);

  static int defaultSeconds(ImuRecordingKind kind) =>
      defaultDuration(kind).inSeconds;

  ImuLabSetup copyWith({Duration? duration}) => ImuLabSetup(
        kind: kind,
        duration: duration ?? this.duration,
        label: label,
        wrist: wrist,
        mounting: mounting,
        posture: posture,
        environment: environment,
      );
}

/// What the app knows about the band and itself when a recording starts.
class ImuLabContext {
  const ImuLabContext({
    required this.bandModel,
    required this.deviceId,
    this.bandFirmware,
    this.appVersion = '',
    this.protocolVersion = '',
  });

  final String bandModel;
  final String? bandFirmware;

  /// The id the live IMU packets carry; packets of another id are ignored.
  final String deviceId;
  final String appVersion;
  final String protocolVersion;
}

enum ImuLabPhase {
  /// Nothing armed.
  idle,

  /// Waiting for the double tap that begins the recording.
  armed,

  /// The tap came, the stream was asked for, no packet yet.
  starting,

  /// Packets are being kept.
  recording,

  /// Finished: [ImuLabRecorder.recording] waits to be saved or discarded.
  review,
}

class ImuLabRecorder extends ChangeNotifier {
  ImuLabRecorder({
    required Stream<ImuPacket> packets,
    required void Function(bool held) setStreamOwner,
    required Duration Function() monotonicNow,
    required bool Function() isConnected,
    required ImuLabContext Function() context,
    DeviceLabLog? lab,
    String Function()? newId,
    DateTime Function()? now,
    this.maxPackets = 1200,
    this.startTimeout = const Duration(seconds: 10),
  })  : _packets = packets,
        _setStreamOwner = setStreamOwner,
        _monotonicNow = monotonicNow,
        _isConnected = isConnected,
        _context = context,
        _lab = lab,
        _newId = newId,
        _now = now ?? (() => clock.now());

  /// The longest duration a recording may ask for.
  static const Duration maxDuration = Duration(seconds: 120);

  final Stream<ImuPacket> _packets;
  final void Function(bool held) _setStreamOwner;
  final Duration Function() _monotonicNow;
  final bool Function() _isConnected;
  final ImuLabContext Function() _context;
  final DeviceLabLog? _lab;
  final String Function()? _newId;
  final DateTime Function() _now;

  /// Packets kept at most; reaching it ends the recording.
  final int maxPackets;

  /// How long to wait for the first packet after asking for the stream.
  final Duration startTimeout;

  ImuLabPhase _phase = ImuLabPhase.idle;
  ImuLabSetup? _setup;
  ImuLabContext? _ctx;
  ImuRecording? _recording;
  String? _note;
  bool _disposed = false;
  bool _holding = false;

  StreamSubscription<ImuPacket>? _sub;
  Timer? _startTimer;
  Timer? _durationTimer;

  // The capture.
  final List<ImuPacket> _kept = [];
  final List<ImuMarker> _markers = [];
  DateTime? _createdAt;
  String? _id;
  int? _generation;
  Duration? _firstPacketAt;
  Duration? _lastPacketAt;
  bool _motionOpen = false;
  ImuTimingRecorder? _timing;

  ImuLabPhase get phase => _phase;

  /// What the wearer entered; null when idle.
  ImuLabSetup? get setup => _setup;

  /// The finished capture, in [ImuLabPhase.review] only.
  ImuRecording? get recording => _recording;

  /// One line about why something did not start or how it ended.
  String? get note => _note;

  /// Normal double-tap actions are suspended: armed, starting or recording.
  bool get holdsActions =>
      _phase == ImuLabPhase.armed ||
      _phase == ImuLabPhase.starting ||
      _phase == ImuLabPhase.recording;

  /// Whether a capture is running (the stream is held).
  bool get capturing =>
      _phase == ImuLabPhase.starting || _phase == ImuLabPhase.recording;

  int get packetCount => _kept.length;

  /// Time from the first packet to the latest one; zero before there is one.
  Duration get elapsed {
    final first = _firstPacketAt, last = _lastPacketAt;
    return first == null || last == null ? Duration.zero : last - first;
  }

  /// A motion start the wearer has not yet closed.
  bool get motionOpen => _motionOpen;

  /// Arm for the next live double tap. Refused (with a [note]) without a
  /// connected band or with a duration that is not positive; ignored while a
  /// capture runs. Arming over a finished capture replaces it.
  void arm(ImuLabSetup setup) {
    if (_disposed || capturing) return;
    if (!_isConnected()) {
      _say('Connect the band first.');
      return;
    }
    if (setup.duration <= Duration.zero) {
      _say('Choose a duration longer than zero.');
      return;
    }
    _recording = null;
    _setup = setup.duration > maxDuration
        ? setup.copyWith(duration: maxDuration)
        : setup;
    _note = null;
    _phase = ImuLabPhase.armed;
    _notify();
  }

  /// Give up: an armed recorder goes idle, a running capture is dropped and the
  /// stream released. Nothing is kept.
  void cancel() {
    if (_disposed) return;
    if (capturing) _abortCapture(reason: 'cancelled');
    if (_phase == ImuLabPhase.armed) {
      _phase = ImuLabPhase.idle;
      _setup = null;
    }
    _notify();
  }

  /// End a running capture now, keeping what arrived.
  void stop() {
    if (capturing) _finish(ImuRecordingStatus.stopped);
  }

  /// Drop a finished capture.
  void discard() {
    if (_phase != ImuLabPhase.review) return;
    _recording = null;
    _setup = null;
    _phase = ImuLabPhase.idle;
    _notify();
  }

  /// Every live band event. A live double tap while armed begins the
  /// recording; one during a capture is kept as a marker.
  void onBandEvent(StrapEvent e) {
    if (_disposed || e.eventId != _doubleTapEventId || !e.isLive) return;
    if (_phase == ImuLabPhase.armed) {
      _begin(e);
    } else if (capturing) {
      _mark(ImuMarkerKind.tapReceived,
          at: e.receivedAt, age: _plausibleAge(e), note: 'tap during recording');
      _notify();
    }
  }

  /// The band disconnected. An armed recorder goes idle; a running capture ends
  /// with what arrived, labelled as disconnected.
  void onDisconnected() {
    if (_disposed) return;
    if (capturing) {
      _finish(ImuRecordingStatus.disconnected);
    } else if (_phase == ImuLabPhase.armed) {
      _phase = ImuLabPhase.idle;
      _setup = null;
      _say('The band disconnected. Arm again once it is back.');
    }
  }

  /// The wearer says the motion began. Ignored outside a capture or while one
  /// is already open.
  void markMotionStart() {
    if (!capturing || _motionOpen) return;
    _motionOpen = true;
    _mark(ImuMarkerKind.motionStart);
    _notify();
  }

  void markMotionEnd() {
    if (!capturing || !_motionOpen) return;
    _motionOpen = false;
    _mark(ImuMarkerKind.motionEnd);
    _notify();
  }

  /// A cue the band or phone played during the capture.
  void addCue(String note) {
    if (!capturing) return;
    _mark(ImuMarkerKind.cue, note: note);
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    if (capturing) _abortCapture(reason: 'the lab closed');
    _disposed = true;
    _cancelPlumbing();
    _phase = ImuLabPhase.idle;
    super.dispose();
  }

  // ── internals ─────────────────────────────────────────────────────────────

  static const int _doubleTapEventId = 14;

  void _begin(StrapEvent e) {
    final setup = _setup!;
    final ctx = _ctx = _context();
    _kept.clear();
    _markers.clear();
    _firstPacketAt = _lastPacketAt = _generation = null;
    _motionOpen = false;
    _createdAt = _now().toUtc();
    _id = _newId?.call() ?? _defaultId(_createdAt!);
    _note = null;
    final tapMono = _monotonicNow();
    final age = _plausibleAge(e);
    _lab?.beginSession(
      method: 'IMU recording',
      settings: '${setup.kind.label}, ${setup.duration.inSeconds} s, '
          '${ctx.bandModel}',
      tapAt: e.receivedAt,
    );
    _timing = ImuTimingRecorder(
      usableSampleTarget: 100,
      onLine: (line) => _lab?.addStep(line),
    )..begin(receivedAt: tapMono, bandEventAge: age);
    _mark(ImuMarkerKind.tapReceived, at: e.receivedAt, age: age);
    _lab?.addStep('IMU recording: double tap received, asking for the stream.');
    _phase = ImuLabPhase.starting;
    // Listen first, so a packet that arrives while the stream is requested is
    // kept.
    _sub = _packets.listen(_onPacket);
    _holdStream();
    _mark(ImuMarkerKind.streamRequested);
    _startTimer = Timer(startTimeout, () {
      if (_phase == ImuLabPhase.starting) {
        _finish(ImuRecordingStatus.streamTimeout);
      }
    });
    _notify();
  }

  void _onPacket(ImuPacket p) {
    if (!capturing) return;
    final ctx = _ctx;
    if (ctx != null && p.deviceId != ctx.deviceId) return;
    final gen = _generation;
    if (gen != null && p.connectionGeneration != gen) {
      // A new link: this capture belongs to the one that dropped.
      _finish(ImuRecordingStatus.disconnected);
      return;
    }
    _generation ??= p.connectionGeneration;
    _kept.add(p);
    _timing?.packet(p);
    _lastPacketAt = p.monotonicReceipt;
    if (_phase == ImuLabPhase.starting) {
      _phase = ImuLabPhase.recording;
      _firstPacketAt = p.monotonicReceipt;
      _startTimer?.cancel();
      _startTimer = null;
      _markers.add(ImuMarker(
        kind: ImuMarkerKind.firstPacket,
        mono: p.monotonicReceipt,
        at: p.receivedAt.toUtc(),
      ));
      _lab?.addStep('IMU recording: first packet.');
      _durationTimer = Timer(_setup!.duration, () {
        if (_phase == ImuLabPhase.recording) {
          _finish(ImuRecordingStatus.completed);
        }
      });
    }
    if (_kept.length >= maxPackets) {
      _finish(ImuRecordingStatus.packetLimit);
      return;
    }
    _notify();
  }

  void _finish(ImuRecordingStatus status) {
    if (!capturing) return;
    try {
      _cancelPlumbing();
      final setup = _setup!, ctx = _ctx!;
      final deviceId = _kept.isEmpty ? ctx.deviceId : _kept.first.deviceId;
      _recording = ImuRecording(
        meta: ImuRecordingMeta(
          id: _id!,
          kind: setup.kind,
          label: setup.label,
          bandModel: ctx.bandModel,
          bandFirmware: ctx.bandFirmware,
          deviceId: deviceId,
          wrist: setup.wrist,
          mounting: setup.mounting,
          posture: setup.posture,
          environment: setup.environment,
          appVersion: ctx.appVersion,
          protocolVersion: ctx.protocolVersion,
          createdAt: _createdAt!,
          requestedDuration: setup.duration,
          maxPackets: maxPackets,
        ),
        status: status,
        packets: _kept,
        markers: _markers,
      );
      _phase = ImuLabPhase.review;
      _motionOpen = false;
      _lab?.endSession(
        result: '${_kept.length} packet${_kept.length == 1 ? '' : 's'}, '
            '${status.label.toLowerCase()}',
      );
    } finally {
      _releaseStream();
      _notify();
    }
  }

  /// Stop without keeping anything.
  void _abortCapture({required String reason}) {
    try {
      _cancelPlumbing();
      _lab?.endSession(result: 'dropped ($reason)');
    } finally {
      _kept.clear();
      _markers.clear();
      _motionOpen = false;
      _phase = ImuLabPhase.idle;
      _setup = null;
      _releaseStream();
    }
  }

  void _cancelPlumbing() {
    _startTimer?.cancel();
    _durationTimer?.cancel();
    _startTimer = _durationTimer = null;
    unawaited(_sub?.cancel());
    _sub = null;
    _timing = null;
  }

  void _holdStream() {
    _holding = true;
    _setStreamOwner(true);
  }

  /// Release the stream owner once; never throws, so no failure on the way out
  /// can leave the recorder believing it still holds the stream.
  void _releaseStream() {
    if (!_holding) return;
    _holding = false;
    try {
      _setStreamOwner(false);
    } catch (_) {}
  }

  void _mark(ImuMarkerKind kind, {DateTime? at, Duration? age, String? note}) {
    _markers.add(ImuMarker(
      kind: kind,
      mono: _monotonicNow(),
      at: (at ?? _now()).toUtc(),
      bandEventAge: age,
      note: note,
    ));
  }

  /// How old the band says the tap was, when its clock allows saying.
  static Duration? _plausibleAge(StrapEvent e) {
    final age = e.age;
    return age == null || age.isNegative ? null : age;
  }

  static String _defaultId(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = at.toUtc();
    final suffix =
        math.Random().nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    return 'imu-${t.year}${two(t.month)}${two(t.day)}T'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}Z-$suffix';
  }

  void _say(String line) {
    _note = line;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
