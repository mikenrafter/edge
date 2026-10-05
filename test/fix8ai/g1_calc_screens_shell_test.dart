// 8AI G1 (red first): no calculation screen hides its page behind a spinner.
//
// USER REPORT (APK a613d8d8): "the different calculation screens are not
// showing 'As of' and instead are not displaying anything and showing me a
// pinwheel. It resolves every time and the entire screen aside from the
// spinner is hidden ... it's slow every time."
//
// REPRODUCED against today's code (these tests fail today for these reasons):
//   * MetricDetail: `MetricData.load` awaits the cheap series (getChart) AND the
//     slow 90-day journal insights, then setState once. Until both land the page
//     is the title, the range chips and a bare `Center(CircularProgressIndicator)`:
//     the series that was ready in milliseconds is not drawn.
//   * Wellness "What you log" (JournalFindings): `if (_loading)` returns
//     `detailScaffold(title, [spinner])`, the whole page.
//   * Beats: the night's own header ("Night of ...") is known after the cheap
//     `pickNight`, but the page keeps `sub: ''` and a bare spinner until the
//     corrected-RR read lands.
//   * Past Workout detail: `_HistoryRow._open` awaits `_detailOf` (the slow
//     store reads) BEFORE it pushes the route, so a first open shows nothing
//     at all, then the whole page.
//   * (Persistence across restarts is g1_calc_screens_persisted_test.dart.)
//
// ASSUMED BEHAVIOUR, with nothing stored for the screen (first-ever open) and
// its slow read still pending:
//   * the page shell renders: title, header, and every part whose data is
//     cheap or already read. Concretely here: MetricDetail draws its series
//     (hero + "Your normal range"); JournalFindings shows its title and the
//     static "Which day of the week" section; Beats shows its title, the
//     "Night of ..." header and the Poincare panel heading;
//   * what waits on the slow read shows an INLINE loading state: a
//     ProgressIndicator that lives inside a Section or Surface card, never the
//     page's only content. (A shared widget for this is the implementer's
//     choice; the tests only look for a ProgressIndicator under a Section or
//     Surface.)
//   * Workout: the route is pushed first; the slow read runs inside it.
//   * AUDIT GUARD: the calculation screens listed below no longer contain the
//     literal full-width spinner `Center(child: CircularProgressIndicator())`.
//     (Audit of lib/ui2/screens + lib/ui2/activity found it in: sleep_detail,
//     metric_detail, wellness_screen (two), day_steps, what_changed, naps,
//     day_timeline, circadian_detail, cycle_screen, activity/zones.dart and
//     journal_compose (a form, not a calculation: not listed).)
//
// Fixtures: test/perf/support/perf_fakes.dart (MetricRepo.insightsGate,
// WellnessRepo.insightsGate, BeatsRepo.beatsGate). A private sqflite_ffi db
// keeps whatever the screens persist away from other files and guarantees
// "nothing stored".

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../perf/support/p3_support.dart';
import '../perf/support/p3_warmer_support.dart';
import '../phase8/support/dart_source.dart';
import 'support/g1_db.dart';

const _db = 'openstrap_fix8ai_g1_shell.db';

