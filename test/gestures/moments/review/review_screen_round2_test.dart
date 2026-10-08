// Round 2 on the screen: a half-done range resumes from the one card left, a
// departed screen's Save leaves a newer screen's drafts alone, bad amounts are
// refused where they are typed, a storage write the platform refused is said
// out loud, Save can never wedge, ambiguous marks are not paired, and the
// pairing sheet scrolls.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
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
Finder _confirm(PendingMoment m) => find.byKey(ValueKey('moment-save:${m.key}'));
Finder _value(PendingMoment m) => find.byKey(ValueKey('moment-value:${m.key}'));
Finder _amountError(PendingMoment m) =>
    find.byKey(ValueKey('moment-amount-error:${m.key}'));
Finder _pair(PendingMoment m) => find.byKey(ValueKey('moment-pair:${m.key}'));
Finder _range(PendingMoment m) => find.byKey(ValueKey('moment-range:${m.key}'));
Finder _ambiguousNote(PendingMoment m) =>
    find.byKey(ValueKey('moment-pair-ambiguous:${m.key}'));
Finder _target(PendingMoment m, PendingMoment o) =>
    find.byKey(ValueKey('moment-pair-target:${m.key}:${o.key}'));
final Finder _save = find.byKey(const ValueKey('review-save'));
final Finder _persistFailed = find.byKey(const ValueKey('moment-persist-failed'));

bool _saveEnabled(WidgetTester t) => t.widget<BigButton>(_save).onTap != null;

class _NoStore extends MomentReviewStore {
  const _NoStore({this.throws = false});
  final bool throws;
  @override
  MomentReviewQueue load() => MomentReviewQueue.empty;
  @override
  Future<bool> save(MomentReviewQueue q) async {
    if (throws) throw StateError('prefs gone');
    return false;
  }
}

class _Rig {
  _Rig({MomentReviewService? service, this.sent}) {
    this.service = service ?? MomentReviewService();
  }
  late final MomentReviewService service;
  final writer = FakeAnswerWriter();
  final ranges = FakeRangeWriter();
  final List<Map<String, Object>>? sent;

