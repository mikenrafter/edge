// BedtimeScreen and BedtimeEntry: Bedtime breathing cues, with an optional stop
// when the band estimates sleep. Evidence: Tsai et al. 2015,
// doi:10.1111/psyp.12333.
//
// The screen must be honest: the sleep stop often will not trigger (the band
// needs about 20 minutes of data before it can estimate sleep); it never shows a
// fall-asleep time; it never uses treatment or guarantee language. The entry is
// developer-only AND behind a default-off flag.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_pacing_policy.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_screen.dart';
import 'package:openstrap_edge/explore/bedtime/bedtime_session_controller.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/bedtime_rig.dart';

const _title = 'Bedtime breathing cues';
const _subtitle =
    'Bedtime breathing cues, with an optional stop when the band estimates sleep.';
const _stopHelper =
    'The band needs about 20 minutes of data before it can estimate sleep, so this often won\'t trigger';

final _banned = RegExp(
  r'\b(insomnia\w*|treat\w*|cure\w*|guarantee\w*)\b|fell asleep in',
  caseSensitive: false,
);

const _reasonText = {
  BedtimeStopReason.durationCap: 'Stopped: the time limit was reached',
  BedtimeStopReason.sleepEstimated: 'Stopped: the band estimated sleep',
  BedtimeStopReason.userStopped: 'Stopped: you stopped the session',
  BedtimeStopReason.deliveryFailing:
      'Stopped: the band was not receiving the cues',
  BedtimeStopReason.disconnected: 'Stopped: the band disconnected',
};

Future<void> _pumpScreen(WidgetTester t, BedtimeRig r) async {
  t.view.physicalSize = const Size(1170, 3000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: BedtimeScreen(controller: r.controller),
  ));
  await t.pump();
}

/// Run [body] on the real event loop, then show the result.
Future<void> _drive(WidgetTester t, Future<void> Function() body) async {
  await t.runAsync(body);
  await t.pump();
}

List<String> _texts(WidgetTester t) => [
      for (final w in t.widgetList<Text>(find.byType(Text)))
        w.data ?? w.textSpan?.toPlainText() ?? '',
    ];

void _expectHonestWording(WidgetTester t, {String? where}) {
  for (final s in _texts(t)) {
    expect(_banned.hasMatch(s), isFalse, reason: '"$s" ${where ?? ''}');
    expect(s.toLowerCase(), isNot(contains('asleep')),
        reason: '"$s": no fall-asleep claim ${where ?? ''}');
  }
}

/// Drive the rig to [why].
Future<void> _end(BedtimeRig r, BedtimeStopReason why) async {
  switch (why) {
    case BedtimeStopReason.userStopped:
      await r.start();
      await r.at(0);
      await r.controller.stop();
    case BedtimeStopReason.durationCap:
      await r.start();
      await r.at(0);
      await r.at(60);
    case BedtimeStopReason.sleepEstimated:
      await r.start();
      // RE-PACED (review P2, skipped phases): to() ticks every 5 s on the way.
      for (final s in [0, 30, 60, 90, 91]) {
        await r.to(s);
      }
    case BedtimeStopReason.deliveryFailing:
      await r.start();
      for (final s in [0, 5, 10, 10.5]) {
        await r.at(s);
      }
    case BedtimeStopReason.disconnected:
      await r.start();
      await r.at(0);
      r.connected = false;
      await r.at(5);
  }
}

