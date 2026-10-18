// Sleep block finalization (owner rule 2026-10-07, part of incremental 3b).
//
// A sleep block ends, and its night is FINAL, at the first DOUBLE wake
// confirmation: the app is opened (foreground) AND the wake is corroborated by
// band movement over the awake threshold (`userAwakeFromInteraction`: a touch
// at most 5 min old plus >= 3 one-second gravity steps of 0.05 g within 45 s)
// OR an alarm event (fired, acknowledged, Natural Wake fired). The window ends
// at that moment, the morning pass scores with it, and the night's numbers never
// change again on a later pass or sync. Going back to bed afterwards is a NEW
// block. Only a user window edit reopens the night. The end is an observed
// event, never an imputed one (design report 3.3).
//
// Seams pinned, bottom up:
//  1. `confirmedWakeSec` (lib/compute/sleep_block_policy.dart): the rule, pure;
//  2. `WakeConfirmationRecorder` (lib/wake/wake_confirmation.dart): evidence
//     from every call site (foreground, movement check, alarm fired / ack /
//     Natural Wake, foreground or headless) to one persisted confirmation;
//  3. `prepareSleepSessionCandidate(confirmedWakeSec:)`: staging stops at the
//     confirmation (so it cannot stretch or bridge past it) and so the night is
//     a function of the data before it only;
//  4. the engine and the DB (`LocalDb.putWakeConfirmation` ...): the night the
//     engine stores is frozen once confirmed, and a user edit reopens it.
//
// RED until implemented. Stubs (all throw `UnimplementedError`, except the
// ignored `confirmedWakeSec` parameter): `confirmedWakeSec`,
// `WakeConfirmationRecorder.note`, `LocalDb.putWakeConfirmation` /
// `wakeConfirmation` / `deleteWakeConfirmation`.
//
// NOT pinned here, and why: the call-site wiring in `AppState` (foreground
// hook, the movement check that runs `userAwakeFromInteraction` on the stored
// accel) and in the alarm/Natural Wake paths (`wake_orchestrator.dart`,
// `alarm_schedule.dart`, the headless alarm entry) lives on branches this
// worktree does not have; it needs a pin once merged (AGENTS 4.7: every call
// site, not one).
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/sleep_block_policy.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/wake/wake_confirmation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── 1. the rule ───────────────────────────────────────────────────────────

  group('confirmedWakeSec', () {
    const onset = 1000000;

    int? confirm({
      List<int> open = const [],
      List<int> move = const [],
      List<int> alarm = const [],
      int at = onset,
    }) =>
        confirmedWakeSec(
          onsetSec: at,
          appOpenedSec: open,
          bandMovementSec: move,
          alarmSec: alarm,
        );

    test('app opened and band movement: final, at the later of the two', () {
      expect(confirm(open: [onset + 20000], move: [onset + 20030]), onset + 20030);
      expect(confirm(open: [onset + 20040], move: [onset + 20000]), onset + 20040);
      expect(confirm(open: [onset + 20000], move: [onset + 20000]), onset + 20000);
    });

    test('app opened and an alarm event: final, whichever kind it was', () {
      // The alarm fired (or was acknowledged, or Natural Wake fired) and the
      // app was opened after it.
      expect(confirm(open: [onset + 21000], alarm: [onset + 20900]), onset + 21000);
      // The app was already open when it went off.
      expect(confirm(open: [onset + 20800], alarm: [onset + 20900]), onset + 20900);
    });

    test('the app opened alone is not final', () {
      expect(confirm(open: [onset + 20000]), isNull);
      expect(confirm(open: [onset + 20000, onset + 25000, onset + 30000]), isNull);
    });

    test('band movement alone is not final (no open)', () {
      expect(confirm(move: [onset + 20000]), isNull);
    });

    test('an alarm alone is not final (never opened)', () {
      expect(confirm(alarm: [onset + 20000]), isNull);
    });

    test('nothing observed: no end, never a default', () {
      expect(confirm(), isNull);
    });

    test('an open far from the movement does not pair with it', () {
      expect(confirm(open: [onset + 20000], move: [onset + 20000 + kWakePairingSec + 1]),
          isNull);
      expect(confirm(open: [onset + 20000], move: [onset + 20000 - kWakePairingSec - 1]),
          isNull);
      expect(confirm(open: [onset + 20000], move: [onset + 20000 + kWakePairingSec]),
          onset + 20000 + kWakePairingSec);
    });

    test('an open hours before the alarm does not pair with it', () {
      // Checked the app at 03:00, asleep again, alarm at 06:30, app not opened.
      expect(confirm(open: [onset + 10000], alarm: [onset + 20000]), isNull);
      expect(confirm(open: [onset + 20000 - kWakePairingSec - 1], alarm: [onset + 20000]),
          isNull);
      expect(confirm(open: [onset + 20000 - kWakePairingSec], alarm: [onset + 20000]),
          onset + 20000);
    });

    test('the earliest double confirmation wins', () {
      expect(
        confirm(
          open: [onset + 30000, onset + 20000],
          move: [onset + 30010, onset + 20020],
          alarm: [onset + 25000],
        ),
        onset + 20020,
      );
      // An early open that never corroborated does not shadow a later pair.
      expect(confirm(open: [onset + 5000, onset + 20000], move: [onset + 20010]),
          onset + 20010);
    });

    test('events from before the block began belong to an earlier block', () {
      expect(confirm(open: [onset - 100], move: [onset - 90]), isNull);
      expect(confirm(open: [onset - 100, onset + 20000], alarm: [onset - 50]), isNull);
      expect(confirm(open: [onset - 100, onset + 20000], move: [onset - 90, onset + 20010]),
          onset + 20010);
    });

    test('never invents an instant: always an observed one, and only with an open',
        () {
      final r = math.Random(41);
      for (var round = 0; round < 300; round++) {
        List<int> events() =>
            [for (var i = r.nextInt(4); i > 0; i--) onset - 500 + r.nextInt(40000)];
        final open = events(), move = events(), alarm = events();
        final got = confirm(open: open, move: move, alarm: alarm);
        if (got != null) {
          expect([...open, ...move, ...alarm], contains(got), reason: 'round $round');
          expect(got, greaterThanOrEqualTo(onset));
        }
        expect(confirm(move: move, alarm: alarm), isNull, reason: 'no open: round $round');
        expect(confirm(open: open), isNull, reason: 'open only: round $round');
      }
    });
  });

  // ── 2. the recorder ───────────────────────────────────────────────────────

  group('WakeConfirmationRecorder', () {
    const onset = 1000000;
    DateTime at(int sec) => DateTime.fromMillisecondsSinceEpoch(sec * 1000);

    late _FakeStore store;
    late WakeConfirmationRecorder recorder;
    setUp(() {
      store = _FakeStore(onset: onset);
      recorder = WakeConfirmationRecorder(store);
    });

    test('open then movement confirms at the second event, once', () async {
      expect(await recorder.note(WakeEvidenceKind.appOpened, at(onset + 20000)), isNull);
      expect(store.confirmations, isEmpty);
      expect(await recorder.note(WakeEvidenceKind.bandMovement, at(onset + 20030)),
          onset + 20030);
      expect(store.confirmations, [(sec: onset + 20030, basis: WakeEvidenceKind.bandMovement)]);
    });

    test('movement then open confirms at the open', () async {
      expect(await recorder.note(WakeEvidenceKind.bandMovement, at(onset + 20000)), isNull);
      expect(await recorder.note(WakeEvidenceKind.appOpened, at(onset + 20010)),
          onset + 20010);
      expect(store.confirmations.single.sec, onset + 20010);
    });

    test('an alarm that fired, was acknowledged, or woke Natural Wake counts, then the open',
        () async {
      for (final kind in [
        WakeEvidenceKind.alarmFired,
        WakeEvidenceKind.alarmAcknowledged,
        WakeEvidenceKind.naturalWake,
      ]) {
        final s = _FakeStore(onset: onset);
        final r = WakeConfirmationRecorder(s);
        expect(await r.note(kind, at(onset + 20000)), isNull, reason: '$kind');
        expect(await r.note(WakeEvidenceKind.appOpened, at(onset + 20100)),
            onset + 20100, reason: '$kind');
        expect(s.confirmations, [(sec: onset + 20100, basis: kind)], reason: '$kind');
      }
    });

    test('an alarm that fired while the app was dead still counts after a restart',
        () async {
      await recorder.note(WakeEvidenceKind.alarmFired, at(onset + 20000));
      // A new process: a new recorder over the same persisted store.
      final restarted = WakeConfirmationRecorder(store);
      expect(await restarted.note(WakeEvidenceKind.appOpened, at(onset + 20500)),
          onset + 20500);
    });

    test('the app opened alone, movement alone, an alarm alone: not final',
        () async {
      for (final kind in WakeEvidenceKind.values) {
        final s = _FakeStore(onset: onset);
        expect(await WakeConfirmationRecorder(s).note(kind, at(onset + 20000)), isNull,
            reason: '$kind');
        expect(s.confirmations, isEmpty, reason: '$kind');
      }
      // Several opens through the morning change nothing.
      for (var i = 0; i < 5; i++) {
        await recorder.note(WakeEvidenceKind.appOpened, at(onset + 20000 + i * 1000));
      }
      expect(store.confirmations, isEmpty);
    });

    test('the first confirmation stands; later events never move it', () async {
      await recorder.note(WakeEvidenceKind.appOpened, at(onset + 20000));
      await recorder.note(WakeEvidenceKind.bandMovement, at(onset + 20010));
      expect(await recorder.note(WakeEvidenceKind.alarmFired, at(onset + 20100)), isNull);
      expect(await recorder.note(WakeEvidenceKind.appOpened, at(onset + 20200)), isNull);
      expect(await recorder.note(WakeEvidenceKind.bandMovement, at(onset + 20210)), isNull);
      expect(store.confirmations, hasLength(1));
      expect(store.confirmations.single.sec, onset + 20010);
    });

    test('with no sleep block known nothing is recorded and nothing is confirmed',
        () async {
      final s = _FakeStore(onset: null);
      final r = WakeConfirmationRecorder(s);
      await r.note(WakeEvidenceKind.appOpened, at(onset + 20000));
      expect(await r.note(WakeEvidenceKind.bandMovement, at(onset + 20010)), isNull);
      expect(s.confirmations, isEmpty);
      expect(s.added, isEmpty, reason: 'no block, so no evidence to keep');
    });

    test('events from before the block began are not evidence for it', () async {
      await recorder.note(WakeEvidenceKind.appOpened, at(onset - 600));
      expect(await recorder.note(WakeEvidenceKind.bandMovement, at(onset - 590)), isNull);
      expect(store.confirmations, isEmpty);
    });
  });

  // ── 3. staging stops at the confirmation ─────────────────────────────────

  group('prepareSleepSessionCandidate with a confirmed wake', () {
    late DateTime mid;
    late String day;
    int h(double hours) =>
        mid.add(Duration(minutes: (hours * 60).round())).millisecondsSinceEpoch ~/ 1000;

    /// 1 Hz heart rate and gravity (no beats: staging off HR and motion alone is
    /// seconds, with beats it is minutes) over `[from, to)` hours, asleep
    /// (still, low HR) wherever [asleep] says so.
    Substrate build(double from, double to, bool Function(int) asleep) {
      final ts = <int>[], hr = <int>[];
      final ax = <double>[], ay = <double>[], az = <double>[];
      for (var t = h(from); t < h(to); t++) {
        final s = asleep(t);
        ts.add(t);
        hr.add(s ? 52 + (t % 7) : 80 + (t ~/ 60) % 20 + t % 3);
        ax.add(s ? 0.0 : .3 * math.sin(t * .21));
        ay.add(s ? 0.0 : .2 * math.cos(t * .13));
        az.add(s ? 1.0 : 1 + .05 * math.sin(t * .07));
      }
      return Substrate(
        tsSec: ts,
        hr: hr,
        rrTsMs: const [],
        rrMs: const [],
        ax: ax,
        ay: ay,
        az: az,
        spo2Red: List.filled(ts.length, 1),
        spo2Ir: List.filled(ts.length, 1),
        skinTemp: List.filled(ts.length, 3000),
        skinContact: List.filled(ts.length, 1),
        deviceFamily: 'gen4',
      );
    }

    // Asleep from 23:00 to 03:42, awake until 04:00, back in bed until 06:30.
    bool nightThenBackToBed(int t) =>
        (t >= h(-1) && t < h(3.7)) || (t >= h(4.0) && t < h(6.5));
    bool oneNight(int t) => t >= h(-1) && t < h(3.7);

    setUp(() {
      final now = DateTime.now();
      mid = DateTime(now.year, now.month, now.day - 1);
      day = dayLabelOf(mid);
    });

    test('the window ends at the confirmation, not where the detector would have',
        () {
      // Still asleep (as far as the band can tell) at 03:50; confirmed awake at
      // 03:33, say the app was opened with the wrist moving.
      final sub = build(-2, 3.83, oneNight);
      final control = prepareSleepSessionCandidate(sub, targetDay: day);
      expect(control.sleepOffsetSec, h(3.83),
          reason: 'guard: unconfirmed, the detector follows the data');
      final c = h(3.55);
      final got = prepareSleepSessionCandidate(sub,
          targetDay: day, confirmedWakeSec: c);
      expect(got.present, isTrue);
      expect(got.sleepOffsetSec, c);
      expect(got.sleepOnsetSec, closeTo(control.sleepOnsetSec, 1800),
          reason: 'the onset is the detector\'s, not moved by the confirmation');
    });

    test('data after the confirmation changes nothing about the night', () {
      final c = h(3.75);
      final short = prepareSleepSessionCandidate(build(-2, 3.8, nightThenBackToBed),
          targetDay: day, confirmedWakeSec: c);
      final long = prepareSleepSessionCandidate(build(-2, 8, nightThenBackToBed),
          targetDay: day, confirmedWakeSec: c);
      expect(short.present, isTrue);
      expect(jsonEncode(long.toJson()), jsonEncode(short.toJson()),
          reason: 'a later sync, night-shaped data included, leaves it as it was');
    });

    test('going back to bed is a new block, not an extension of the night', () {
      final sub = build(-2, 8, nightThenBackToBed);
      final control = prepareSleepSessionCandidate(sub, targetDay: day);
      expect(control.sleepOffsetSec, greaterThan(h(6.0)),
          reason: 'guard: unconfirmed, the 18 minute gap is bridged');
      final c = h(3.75);
      final got = prepareSleepSessionCandidate(sub,
          targetDay: day, confirmedWakeSec: c);
      expect(got.sleepOffsetSec, lessThanOrEqualTo(c),
          reason: 'the night ends where the wake was confirmed');
      expect(got.sleepOffsetSec, lessThan(h(4.0)));
    });

    test('a detector end before the confirmation stands; it is never stretched',
        () {
      // Awake from 03:42; the app was opened at 04:20. The end is the detector\'s
      // observed 03:42, not the later confirmation (that would count awake
      // minutes as sleep).
      final sub = build(-2, 4.5, oneNight);
      final control = prepareSleepSessionCandidate(sub, targetDay: day);
      final got = prepareSleepSessionCandidate(sub,
          targetDay: day, confirmedWakeSec: h(4.33));
      expect(got.sleepOffsetSec, control.sleepOffsetSec);
      expect(got.sleepOffsetSec, lessThan(h(4.0)));
      // Guard against the stub: the parameter must be what made it so.
      final early = prepareSleepSessionCandidate(build(-2, 3.83, oneNight),
          targetDay: day, confirmedWakeSec: h(3.55));
      expect(early.sleepOffsetSec, h(3.55));
    });

    test('a confirmation from before the block began leaves no night, not a zero-length one',
        () {
      final sub = build(-2, 6.5, nightThenBackToBed);
      final got = prepareSleepSessionCandidate(sub,
          targetDay: day, confirmedWakeSec: h(-1.5));
      expect(got.present, isFalse);
      expect(got.sleepOffsetSec, 0);
    });
  });

  // ── 4. the engine and the database ───────────────────────────────────────

  group('the stored night', () {
    const profile = Profile(
      ageYears: 35,
      weightKg: 75,
      heightCm: 178,
      sex: 'male',
      restingHrManual: 54,
    );
    late DateTime mid;
    late String label;
    late int counter;
    int h(double hours) =>
        mid.add(Duration(minutes: (hours * 60).round())).millisecondsSinceEpoch ~/ 1000;

    // Asleep 23:00 to 03:42, awake to 04:00, back in bed to 06:30, awake after.
    bool asleep(int t) => (t >= h(-1) && t < h(3.7)) || (t >= h(4.0) && t < h(6.5));

    Future<void> rows(double from, double to) async {
      final db = await LocalDb.instance;
      final b = db.batch();
      for (var ts = h(from); ts < h(to); ts++) {
        final s = asleep(ts);
        b.rawInsert(
          'INSERT OR REPLACE INTO decoded_onehz '
          '(device_id, ts_ms, rec_ts, counter, hr, ax, ay, az, spo2_red_raw, '
          "spo2_ir_raw, skin_temp_raw, device_family) VALUES ('', ?, ?, ?, ?, ?, ?, ?, 1, 1, 3000, 'gen4')",
          [
            ts * 1000,
            ts,
            counter++,
            s ? 52 + (ts % 7) : 80 + (ts ~/ 60) % 20 + ts % 3,
            s ? 0.0 : .3 * math.sin(ts * .21),
            s ? 0.0 : .2 * math.cos(ts * .13),
            s ? 1.0 : 1 + .05 * math.sin(ts * .07),
          ],
        );
      }
      await b.commit(noResult: true);
    }

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'sleep_block_finalization_test.db';
    });

    Future<void> wipe() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    }

    setUp(() async {
      await wipe();
      counter = 0;
      final now = DateTime.now();
      mid = DateTime(now.year, now.month, now.day - 1);
      label = dayLabelOf(mid);
    });
    tearDownAll(wipe);

    Future<Map<String, dynamic>> payload() async => jsonDecode(
        (await LocalDb.dayResult(label))!['payload_json'] as String)
        as Map<String, dynamic>;

    /// What the night persisted: its scalars, its whole `sleep` block (window,
    /// accounting, stages) and the main period of `sleep_periods`.
    Future<Map<String, dynamic>> night() async {
      final b = await payload();
      final scalars = (b['scalars'] as Map).cast<String, dynamic>();
      const keys = [
        'tst_min', 'efficiency', 'awakenings', 'longest_sleep_min', 'sol_min',
        'light_min', 'deep_min', 'rem_min', 'sleep_onset_sec', 'midsleep_sec',
        'rhr_nocturnal', 'sleeping_hr_nadir', 'sleeping_hr_nadir_ts',
      ];
      final periods = ((b['sleep_periods'] as Map)['periods'] as List)
          .cast<Map>()
          .where((e) => e['is_main'] == true)
          .toList();
      return {
        'scalars': {for (final k in keys) k: scalars[k]},
        'sleep': b['sleep'],
        'main_period': periods,
      };
    }

    Future<int?> candidateOffset() async {
      final row = await LocalDb.sleepSessionCandidate(label, kAlgoVersion);
      if (row == null) return null;
      return (jsonDecode(row['payload_json'] as String)
              as Map)['sleep_offset_sec'] as int?;
    }

    group('the confirmation record', () {
      test('is stored, read back, and the first confirmation stands', () async {
        expect(await LocalDb.wakeConfirmation(label), isNull);
        await LocalDb.putWakeConfirmation(
            dayId: label, atSec: h(3.75), basis: 'movement');
        await LocalDb.putWakeConfirmation(
            dayId: label, atSec: h(3.9), basis: 'alarm_fired');
        final got = (await LocalDb.wakeConfirmation(label))!;
        expect(got.atSec, h(3.75));
        expect(got.basis, 'movement');
        await LocalDb.deleteWakeConfirmation(label);
        expect(await LocalDb.wakeConfirmation(label), isNull);
        await LocalDb.putWakeConfirmation(
            dayId: label, atSec: h(4.1), basis: 'alarm_acknowledged');
        expect((await LocalDb.wakeConfirmation(label))!.atSec, h(4.1),
            reason: 'reopened, then confirmed again');
      });
    });

    test('a confirmed night does not change on later passes, and a second sleep is not folded into it',
        () async {
      await rows(-2, 3.9);
      await LocalDb.putWakeConfirmation(
          dayId: label, atSec: h(3.8), basis: 'movement');
      await DerivationEngine().run(profile);
      final first = await night();
      final firstScalars = (await payload())['scalars'] as Map;
      final offset = await candidateOffset();
      expect(offset, isNotNull);
      expect(offset, lessThanOrEqualTo(h(3.8)));
      expect((first['scalars'] as Map)['tst_min'], isNotNull,
          reason: 'the fixture really produced a night');

      // The band syncs the rest of the morning: back in bed from 04:00 to
      // 06:30, then awake. 18 minutes apart, which unconfirmed staging bridges.
      await rows(3.9, 9);
      await DerivationEngine().run(profile);
      expect(await candidateOffset(), offset, reason: 'the night\'s window held');
      expect(jsonEncode(await night()), jsonEncode(first),
          reason: 'no figure of the night moved');
      final secondScalars = (await payload())['scalars'] as Map;
      expect(secondScalars['worn_min'] as num,
          greaterThan(firstScalars['worn_min'] as num),
          reason: 'the pass did run: only the night is frozen, not the day');
    });

    test('an unconfirmed night keeps following the data (nothing is frozen on a guess)',
        () async {
      // (Guard: passes today and must keep passing: nothing is confirmed here.)
      await rows(-2, 3.9);
      expect(await LocalDb.getSleepOverride(label), isNull);
      await DerivationEngine().run(profile);
      final before = await candidateOffset();
      await rows(3.9, 9);
      await DerivationEngine().run(profile);
      expect(await candidateOffset(), greaterThan(before!),
          reason: 'bridged into the second sleep, as it always was');
    });

    test('a user window edit reopens the night and it is re-scored on the new window',
        () async {
      await rows(-2, 3.9);
      await LocalDb.putWakeConfirmation(
          dayId: label, atSec: h(3.8), basis: 'movement');
      await DerivationEngine().run(profile);
      final tst = ((await payload())['scalars'] as Map)['tst_min'] as num;

      // The user says the night was 23:30 to 02:30.
      await LocalDb.putSleepOverride(
        dayId: label,
        onsetTs: h(-0.5),
        offsetTs: h(2.5),
        source: 'confirmed',
      );
      expect(await LocalDb.wakeConfirmation(label), isNull,
          reason: 'the edit reopens the night');
      await DerivationEngine().run(profile, force: true);
      final scalars = (await payload())['scalars'] as Map;
      expect(scalars['tst_min'], isNot(tst));
      expect((scalars['tst_min'] as num).toDouble(), closeTo(180, 2),
          reason: 'scored on the marked window, not blanked and not the old one');
      expect((await payload())['sleep_source'], 'confirmed');
    });
  });
}

typedef _Confirmation = ({int sec, WakeEvidenceKind basis});

/// In-memory [WakeConfirmationStore]: the block's onset (null = no block
/// known), the evidence kept, and what was confirmed.
class _FakeStore implements WakeConfirmationStore {
  _FakeStore({required this.onset});

  final int? onset;
  final List<WakeEvidenceEvent> added = [];
  final List<_Confirmation> confirmations = [];
  int? _confirmed;

  @override
  Future<int?> sleepOnsetSec() async => onset;

  @override
  Future<int?> confirmedWakeSec() async => _confirmed;

  @override
  Future<List<WakeEvidenceEvent>> evidence() async => List.of(added);

  @override
  Future<void> addEvidence(WakeEvidenceKind kind, int sec) async =>
      added.add((kind: kind, sec: sec));

  @override
  Future<void> confirmWake(int sec, {required WakeEvidenceKind basis}) async {
    _confirmed ??= sec;
    confirmations.add((sec: sec, basis: basis));
  }
}
