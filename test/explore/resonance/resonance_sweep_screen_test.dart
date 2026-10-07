// Light widget tests for the developer-only sweep screen and its Device lab
// entry. The screen is driven by a fake controller that reports whatever
// state a test sets, so only the screen's wording and wiring are under test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/explore/resonance/resonance_analyzer.dart';
import 'package:openstrap_edge/explore/resonance/resonance_history.dart';
import 'package:openstrap_edge/explore/resonance/resonance_sweep_controller.dart';
import 'package:openstrap_edge/explore/resonance/resonance_sweep_screen.dart';
import 'package:openstrap_edge/explore/resonance/resonance_sweep_plan.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/sweep_fixtures.dart';

const _stopText = 'Stop if you feel dizzy or short of breath';

class FakeController extends ResonanceSweepController {
  FakeController({
    this.fakeState = SweepState.idle,
    this.fakeResult,
    this.fakeError,
  }) : super(
          plan: planFor([6.0, 5.0]),
          isConnected: () => true,
          deliverCue: (_) async => CueDelivery.delivered,
          decodeBeats: (_) async => const [],
          acquireStreams: () async {},
          releaseStreams: () {},
        );

  SweepState fakeState;
  SweepComparison? fakeResult;
  String? fakeError;
  int stopCalls = 0;

  @override
  SweepState get state => fakeState;
  @override
  Duration get elapsed => const Duration(seconds: 42);
  @override
  SweepBlock? get currentBlock => fakeState == SweepState.running
      ? plan.blocks.first
      : null;
  @override
  SweepComparison? get result => fakeResult;
  @override
  String? get error => fakeError;

  @override
  Future<void> start() async {}
  @override
  void tick() {}
  @override
  Future<void> stop() async {
    stopCalls++;
  }

  // The base dispose releases streams; a fake holds none.
  @override
  // ignore: must_call_super
  void dispose() {}
}

BlockResult _block(double rate, double? amp, {BlockRejection? rejection}) =>
    BlockResult(
      rateBpm: rate,
      amplitudeBpm: amp,
      coverage: 0.99,
      observedFraction: 1.0,
      cycles: 10,
      rejection: rejection,
    );

SweepComparison _comparison(ComparisonOutcome outcome,
    {double? rate, ({double lo, double hi})? range}) {
  return SweepComparison(
    blocks: [
      _block(6.5, 6),
      _block(6.0, 8),
      _block(5.5, 12),
      _block(5.0, 8),
      _block(4.5, null, rejection: BlockRejection.movement),
    ],
    outcome: outcome,
    rateBpm: rate,
    range: range,
  );
}

Future<void> _pumpScreen(WidgetTester t, FakeController c) async {
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: ResonanceSweepScreen(
      key: UniqueKey(),
      controller: c,
      history: const ResonanceHistoryStore(),
    ),
  ));
  await t.pump();
}

Iterable<String> _allText(WidgetTester t) => [
      for (final w in t.widgetList<Text>(find.byType(Text)))
        w.data ?? w.textSpan?.toPlainText() ?? '',
    ];

const _banned = ['resonance frequency', 'vagal', 'diagnos', 'treat'];

