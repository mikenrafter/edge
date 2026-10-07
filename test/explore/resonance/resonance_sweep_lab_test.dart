// Sol P1: the sweep is opened from the Device lab, whose LabSession stays
// mounted underneath. While the lab is "open" the band queue rejects every
// immediate non-lab job, and the sweep's pacing cues are immediate jobs, so
// every cue was refused.
//
// Real pieces: AppState.forTesting (its haptics queue, its hardware-probe
// runner wired to beginLab/endLab), the real LabSession, and the real
// ResonanceSweepEntry that pushes the real sweep screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/explore/resonance/resonance_sweep_screen.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

/// One immediate phase-cue-shaped job, as the sweep sends them.
Future<BuzzDelivery> _cue(AppState app) => app.haptics.asImmediate(
      () => app.haptics.runJob(1, (job) async => BuzzDelivery.complete),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setBool(Prefs.exploreResonance, true);
    app = AppState.forTesting();
  });
  tearDown(() => app.dispose());

  Future<void> pumpLab(WidgetTester t) async {
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        Provider<Capabilities>.value(
            value: Capabilities(const CapabilityInputs(devMode: true))),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: LabSession(
            runner: app.hardwareProbes,
            child: const ResonanceSweepEntry(),
          ),
        ),
      ),
    ));
    await t.pump();
  }

  Future<BuzzDelivery> tryCue(WidgetTester t) async {
    BuzzDelivery? out;
    _cue(app).then((v) => out = v);
    await t.pump(const Duration(seconds: 5));
    return out ?? BuzzDelivery.rejected;
  }

  testWidgets('with the sweep screen on top of the Lab, a pacing cue is '
      'accepted', (t) async {
    await pumpLab(t);
    expect(app.haptics.labOpen, isTrue, reason: 'the Lab itself is open');

    await t.tap(find.text('Pacing rates compared'));
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Stop if you feel dizzy or short of breath'),
        findsOneWidget,
        reason: 'the sweep screen is on top');

    expect(app.haptics.labOpen, isFalse,
        reason: 'a Lab covered by the sweep must not hold the queue');
    expect(await tryCue(t), BuzzDelivery.complete);
  });

  // Guard (passes today and must keep passing): coming back to the Lab
  // re-opens it, and the queue's rules for a Lab on screen are unchanged.
  testWidgets('going back to the Lab holds the queue again; leaving it '
      'frees the queue', (t) async {
    await pumpLab(t);
    await t.tap(find.text('Pacing rates compared'));
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));

    final navigator = t.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(app.haptics.labOpen, isTrue);
    expect(await tryCue(t), BuzzDelivery.rejected,
        reason: 'an open Lab still rejects an immediate non-lab job');

    await t.pumpWidget(const SizedBox());
    expect(app.haptics.labOpen, isFalse);
  });

  // The release is explicit to the sweep page. Any other page pushed over the
  // lab (the pattern probe's, for one) keeps the lab's hold on the queue.
  testWidgets('a plain page pushed over LabSession does not end the lab',
      (t) async {
    await t.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(
        home: Scaffold(
          body: LabSession(
            runner: app.hardwareProbes,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('probe page'))),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('probe page'), findsOneWidget);
    expect(app.haptics.labOpen, isTrue);
    expect(await tryCue(t), BuzzDelivery.rejected);
  });
}
