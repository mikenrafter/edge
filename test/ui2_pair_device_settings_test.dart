// Settings > My sources > "Pair a device": no band, a band paired, and what
// the "Add a device" screen adds (pills, band badge, the paired notice).
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/hrs_link.dart' show BandCandidate;
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/pairing/device_picker.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/pair_ui_support.dart';

HealthSource _band([String name = 'Tyler’s WHOOP 5.0 / MG']) => HealthSource(
      name: name,
      kind: 'WHOOP',
      tier: SourceTier.phone,
      icon: Icons.watch,
      connected: true,
      isBand: true,
    );

HealthSource _strap() => const HealthSource(
      name: 'Polar H10',
      kind: 'Bluetooth heart rate sensor',
      tier: SourceTier.beatToBeat,
      icon: Icons.favorite,
      isBand: false,
      deviceId: 'ble_hrs-0a1b2c3d',
      family: 'ble_hrs',
    );

BandCandidate _cand(String entryId,
        {String id = 'AA:BB:CC:DD:EE:01', String? label, BandEntry? alsoBand}) =>
    (
      device: BluetoothDevice.fromId(id),
      label: label,
      rssi: -60,
      entryId: entryId,
      alsoBand: alsoBand == null ? null : (entry: alsoBand, modelCertain: true),
    );

