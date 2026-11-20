import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/derive_progress.dart';
import 'package:openstrap_edge/ui2/app_shell.dart';
import 'package:openstrap_edge/ui2/grammar.dart' show Pressable;
import 'package:openstrap_edge/ui2/home_header.dart';
import 'package:openstrap_edge/ui2/profile/home_header_settings.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import 'support/header_rows_fakes.dart';
import 'support/home_header_pilot_fakes.dart';
import 'support/tabs_consistency_fakes.dart';

const _day = '2026-11-19';
const _older = '2026-11-17';
const _pillKey = ValueKey('home-header-pill');
const _barKey = ValueKey('home-header-day-bar');
const _detailKey = ValueKey('home-header-details');
const _chooserKey = ValueKey('day-nav-choose');
const _downloadKey = ValueKey('home-header-fill:download');
const _calculateKey = ValueKey('home-header-fill:calculate');
const _dotKey = ValueKey('home-header-connection-dot');

class _Sessions extends EmptyTabsRepo {
  @override
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) async => {
    'workouts': [
      {
        'id': 'older', 'type': 'running',
        'start_ts': DateTime(2026, 11, 17, 7).millisecondsSinceEpoch ~/ 1000,
        'duration_min': 42, 'strain': 8.1,
      },
      {
        'id': 'newer', 'type': 'walking',
        'start_ts': DateTime(2026, 11, 18, 8).millisecondsSinceEpoch ~/ 1000,
        'duration_min': 20, 'strain': 3.6,
      },
    ],
  };
}

Widget _header({ValueChanged<String>? onDay}) => HomeHeader(
  tab: HomeHeaderTab.today,
  day: _day,
  days: const [_day, _older],
  onDay: onDay ?? (_) {},
);

Finder _under(Key key, Finder matching) =>
    find.descendant(of: find.byKey(key), matching: matching);

Future<void> _mountHeader(WidgetTester t, PilotHeaderApp app,
    {double scale = 1, ValueChanged<String>? onDay}) async {
  addTearDown(app.dispose);
  await t.pumpWidget(pilotApp(app, Scaffold(body: Column(children: [
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: _header(onDay: onDay)),
    const Expanded(child: SizedBox(key: ValueKey('outside'))),
  ])), scale: scale));
  await t.pump();
}

Future<void> _motion(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 250));
}