void _expectNoBannedWords(WidgetTester t) {
  for (final text in _allText(t)) {
    final lower = text.toLowerCase();
    for (final word in _banned) {
      expect(lower.contains(word), isFalse, reason: '"$text" says "$word"');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });

  group('ResonanceSweepScreen', () {
    testWidgets('is titled "Pacing rates compared" with a visible Stop',
        (t) async {
      await _pumpScreen(t, FakeController());
      expect(find.text('Pacing rates compared'), findsOneWidget);
      expect(find.text(_stopText), findsOneWidget);
    });

    testWidgets('Stop is there while running, and calls stop()', (t) async {
      final c = FakeController(fakeState: SweepState.running);
      await _pumpScreen(t, c);
      expect(find.text(_stopText), findsOneWidget);
      await t.tap(find.text(_stopText));
      await t.pump();
      expect(c.stopCalls, 1);
    });

    testWidgets('an inconclusive result says Inconclusive and shows no rate',
        (t) async {
      final c = FakeController(
        fakeState: SweepState.finished,
        fakeResult: _comparison(ComparisonOutcome.inconclusiveFlat),
      );
      await _pumpScreen(t, c);
      expect(find.textContaining('Inconclusive'), findsWidgets);
      expect(find.textContaining('Tentative'), findsNothing);
      for (final text in _allText(t)) {
        expect(text.contains('breaths/min'), isFalse,
            reason: '"$text" shows a rate on an inconclusive result');
      }
    });

    testWidgets('a tentative rate shows one decimal and the unit', (t) async {
      final c = FakeController(
        fakeState: SweepState.finished,
        fakeResult:
            _comparison(ComparisonOutcome.tentativeRate, rate: 5.0),
      );
      await _pumpScreen(t, c);
      expect(find.textContaining('Tentative practice rate'), findsWidgets);
      expect(find.textContaining('5.0 breaths/min'), findsWidgets);
      expect(find.textContaining('Inconclusive'), findsNothing);
    });

    testWidgets('a different tentative rate is shown as given', (t) async {
      final c = FakeController(
        fakeState: SweepState.finished,
        fakeResult:
            _comparison(ComparisonOutcome.tentativeRate, rate: 5.5),
      );
      await _pumpScreen(t, c);
      expect(find.textContaining('5.5 breaths/min'), findsWidgets);
    });

    testWidgets('unknown movement says plainly that no rate is suggested',
        (t) async {
      final c = FakeController(
        fakeState: SweepState.finished,
        fakeResult: SweepComparison(
          blocks: [
            for (final rate in [6.0, 5.0])
              BlockResult(
                rateBpm: rate,
                amplitudeBpm: null,
                coverage: 0.99,
                observedFraction: 1.0,
                cycles: 10,
                rejection: BlockRejection.movementUnknown,
              ),
          ],
          outcome: ComparisonOutcome.inconclusiveTooFewBlocks,
          rateBpm: null,
          range: null,
        ),
      );
      await _pumpScreen(t, c);
      expect(
        find.text("Movement can't be checked yet, so no rate is suggested; "
            'the comparison table still shows each pace.'),
        findsOneWidget,
      );
      expect(find.text("Movement can't be checked"), findsNWidgets(2));
      expect(find.textContaining('Tentative'), findsNothing);
    });

    testWidgets('a failed session shows its error', (t) async {
      final c = FakeController(
        fakeState: SweepState.failed,
        fakeError: 'Connect your band first.',
      );
      await _pumpScreen(t, c);
      expect(find.text('Connect your band first.'), findsOneWidget);
    });

    testWidgets('no state ever uses the banned words', (t) async {
      final states = <FakeController>[
        FakeController(),
        FakeController(fakeState: SweepState.running),
        FakeController(
            fakeState: SweepState.failed, fakeError: 'Connect your band first.'),
        for (final outcome in ComparisonOutcome.values)
          FakeController(
            fakeState: outcome == ComparisonOutcome.stoppedEarly
                ? SweepState.stopped
                : SweepState.finished,
            fakeResult: _comparison(
              outcome,
              rate: outcome == ComparisonOutcome.tentativeRate ? 5.5 : null,
              range: outcome == ComparisonOutcome.tiedRange
                  ? (lo: 5.0, hi: 6.0)
                  : null,
            ),
          ),
      ];
      for (final c in states) {
        await _pumpScreen(t, c);
        expect(_allText(t), isNotEmpty);
        _expectNoBannedWords(t);
      }
    });
  });

  group('ResonanceSweepEntry', () {
    Future<void> pumpEntry(
      WidgetTester t, {
      required bool devMode,
      required bool flag,
    }) async {
      Prefs.setBool(Prefs.exploreResonance, flag);
      await t.pumpWidget(MultiProvider(
        providers: [
          Provider<Capabilities>.value(
              value: Capabilities(CapabilityInputs(devMode: devMode))),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: ResonanceSweepEntry()),
        ),
      ));
      await t.pump();
    }

    testWidgets('is offered with developer mode and the flag both on',
        (t) async {
      await pumpEntry(t, devMode: true, flag: true);
      expect(find.text('Pacing rates compared'), findsOneWidget);
    });

    testWidgets('is absent without developer mode', (t) async {
      await pumpEntry(t, devMode: false, flag: true);
      expect(find.text('Pacing rates compared'), findsNothing);
    });

    testWidgets('is absent with the flag off', (t) async {
      await pumpEntry(t, devMode: true, flag: false);
      expect(find.text('Pacing rates compared'), findsNothing);
    });

    testWidgets('is absent with both off', (t) async {
      await pumpEntry(t, devMode: false, flag: false);
      expect(find.text('Pacing rates compared'), findsNothing);
    });
  });
}