BedtimeRig _rigFor(BedtimeStopReason why) => switch (why) {
      BedtimeStopReason.sleepEstimated => BedtimeRig(
          plan: BedtimePlan(stopOnSleep: true),
          script: (c) => bedtimeObs('nrem', c)),
      BedtimeStopReason.durationCap =>
        BedtimeRig(plan: BedtimePlan(duration: const Duration(minutes: 1))),
      BedtimeStopReason.deliveryFailing =>
        BedtimeRig()..deliverResult = false,
      _ => BedtimeRig(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });
  setUp(() async {
    await Prefs.ensureLoaded();
    await (await SharedPreferences.getInstance()).clear();
  });

  group('setup (idle)', () {
    testWidgets('titled "Bedtime breathing cues" with the honest one-liner',
        (t) async {
      await _pumpScreen(t, BedtimeRig());
      expect(find.text(_title), findsWidgets);
      expect(find.text(_subtitle), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
    });

    testWidgets('a pace picker offers a fixed pace or a taper; fixed to begin with',
        (t) async {
      final r = BedtimeRig();
      await _pumpScreen(t, r);
      expect(find.text('Fixed pace'), findsOneWidget);
      expect(find.text('Taper'), findsOneWidget);
      expect(r.controller.plan.endBpm, r.controller.plan.startBpm);

      await t.tap(find.text('Taper'));
      await t.pump();
      final taper = r.controller.plan;
      expect(taper.endBpm, lessThan(taper.startBpm),
          reason: 'a taper slows down');
      expect(taper.startBpm, inInclusiveRange(kBedtimeMinBpm, kBedtimeMaxBpm));
      expect(taper.endBpm, inInclusiveRange(kBedtimeMinBpm, kBedtimeMaxBpm));

      await t.tap(find.text('Fixed pace'));
      await t.pump();
      expect(r.controller.plan.endBpm, r.controller.plan.startBpm);
    });

    testWidgets('picking a pace keeps the duration and the stop choice',
        (t) async {
      final r = BedtimeRig(
          plan: BedtimePlan(
              duration: const Duration(minutes: 12), stopOnSleep: true));
      await _pumpScreen(t, r);
      await t.tap(find.text('Taper'));
      await t.pump();
      expect(r.controller.plan.duration, const Duration(minutes: 12));
      expect(r.controller.plan.stopOnSleep, isTrue);
    });

    testWidgets('the duration control runs 1 to 20 minutes, 15 to begin with',
        (t) async {
      final r = BedtimeRig();
      await _pumpScreen(t, r);
      final slider = t.widget<Slider>(find.byType(Slider));
      expect(slider.min, 1);
      expect(slider.max, 20);
      expect(slider.value, 15);
    });

    testWidgets('dragging the duration as far as it goes stops at 20 minutes',
        (t) async {
      final r = BedtimeRig();
      await _pumpScreen(t, r);
      await t.drag(find.byType(Slider), const Offset(3000, 0));
      await t.pump();
      expect(r.controller.plan.duration, const Duration(minutes: 20));
      expect(t.widget<Slider>(find.byType(Slider)).max, 20);
    });

    testWidgets('dragging it all the way back is 1 minute, never zero',
        (t) async {
      final r = BedtimeRig();
      await _pumpScreen(t, r);
      await t.drag(find.byType(Slider), const Offset(-3000, 0));
      await t.pump();
      expect(r.controller.plan.duration, const Duration(minutes: 1));
    });

    testWidgets('the stop-on-sleep switch is off by default and says why it often will not trigger',
        (t) async {
      final r = BedtimeRig();
      await _pumpScreen(t, r);
      expect(find.text(_stopHelper), findsOneWidget);
      expect(t.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(r.controller.plan.stopOnSleep, isFalse);

      await t.tap(find.byType(Switch));
      await t.pump();
      expect(r.controller.plan.stopOnSleep, isTrue);
      expect(t.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text(_stopHelper), findsOneWidget,
          reason: 'the caveat stays visible when it is on');
    });

    testWidgets('no sleep estimate is shown before a session runs', (t) async {
      await _pumpScreen(t, BedtimeRig(plan: BedtimePlan(stopOnSleep: true)));
      expect(find.textContaining('Sleep estimate'), findsNothing);
    });

    testWidgets('Start begins the session and Stop ends it as stopped by you',
        (t) async {
      final r = BedtimeRig();
      await _pumpScreen(t, r);
      await t.tap(find.text('Start'));
      await t.pump();
      await t.runAsync(() => pumpEventQueue());
      await t.pump();
      expect(r.controller.state, BedtimeState.running);
      expect(find.text('Start'), findsNothing);
      expect(find.text('Stop'), findsOneWidget);

      await t.tap(find.text('Stop'));
      await t.pump();
      await t.runAsync(() => pumpEventQueue());
      await t.pump();
      expect(r.controller.state, BedtimeState.ended);
      expect(find.text(_reasonText[BedtimeStopReason.userStopped]!),
          findsOneWidget);
      expect(r.releases, 1);
    });
  });

  group('running', () {
    testWidgets('shows the sleep-estimate status, starting as unavailable',
        (t) async {
      final r = BedtimeRig(plan: BedtimePlan(stopOnSleep: true));
      await _pumpScreen(t, r);
      await _drive(t, r.start);
      expect(find.text('Sleep estimate: unavailable'), findsOneWidget);
      await _drive(t, r.controller.stop);
    });

    testWidgets('follows the stager: not yet sustained, awake, unavailable',
        (t) async {
      final r = BedtimeRig(plan: BedtimePlan(stopOnSleep: true));
      await _pumpScreen(t, r);
      await _drive(t, r.start);

      r.script = (c) => bedtimeObs('nrem', c);
      await _drive(t, () => r.at(0));
      expect(find.text('Sleep estimate: not yet sustained'), findsOneWidget);

      r.script = (c) => bedtimeObs('wake', c);
      await _drive(t, () => r.to(30)); // RE-PACED (review P2, skipped phases)
      expect(find.text('Sleep estimate: awake'), findsOneWidget);

      r.script = (c) => bedtimeObs('absent', c);
      await _drive(t, () => r.to(60)); // RE-PACED (review P2, skipped phases)
      expect(find.text('Sleep estimate: unavailable'), findsOneWidget);
      await _drive(t, r.controller.stop);
    });

    testWidgets('without stop-on-sleep there is no sleep estimate line', (t) async {
      final r = BedtimeRig();
      await _pumpScreen(t, r);
      await _drive(t, r.start);
      await _drive(t, () => r.at(0));
      expect(find.textContaining('Sleep estimate'), findsNothing);
      await _drive(t, r.controller.stop);
    });

    testWidgets('the setup controls are gone while it runs', (t) async {
      final r = BedtimeRig();
      await _pumpScreen(t, r);
      await _drive(t, r.start);
      expect(find.byType(Slider), findsNothing);
      expect(find.text('Fixed pace'), findsNothing);
      await _drive(t, r.controller.stop);
    });

    testWidgets('shows the phase word the band is cueing', (t) async {
      final r = BedtimeRig();
      await _pumpScreen(t, r);
      await _drive(t, r.start);
      await _drive(t, () => r.at(0));
      expect(find.text('Inhale'), findsOneWidget);
      await _drive(t, () => r.at(5));
      expect(find.text('Exhale'), findsOneWidget);
      await _drive(t, r.controller.stop);
    });
  });

  group('ended', () {
    for (final why in BedtimeStopReason.values) {
      testWidgets('${why.name} reads "${_reasonText[why]}"', (t) async {
        final r = _rigFor(why);
        await _pumpScreen(t, r);
        await _drive(t, () => _end(r, why));
        expect(r.controller.stopReason, why);
        expect(find.text(_reasonText[why]!), findsOneWidget);
        for (final other in BedtimeStopReason.values.where((o) => o != why)) {
          expect(find.text(_reasonText[other]!), findsNothing);
        }
        _expectHonestWording(t, where: 'after ${why.name}');
      });
    }

    testWidgets('a sleep stop never shows how long it took to fall asleep',
        (t) async {
      final r = _rigFor(BedtimeStopReason.sleepEstimated);
      await _pumpScreen(t, r);
      await _drive(t, () => _end(r, BedtimeStopReason.sleepEstimated));
      for (final s in _texts(t)) {
        expect(s.toLowerCase(), isNot(contains('asleep')), reason: s);
        expect(s.toLowerCase(), isNot(contains('fell')), reason: s);
      }
      expect(find.text(_reasonText[BedtimeStopReason.sleepEstimated]!),
          findsOneWidget,
          reason: 'the whole reason is that sentence, with no minutes in it');
    });
  });

  group('wording', () {
    testWidgets('no insomnia / treat / cure / guarantee / "fell asleep in" when idle',
        (t) async {
      await _pumpScreen(t, BedtimeRig(plan: BedtimePlan(stopOnSleep: true)));
      expect(_texts(t), isNotEmpty);
      _expectHonestWording(t, where: 'idle');
    });

    testWidgets('and none while running', (t) async {
      final r = BedtimeRig(
          plan: BedtimePlan(stopOnSleep: true),
          script: (c) => bedtimeObs('nrem', c));
      await _pumpScreen(t, r);
      await _drive(t, r.start);
      await _drive(t, () => r.at(0));
      expect(_texts(t), isNotEmpty);
      _expectHonestWording(t, where: 'running');
      await _drive(t, r.controller.stop);
    });

    test('the banned-word check itself catches what it should', () {
      for (final bad in [
        'Insomnia relief',
        'Treat sleep problems',
        'a cure',
        'Guaranteed sleep',
        'You fell asleep in 9 minutes',
      ]) {
        expect(_banned.hasMatch(bad), isTrue, reason: bad);
      }
      expect(_banned.hasMatch('Bedtime breathing cues'), isFalse);
      expect(_banned.hasMatch('secure link'), isFalse);
    });
  });

  group('BedtimeEntry', () {
    Future<void> pumpEntry(
      WidgetTester t, {
      required bool developerMode,
      required bool flag,
      VoidCallback? onOpen,
    }) async {
      await t.runAsync(() => Prefs.setBoolAcked(Prefs.exploreBedtime, flag));
      await t.pumpWidget(Provider<Capabilities>.value(
        value: Capabilities(CapabilityInputs(devMode: developerMode)),
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: BedtimeEntry(onOpen: onOpen ?? () {})),
        ),
      ));
      await t.pump();
    }

    testWidgets('shown with developer mode on AND the flag on', (t) async {
      await pumpEntry(t, developerMode: true, flag: true);
      expect(find.text(_title), findsOneWidget);
    });

    testWidgets('tapping it opens the screen', (t) async {
      var opened = 0;
      await pumpEntry(t, developerMode: true, flag: true, onOpen: () => opened++);
      await t.tap(find.text(_title));
      await t.pump();
      expect(opened, 1);
    });

    testWidgets('absent with developer mode off, flag on', (t) async {
      await pumpEntry(t, developerMode: false, flag: true);
      expect(find.text(_title), findsNothing);
    });

    testWidgets('absent with developer mode on, flag off', (t) async {
      await pumpEntry(t, developerMode: true, flag: false);
      expect(find.text(_title), findsNothing);
    });

    testWidgets('absent with both off', (t) async {
      await pumpEntry(t, developerMode: false, flag: false);
      expect(find.text(_title), findsNothing);
    });

    testWidgets('the flag is off when never set', (t) async {
      await t.pumpWidget(Provider<Capabilities>.value(
        value: const Capabilities(CapabilityInputs(devMode: true)),
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: BedtimeEntry(onOpen: () {})),
        ),
      ));
      await t.pump();
      expect(Prefs.getBool(Prefs.exploreBedtime, false), isFalse);
      expect(find.text(_title), findsNothing);
    });

    testWidgets('the flag key is its own, not developer mode', (t) async {
      expect(Prefs.exploreBedtime, isNot(Prefs.devMode));
      expect(Prefs.exploreBedtime, isNotEmpty);
    });
  });
}
