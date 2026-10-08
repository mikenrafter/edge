// Round 3 on the screen.
//  5  the remaining end of a started range has no live answer / Skip / pair
//     controls (and the queue owner would refuse them anyway)
//  6  the consent switch uses the acknowledged write, and shows what is stored
//  7  a range awaiting only its announcement has a card and a Save

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/gestures/moment_review_queue.dart';
import 'package:openstrap_edge/gestures/moment_review_service.dart';
import 'package:openstrap_edge/gestures/moment_review_store.dart';
import 'package:openstrap_edge/platform/tasker_moment_export.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/screens/moment_follow_up.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/moment_review_fakes.dart';
import '../../../support/settings_sections.dart';

Finder _card(PendingMoment m) => find.byKey(ValueKey('moment-follow-up:${m.key}'));
Finder _choice(PendingMoment m, MomentChoice c) =>
    find.byKey(ValueKey('moment-choice:${m.key}:${c.id}'));
Finder _skip(PendingMoment m) => find.byKey(ValueKey('moment-skip:${m.key}'));
Finder _pair(PendingMoment m) => find.byKey(ValueKey('moment-pair:${m.key}'));
Finder _range(PendingMoment m) => find.byKey(ValueKey('moment-range:${m.key}'));
final Finder _save = find.byKey(const ValueKey('review-save'));
final Finder _empty = find.byKey(const ValueKey('moment-follow-up-empty'));
final Finder _orphan = find.byKey(
    ValueKey('moment-range-orphan:${mA.key}|${mB.key}'));

ReviewRange _range0() => MomentReviewQueue.empty
    .withRange(mA, mB, MomentChoice.nap)
    .ranges
    .single;