AppState _app(LocalRepository repo) {
  final a = AppState.forTesting();
  a.repo = repo;
  addTearDown(a.dispose);
  return a;
}

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(390 * 3, 2600 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> _fresh(WidgetTester t) async {
  await t.runAsync(() => g1FreshDb(_db));
  LastResultCache.instance.clear();
}

/// Every loading indicator on screen.
final _bars = find.byWidgetPredicate((w) => w is ProgressIndicator,
    description: 'a ProgressIndicator');

/// The inline loading state: at least one indicator, and every one of them sits
/// inside a Section or a Surface card (never the page's bare body).
void _expectInlineLoading(WidgetTester t, String screen) {
  expect(_bars, findsWidgets,
      reason: '$screen: first-ever open shows an inline loading state, not a '
          'blank section');
  for (final e in _bars.evaluate()) {
    final inCard = find
        .ancestor(
            of: find.byElementPredicate((x) => identical(x, e)),
            matching: find.byWidgetPredicate(
                (w) => w is Section || w is Surface,
                description: 'a Section or Surface'))
        .evaluate()
        .isNotEmpty;
    expect(inCard, isTrue,
        reason: '$screen: a spinner that is not inside a Section or Surface '
            'card is the page-level spinner this fix removes');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDownAll(() => g1DropDb(_db));

  group('MetricDetail', () {
    testWidgets('slow journal insights pending, nothing stored: the series '
        'and the page are there, only "What moves it" waits', (t) async {
      _tall(t);
      await _fresh(t);
      final repo = MetricRepo()..insightsGate = Completer();
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const MetricDetail('resting_hr')));
      await settle(t, n: 20);
      expect(repo.insightsCalls, 1, reason: 'the slow read is in flight');

      expect(find.text('Your normal range'), findsOneWidget,
          reason: 'the series came from the cheap getChart read; it is drawn '
              'while the 90-day insights compute');
      _expectInlineLoading(t, 'MetricDetail');

      repo.insightsGate!.complete(const {'insights': []});
      await settle(t);
      expect(_bars, findsNothing, reason: 'the fresh result clears it');
      expect(find.text('Your normal range'), findsOneWidget);
    });
  });

  group('Wellness: What you log (JournalFindings)', () {
    testWidgets('slow insights pending, nothing stored: title and the static '
        'section render, the section waiting on the read is inline',
        (t) async {
      _tall(t);
      await _fresh(t);
      final repo = WellnessRepo()..insightsGate = Completer();
      final app = _app(repo);
      await t.pumpWidget(perfApp(app, const JournalFindings()));
      await settle(t, n: 20);
      expect(repo.insightsCalls, 1);

      expect(find.text('What you log'), findsOneWidget);
      expect(find.text('Which day of the week'), findsOneWidget,
          reason: 'the page shell (its section headings) is not hidden behind '
              'a full-page spinner');
      _expectInlineLoading(t, 'JournalFindings');

      repo.insightsGate!.complete(const {'numeric_insights': []});
      await settle(t);
      expect(_bars, findsNothing);
    });
  });

  group('Beats', () {
    testWidgets('corrected RR pending, nothing stored: title, the night\'s '
        'own header and the panel heading render; the panel is inline',
        (t) async {
      _tall(t);
      await _fresh(t);
      // The read is the warmer's now: the screen asks for it and waits.
      final key = p3Beats(todayId);
      final repo = P3BeatsRepo()..sigs[key] = 'b1';
      final src = FakeArtifactSource()
        ..sigs[key] = 'b1'
        ..results[key] = {
          'nn': [for (var i = 0; i < 400; i++) 880 + (i % 37) * 3.0],
          'raw_beats': 412,
          'clean_fraction': .97,
        }
        ..gates[key] = Completer<void>();
      final app = _app(repo)..debugArtifactSource = src;
      await t.pumpWidget(perfApp(app, const Beats()));
      await settle(t, n: 20);
      expect(src.computes(key), 1, reason: 'the warm is requested once');
      expect(repo.beatsCalls, 0, reason: 'the screen computes nothing');

      expect(find.text('Beats'), findsOneWidget);
      expect(find.textContaining('Night of'), findsOneWidget,
          reason: 'the night is known after the cheap pickNight; the header '
              'must not wait for the corrected-RR read');
      expect(find.text('Every beat against the one before it'), findsOneWidget,
          reason: 'the Poincare panel\'s heading is the shell of the section '
              'that waits');
      _expectInlineLoading(t, 'Beats');

      src.gates[key]!.complete();
      await settle(t);
      expect(_bars, findsNothing);
    });
  });

  group('Workout detail (structural; the private history row needs sqflite)',
      () {
    final src = File('lib/ui2/screens/workout_screen.dart').readAsStringSync();

    test('opening a past workout pushes its route BEFORE the slow store '
        'reads', () {
      final open =
          codeOnly(bodyOf(src, 'Future<void> _open(BuildContext c)'));
      expect(open, isNotEmpty, reason: '_open exists');
      final push = open.lastIndexOf('.push(');
      expect(push, isNonNegative);
      final slow = open.indexOf('_detailOf(');
      // The slow read moves into the pushed page (-1 here), or at least runs
      // after the LAST push. Today the cold path awaits it first.
      expect(slow < 0 || push < slow, isTrue,
          reason: 'today `_open` awaits _detailOf and only then pushes: a '
              'first tap shows nothing until the whole page is ready');
    });

    test('the page the route shows can open WITHOUT a result in hand', () {
      final page = codeOnly(bodyOf(src, 'class _PastSummary extends'));
      expect(page.contains('required this.first'), isFalse,
          reason: 'today the page needs a finished ActivityResult to exist; '
              'it must open on its shell and fill in when the read lands');
      final state = codeOnly(bodyOf(src, 'class _PastSummaryState'));
      expect(state, contains('_detailOf('),
          reason: 'the route itself runs the slow read');
    });
  });

  group('audit guard: no full-width page spinner on a calculation screen', () {
    const files = [
      'lib/ui2/screens/sleep_detail.dart',
      'lib/ui2/screens/metric_detail.dart',
      'lib/ui2/screens/wellness_screen.dart',
      'lib/ui2/screens/day_steps.dart',
      'lib/ui2/screens/what_changed.dart',
      'lib/ui2/screens/naps.dart',
      'lib/ui2/screens/day_timeline.dart',
      'lib/ui2/screens/circadian_detail.dart',
      'lib/ui2/screens/cycle_screen.dart',
      'lib/ui2/screens/beats.dart',
      'lib/ui2/activity/zones.dart',
    ];
    final bare =
        RegExp(r'Center\(\s*child:\s*(const\s+)?CircularProgressIndicator\(\)');
    for (final f in files) {
      test(f, () {
        final code = codeOnly(File(f).readAsStringSync());
        expect(bare.allMatches(code).length, 0,
            reason: '$f still draws a bare full-width spinner as page content;'
                ' use the inline loading state inside the section that waits');
      });
    }
  });
}
