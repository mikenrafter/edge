// Fakes shared by the marked-moment REVIEW tests (queue -> Save -> Tasker).
// Fixed dates only: nothing here reads the real clock.

import 'package:openstrap_edge/compute/manual_session.dart';
import 'package:openstrap_edge/compute/nap_edits.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_range.dart';
import 'package:openstrap_edge/gestures/symptom_description.dart';

/// 12:00 local on 2026-10-07.
final DateTime reviewNow = DateTime(2026, 10, 7, 12, 0);

const mA = PendingMoment(date: '2026-10-06', hhmm: '09:15');
const mB = PendingMoment(date: '2026-10-06', hhmm: '10:05');
const mC = PendingMoment(date: '2026-10-07', hhmm: '07:05');
// 23:40 -> 00:20 across local midnight.
const mLate = PendingMoment(date: '2026-10-05', hhmm: '23:40');
const mEarly = PendingMoment(date: '2026-10-06', hhmm: '00:20');

AssumedGlass glass(String date, int atMin) => AssumedGlass(
    date: date, atMin: atMin, ml: 250, state: AssumedState.assumed, loggedAtMs: 1);

/// Same minute as [mA] on purpose: a glass key equals a moment key, so only
/// the review-key prefix tells them apart.
final AssumedGlass gSameMinuteAsA = glass('2026-10-06', 9 * 60 + 15);
final AssumedGlass gNoon = glass('2026-10-07', 8 * 60);

const symptomDesc = SymptomDescription(
  severity: SymptomSeverity.moderate,
  kind: SymptomKind.pain,
  area: SymptomArea.knees,
);

/// Ordered log of every write any fake received, for ordering assertions.
class WriteLog {
  final List<String> entries = [];
}

class FakeAnswerWriter extends MomentAnswerWriter {
  FakeAnswerWriter({WriteLog? log, this.failOn = const {}, this.already = const {}})
      : log = log ?? WriteLog();
  final WriteLog log;

  /// Moment keys whose write throws.
  Set<String> failOn;

  /// Moment keys that report alreadyAnswered.
  Set<String> already;

  /// Moments answered through this fake (so a later check sees them).
  final answeredNow = <String>{};

  @override
  Future<bool> isAnswered(PendingMoment m) async =>
      already.contains(m.key) || answeredNow.contains(m.key);

  /// Key -> label id of what this fake stored.
  final labels = <String, String>{};

  @override
  Future<String?> labelOf(String date, String hhmm) async => labels['$date $hhmm'];

  final answers = <({String key, MomentChoice choice, double? value, String? note})>[];
  final skips = <String>[];
  final symptoms = <String>[];

  MomentAnswerResult _res(PendingMoment m) {
    if (failOn.contains(m.key)) throw StateError('disk full for ${m.key}');
    return already.contains(m.key)
        ? MomentAnswerResult.alreadyAnswered
        : MomentAnswerResult.saved;
  }

  @override
  Future<MomentAnswerResult> answer(PendingMoment m, MomentChoice choice,
      {double? value, String? note, DateTime? now}) async {
    log.entries.add('answer:${m.key}:${choice.id}');
    final r = _res(m);
    if (r == MomentAnswerResult.saved) {
      answeredNow.add(m.key);
      labels[m.key] = choice.id;
    }
    answers.add((key: m.key, choice: choice, value: value, note: note));
    return r;
  }

  @override
  Future<MomentAnswerResult> skip(PendingMoment m, {DateTime? now}) async {
    log.entries.add('skip:${m.key}');
    final r = _res(m);
    if (r == MomentAnswerResult.saved) answeredNow.add(m.key);
    skips.add(m.key);
    return r;
  }

  @override
  Future<MomentAnswerResult> answerSymptom(PendingMoment m, SymptomDescription d,
      {DateTime? now}) async {
    log.entries.add('symptom:${m.key}');
    final r = _res(m);
    symptoms.add(m.key);
    return r;
  }
}

class FakeGlassWriter extends AssumedWaterWriter {
  FakeGlassWriter({WriteLog? log, this.failOn = const {}}) : log = log ?? WriteLog();
  final WriteLog log;
  Set<String> failOn;
  final kept = <String>[];
  final removed = <String>[];

  @override
  Future<void> keep(AssumedGlass g) async {
    log.entries.add('keep:${g.key}');
    if (failOn.contains(g.key)) throw StateError('disk full');
    kept.add(g.key);
  }

  @override
  Future<void> remove(AssumedGlass g) async {
    log.entries.add('remove:${g.key}');
    if (failOn.contains(g.key)) throw StateError('disk full');
    removed.add(g.key);
  }
}

class FakeRangeWriter extends ReviewRangeWriter {
  FakeRangeWriter({
    WriteLog? log,
    this.naps = const {},
    this.spans = const [],
    this.failNap = false,
    this.failWorkout = false,
  }) : log = log ?? WriteLog();
  final WriteLog log;

  /// dayId -> naps already on that day.
  Map<String, List<NapMap>> naps;
  List<SessionSpan> spans;
  bool failNap, failWorkout;

  final loggedNaps = <({String dayId, int startSec, int endSec})>[];
  final loggedWorkouts = <({int startSec, int endSec, String type})>[];
  int finished = 0;

  @override
  Future<List<NapMap>> existingNaps(String dayId) async => naps[dayId] ?? const [];

  @override
  Future<List<SessionSpan>> sessionSpans() async => spans;

  @override
  Future<void> logNap(
      {required String dayId, required int startSec, required int endSec}) async {
    log.entries.add('nap:$dayId:$startSec:$endSec');
    if (failNap) throw StateError('nap write failed');
    loggedNaps.add((dayId: dayId, startSec: startSec, endSec: endSec));
  }

  @override
  Future<void> finishNaps() async => finished++;

  @override
  Future<void> logWorkout(
      {required int startSec, required int endSec, String type = 'other'}) async {
    log.entries.add('workout:$startSec:$endSec');
    if (failWorkout) throw StateError('workout write failed');
    loggedWorkouts.add((startSec: startSec, endSec: endSec, type: type));
  }
}

/// Epoch seconds of a LOCAL wall-clock time.
int sec(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;