Future<void> _pump(WidgetTester t, MomentReviewService service,
    List<PendingMoment> moments,
    {FakeAnswerWriter? writer,
    FakeRangeWriter? ranges,
    List<Map<String, Object>>? sent}) async {
  t.view.physicalSize = const Size(390 * 3, 9000 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: MomentFollowUpScreen(
      preloaded: moments,
      preloadedAssumed: const [],
      writer: writer ?? FakeAnswerWriter(),
      rangeWriter: ranges ?? FakeRangeWriter(),
      service: service,
      exporter: TaskerMomentExport(
          connectionOn: () => true,
          emit: (e, x) async {
            sent?.add(x);
            return true;
          }),
      now: reviewNow,
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setString(MomentReviewStore.prefKey, '');
  });

  group('5  the end of a started range', () {
    Future<MomentReviewService> started() async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRangeProgress(
          _range0().copyWith(windowWritten: true, startLabelled: true)));
      return s;
    }

    testWidgets('tapping an answer or Skip does nothing', (t) async {
      final s = await started();
      await _pump(t, s, [mB]);
      expect(_range(mB), findsOneWidget);
      for (final f in [
        _choice(mB, MomentChoice.meal),
        _choice(mB, MomentChoice.nap),
        _choice(mB, MomentChoice.caffeine),
        _skip(mB),
      ]) {
        await t.tap(f, warnIfMissed: false);
        await t.pumpAndSettle();
      }
      expect(s.queue.ranges, hasLength(1));
      expect(s.queue.decisionFor(ReviewKey.moment(mB)), isNull);
      expect(_range(mB), findsOneWidget);
      expect(find.byKey(ValueKey('moment-value:${mB.key}')), findsNothing,
          reason: 'no amount form opened');
    });

    testWidgets('the controls are drawn disabled (never hidden), and there is '
        'no pairing', (t) async {
      final s = await started();
      await _pump(t, s, [mB]);
      expect(_choice(mB, MomentChoice.meal), findsOneWidget);
      expect(_skip(mB), findsOneWidget);
      expect(_pair(mB), findsNothing);
      expect(t.widget<Pressable>(_choice(mB, MomentChoice.meal)).onTap, isNull);
      expect(t.widget<Pressable>(_skip(mB)).onTap, isNull);
    });

    testWidgets('Save still finishes it', (t) async {
      final s = await started();
      final sent = <Map<String, Object>>[];
      final w = FakeAnswerWriter();
      await _pump(t, s, [mB], writer: w, sent: sent);
      await t.tap(_save);
      await t.pumpAndSettle();
      expect(w.answers.map((a) => a.key), [mB.key]);
      expect(sent, hasLength(1));
      expect(_card(mB), findsNothing);
    });

    testWidgets('an unstarted range\'s cards keep their controls', (t) async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRange(mA, mB, MomentChoice.nap));
      await _pump(t, s, [mA, mB]);
      expect(t.widget<Pressable>(_skip(mB)).onTap, isNotNull);
    });
  });

  group('6  the consent switch', () {
    final row = find.byKey(const ValueKey('tasker-moment-export'));
    Finder sw() => find.descendant(of: row, matching: find.byType(Switch));
    final err = find.byKey(const ValueKey('tasker-moment-export-error'));

    testWidgets('a refused OFF write keeps the switch ON, restores the stored '
        'value and says so', (t) async {
      Prefs.setBool(Prefs.taskerMomentExport, true);
      final asked = <(String, bool)>[];
      await pumpTall(
          t,
          AutomationSettings(setBoolAcked: (k, v) async {
            asked.add((k, v));
            return false;
          }));
      await t.pumpAndSettle();
      expect(t.widget<Switch>(sw()).value, isTrue);
      await t.tap(sw());
      await t.pumpAndSettle();
      expect(asked, [(Prefs.taskerMomentExport, false)]);
      expect(t.widget<Switch>(sw()).value, isTrue,
          reason: 'consent is still on, and the switch must not claim otherwise');
      expect(Prefs.taskerMomentExportOn, isTrue);
      expect(err, findsOneWidget);
    });

    testWidgets('a refused ON write leaves it OFF', (t) async {
      Prefs.setBool(Prefs.taskerMomentExport, false);
      await pumpTall(
          t, AutomationSettings(setBoolAcked: (k, v) async => false));
      await t.pumpAndSettle();
      await t.tap(sw());
      await t.pumpAndSettle();
      expect(t.widget<Switch>(sw()).value, isFalse);
      expect(Prefs.taskerMomentExportOn, isFalse);
      expect(err, findsOneWidget);
    });

    testWidgets('a confirmed write turns it, with no message', (t) async {
      Prefs.setBool(Prefs.taskerMomentExport, true);
      await pumpTall(t, const AutomationSettings());
      await t.pumpAndSettle();
      await t.tap(sw());
      await t.pumpAndSettle();
      expect(t.widget<Switch>(sw()).value, isFalse);
      expect(Prefs.taskerMomentExportOn, isFalse);
      expect(err, findsNothing);
    });

    testWidgets('the message goes at the next successful change', (t) async {
      Prefs.setBool(Prefs.taskerMomentExport, false);
      var ok = false;
      await pumpTall(
          t, AutomationSettings(setBoolAcked: (k, v) async {
        if (ok) Prefs.setBool(k, v);
        return ok;
      }));
      await t.pumpAndSettle();
      await t.tap(sw());
      await t.pumpAndSettle();
      expect(err, findsOneWidget);
      ok = true;
      await t.tap(sw());
      await t.pumpAndSettle();
      expect(err, findsNothing);
      expect(t.widget<Switch>(sw()).value, isTrue);
    });
  });

  group('7  a range awaiting only its announcement', () {
    Future<MomentReviewService> owed() async {
      final s = MomentReviewService();
      await s.edit((q) => q.withRangeProgress(_range0().copyWith(
          windowWritten: true, startLabelled: true, endLabelled: true)));
      return s;
    }

    testWidgets('the screen is not the empty state: it shows the range and a '
        'Save', (t) async {
      final s = await owed();
      await _pump(t, s, const []);
      expect(_empty, findsNothing);
      expect(_orphan, findsOneWidget);
      expect(_save, findsOneWidget);
      expect(t.widget<BigButton>(_save).onTap, isNotNull);
    });

    testWidgets('Save sends the one owed event, then the screen is empty',
        (t) async {
      final s = await owed();
      final sent = <Map<String, Object>>[];
      final w = FakeAnswerWriter();
      final ranges = FakeRangeWriter();
      await _pump(t, s, const [], writer: w, ranges: ranges, sent: sent);
      await t.tap(_save);
      await t.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(sent.single['kind'], 'range');
      expect(w.answers, isEmpty, reason: 'both labels were already in');
      expect(ranges.loggedNaps, isEmpty, reason: 'the window was already in');
      expect(_orphan, findsNothing);
      expect(_empty, findsOneWidget);
      expect(s.queue.isEmpty, isTrue);
    });

    testWidgets('nothing owed and nothing pending is still the empty state',
        (t) async {
      await _pump(t, MomentReviewService(), const []);
      expect(_empty, findsOneWidget);
      expect(_orphan, findsNothing);
    });
  });
}
