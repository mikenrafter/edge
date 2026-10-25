// The owner's locked Home and chart look (2026-10-25 review, mockups r4):
//  - Home always has ONE Review activities card: green "Review activities" and
//    a count when something waits, grey "Breakdown of your day" when nothing
//    does, the same icon either way; no separate marked-moment Answer card.
//  - The ring card's bottom slot holds 0-2 info rows in one shared style and
//    reserves nothing when empty; a status note is such a row.
//  - Nerd stats is reached only from a chart panel's own action, which is
//    present, tappable and spoken (also with no data); an empty chart draws a
//    placeholder wave and says there is no data.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'backup/backup_support.dart';
import 'support/apk1_harness.dart';
import 'support/as_of_recalc_fakes.dart';
import 'support/pin_tz.dart';

final _card = find.byKey(const ValueKey<String>('card:detected'));

/// The Review card's icon, wherever it is in the card.
Icon _cardIcon(WidgetTester t) => t.widget<Icon>(find.descendant(
    of: _card, matching: find.byIcon(LucideIcons.radar)));

// ── ring card ───────────────────────────────────────────────────────────────

Metric _m(num v) => Metric(value: v, confidence: .8, tier: MetricTier.high);

HomeData _rings({num recovery = 58, num sleep = 450, num need = 480}) => HomeData(
      dayId: '2026-10-08',
      recoveryState: 'final',
      readiness: _m(recovery),
      sleepMin: _m(sleep),
      sleepNeedMin: _m(need),
      strain: _m(5),
    );

Future<void> _pumpRings(WidgetTester t, HomeData d, {RingHelp? help}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(390, 3000);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
        body: SingleChildScrollView(
            child: RingTrio(d: d, now: DateTime(2026, 10, 8, 15), help: help))),
  ));
  await t.pump();
}

/// The slot's rows, whatever kind: why, gap note, status, update, older.
Finder get _slotRows => find.byWidgetPredicate((w) {
      final k = w.key;
      if (k is! ValueKey<String>) return false;
      final v = k.value;
      return !v.contains('-icon') && !v.contains('-title') && !v.contains('-body') &&
          (v.startsWith('home-note:') || v.startsWith('home-why:') ||
              v == 'home-update-note' || v == 'home-older-row');
    });

Finder get _units => find.byWidgetPredicate((w) =>
    w.runtimeType.toString() == '_RingColumn' ||
    w.runtimeType.toString() == '_RingRow');

