// Offline evaluation of the motion recognizer over lab recordings: a
// confusion table (true class by recognized label, "none" and "unknown"
// included) and the counts that matter for a ~zero-false-activation target.
//
// Truth comes from the wearer's label, not from the recognizer: rotations,
// circles, claps and shrugs are intended; jogging, shaking, hammering and any
// unintended-tap recording are accidental activations that must come out as
// "none" or "unknown", never as a gesture.
//
// A recording is read from its gyro-ready marker on (`motionPackets`): before
// it the wearer had not been told to move and the stream was not usable. No
// recording is excluded or marked low quality for starting or ending in
// motion; accidental ones naturally do.
//
// Pure Dart, isolate-safe.
import '../../state/imu_packet.dart';
import '../imu_recording.dart';
import 'motion_config.dart';
import 'motion_recognizer.dart';
import 'twist_calibration.dart';

/// `rotateOut`, `rotateIn`, `clapN`, `shrugN`, `circleCw`, `circleCcw`,
/// `accidental`, or `other`.
String defaultTruthOf(ImuRecording r) {
  final label = r.meta.label.toLowerCase();
  if (r.meta.kind == ImuRecordingKind.unintendedTap ||
      label.contains('jogging') ||
      label.contains('shaking') ||
      label.contains('hammering')) {
    return 'accidental';
  }
  if (label.contains('wrist rotate out')) return 'rotateOut';
  if (label.contains('wrist rotate in')) return 'rotateIn';
  final count = RegExp(r'(clap|shrug) (\d)x').firstMatch(label);
  if (count != null) return '${count[1]}${count[2]}';
  if (label.contains('circle')) {
    return label.contains('ccw') ? 'circleCcw' : 'circleCw';
  }
  return 'other';
}

class EvalCase {
  const EvalCase(this.id, this.label, this.truth, this.decision);
  final String id;
  final String label;
  final String truth;
  final MotionDecision decision;
}

class ImuEvaluation {
  ImuEvaluation(this.cases);

  final List<EvalCase> cases;

  /// truth -> recognized label -> count.
  Map<String, Map<String, int>> get table {
    final t = <String, Map<String, int>>{};
    for (final c in cases) {
      final row = t.putIfAbsent(c.truth, () => {});
      row[c.decision.label] = (row[c.decision.label] ?? 0) + 1;
    }
    return t;
  }

  static bool _quiet(EvalCase c) => !c.decision.isGesture;

  /// An accidental recording recognized as a gesture.
  int get falseActivations =>
      cases.where((c) => c.truth == 'accidental' && !_quiet(c)).length;

  /// An intended recording recognized as a different gesture.
  int get wrong => cases
      .where((c) =>
          c.truth != 'accidental' && !_quiet(c) && c.decision.label != c.truth)
      .length;

  /// An intended recording that came out none or unknown.
  int get missed =>
      cases.where((c) => c.truth != 'accidental' && _quiet(c)).length;

  /// Right answers: the intended gesture, or no gesture for an accidental one.
  int get correct => cases.length - falseActivations - wrong - missed;

  String format() {
    final t = table;
    final cols = <String>{for (final r in t.values) ...r.keys}.toList()
      ..sort((a, b) => _rank(a).compareTo(_rank(b)));
    final rows = t.keys.toList()..sort((a, b) => _rank(a).compareTo(_rank(b)));
    final w = rows.fold<int>(6, (m, r) => r.length > m ? r.length : m);
    final out = StringBuffer()
      ..writeln('${'truth'.padRight(w)}  ${cols.map((c) => c.padLeft(9)).join()}');
    for (final r in rows) {
      out.writeln(
          '${r.padRight(w)}  ${cols.map((c) => '${t[r]![c] ?? 0}'.padLeft(9)).join()}');
    }
    out.writeln('correct $correct, missed $missed, wrong $wrong, '
        'false activations $falseActivations of ${cases.length}');
    return out.toString();
  }

  static int _rank(String s) {
    const order = [
      'rotateOut', 'rotateIn', 'clap', 'shrug', 'circle', 'accidental',
      'none', 'unknown',
    ];
    final i = order.indexWhere(s.startsWith);
    return (i < 0 ? order.length : i) * 100 + (s.codeUnitAt(s.length - 1));
  }
}

ImuEvaluation evaluateRecordings(
  Iterable<ImuRecording> recordings, {
  MotionConfig config = const MotionConfig(),
  TwistCalibration? calibration,
  String Function(ImuRecording)? truthOf,
}) =>
    ImuEvaluation([
      for (final r in recordings)
        EvalCase(
          r.meta.id,
          r.meta.label,
          (truthOf ?? defaultTruthOf)(r),
          recognizeMotion(r.motionPackets,
              config: config, calibration: calibration),
        ),
    ]);

/// Consecutive [packets]-long windows of a stream, [hop] packets apart: what
/// the recognizer would see had the wearer's attempt fallen anywhere inside a
/// longer recording. A stress test for sustained activity.
List<List<ImuPacket>> packetSlices(List<ImuPacket> all,
    {int packets = 5, int hop = 1}) {
  final out = <List<ImuPacket>>[];
  for (var i = 0; i + packets <= all.length; i += hop) {
    out.add(all.sublist(i, i + packets));
  }
  return out;
}
