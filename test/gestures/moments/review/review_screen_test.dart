// The follow-up screen as a REVIEW: choices are queued, not applied. Each card
// stays and shows its pending decision (editable, undoable); nothing is written
// until Save; Save applies everything in one go and tells which failed; the
// queue survives leaving the screen and an app restart; a nap / workout can be
// paired into a range. Writers, range writer, store and Tasker emitter are
// fakes; time is injected (`now`), never read. RED: the screen still applies
// each answer at once and has no queue.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/assumed_water.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_review_store.dart';
import 'package:openstrap_edge/platform/tasker_moment_export.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/moment_review_fakes.dart';

Finder _card(PendingMoment m) => find.byKey(ValueKey('moment-follow-up:${m.key}'));
Finder _choice(PendingMoment m, MomentChoice c) =>
    find.byKey(ValueKey('moment-choice:${m.key}:${c.id}'));
Finder _pending(PendingMoment m) => find.byKey(ValueKey('moment-pending:${m.key}'));
Finder _undo(PendingMoment m) => find.byKey(ValueKey('moment-undo:${m.key}'));
Finder _skip(PendingMoment m) => find.byKey(ValueKey('moment-skip:${m.key}'));
Finder _confirm(PendingMoment m) => find.byKey(ValueKey('moment-save:${m.key}'));
Finder _value(PendingMoment m) => find.byKey(ValueKey('moment-value:${m.key}'));
Finder _pair(PendingMoment m) => find.byKey(ValueKey('moment-pair:${m.key}'));
Finder _pairTarget(PendingMoment m, PendingMoment o) =>
    find.byKey(ValueKey('moment-pair-target:${m.key}:${o.key}'));
Finder _range(PendingMoment m) => find.byKey(ValueKey('moment-range:${m.key}'));
Finder _rangeError(PendingMoment m) =>
    find.byKey(ValueKey('moment-range-error:${m.key}'));
Finder _failedNote(PendingMoment m) =>
    find.byKey(ValueKey('moment-save-failed:${m.key}'));
Finder _gPending(AssumedGlass g) => find.byKey(ValueKey('assumed-pending:${g.key}'));
Finder _gUndo(AssumedGlass g) => find.byKey(ValueKey('assumed-undo:${g.key}'));
Finder _gKeep(AssumedGlass g) => find.byKey(ValueKey('assumed-keep:${g.key}'));
Finder _gRemove(AssumedGlass g) => find.byKey(ValueKey('assumed-remove:${g.key}'));
final Finder _save = find.byKey(const ValueKey('review-save'));
final Finder _empty = find.byKey(const ValueKey('moment-follow-up-empty'));

Finder _in(Finder of, String text) =>
    find.descendant(of: of, matching: find.textContaining(text));

bool _saveEnabled(WidgetTester t) => t.widget<BigButton>(_save).onTap != null;

class _Rig {
  final log = WriteLog();
  late final writer = FakeAnswerWriter(log: log);
  late final glasses = FakeGlassWriter(log: log);
  late final ranges = FakeRangeWriter(log: log);
  final sent = <Map<String, Object>>[];
  bool taskerOn = true;
  final store = const MomentReviewStore();

  late final exporter = TaskerMomentExport(
      connectionOn: () => taskerOn,
      emit: (e, x) async {
        sent.add(x);
        return true;
      });