/// Space between the last thing in the card and its bottom edge.
double _bottomPad(WidgetTester t) {
  final card = t.getRect(find.descendant(
      of: find.byType(RingTrio), matching: find.byType(Surface)).first);
  var last = [
    for (var i = 0; i < _units.evaluate().length; i++) t.getRect(_units.at(i)).bottom
  ].reduce((a, b) => a > b ? a : b);
  for (var i = 0; i < _slotRows.evaluate().length; i++) {
    final b = t.getRect(_slotRows.at(i)).bottom;
    if (b > last) last = b;
  }
  return card.bottom - last;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  pinProcessTimeZone();
  late BackupEnv env;
  setUpAll(() async => env = await apk1Environment('ui_fix_home.db'));
  tearDownAll(() => env.dispose());
  setUp(apk1ClearPrefs);

  group('Home: one Review activities card, always there', () {
    apk1Test('with items it reads Review activities and the count, in colour', (t) async {
      await apk1Mount(t, source: HomeScreen(
          data: apk1Home(observation: null, pending: 3), now: apk1Now));
      await apk1Reveal(t, _card);
      expect(find.descendant(of: _card, matching: find.text('Review activities')),
          findsOneWidget);
      expect(find.descendant(of: _card, matching: find.text('3 to review')),
          findsOneWidget);
      expect(find.text('Breakdown of your day'), findsNothing);
      final p = P.of(t.element(_card));
      expect(_cardIcon(t).color, p.on(C.domHome), reason: 'the review colour');
    });

    apk1Test('with nothing to review it is the grey Breakdown of your day, same icon', (t) async {
      await apk1Mount(t, source: HomeScreen(
          data: apk1Home(observation: null, pending: 0), now: apk1Now));
      await apk1Reveal(t, _card);
      expect(find.descendant(of: _card, matching: find.text('Breakdown of your day')),
          findsOneWidget);
      expect(find.text('Review activities'), findsNothing);
      final p = P.of(t.element(_card));
      expect(_cardIcon(t).color, p.on(C.n500), reason: 'neutral, not the review colour');
      expect(p.on(C.n500), isNot(p.on(C.domHome)));
      expect(_cardIcon(t).icon, LucideIcons.radar, reason: 'the same icon in both states');
    });

    apk1Test('marked moments are counted in that card; there is no Answer card', (t) async {
      final app = await apk1Mount(t, source: HomeScreen(
          data: apk1Home(observation: null, pending: 0), now: apk1Now));
      await apk1Reveal(t, _card);
      expect(find.text('Breakdown of your day'), findsOneWidget);
      // A waiting marked moment's day: follow-ups on, one assumed glass owed.
      await t.runAsync(() async {
        await app.gestureSettings.setFollowUpMoments(true,
            now: DateTime.now().subtract(const Duration(hours: 1)));
        await LocalDb.logAssumedWater(
            date: todayLabel(),
            atMin: DateTime.now().hour * 60 + DateTime.now().minute,
            ml: 250,
            loggedAtMs: 1);
      });
      app.bumpInsights();
      for (var i = 0; i < 60 && find.text('Review activities').evaluate().isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      expect(find.text('Review activities'), findsOneWidget,
          reason: 'the waiting item turns the one card into the review card');
      expect(find.byKey(const ValueKey('moment-follow-up-card'), skipOffstage: false),
          findsNothing);
      expect(find.text('Answer', skipOffstage: false), findsNothing);
    });
  });

  group('the ring card bottom slot', () {
    testWidgets('holds 0, 1 or 2 rows and reserves nothing when empty', (t) async {
      await _pumpRings(t, _rings());
      expect(_slotRows, findsNothing, reason: 'a healthy day has nothing to say');
      final empty = _bottomPad(t);
      await _pumpRings(t, _rings(recovery: 10));
      expect(_slotRows, findsNWidgets(1));
      expect(_bottomPad(t), closeTo(empty, .01), reason: 'one row: the same padding');
      await _pumpRings(t, _rings(recovery: 10, sleep: 350, need: 528));
      expect(_slotRows, findsNWidgets(2));
      expect(_bottomPad(t), closeTo(empty, .01), reason: 'two rows: the same padding');
      // Never a third.
      await _pumpRings(t, HomeData(
          dayId: '2026-10-08', recoveryState: 'final',
          readiness: _m(10), sleepMin: _m(350), sleepNeedMin: _m(528),
          strain: const Metric(value: 8.4, confidence: .8, tier: MetricTier.high,
              fromOlderVersion: 104)));
      expect(_slotRows.evaluate().length, lessThanOrEqualTo(2));
    });

    testWidgets('every kind of row is the same inset row', (t) async {
      final inset = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_HomeInsetRow');
      for (final (name, d, help) in <(String, HomeData, RingHelp?)>[
        ('why', _rings(recovery: 10), null),
        ('gap note', HomeData(
            dayId: '2026-10-08', recoveryState: 'final', readiness: _m(58),
            sleepMin: _m(450), sleepNeedMin: _m(480)), null),
        ('status', const HomeData(), const RingHelp('Still reading your night')),
      ]) {
        await _pumpRings(t, d, help: help);
        expect(_slotRows, findsWidgets, reason: name);
        for (var i = 0; i < _slotRows.evaluate().length; i++) {
          final row = _slotRows.at(i);
          expect(find.ancestor(of: row, matching: inset, matchRoot: true),
              findsWidgets, reason: '$name row $i is not in the shared row style');
          // Same height class: an icon circle of 32 and the inset panel colour.
          final p = P.of(t.element(row));
          final panels = t.widgetList<Container>(find.descendant(
              of: row, matching: find.byType(Container), matchRoot: true)).where((c) {
            final dec = c.decoration;
            return dec is BoxDecoration && dec.color == p.card2 && dec.borderRadius == R.rMd;
          });
          expect(panels, isNotEmpty, reason: '$name: inset panel');
        }
      }
    });

    testWidgets('a status note renders as a row in that slot', (t) async {
      await _pumpRings(t, const HomeData(),
          help: const RingHelp('Recovery is still being worked out'));
      final status = find.byKey(const ValueKey('home-note:status'));
      expect(status, findsOneWidget);
      expect(find.descendant(of: status,
          matching: find.text('Recovery is still being worked out')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-note-icon:status')), findsOneWidget);
      // A busy status keeps the row and swaps the icon for the spinner.
      await _pumpRings(t, const HomeData(),
          help: const RingHelp.busy('Reading your night'));
      expect(find.descendant(of: find.byKey(const ValueKey('home-note:status')),
          matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    });
  });

  group('Nerd stats lives only in the scrub panel', () {
    final cells = [
      const ChartCell('Heart rate', C.red, value: '62 bpm'),
    ];
    final bare = [const ChartCell('Heart rate', C.red, hasValue: false)];

    Future<_Door> pumpPanel(WidgetTester t, List<ChartCell> c) async {
      final door = _Door();
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: Center(child: SizedBox(width: 340,
            child: ChartKeyReadout(cells: c, time: '09:00', nerdStats: door)))),
      ));
      await t.pump();
      return door;
    }

    for (final (name, data) in [('with data', cells), ('with no data', bare)]) {
      testWidgets('the panel has a tappable, spoken Nerd stats action $name', (t) async {
        final semantics = t.ensureSemantics();
        final door = await pumpPanel(t, data);
        final link = find.byKey(NerdStatsLink.linkKey);
        expect(link, findsOneWidget);
        expect(t.getSize(link).height, greaterThanOrEqualTo(24));
        final node = t.getSemantics(link).getSemanticsData();
        expect(node.label, 'Nerd stats');
        expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
        expect(node.hasAction(SemanticsAction.tap), isTrue);
        await t.tap(link);
        expect(door.opened, 1);
        semantics.dispose();
      });
    }

    testWidgets('a sleep card carries exactly one, in its panel', (t) async {
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      t.view.devicePixelRatio = 3;
      t.view.physicalSize = const Size(390 * 3, 3000 * 3);
      addTearDown(t.view.reset);
      final app = AppState.forTesting()..repo = SleepRepo();
      addTearDown(app.dispose);
      await t.pumpWidget(perfApp(app, SleepDetail(day: yesterdayId)));
      await t.pump(const Duration(seconds: 3));
      final night = find.byKey(const ValueKey('card:night'));
      expect(night, findsOneWidget);
      expect(find.descendant(of: night, matching: find.byKey(NerdStatsLink.linkKey)),
          findsOneWidget, reason: 'a second action outside the panel is a second door');
    });

    test('no other entry point to Nerd stats exists in lib/ui2', () {
      final hits = <String>[];
      for (final f in Directory('lib/ui2').listSync(recursive: true)
          .whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        if (f.path.endsWith('screens/investigate.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final code = lines[i].split('//').first;
          if (code.contains('investigateRow')) hits.add('${f.path}:${i + 1} investigateRow');
          if (!RegExp(r'\bInvestigate\(').hasMatch(code)) continue;
          // Allowed: inside a panel's listener method, or the day-screen switch
          // the panel's own open action uses.
          final context = lines.sublist(i < 14 ? 0 : i - 14, i + 1).join('\n');
          if (!RegExp(r'openNerdStats|_dayScreen|_WearNerdStats').hasMatch(context)) {
            hits.add('${f.path}:${i + 1} ${code.trim()}');
          }
        }
      }
      expect(hits, isEmpty, reason: 'Nerd stats opens from the scrub panel only');
    });
  });

  group('an empty chart', () {
    testWidgets('draws the greyed placeholder wave and says there is no data', (t) async {
      final semantics = t.ensureSemantics();
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: SingleChildScrollView(child: ChartFrame(
          title: 'Heart rate', unit: 'bpm', height: 120,
          nerdStats: _Door(),
          empty: const NoData(message: 'No data for this day'),
          child: const SizedBox.expand(),
        ))),
      ));
      await t.pump();
      final wave = find.byWidgetPredicate((w) =>
          w is CustomPaint && w.painter.runtimeType.toString() == '_PlaceholderWave');
      expect(wave, findsOneWidget);
      expect(find.text('No data for this day'), findsOneWidget);
      // The wave is a picture of nothing: no semantics of its own.
      expect(find.ancestor(of: wave, matching: find.byType(ExcludeSemantics)),
          findsWidgets);
      // And the action is still there.
      expect(find.byKey(NerdStatsLink.linkKey), findsOneWidget);
      semantics.dispose();
    });
  });
}

class _Door implements NerdStatsListener {
  int opened = 0;
  @override
  void openNerdStats() => opened++;
}