  Widget screen(List<PendingMoment> moments) => MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MomentFollowUpScreen(
          preloaded: moments,
          preloadedAssumed: const [],
          writer: writer,
          rangeWriter: ranges,
          service: service,
          exporter: TaskerMomentExport(
              connectionOn: () => true,
              emit: (e, x) async {
                sent?.add(x);
                return true;
              }),
          now: reviewNow,
        ),
      );

  Future<void> pump(WidgetTester t, List<PendingMoment> moments,
      {double height = 9000}) async {
    t.view.physicalSize = Size(390 * 3, height * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(screen(moments));
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

  group('resume (P1-2)', () {
    testWidgets('only the END is pending: it shows the range, cannot be '
        'undone, and Save finishes it', (t) async {
      final sent = <Map<String, Object>>[];
      final r = _Rig(sent: sent);
      final half = MomentReviewQueue.empty
          .withRange(mA, mB, MomentChoice.nap)
          .ranges
          .single
          .copyWith(windowWritten: true, startLabelled: true);
      await r.service
          .edit((q) => MomentReviewQueue.empty.withRangeProgress(half));
      await r.pump(t, [mB]); // the start is answered, so it is not listed
      expect(_card(mB), findsOneWidget);
      expect(_range(mB), findsOneWidget);
      expect(_undo(mB), findsNothing,
          reason: 'the window is already saved: nothing to take back');
      expect(_saveEnabled(t), isTrue);
      await _tap(t, _save);
      expect(r.writer.answers.map((a) => a.key), [mB.key]);
      expect(r.ranges.loggedNaps, isEmpty, reason: 'not written twice');
      expect(sent, hasLength(1));
      expect(_card(mB), findsNothing);
      expect(r.service.queue.isEmpty, isTrue);
    });
  });

  group('a departed screen (P1-3)', () {
    testWidgets('its Save finishes later without touching what the new screen '
        'queued', (t) async {
      final service = MomentReviewService();
      final slow = _SlowRanges();
      final old = _Rig(service: service);
      final a = MaterialApp(
          theme: buildTheme(Brightness.light),
          home: MomentFollowUpScreen(
              preloaded: const [mA, mB, mC],
              writer: old.writer,
              rangeWriter: slow,
              service: service,
              exporter: TaskerMomentExport(connectionOn: () => false),
              now: reviewNow));
      t.view.physicalSize = const Size(390 * 3, 9000 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(a);
      await t.pumpAndSettle();
      await _tap(t, _choice(mA, MomentChoice.nap));
      await _tap(t, _pair(mA));
      await _tap(t, _target(mA, mB));
      await t.tap(_save);
      await t.pump();
      await slow.started.future;
      // Leave, come back, queue something else.
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      final fresh = _Rig(service: service);
      await fresh.pump(t, [mC]);
      await _tap(t, _choice(mC, MomentChoice.meal));
      expect(_pending(mC), findsOneWidget);
      slow.gate.complete();
      await t.pumpAndSettle();
      expect(_pending(mC), findsOneWidget,
          reason: 'the old Save must not erase the new draft');
      expect(service.queue.decisionFor(ReviewKey.moment(mC)), isNotNull);
      expect(const MomentReviewStore().load().decisionFor(ReviewKey.moment(mC)),
          isNotNull);
    });
  });

  group('amounts (P2-8)', () {
    for (final bad in ['NaN', 'Infinity', '-Infinity', '-5', '0', '99999999']) {
      testWidgets('"$bad" is refused where it is typed: nothing queued',
          (t) async {
        final r = _Rig();
        await r.pump(t, [mA]);
        await _tap(t, _choice(mA, MomentChoice.caffeine));
        await t.enterText(_value(mA), bad);
        await _tap(t, _confirm(mA));
        expect(_amountError(mA), findsOneWidget);
        expect(_pending(mA), findsNothing);
        expect(r.service.queue.isEmpty, isTrue);
        expect(_saveEnabled(t), isFalse);
      });
    }

    testWidgets('fixing it clears the message and queues', (t) async {
      final r = _Rig();
      await r.pump(t, [mA]);
      await _tap(t, _choice(mA, MomentChoice.caffeine));
      await t.enterText(_value(mA), 'NaN');
      await _tap(t, _confirm(mA));
      await t.enterText(_value(mA), '80');
      await _tap(t, _confirm(mA));
      expect(_amountError(mA), findsNothing);
      expect(_pending(mA), findsOneWidget);
    });

    testWidgets('the queue itself refuses a non-finite value', (t) async {
      expect(
          () => MomentReviewQueue.empty.withDecision(ReviewKey.moment(mA),
              const ReviewDecision.label(MomentChoice.caffeine, value: double.nan)),
          throwsArgumentError);
      expect(
          () => MomentReviewQueue.empty.withDecision(
              ReviewKey.moment(mA),
              const ReviewDecision.label(MomentChoice.caffeine,
                  value: double.infinity)),
          throwsArgumentError);
    });

    testWidgets('Save never wedges: a store that throws still lets the next '
        'Save run', (t) async {
      final r = _Rig(service: MomentReviewService(store: const _NoStore(throws: true)));
      r.writer.failOn = {mA.key};
      await r.pump(t, [mA]);
      await _tap(t, _choice(mA, MomentChoice.meal));
      await _tap(t, _save);
      expect(_card(mA), findsOneWidget);
      expect(_saveEnabled(t), isTrue, reason: 'busy was cleared');
      r.writer.failOn = {};
      await _tap(t, _save);
      expect(_card(mA), findsNothing);
    });
  });

  group('storage that did not confirm (P2-6)', () {
    testWidgets('a refused write shows a warning; a confirmed one does not',
        (t) async {
      final bad = _Rig(service: MomentReviewService(store: const _NoStore()));
      await bad.pump(t, [mA]);
      expect(_persistFailed, findsNothing);
      await _tap(t, _choice(mA, MomentChoice.meal));
      expect(_persistFailed, findsOneWidget);
      expect(_pending(mA), findsOneWidget, reason: 'the choice is still shown');
    });

    testWidgets('normal storage: no warning', (t) async {
      final ok = _Rig();
      await ok.pump(t, [mA]);
      await _tap(t, _choice(mA, MomentChoice.meal));
      expect(_persistFailed, findsNothing);
    });
  });

  group('ambiguous marks (P2-7)', () {
    const old = PendingMoment(date: '2026-11-01', hhmm: '01:30', ambiguous: true);

    testWidgets('a nap answer on an ambiguous mark offers no pairing and says '
        'why', (t) async {
      final r = _Rig();
      await r.pump(t, [old, mC]);
      await _tap(t, _choice(old, MomentChoice.nap));
      expect(_pair(old), findsNothing);
      expect(_ambiguousNote(old), findsOneWidget);
    });

    testWidgets('and it is not offered as a partner for another mark',
        (t) async {
      final r = _Rig();
      await r.pump(t, [mA, old, mB]);
      await _tap(t, _choice(mA, MomentChoice.nap));
      await _tap(t, _pair(mA));
      expect(_target(mA, mB), findsOneWidget);
      expect(_target(mA, old), findsNothing);
    });
  });

  group('the pairing sheet scrolls (P2-9)', () {
    testWidgets('thirty candidates on a short screen: the last is reachable, '
        'no overflow', (t) async {
      // 09:25 .. 09:54 on mA's day: all later than mA, each a valid nap away.
      final many = [
        for (var i = 0; i < 30; i++)
          PendingMoment(
              date: '2026-10-06', hhmm: '09:${(25 + i).toString().padLeft(2, '0')}'),
      ];
      final r = _Rig();
      await r.pump(t, [mA, ...many], height: 640);
      await _tap(t, _choice(mA, MomentChoice.nap));
      await _tap(t, _pair(mA));
      final last = _target(mA, many.last);
      await t.scrollUntilVisible(last, 120,
          scrollable: find
              .descendant(
                  of: find.byKey(const ValueKey('moment-pair-list')),
                  matching: find.byType(Scrollable))
              .first);
      expect(last, findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(last);
      await t.pumpAndSettle();
      expect(_range(mA), findsOneWidget);
    });
  });
}

class _SlowRanges extends FakeRangeWriter {
  final gate = Completer<void>();
  final started = Completer<void>();
  @override
  Future<void> finishNaps() async {
    if (!started.isCompleted) started.complete();
    await gate.future;
  }
}