  Widget screen(
          {List<PendingMoment> moments = const [mA, mB, mC],
          List<AssumedGlass> glassList = const []}) =>
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MomentFollowUpScreen(
          preloaded: moments,
          preloadedAssumed: glassList,
          writer: writer,
          assumedWriter: glasses,
          rangeWriter: ranges,
          store: store,
          exporter: exporter,
          now: reviewNow,
        ),
      );

  Future<void> pump(WidgetTester t,
      {List<PendingMoment> moments = const [mA, mB, mC],
      List<AssumedGlass> glassList = const []}) async {
    t.view.physicalSize = const Size(390 * 3, 9000 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(screen(moments: moments, glassList: glassList));
    await t.pumpAndSettle();
  }
}

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setString(MomentReviewStore.prefKey, '');
  });

  group('choices are queued, not applied', () {
    testWidgets('a one-tap choice leaves the card in place, shows what is '
        'pending, and writes nothing', (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.meal));
      expect(_card(mA), findsOneWidget, reason: 'the card does not disappear');
      expect(_pending(mA), findsOneWidget);
      expect(_in(_pending(mA), 'Meal'), findsOneWidget);
      expect(_pending(mB), findsNothing, reason: 'other cards untouched');
      expect(r.log.entries, isEmpty);
    });

    testWidgets('a dose: confirm queues it with the typed amount, still no '
        'write', (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.caffeine));
      await t.enterText(_value(mA), '80');
      await _tap(t, _confirm(mA));
      expect(_card(mA), findsOneWidget);
      expect(_in(_pending(mA), 'Caffeine'), findsOneWidget);
      expect(_in(_pending(mA), '80'), findsOneWidget);
      expect(r.log.entries, isEmpty);
    });

    testWidgets('a blank dose queues the label alone (no guessed amount)',
        (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.alcohol));
      await _tap(t, _confirm(mA));
      expect(_in(_pending(mA), 'Alcohol'), findsOneWidget);
      await _tap(t, find.byKey(const ValueKey('review-save')));
      expect(r.writer.answers.single.value, isNull);
    });

    testWidgets('Skip is queued too', (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _skip(mB));
      expect(_card(mB), findsOneWidget);
      expect(_in(_pending(mB), 'Skip'), findsOneWidget);
      expect(r.log.entries, isEmpty);
    });

    testWidgets('a symptom description is queued, shown as its sentence',
        (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.symptom));
      await _tap(t, find.byKey(ValueKey('symptom-severity:${mA.key}:moderate')));
      await _tap(t, find.byKey(ValueKey('symptom-kind:${mA.key}:pain')));
      await _tap(t, find.byKey(ValueKey('symptom-area:${mA.key}:knees')));
      await _tap(t, _confirm(mA));
      expect(_in(_pending(mA), symptomDesc.describe(null)), findsOneWidget);
      expect(r.writer.symptoms, isEmpty);
    });

    testWidgets('choosing again edits the pending decision (one, not two)',
        (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.meal));
      await _tap(t, _choice(mA, MomentChoice.other));
      await _tap(t, _confirm(mA));
      expect(_pending(mA), findsOneWidget);
      expect(_in(_pending(mA), 'Meal'), findsNothing);
      expect(_in(_pending(mA), 'Other'), findsOneWidget);
    });

    testWidgets('Undo clears the pending decision and the stored draft',
        (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.meal));
      expect(r.store.load().length, 1);
      await _tap(t, _undo(mA));
      expect(_pending(mA), findsNothing);
      expect(_card(mA), findsOneWidget);
      expect(r.store.load().isEmpty, isTrue);
      expect(r.log.entries, isEmpty);
    });

    testWidgets('an assumed glass: Keep / Remove are queued, shown, undoable',
        (t) async {
      final r = _Rig();
      await r.pump(t, glassList: [gNoon]);
      await _tap(t, _gKeep(gNoon));
      expect(find.byKey(ValueKey('assumed-water:${gNoon.key}')), findsOneWidget);
      expect(_in(_gPending(gNoon), 'Keep'), findsOneWidget);
      await _tap(t, _gRemove(gNoon));
      expect(_in(_gPending(gNoon), 'Remove'), findsOneWidget);
      expect(r.glasses.kept, isEmpty);
      expect(r.glasses.removed, isEmpty);
      await _tap(t, _gUndo(gNoon));
      expect(_gPending(gNoon), findsNothing);
    });
  });

  group('the Save button', () {
    testWidgets('disabled with nothing queued, enabled with something, '
        'disabled again after Undo', (t) async {
      final r = _Rig();
      await r.pump(t);
      expect(_save, findsOneWidget);
      expect(_saveEnabled(t), isFalse);
      await _tap(t, _choice(mA, MomentChoice.meal));
      expect(_saveEnabled(t), isTrue);
      await _tap(t, _undo(mA));
      expect(_saveEnabled(t), isFalse);
    });

    testWidgets('it says how many items it will save (a range is one)',
        (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.meal));
      await _tap(t, _skip(mC));
      expect(_in(_save, '2'), findsOneWidget);
    });

    testWidgets('an empty list shows no way to save', (t) async {
      final r = _Rig();
      await r.pump(t, moments: const []);
      expect(_empty, findsOneWidget);
      expect(_save, findsNothing);
    });
  });

  group('Save applies everything in one go', () {
    testWidgets('every queued decision is written once; applied cards leave; '
        'the stored draft is cleared', (t) async {
      final r = _Rig();
      await r.pump(t, glassList: [gNoon]);
      await _tap(t, _choice(mA, MomentChoice.meal));
      await _tap(t, _skip(mB));
      await _tap(t, _gRemove(gNoon));
      expect(r.log.entries, isEmpty, reason: 'nothing before Save');
      await _tap(t, _save);
      expect(r.writer.answers.map((a) => a.key), [mA.key]);
      expect(r.writer.skips, [mB.key]);
      expect(r.glasses.removed, [gNoon.key]);
      expect(_card(mA), findsNothing);
      expect(_card(mB), findsNothing);
      expect(find.byKey(ValueKey('assumed-water:${gNoon.key}')), findsNothing);
      expect(_card(mC), findsOneWidget, reason: 'unreviewed stays');
      expect(r.store.load().isEmpty, isTrue);
      expect(_saveEnabled(t), isFalse);
    });

    testWidgets('everything answered: the empty state', (t) async {
      final r = _Rig();
      await r.pump(t, moments: [mA]);
      await _tap(t, _skip(mA));
      await _tap(t, _save);
      expect(_empty, findsOneWidget);
    });

    testWidgets('one failure: the others land, the failed card stays with its '
        'decision, says so, and stays queued', (t) async {
      final r = _Rig();
      r.writer.failOn = {mB.key};
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.meal));
      await _tap(t, _choice(mB, MomentChoice.meal));
      await _tap(t, _skip(mC));
      await _tap(t, _save);
      expect(_card(mA), findsNothing);
      expect(_card(mC), findsNothing);
      expect(_card(mB), findsOneWidget);
      expect(_in(_pending(mB), 'Meal'), findsOneWidget);
      expect(_failedNote(mB), findsOneWidget);
      expect(_failedNote(mA), findsNothing);
      expect(r.store.load().decisionFor(ReviewKey.moment(mB)), isNotNull);
      expect(r.store.load().length, 1);
      expect(_saveEnabled(t), isTrue, reason: 'Save can be pressed again');
    });

    testWidgets('pressing Save again retries only what failed', (t) async {
      final r = _Rig();
      r.writer.failOn = {mB.key};
      await r.pump(t);
      await _tap(t, _skip(mA));
      await _tap(t, _skip(mB));
      await _tap(t, _save);
      r.writer.failOn = {};
      await _tap(t, _save);
      expect(r.writer.skips, [mA.key, mB.key]);
      expect(_card(mB), findsNothing);
      expect(_failedNote(mB), findsNothing);
    });

    testWidgets('editing a failed card clears its failure note', (t) async {
      final r = _Rig();
      r.writer.failOn = {mB.key};
      await r.pump(t);
      await _tap(t, _skip(mB));
      await _tap(t, _save);
      expect(_failedNote(mB), findsOneWidget);
      await _tap(t, _choice(mB, MomentChoice.meal));
      expect(_failedNote(mB), findsNothing);
    });
  });

  group('the queue persists', () {
    testWidgets('written at once, not on dispose', (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.meal));
      final q = r.store.load();
      expect(q.decisionFor(ReviewKey.moment(mA))!.choice, MomentChoice.meal);
    });

    testWidgets('leaving and returning: a NEW screen shows the same pending '
        'decisions and enables Save', (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.meal));
      await _tap(t, _skip(mC));
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      await t.pumpAndSettle();
      await t.pumpWidget(r.screen());
      await t.pumpAndSettle();
      expect(_in(_pending(mA), 'Meal'), findsOneWidget);
      expect(_in(_pending(mC), 'Skip'), findsOneWidget);
      expect(_pending(mB), findsNothing);
      expect(_saveEnabled(t), isTrue);
      expect(r.log.entries, isEmpty, reason: 'leaving applies nothing');
    });

    testWidgets('an app restart: a draft already on disk is shown', (t) async {
      final r = _Rig();
      await r.store.save(MomentReviewQueue.empty
          .withDecision(ReviewKey.moment(mA),
              const ReviewDecision.label(MomentChoice.caffeine, value: 80))
          .withDecision(
              ReviewKey.glass(gNoon), const ReviewDecision.removeGlass()));
      await r.pump(t, glassList: [gNoon]);
      expect(_in(_pending(mA), 'Caffeine'), findsOneWidget);
      expect(_in(_pending(mA), '80'), findsOneWidget);
      expect(_in(_gPending(gNoon), 'Remove'), findsOneWidget);
    });

    testWidgets('a persisted range comes back as a range', (t) async {
      final r = _Rig();
      await r.store.save(
          MomentReviewQueue.empty.withRange(mA, mB, MomentChoice.nap));
      await r.pump(t);
      expect(_range(mA), findsOneWidget);
      expect(_range(mB), findsOneWidget);
    });

    testWidgets('a draft for something no longer pending is dropped, from the '
        'screen and from storage', (t) async {
      final r = _Rig();
      await r.store.save(MomentReviewQueue.empty
          .withDecision(ReviewKey.moment(mA), const ReviewDecision.skip())
          .withDecision(ReviewKey.moment(mC), const ReviewDecision.skip())
          .withDecision(
              ReviewKey.glass(gNoon), const ReviewDecision.keepGlass()));
      await r.pump(t, moments: [mA]);
      expect(_pending(mA), findsOneWidget);
      expect(_card(mC), findsNothing);
      final q = r.store.load();
      expect(q.decisions.keys, [ReviewKey.moment(mA)]);
    });

    testWidgets('a draft for a MOMENT does not attach to a glass of the same '
        'minute', (t) async {
      final r = _Rig();
      await r.store.save(MomentReviewQueue.empty
          .withDecision(ReviewKey.moment(mA), const ReviewDecision.skip()));
      await r.pump(t, moments: const [], glassList: [gSameMinuteAsA]);
      expect(_gPending(gSameMinuteAsA), findsNothing);
      expect(r.store.load().isEmpty, isTrue);
    });
  });

  group('ranges', () {
    testWidgets('Pair appears for a nap or a workout answer, not for a meal',
        (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.meal));
      expect(_pair(mA), findsNothing);
      await _tap(t, _choice(mA, MomentChoice.nap));
      expect(_pair(mA), findsOneWidget);
      await _tap(t, _choice(mB, MomentChoice.workout));
      expect(_pair(mB), findsOneWidget);
    });

    testWidgets('the partner list: other moments without a decision of their '
        'own, not the moment itself', (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.nap));
      await _tap(t, _skip(mC));
      await _tap(t, _pair(mA));
      expect(_pairTarget(mA, mB), findsOneWidget);
      expect(_pairTarget(mA, mC), findsNothing, reason: 'it has a decision');
      expect(_pairTarget(mA, mA), findsNothing);
    });

    testWidgets('pairing shows the range on BOTH cards, in place of their own '
        'pending decisions', (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.nap));
      await _tap(t, _pair(mA));
      await _tap(t, _pairTarget(mA, mB));
      for (final m in [mA, mB]) {
        expect(_range(m), findsOneWidget);
        expect(_in(_range(m), '09:15'), findsOneWidget);
        expect(_in(_range(m), '10:05'), findsOneWidget);
        expect(_in(_range(m), 'Nap'), findsOneWidget);
        expect(_pending(m), findsNothing);
      }
      expect(r.log.entries, isEmpty);
      expect(r.store.load().ranges, hasLength(1));
    });

    testWidgets('pairing in the other direction gives the same range (earlier '
        'is the start)', (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mB, MomentChoice.nap));
      await _tap(t, _pair(mB));
      await _tap(t, _pairTarget(mB, mA));
      final range = r.store.load().ranges.single;
      expect((range.startKey, range.endKey), (mA.key, mB.key));
    });

    testWidgets('Undo on either end dissolves the range', (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.nap));
      await _tap(t, _pair(mA));
      await _tap(t, _pairTarget(mA, mB));
      await _tap(t, _undo(mB));
      expect(_range(mA), findsNothing);
      expect(_range(mB), findsNothing);
      expect(r.store.load().isEmpty, isTrue);
      expect(_saveEnabled(t), isFalse);
    });

    testWidgets('an impossible pair (a "nap" of almost a day) is refused on '
        'the spot, with a reason, and queues nothing', (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.nap));
      await _tap(t, _pair(mA));
      await _tap(t, _pairTarget(mA, mC));
      expect(_rangeError(mA), findsOneWidget);
      expect(_range(mA), findsNothing);
      expect(r.store.load().ranges, isEmpty);
    });

    testWidgets('a pair overlapping a nap already logged is refused', (t) async {
      final r = _Rig();
      r.ranges.naps = {
        '2026-10-06': [
          {'start': sec(2026, 10, 6, 9, 30), 'end': sec(2026, 10, 6, 9, 50)}
        ]
      };
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.nap));
      await _tap(t, _pair(mA));
      await _tap(t, _pairTarget(mA, mB));
      expect(_rangeError(mA), findsOneWidget);
      expect(r.store.load().ranges, isEmpty);
    });

    testWidgets('Save writes the nap range once, labels both moments, and '
        'both cards leave', (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.nap));
      await _tap(t, _pair(mA));
      await _tap(t, _pairTarget(mA, mB));
      await _tap(t, _save);
      expect(r.ranges.loggedNaps.single.startSec, sec(2026, 10, 6, 9, 15));
      expect(r.ranges.loggedNaps.single.endSec, sec(2026, 10, 6, 10, 5));
      expect(r.writer.answers.map((a) => a.choice),
          [MomentChoice.nap, MomentChoice.nap]);
      expect(_card(mA), findsNothing);
      expect(_card(mB), findsNothing);
      expect(r.store.load().isEmpty, isTrue);
    });

    testWidgets('Save writes a workout range through the workout path',
        (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.workout));
      await _tap(t, _pair(mA));
      await _tap(t, _pairTarget(mA, mB));
      await _tap(t, _save);
      expect(r.ranges.loggedWorkouts, hasLength(1));
      expect(r.ranges.loggedNaps, isEmpty);
    });

    testWidgets('a range whose write fails stays on both cards, queued',
        (t) async {
      final r = _Rig();
      r.ranges.failNap = true;
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.nap));
      await _tap(t, _pair(mA));
      await _tap(t, _pairTarget(mA, mB));
      await _tap(t, _save);
      expect(_range(mA), findsOneWidget);
      expect(_range(mB), findsOneWidget);
      expect(_failedNote(mA), findsOneWidget);
      expect(r.store.load().ranges, hasLength(1));
    });
  });

  group('Tasker, from the screen', () {
    testWidgets('nothing is sent while queueing, editing or undoing',
        (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.meal));
      await _tap(t, _choice(mA, MomentChoice.caffeine));
      await _tap(t, _confirm(mA));
      await _tap(t, _undo(mA));
      await _tap(t, _choice(mB, MomentChoice.nap));
      await _tap(t, _pair(mB));
      await _tap(t, _pairTarget(mB, mC));
      expect(r.sent, isEmpty);
    });

    testWidgets('Save sends one broadcast per reviewed item (a range once)',
        (t) async {
      final r = _Rig();
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.nap));
      await _tap(t, _pair(mA));
      await _tap(t, _pairTarget(mA, mB));
      await _tap(t, _choice(mC, MomentChoice.meal));
      await _tap(t, _save);
      expect(r.sent.map((x) => '${x['kind']}:${x['type']}'),
          ['range:nap', 'moment:meal']);
    });

    testWidgets('connection off: Save still saves, nothing is sent', (t) async {
      final r = _Rig()..taskerOn = false;
      await r.pump(t);
      await _tap(t, _choice(mA, MomentChoice.meal));
      await _tap(t, _save);
      expect(r.writer.answers, hasLength(1));
      expect(r.sent, isEmpty);
    });
  });
}
