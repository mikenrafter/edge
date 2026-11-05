// The "this is a band" / "sensor without a band" sheets, and the tap flow that
// decides which one a scanned device gets. Rendered, with a fake pairing
// operation: no BLE.
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/band_identity.dart';
import 'package:openstrap_edge/ble/hrs_link.dart' show BandCandidate;
import 'package:openstrap_edge/ui2/pairing/add_device_flow.dart';
import 'package:openstrap_edge/ui2/pairing/pair_sheets.dart';

import 'support/pair_ui_support.dart';

BandCandidate _cand(String entryId,
        {String id = 'AA:BB:CC:DD:EE:01', String? label, BandEntry? alsoBand}) =>
    (
      device: BluetoothDevice.fromId(id),
      label: label,
      rssi: -60,
      entryId: entryId,
      alsoBand: alsoBand == null ? null : (entry: alsoBand, modelCertain: true),
    );

/// A screen with one button that runs [flow] on [cand] and prints the result.
class _Harness extends StatefulWidget {
  final AddDeviceFlow flow;
  final BandCandidate cand;
  const _Harness(this.flow, this.cand);
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String result = 'none';
  @override
  Widget build(BuildContext c) => Scaffold(
        body: Column(children: [
          TextButton(
              onPressed: () async {
                final r = await widget.flow.onTap(c, widget.cand);
                setState(() => result = '${r.outcome.name}|${r.message ?? ''}');
              },
              child: const Text('tap')),
          Text(result, key: const ValueKey('result')),
        ]),
      );
}

class _Calls implements AddDeviceIo {
  final pairs = <(String entryId, PairConfirmation? confirmation)>[];
  final opened = <String>[];
  final events = <String>[];
  String? heldBack;
  final List<PairOutcome> outcomes;
  _Calls([this.outcomes = const [PairOutcome.saved()]]);
  int _i = 0;
  bool _hasMain = false;
  @override
  bool get hasMainBand => _hasMain;
  @override
  Future<PairOutcome> pair(BandCandidate cand, BandEntry entry,
      PairConfirmation? confirmation) async {
    events.add('pair:${entry.id}');
    pairs.add((entry.id, confirmation));
    return outcomes[_i < outcomes.length ? _i++ : outcomes.length - 1];
  }

  @override
  Future<void> openBandFlow(BandEntry band) async {
    events.add('open:${band.id}');
    opened.add(band.id);
  }

  @override
  Future<void> stopScan() async => events.add('stop');

  @override
  Future<String?> mainBandBlockedReason() async => heldBack;

  AddDeviceFlow flow({bool hasMain = false}) {
    _hasMain = hasMain;
    return AddDeviceFlow(this);
  }
}

String _result(WidgetTester t) =>
    (t.widget(find.byKey(const ValueKey('result'))) as Text).data!;

Future<void> _tap(WidgetTester t, _Calls calls, BandCandidate cand,
    {bool hasMain = false}) async {
  await pumpPair(t, _Harness(calls.flow(hasMain: hasMain), cand),
      size: const Size(412, 1100));
  await t.tap(find.text('tap'));
  await t.pumpAndSettle();
}