void main() {
  group('My sources: Pair a device', () {
    Widget view(List<HealthSource> sources,
            {VoidCallback? onPair, VoidCallback? onAdd, VoidCallback? onUnpair}) =>
        MyDevicesView(
            sources: sources,
            onPair: onPair,
            onAddSensor: onAdd,
            onUnpair: onUnpair);

    testWidgets('no band: a Pair your band card that opens the band flow, and an Add a device row', (t) async {
      var pair = 0, add = 0;
      await pumpPair(t, view(const [], onPair: () => pair++, onAdd: () => add++),
          size: const Size(412, 1400));
      expect(find.text('Pair a device'), findsOneWidget);
      expect(find.byKey(const ValueKey('pair-band-card')), findsOneWidget);
      await t.tap(find.descendant(
          of: find.byKey(const ValueKey('pair-band-card')),
          matching: find.byType(BigButton)));
      expect(pair, 1);
      await t.tap(find.text('Add a device'));
      expect(add, 1);
      expect(find.text('Unpair band'), findsNothing);
      expect(find.byKey(const ValueKey('band-paired-card')), findsNothing);
    });

    testWidgets('the section says plainly that only WHOOP is the main band, with or without one paired', (t) async {
      const note = 'Main band: WHOOP 4.0 or WHOOP 5.0/MG only. Other devices can be added as additional devices.';
      await pumpPair(t, view(const [], onPair: () {}, onAdd: () {}), size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('main-band-whoop-only-note')), findsOneWidget);
      expect(find.text(note), findsOneWidget);
      await pumpPair(t, view([_band()], onUnpair: () {}, onAdd: () {}), size: const Size(412, 1400));
      expect(find.text(note), findsOneWidget);
    });

    testWidgets('the old “Add a sensor” row is gone', (t) async {
      await pumpPair(t, view(const [], onPair: () {}, onAdd: () {}), size: const Size(412, 1400));
      expect(find.text('Add a sensor'), findsNothing);
    });

    testWidgets('the missing-band status card no longer carries a second Pair button', (t) async {
      await pumpPair(t, view(const [], onPair: () {}, onAdd: () {}), size: const Size(412, 1400));
      expect(find.text('Nothing is measuring yet'), findsOneWidget);
      expect(find.text('Pair a band'), findsNothing);
      expect(find.byType(BigButton), findsOneWidget);
    });

    testWidgets('a paired strap is not a band: still the Pair your band card', (t) async {
      await pumpPair(t, view([_strap()], onPair: () {}, onAdd: () {}), size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('pair-band-card')), findsOneWidget);
    });

    testWidgets('a band paired: says which, says to unpair first, offers Unpair band, still Add a device', (t) async {
      var unpair = 0, add = 0;
      await pumpPair(t, view([_band()], onPair: () {}, onAdd: () => add++, onUnpair: () => unpair++),
          size: const Size(412, 1400));
      expect(find.byKey(const ValueKey('pair-band-card')), findsNothing);
      final card = find.byKey(const ValueKey('band-paired-card'));
      expect(card, findsOneWidget);
      expect(
          find.descendant(
              of: card,
              matching: find.text(
                  'You already have a band paired: Tyler’s WHOOP 5.0 / MG. Unpair it first to switch to another band.')),
          findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Paired')), findsOneWidget);
      await t.tap(find.text('Unpair band'));
      expect(unpair, 1);
      await t.tap(find.text('Add a device'));
      expect(add, 1);
    });

    testWidgets('Unpair band is a red outline, not a filled button', (t) async {
      await pumpPair(t, view([_band()], onUnpair: () {}), size: const Size(412, 1400));
      final p = P.of(t.element(find.text('Unpair band')));
      final box = t.widget<Container>(find.ancestor(
          of: find.text('Unpair band'), matching: find.byType(Container)).first);
      final deco = box.decoration! as BoxDecoration;
      expect(deco.color, isNull);
      expect((deco.border! as Border).top.color, p.on(C.red));
    });

    testWidgets('no callbacks, no band: no Pair a device section at all', (t) async {
      await pumpPair(t, const MyDevicesView(), size: const Size(412, 1400));
      expect(find.text('Pair a device'), findsNothing);
    });

    testWidgets('the forget flow asks first, and Keep it paired changes nothing', (t) async {
      final app = AppState();
      addTearDown(app.dispose);
      await pumpPair(
          t,
          Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () => debugConfirmForgetBand(c, app, 'Tyler’s WHOOP'),
                      child: const Text('go')))),
          size: const Size(412, 900));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.text('Forget Tyler’s WHOOP?'), findsOneWidget);
      await t.tap(find.text('Keep it paired'));
      await t.pumpAndSettle();
      expect(find.text('Forget Tyler’s WHOOP?'), findsNothing);
    });

    testWidgets('German at 2x text does not overflow, in either state', (t) async {
      for (final sources in [const <HealthSource>[], [_band()]]) {
        await pumpPair(t, view(sources, onPair: () {}, onAdd: () {}, onUnpair: () {}),
            locale: const Locale('de'), textScale: 2, size: const Size(360, 1800));
        final ex = t.takeException();
        expect(ex, isNull, reason: ex is FlutterError ? ex.toStringDeep() : '$ex');
      }
    });
  });

  group('Add a device (the unified scan screen)', () {
    DevicePickerView view({
      List<BandCandidate> found = const [],
      List<({BandEntry entry, String blurb, IconData icon})> categories = const [],
      ValueNotifier<DeviceKind?>? kindSelection,
      String? notice,
      ValueChanged<BandCandidate>? onPick,
    }) =>
        DevicePickerView(
          query: TextEditingController(),
          title: 'Add a device',
          subtitle: 'Scan once.',
          found: found,
          categories: categories,
          kindSelection: kindSelection ?? ValueNotifier<DeviceKind?>(null),
          notice: notice,
          onPickNearby: onPick,
        );

    testWidgets('a WHOOP heard as a strap is tagged as a band; a plain strap is not', (t) async {
      await pumpPair(
          t,
          view(found: [
            _cand('ble_hrs', label: 'Jordan’s WHOOP', alsoBand: kWhoopGen5, id: 'AA:01'),
            _cand('ble_hrs', label: 'Polar H10', id: 'AA:02'),
          ]),
          size: const Size(412, 1400));
      expect(find.text('This is a band'), findsOneWidget);
      expect(
          find.descendant(
              of: find.ancestor(of: find.text('Jordan’s WHOOP'), matching: find.byType(Surface)).first,
              matching: find.text('This is a band')),
          findsOneWidget);
    });

    testWidgets('a candidate that is a band in its own right (a ring) is tagged too', (t) async {
      await pumpPair(t, view(found: [_cand('oura', label: 'Oura Ring')]), size: const Size(412, 1400));
      expect(find.text('This is a band'), findsOneWidget);
    });

    testWidgets('pills cover the found devices and the browse list; Rings narrows both', (t) async {
      final kind = ValueNotifier<DeviceKind?>(null);
      Widget harness() => ValueListenableBuilder<DeviceKind?>(
          valueListenable: kind,
          builder: (_, _, _) => view(
              kindSelection: kind,
              found: [
                _cand('oura', label: 'Oura Ring', id: 'AA:01'),
                _cand('ble_hrs', label: 'Polar H10', id: 'AA:02'),
              ],
              categories: [
                (entry: kOura, blurb: 'ring blurb', icon: Icons.circle),
                (entry: kBleHrs, blurb: 'strap blurb', icon: Icons.favorite),
              ]));
      await pumpPair(t, harness(), size: const Size(412, 1400));
      expect(find.text('Rings'), findsOneWidget);
      expect(find.text('Chest straps'), findsOneWidget);
      await t.tap(find.text('Rings'));
      await t.pumpAndSettle();
      expect(kind.value, DeviceKind.ring);
      expect(find.text('Polar H10'), findsNothing);
      expect(find.text('Oura Ring'), findsWidgets);
      expect(find.text('strap blurb'), findsNothing);
      expect(find.text('ring blurb'), findsOneWidget);
    });

    testWidgets('no pills when onKind is not supplied (the old screen is unchanged)', (t) async {
      await pumpPair(
          t,
          DevicePickerView(
              query: TextEditingController(),
              title: 't',
              subtitle: 's',
              found: [_cand('oura', label: 'Oura Ring'), _cand('ble_hrs', label: 'Polar H10', id: 'AA:02')]),
          size: const Size(412, 1400));
      expect(find.text('All'), findsNothing);
    });

    testWidgets('after a secondary sensor pairs: “You paired a secondary sensor.”', (t) async {
      await pumpPair(t, view(notice: 'You paired a secondary sensor.'), size: const Size(412, 1400));
      expect(find.text('You paired a secondary sensor.'), findsOneWidget);
    });

    testWidgets('tapping a nearby row hands the candidate over', (t) async {
      final got = <String>[];
      await pumpPair(t, view(found: [_cand('ble_hrs', label: 'Polar H10')], onPick: (c) => got.add(c.entryId)),
          size: const Size(412, 1400));
      await t.tap(find.text('Polar H10'));
      expect(got, ['ble_hrs']);
    });
  });
}