void main() {
  setUp(pilotPrefs);
  setUp(h24);
  tearDown(ClockFormatController.debugReset);

  testWidgets('pilot Today shows a 44 dp pill and 48 dp bar with the old header available',
      (t) async {
    final app = PilotHeaderApp(
      pres: pilotIdle(lastSync: DateTime(2026, 11, 19, 22, 58)),
      battery: 50,
    );
    addTearDown(app.dispose);
    final home = pilotApp(app, HomeHeaderOpening(
      play: false, child: Scaffold(body: pilotTab(ShellDomain.today)),
    ));
    await withClock(Clock.fixed(pilotNow), () async {
      await t.pumpWidget(home);
      expect(t.getSize(find.byKey(_pillKey)).height, 44);
      expect(t.getSize(find.byKey(_barKey)).height, 48);
      expect(_under(_pillKey, find.text('Synced 22:58')), findsOneWidget);
      await PilotFlags.set(PilotFlag.homeHeader, false);
      await t.pump();
      expect(find.byKey(_pillKey), findsNothing);
      expect(find.byKey(const ValueKey('shared:header-rows')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('the pill switches between committed records, finished days, battery and error',
      (t) async {
    final app = PilotHeaderApp(
      pres: pilotSync('downloading'), startEdge: pilotStartEdge, battery: 50,
    );
    await withClock(Clock.fixed(pilotNow), () async {
      await _mountHeader(t, app);
      expect(_under(_pillKey, find.text('465 records')), findsOneWidget);
      expect(_under(_pillKey, find.text('14:48 → 22:49')), findsOneWidget);
      expect(_under(_pillKey, find.byIcon(LucideIcons.download)), findsOneWidget);

      app.derive.value = const DeriveProgress(dayIndex: 2, dayTotal: 3);
      app.setPres(pilotSync('deriving'));
      await _motion(t);
      expect(_under(_pillKey, find.text('Day 2 of 3')), findsOneWidget);
      final calc = _under(_pillKey, find.byIcon(LucideIcons.moon));
      expect(find.ancestor(of: calc, matching: find.byType(Opacity)), findsWidgets);
      expect(t.getSize(find.byKey(_downloadKey)).width, t.getSize(find.byKey(_barKey)).width);
      expect(t.getSize(find.byKey(_calculateKey)).width,
          closeTo(t.getSize(find.byKey(_barKey)).width * 2 / 3, .01));

      app.derive.value = const DeriveProgress(dayIndex: 3, dayTotal: 3);
      await _motion(t);
      expect(find.ancestor(of: calc, matching: find.byType(Opacity)), findsNothing);

      app.derive.value = null;
      app.setPres(pilotIdle());
      await t.pump();
      expect(_under(_pillKey, find.text('50%')), findsOneWidget);
      expect(_under(_pillKey, find.text('Synced 13:26')), findsOneWidget);
      expect(find.byKey(_dotKey), findsOneWidget);

      app.setPres(pilotSync('failed'));
      await t.pump();
      expect(_under(_pillKey, find.text('Band disconnected during sync')), findsOneWidget);
      expect(_under(_pillKey, find.byIcon(LucideIcons.triangleAlert)), findsOneWidget);
      expect(find.byKey(_dotKey), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('download fill uses elapsed band time, then the reported target', (t) async {
    final app = PilotHeaderApp(
      pres: pilotSync('downloading'), startEdge: pilotStartEdge,
    );
    var now = pilotNow;
    await withClock(Clock(() => now), () async {
      await _mountHeader(t, app);
      final width = t.getSize(find.byKey(_barKey)).width;
      double fill() => t.getSize(find.byKey(_downloadKey)).width;
      // 85 minutes landed within an initial 566-minute guess.
      expect(fill(), closeTo(width * 85 / 566, .01));

      now = DateTime(2026, 11, 19, 23, 9);
      await t.pump(const Duration(seconds: 30));
      await _motion(t);
      expect(fill(), closeTo(width * 85 / 586, .01));
      expect(_under(_pillKey, find.text('14:48 → 23:09')), findsOneWidget);

      final reported = DateTime(2026, 11, 19, 16, 13);
      app.setPres(pilotSync('downloading', newest: reported));
      await _motion(t);
      expect(fill(), closeTo(width / 2, .01));
      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('opening fades out, holds empty and fades into the date only on the first tab',
      (t) async {
    final app = PilotHeaderApp(pres: pilotIdle())..repo = EmptyTabsRepo();
    addTearDown(app.dispose);
    pilotSurface(t);
    await withClock(Clock.fixed(pilotNow), () async {
      await t.pumpWidget(pilotApp(app, HomeHeaderOpening(child: AppShell(
        builder: (_, domain) => pilotTab(domain),
      ))));
      final day = find.byKey(_barKey);
      final greeting = _under(_barKey, find.text('Good evening'));
      final cycle = _under(_barKey, find.text('Cycle of Nov 19'));
      double opacity(Finder target) =>
          t.widget<Opacity>(find.ancestor(of: target, matching: find.byType(Opacity)).first).opacity;

      expect(opacity(greeting), 1);
      await t.pump(const Duration(milliseconds: 2240));
      expect(opacity(greeting), closeTo(.5, .03));
      await t.pump(const Duration(milliseconds: 420));
      expect(find.descendant(of: day, matching: find.byType(Text)), findsNothing);
      await t.pump(const Duration(milliseconds: 560));
      expect(opacity(cycle), closeTo(.5, .03));
      await t.pump(const Duration(milliseconds: 300));
      expect(opacity(cycle), 1);

      await t.tap(find.widgetWithText(Pressable, 'Sleep').last);
      await t.pump();
      expect(_under(_barKey, find.text('Night of Nov 19')), findsOneWidget);
      expect(greeting, findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  });

  test('the battery bands meet the exact cutoffs at A = 20 and A = 30', () {
    const red = Color(0xfff87171), amber = Color(0xfffb923c),
        grey = Color(0xff7f8da0), mint = Color(0xff86efac), green = Color(0xff22c55e);
    for (final a in [20, 30]) {
      expect([
        for (final level in [a - 1, a, a + 9, a + 10, 59, 60, 79, 80, 100])
          headerBatteryColor(level, a),
      ], [red, amber, amber, grey, grey, mint, mint, green, green]);
    }
  });

  for (final (alertAt, expected) in [(null, C.batteryAmber), (30, C.syncWarning)]) {
    testWidgets('25% uses the stored alert, or 20% when unset ($alertAt)', (t) async {
      await pilotPrefs(alertAt: alertAt);
      final app = PilotHeaderApp(pres: pilotIdle(), battery: 25);
      await withClock(Clock.fixed(pilotNow), () async {
        await _mountHeader(t, app);
        expect(t.widget<Text>(_under(_pillKey, find.text('25%'))).style?.color, expected);
        await t.tapAt(t.getTopLeft(find.byKey(_pillKey)) + const Offset(52, 22));
        await _motion(t);
        expect(t.widget<Text>(_under(_detailKey, find.text('25%'))).style?.color, expected);
        expect(find.byKey(_dotKey), findsNothing);
        await t.pumpWidget(const SizedBox());
      });
    });
  }

  for (final compact in [false, true]) {
    testWidgets('at 360 dp and 1.3x, the count truncates before its time (compact=$compact)',
        (t) async {
      await pilotPrefs(compact: compact);
      pilotSurface(t, width: 360);
      final app = PilotHeaderApp(pres: pilotSync('downloading', records: 1234567890),
        startEdge: pilotStartEdge, battery: 25);
      await withClock(Clock.fixed(pilotNow), () async {
        await _mountHeader(t, app, scale: 1.3);
        if (compact) {
          await t.longPress(find.byKey(_chooserKey));
        } else {
          await t.tapAt(t.getTopLeft(find.byKey(_pillKey)) + const Offset(52, 22));
        }
        await _motion(t);
        final count = _under(_detailKey, find.text('1234567890'));
        final time = _under(_detailKey, find.text('14:48 → 22:49'));
        expect(t.renderObject<RenderParagraph>(count).didExceedMaxLines, isTrue);
        expect(t.renderObject<RenderParagraph>(time).didExceedMaxLines, isFalse);
        expect(t.getRect(count).right, lessThan(t.getRect(time).left));
        expect(t.getCenter(count).dy, closeTo(t.getCenter(time).dy, 2));
        expect(t.takeException(), isNull);
        if (compact) {
          await t.tapAt(t.getCenter(find.byKey(const ValueKey('outside'))));
          await _motion(t);
          expect(find.byKey(_detailKey), findsNothing);
          expect(t.getSize(find.byKey(_barKey)).height, 48);
        }
        await t.pumpWidget(const SizedBox());
      });
    });
  }

  testWidgets('Today, Sleep and Activity share header bounds and status at the same moment',
      (t) async {
    pilotSurface(t);
    final app = PilotHeaderApp(pres: pilotSync('deriving'), startEdge: pilotStartEdge)
      ..derive.value = const DeriveProgress(dayIndex: 2, dayTotal: 3)
      ..repo = EmptyTabsRepo();
    addTearDown(app.dispose);
    await withClock(Clock.fixed(pilotNow), () async {
      await t.pumpWidget(pilotApp(app, HomeHeaderOpening(child: AppShell(
        builder: (_, domain) => pilotTab(domain),
      ))));
      await t.pump(const Duration(seconds: 4));
      final reference = (t.getRect(find.byKey(_pillKey)), t.getRect(find.byKey(_barKey)));
      for (final (domain, label) in [
        (ShellDomain.today, 'Cycle of Nov 19'), (ShellDomain.sleep, 'Night of Nov 19'),
        (ShellDomain.activity, 'Thu, Nov 19'),
      ]) {
        if (domain != ShellDomain.today) {
          await t.tap(find.widgetWithText(Pressable, domain.label).last);
          await t.pump();
        }
        expect((t.getRect(find.byKey(_pillKey)), t.getRect(find.byKey(_barKey))), reference);
        expect(_under(_barKey, find.text(label)), findsOneWidget);
        expect(_under(_pillKey, find.text('Day 2 of 3')), findsOneWidget);
      }
      await t.pumpWidget(const SizedBox());
    });
  });

  for (final summary in [false, true]) {
    testWidgets('Sleep keeps one day stepper (summary=$summary)', (t) async {
      await pilotPrefs(sleepSummary: summary);
      final app = PilotHeaderApp(pres: pilotIdle());
      addTearDown(app.dispose);
      pilotSurface(t);
      await withClock(Clock.fixed(pilotNow), () async {
        await t.pumpWidget(pilotApp(app, Scaffold(body: pilotTab(ShellDomain.sleep))));
        expect(find.byKey(const ValueKey('day-nav-previous')), findsOneWidget,
            reason: 'the day control moves out of the Sleep timeline card');
        expect(_under(_barKey, find.text('Night of Nov 19')), findsOneWidget);
        await t.pumpWidget(const SizedBox());
      });
    });
  }

  testWidgets('Activity moves History within the tab by session date', (t) async {
    pilotSurface(t);
    final app = PilotHeaderApp(pres: pilotIdle())..repo = _Sessions();
    addTearDown(app.dispose);
    await withClock(Clock.fixed(pilotNow), () async {
      await t.pumpWidget(pilotApp(app, Scaffold(body: pilotTab(ShellDomain.activity))));
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      final previous = find.byKey(const ValueKey('day-nav-previous'));
      final next = find.byKey(const ValueKey('day-nav-next'));
      await t.tap(previous);
      await t.pump();
      expect(_under(_barKey, find.text('Wed, Nov 18')), findsOneWidget);
      expect(find.text('Walking'), findsOneWidget);
      expect(find.text('Running'), findsNothing);
      await t.tap(previous);
      await t.pump();
      expect(_under(_barKey, find.text('Tue, Nov 17')), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Walking'), findsNothing);
      await t.tap(next);
      await t.pump();
      expect(_under(_barKey, find.text('Wed, Nov 18')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  testWidgets('Appearance persists Compact and shows its hints', (t) async {
    final app = PilotHeaderApp();
    addTearDown(app.dispose);
    await t.pumpWidget(pilotApp(app, const Scaffold(body: HomeHeaderChoice())));
    expect(find.textContaining('Long press', findRichText: true), findsNothing);
    await t.tap(find.text('Compact'));
    await _motion(t);
    expect(find.textContaining('Long press', findRichText: true), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(HomeHeader.compactKey), isTrue);
    await t.pumpWidget(const SizedBox());
  });
}