void main() {
  group('the band-found sheet', () {
    Future<BandSheetChoice?> open(WidgetTester t, BandEntry band,
        {required bool hasMain, bool afterConnect = false}) async {
      BandSheetChoice? got;
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async => got = await showBandFoundSheet(c,
                          band: band,
                          hasMainBand: hasMain,
                          afterConnect: afterConnect),
                      child: const Text('open')))),
          size: const Size(412, 1100));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return got;
    }

    testWidgets('no main band yet: pair it as my band, or a secondary sensor anyway', (t) async {
      await open(t, kWhoopGen5, hasMain: false);
      expect(find.text('This is WHOOP 5'), findsOneWidget);
      expect(find.text('It does much more as your band than as a sensor. Which do you want?'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('Pair it as my band'), findsOneWidget);
      expect(find.text('Use it as a secondary sensor anyway'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
    });

    testWidgets('the matrix shows what a sensor would NOT send', (t) async {
      await open(t, kWhoopGen5, hasMain: false);
      final sleepSensor = t.getSemantics(find.byKey(const ValueKey('slot-sensor-sleep')));
      expect(sleepSensor.label, 'Doesn’t send');
    });

    testWidgets('the choices come back to the caller', (t) async {
      BandSheetChoice? got;
      Future<void> run(String label) async {
        await pumpPair(
            t,
            Builder(
                builder: (c) => Scaffold(
                    body: TextButton(
                        onPressed: () async => got = await showBandFoundSheet(c,
                            band: kWhoopGen5, hasMainBand: false),
                        child: const Text('open')))),
            size: const Size(412, 1100));
        await t.tap(find.text('open'));
        await t.pumpAndSettle();
        await t.tap(find.text(label));
        await t.pumpAndSettle();
      }

      await run('Pair it as my band');
      expect(got, BandSheetChoice.asBand);
      got = null;
      await run('Use it as a secondary sensor anyway');
      expect(got, BandSheetChoice.asSensor);
      got = BandSheetChoice.asBand;
      await run('Go back');
      expect(got, isNull);
    });

    testWidgets('a main band already exists: only the secondary-sensor button', (t) async {
      await open(t, kWhoopGen5, hasMain: true);
      expect(find.text('Use it as a secondary sensor'), findsOneWidget);
      expect(find.text('Pair it as my band'), findsNothing);
      expect(find.text('Use it as a secondary sensor anyway'), findsNothing);
      expect(find.text('You already have a band paired, so this can only be a secondary sensor.'), findsOneWidget);
      expect(t.getSemantics(find.byKey(const ValueKey('slot-sensor-sleep'))).label, 'Doesn’t send');
    });

    testWidgets('a device the app cannot use as a main band: only secondary sensor, and says why', (t) async {
      await open(t, kCoros, hasMain: false);
      expect(find.text('This is Coros watch'), findsOneWidget);
      expect(find.text('Use it as a secondary sensor'), findsOneWidget);
      expect(find.text('Pair it as my band'), findsNothing);
      expect(find.textContaining('can’t use it as your main band yet'), findsOneWidget);
    });

    testWidgets('a non-WHOOP band shows the main-band column as unavailable, with the reason', (t) async {
      await open(t, kOura, hasMain: false);
      expect(find.text('Only WHOOP is supported as the main band'), findsOneWidget);
      final sleep = t.getSemantics(find.byKey(const ValueKey('slot-band-sleep')));
      expect(sleep.label, 'Only WHOOP is supported as the main band');
      expect(find.byIcon(LucideIcons.check), findsNothing, reason: 'no check in either column for Oura');
    });

    testWidgets('a WHOOP does not carry that reason', (t) async {
      await open(t, kWhoopGen5, hasMain: false);
      expect(find.text('Only WHOOP is supported as the main band'), findsNothing);
      expect(t.getSemantics(find.byKey(const ValueKey('slot-band-sleep'))).label, 'Sends');
    });

    testWidgets('after connecting: says it identified itself, and that nothing was saved', (t) async {
      await open(t, kWhoopGen5, hasMain: false, afterConnect: true);
      expect(
          find.text('It looked like a heart-rate strap, but when we connected it identified itself as WHOOP 5. Nothing was saved.'),
          findsOneWidget);
      expect(find.text('Pair it as my band'), findsOneWidget);
    });

    testWidgets('German at 2x text does not overflow', (t) async {
      BandSheetChoice? ignore;
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async => ignore = await showBandFoundSheet(c,
                          band: kWhoopGen5, hasMainBand: false),
                      child: const Text('open')))),
          locale: const Locale('de'), textScale: 2, size: const Size(360, 900));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(ignore, isNull);
    });
  });

  group('the sensor-without-a-band sheet', () {
    Future<void> open(WidgetTester t, BandEntry sensor, void Function(bool?) got) async {
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async =>
                          got(await showSensorWithoutBandSheet(c, sensor: sensor)),
                      child: const Text('open')))),
          size: const Size(412, 1100));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }

    testWidgets('a heart-rate strap: A band vs This strap, and the anyway button', (t) async {
      await open(t, kBleHrs, (_) {});
      expect(find.text('Pair a sensor without a band?'), findsOneWidget);
      expect(find.text('A band'), findsOneWidget);
      expect(find.text('This strap'), findsOneWidget);
      expect(find.text('Pair it as a sensor anyway'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
      expect(t.getSemantics(find.byKey(const ValueKey('slot-band-sleep'))).label, 'Sends');
      expect(t.getSemantics(find.byKey(const ValueKey('slot-sensor-sleep'))).label, 'Doesn’t send');
      expect(t.getSemantics(find.byKey(const ValueKey('slot-sensor-workoutHeartRate'))).label, 'Sends');
    });

    testWidgets('another kind of sensor reads “This device”', (t) async {
      await open(t, kPolarPmd, (_) {});
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('This strap'), findsNothing);
    });

    testWidgets('anyway returns true, Go back false', (t) async {
      bool? got;
      await open(t, kBleHrs, (v) => got = v);
      await t.tap(find.text('Pair it as a sensor anyway'));
      await t.pumpAndSettle();
      expect(got, isTrue);
      await open(t, kBleHrs, (v) => got = v);
      await t.tap(find.text('Go back'));
      await t.pumpAndSettle();
      expect(got, isFalse);
    });
  });

  group('tap flow', () {
    final whoopAsStrap = _cand('ble_hrs', label: 'Jordan’s WHOOP', alsoBand: kWhoopGen5);

    testWidgets('a WHOOP heard as a strap, no band yet: sheet, then “secondary anyway” pairs with a confirmation bound to that device and entry', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoopAsStrap);
      expect(find.text('This is WHOOP 5'), findsOneWidget);
      await t.tap(find.text('Use it as a secondary sensor anyway'));
      await t.pumpAndSettle();
      expect(calls.pairs.length, 1);
      expect(calls.pairs.single.$1, 'ble_hrs');
      expect(calls.pairs.single.$2!.remoteId, 'AA:BB:CC:DD:EE:01');
      expect(calls.pairs.single.$2!.bandEntryId, 'gen5');
      expect(_result(t), 'pairedSecondary|');
    });

    testWidgets('“Pair it as my band” goes to the main band flow and pairs nothing here', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoopAsStrap);
      await t.tap(find.text('Pair it as my band'));
      await t.pumpAndSettle();
      expect(calls.pairs, isEmpty);
      expect(calls.opened, ['gen5']);
      expect(_result(t), 'openedBandFlow|');
    });

    testWidgets('Go back pairs nothing and opens nothing', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoopAsStrap);
      await t.tap(find.text('Go back'));
      await t.pumpAndSettle();
      expect(calls.pairs, isEmpty);
      expect(calls.opened, isEmpty);
      expect(_result(t), 'cancelled|');
    });

    testWidgets('a band already paired: the same sheet, secondary only, pairs with the confirmation', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoopAsStrap, hasMain: true);
      expect(find.text('Pair it as my band'), findsNothing);
      await t.tap(find.text('Use it as a secondary sensor'));
      await t.pumpAndSettle();
      expect(calls.pairs.single.$2!.bandEntryId, 'gen5');
      expect(_result(t), 'pairedSecondary|');
    });

    testWidgets('a plain strap and no band: the W4 sheet, then pairs without a confirmation', (t) async {
      final calls = _Calls();
      await _tap(t, calls, _cand('ble_hrs', label: 'Polar H10'));
      expect(find.text('Pair a sensor without a band?'), findsOneWidget);
      await t.tap(find.text('Pair it as a sensor anyway'));
      await t.pumpAndSettle();
      expect(calls.pairs.single.$1, 'ble_hrs');
      expect(calls.pairs.single.$2, isNull);
      expect(_result(t), 'pairedSecondary|');
    });

    testWidgets('a plain strap, declined: nothing pairs', (t) async {
      final calls = _Calls();
      await _tap(t, calls, _cand('ble_hrs'));
      await t.tap(find.text('Go back'));
      await t.pumpAndSettle();
      expect(calls.pairs, isEmpty);
      expect(_result(t), 'cancelled|');
    });

    testWidgets('a plain strap with a band already paired pairs at once, no sheet', (t) async {
      final calls = _Calls();
      await _tap(t, calls, _cand('ble_hrs'), hasMain: true);
      expect(find.text('Pair a sensor without a band?'), findsNothing);
      expect(calls.pairs.single.$1, 'ble_hrs');
      expect(_result(t), 'pairedSecondary|');
    });

    testWidgets('a thermometer is not a secondary sensor: no sheet, and no secondary message', (t) async {
      final calls = _Calls();
      await _tap(t, calls, _cand('thermometer'));
      expect(find.text('Pair a sensor without a band?'), findsNothing);
      expect(calls.pairs.single.$1, 'thermometer');
      expect(_result(t), 'pairedOther|');
    });

    testWidgets('a connect that finds a band: the identified-itself sheet; confirming re-runs pairing with the confirmation', (t) async {
      final calls = _Calls([PairOutcome.band(kWhoopGen5), const PairOutcome.saved()]);
      await _tap(t, calls, _cand('ble_hrs', label: 'Polar H10'), hasMain: true);
      expect(find.textContaining('identified itself as WHOOP 5. Nothing was saved.'), findsOneWidget);
      await t.tap(find.text('Use it as a secondary sensor'));
      await t.pumpAndSettle();
      expect(calls.pairs.length, 2);
      expect(calls.pairs[0].$2, isNull);
      expect(calls.pairs[1].$2!.remoteId, 'AA:BB:CC:DD:EE:01');
      expect(calls.pairs[1].$2!.bandEntryId, 'gen5');
      expect(_result(t), 'pairedSecondary|');
    });

    testWidgets('a connect that finds a band, no main band: “Pair it as my band” opens that flow', (t) async {
      final calls = _Calls([PairOutcome.band(kWhoopGen5)]);
      await _tap(t, calls, _cand('ble_hrs'), hasMain: false);
      // The strap sheet first (nothing known yet), then the band sheet after connect.
      await t.tap(find.text('Pair it as a sensor anyway'));
      await t.pumpAndSettle();
      expect(find.textContaining('identified itself as WHOOP 5'), findsOneWidget);
      await t.tap(find.text('Pair it as my band'));
      await t.pumpAndSettle();
      expect(calls.pairs.length, 1);
      expect(calls.opened, ['gen5']);
      expect(_result(t), 'openedBandFlow|');
    });

    testWidgets('a connect that finds a band, then Go back: pairing ran once and nothing was saved', (t) async {
      final calls = _Calls([PairOutcome.band(kWhoopGen5)]);
      await _tap(t, calls, _cand('ble_hrs'), hasMain: true);
      await t.tap(find.text('Go back'));
      await t.pumpAndSettle();
      expect(calls.pairs.length, 1);
      expect(_result(t), 'cancelled|');
    });

    testWidgets('a failure comes back as its sentence', (t) async {
      final calls = _Calls([const PairOutcome.failed('The sensor did not answer.')]);
      await _tap(t, calls, _cand('ble_hrs'), hasMain: true);
      expect(_result(t), 'failed|The sensor did not answer.');
    });

    testWidgets('a ring (a band in its own right) gets the band sheet, and its own screen does the pairing', (t) async {
      final calls = _Calls();
      await _tap(t, calls, _cand('oura', label: 'Oura Ring'));
      expect(find.text('This is Oura Ring'), findsOneWidget);
      // Not a WHOOP, so there is no main-band choice (DT12): one button.
      expect(find.text('Pair it as my band'), findsNothing);
      await t.tap(find.text('Use it as a secondary sensor'));
      await t.pumpAndSettle();
      // The ring needs its own key screen, so it never pairs from here.
      expect(calls.pairs, isEmpty);
      expect(calls.opened, ['oura']);
    });
  });

  group('G3 r1 S2: browsing goes through the same confirmations', () {
    // A button that runs confirmBrowse and prints the answer.
    Future<bool?> browse(WidgetTester t, _Calls calls, BandEntry e,
        {required bool hasMain, String? tapLabel}) async {
      bool? got;
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async =>
                          got = await calls.flow(hasMain: hasMain).confirmBrowse(c, e),
                      child: const Text('go')))),
          size: const Size(412, 1100));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      if (tapLabel != null) {
        await t.tap(find.text(tapLabel));
        await t.pumpAndSettle();
      }
      return got;
    }

    testWidgets('the generic heart-rate sensor with no main band asks first; Go back says no', (t) async {
      final calls = _Calls();
      final got = await browse(t, calls, kBleHrs, hasMain: false, tapLabel: 'Go back');
      expect(got, isFalse);
    });

    testWidgets('... and “Pair it as a sensor anyway” says yes', (t) async {
      final calls = _Calls();
      expect(await browse(t, calls, kBleHrs, hasMain: false, tapLabel: 'Pair it as a sensor anyway'), isTrue);
    });

    testWidgets('Polar PMD is a workout sensor too: same sheet', (t) async {
      final calls = _Calls();
      await browse(t, calls, kPolarPmd, hasMain: false);
      expect(find.text('Pair a sensor without a band?'), findsOneWidget);
    });

    testWidgets('with a main band, or for a device that is its own entry, no sheet', (t) async {
      final calls = _Calls();
      expect(await browse(t, calls, kBleHrs, hasMain: true), isTrue);
      expect(find.text('Pair a sensor without a band?'), findsNothing);
      expect(await browse(t, calls, kColmi, hasMain: false), isTrue);
      expect(find.text('Pair a sensor without a band?'), findsNothing);
    });

    testWidgets('a connect that finds a band (category path): band-found sheet, then re-pair with the confirmation', (t) async {
      final calls = _Calls([const PairOutcome.saved()]);
      bool? ok;
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        final r = await calls.flow(hasMain: true).afterConnect(
                            c, _cand('ble_hrs'), kBleHrs, PairOutcome.band(kWhoopGen5));
                        ok = r.outcome == AddDeviceOutcome.pairedSecondary;
                      },
                      child: const Text('go')))),
          size: const Size(412, 1100));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.textContaining('identified itself as WHOOP 5. Nothing was saved.'), findsOneWidget);
      await t.tap(find.text('Use it as a secondary sensor'));
      await t.pumpAndSettle();
      expect(calls.pairs.single.$2!.bandEntryId, 'gen5');
      expect(ok, isTrue);
    });
  });

  group('G3 r1 S3: the handoff to the main-band flow', () {
    final whoopOnly = _cand('gen5', label: 'WHOOP 5A1B');

    testWidgets('the scan is stopped BEFORE the main-band flow opens', (t) async {
      final calls = _Calls();
      await _tap(t, calls, whoopOnly);
      await t.tap(find.text('Pair it as my band'));
      await t.pumpAndSettle();
      expect(calls.events, ['stop', 'open:gen5']);
      expect(_result(t), 'openedBandFlow|');
    });

    testWidgets('where the system pairing sheet cannot open (iOS, no provisioned band) restart guidance replaces it', (t) async {
      final calls = _Calls()..heldBack = 'Restart the app before you pair it.';
      await _tap(t, calls, whoopOnly);
      await t.tap(find.text('Pair it as my band'));
      await t.pumpAndSettle();
      expect(calls.opened, isEmpty);
      expect(calls.events, ['stop']);
      expect(_result(t), 'bandFlowHeldBack|Restart the app before you pair it.');
    });
  });

  group('G3 r1 S4: a WHOOP-only advertisement', () {
    testWidgets('the band-choice flow runs for a scanned framed entry; a secondary choice pairs under ble_hrs with the confirmation', (t) async {
      final calls = _Calls();
      await _tap(t, calls, _cand('gen5', label: 'WHOOP 5A1B'), hasMain: true);
      expect(find.text('This is WHOOP 5'), findsOneWidget);
      await t.tap(find.text('Use it as a secondary sensor'));
      await t.pumpAndSettle();
      expect(calls.pairs.single.$1, 'ble_hrs');
      expect(calls.pairs.single.$2!.bandEntryId, 'gen5');
      expect(_result(t), 'pairedSecondary|');
    });
  });
}
