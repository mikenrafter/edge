// The two swappable pairing building blocks: the capability matrix (C1) and
// the category filter pills (K3), plus the registry field the pills read.
// Rendered, not read: both are layout.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/slot_comparison.dart';
import 'package:openstrap_edge/ui2/pairing/category_filter_pills.dart';
import 'package:openstrap_edge/ui2/pairing/slot_comparison_view.dart';

import 'support/pair_ui_support.dart';

Finder _mark(String side, DeviceCapability c) =>
    find.byKey(ValueKey('slot-$side-${c.name}'));

bool _hasIcon(WidgetTester t, Finder mark, IconData icon) => t
    .widgetList<Icon>(find.descendant(of: mark, matching: find.byType(Icon)))
    .any((i) => i.icon == icon);

bool _sel(SemanticsNode n) => n.getSemanticsData().flagsCollection.isSelected == Tristate.isTrue;

void main() {
  group('BandEntry.kind', () {
    test('every registry entry says what it physically is', () {
      // WHY: an `other` default would put a new device under the catch-all pill.
      final other = [
        for (final e in kBandRegistry)
          if (e.kind == DeviceKind.other) e.id
      ];
      expect(other, isEmpty);
    });

    test('the kinds the owner named', () {
      expect(kWhoopGen4.kind, DeviceKind.strap);
      expect(kWhoopGen5.kind, DeviceKind.strap);
      expect(kOura.kind, DeviceKind.ring);
      expect(kColmi.kind, DeviceKind.ring);
      expect(kUltrahuman.kind, DeviceKind.ring);
      expect(kGarmin.kind, DeviceKind.watch);
      expect(kMiBand234.kind, DeviceKind.band);
      expect(kBleHrs.kind, DeviceKind.chestStrap);
      expect(kThermometer.kind, DeviceKind.thermometer);
      expect(kMiScale2.kind, DeviceKind.scale);
    });
  });

  group('CategoryFilterPills (K3)', () {
    Widget pills(List<DeviceKind> kinds,
            {DeviceKind? selected, ValueNotifier<DeviceKind?>? selection}) =>
        Scaffold(
          body: CategoryFilterPills(
              kinds: kinds,
              selection: selection ?? ValueNotifier<DeviceKind?>(selected)),
        );

    testWidgets('shows All first, then only the kinds that have entries, in a fixed order',
        (t) async {
      await pumpPair(t, pills([DeviceKind.ring, DeviceKind.strap, DeviceKind.ring]));
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Straps'), findsOneWidget);
      expect(find.text('Rings'), findsOneWidget);
      expect(find.text('Watches'), findsNothing);
      expect(find.text('Bands'), findsNothing);
      // Straps come before Rings whatever order the entries arrive in.
      expect(t.getTopLeft(find.text('Straps')).dx,
          lessThan(t.getTopLeft(find.text('Rings')).dx));
      expect(t.getTopLeft(find.text('All')).dx,
          lessThan(t.getTopLeft(find.text('Straps')).dx));
    });

    testWidgets('a list with a single kind shows no pills at all', (t) async {
      await pumpPair(t, pills([DeviceKind.ring, DeviceKind.ring]));
      expect(find.text('All'), findsNothing);
      expect(find.text('Rings'), findsNothing);
    });

    testWidgets('tapping a pill reports its kind; All reports null', (t) async {
      final got = <DeviceKind?>[];
      final sel = ValueNotifier<DeviceKind?>(DeviceKind.ring);
      sel.addListener(() => got.add(sel.value));
      await pumpPair(t, pills([DeviceKind.ring, DeviceKind.watch], selection: sel));
      await t.tap(find.text('Watches'));
      await t.tap(find.text('All'));
      expect(got, [DeviceKind.watch, null]);
    });

    testWidgets('the selected pill is marked selected for screen readers, the rest are not',
        (t) async {
      await pumpPair(
          t, pills([DeviceKind.ring, DeviceKind.watch], selected: DeviceKind.ring));
      final s = t.getSemantics(find.byKey(const ValueKey('pill-ring')));
      expect(_sel(s), isTrue);
      final o = t.getSemantics(find.byKey(const ValueKey('pill-watch')));
      expect(_sel(o), isFalse);
    });

    testWidgets('nothing selected means All is the selected pill', (t) async {
      await pumpPair(t, pills([DeviceKind.ring, DeviceKind.watch]));
      expect(_sel(t.getSemantics(find.byKey(const ValueKey('pill-all')))), isTrue);
    });

    testWidgets('labels follow the locale', (t) async {
      await pumpPair(t, pills([DeviceKind.ring, DeviceKind.watch]),
          locale: const Locale('de'));
      expect(find.text('Alle'), findsOneWidget);
      expect(find.text('Ringe'), findsOneWidget);
      expect(find.text('Uhren'), findsOneWidget);
    });

    testWidgets('five kinds wrap instead of overflowing at 2x text on a narrow phone',
        (t) async {
      await pumpPair(
          t,
          pills([
            DeviceKind.strap,
            DeviceKind.ring,
            DeviceKind.watch,
            DeviceKind.band,
            DeviceKind.chestStrap
          ]),
          textScale: 2,
          size: const Size(320, 700));
      expect(t.takeException(), isNull);
    });

    test('filterByKind keeps only that kind, null keeps all', () {
      final all = [kWhoopGen5, kOura, kColmi, kMiBand234];
      expect(filterByKind(all, null), all);
      expect(filterByKind(all, DeviceKind.ring), [kOura, kColmi]);
    });
  });

  group('slot rows (pure)', () {
    final whoop = slotComparisonFor(kWhoopGen5);
    final strap = slotComparisonFor(kBleHrs);

    test('a WHOOP lists its five whole-day outputs plus the two workout lines', () {
      final rows = slotRowsFor(whoop);
      expect([for (final r in rows) r.capability], [
        DeviceCapability.sleep,
        DeviceCapability.recovery,
        DeviceCapability.strain,
        DeviceCapability.hrv,
        DeviceCapability.skinTemperature,
        DeviceCapability.workoutHeartRate,
        DeviceCapability.workoutBeatToBeat,
      ]);
    });

    test('a band gives workout heart rate too; a sensor gives no whole-day output', () {
      final rows = {for (final r in slotRowsFor(whoop)) r.capability: r};
      expect(rows[DeviceCapability.workoutHeartRate]!.band, isNotNull);
      expect(rows[DeviceCapability.workoutHeartRate]!.sensor, isNotNull);
      expect(rows[DeviceCapability.sleep]!.band, isNotNull);
      expect(rows[DeviceCapability.sleep]!.sensor, isNull);
    });

    test('skin temperature keeps its condition', () {
      final r = slotRowsFor(whoop)
          .firstWhere((r) => r.capability == DeviceCapability.skinTemperature);
      expect(r.band!.kind, CapabilityKind.conditional);
      expect(r.band!.reasonKey, kReasonSkinTempNights);
    });

    test('a strap alone has no band column to claim: its rows are its own sensor lines plus the slot gaps', () {
      final rows = {for (final r in slotRowsFor(strap)) r.capability: r};
      // WHY: "Doesn't send" must stay visible for what a secondary sensor lacks.
      expect(rows[DeviceCapability.sleep]!.sensor, isNull);
      expect(rows[DeviceCapability.workoutHeartRate]!.sensor, isNotNull);
      expect(rows[DeviceCapability.workoutHeartRate]!.band, isNull);
    });
  });

  group('SlotComparisonView (C1)', () {
    testWidgets('one row per capability with Band and Sensor marks', (t) async {
      await pumpPair(t,
          Scaffold(body: SingleChildScrollView(child: SlotComparisonView(comparison: slotComparisonFor(kWhoopGen5)))));
      expect(find.text('Band'), findsOneWidget);
      expect(find.text('Sensor'), findsOneWidget);
      for (final c in [
        DeviceCapability.sleep,
        DeviceCapability.recovery,
        DeviceCapability.strain,
        DeviceCapability.hrv,
        DeviceCapability.skinTemperature,
        DeviceCapability.workoutHeartRate,
        DeviceCapability.workoutBeatToBeat,
      ]) {
        expect(find.byKey(ValueKey('slot-row-${c.name}')), findsOneWidget, reason: c.name);
      }
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('Heart rate during workouts'), findsOneWidget);
    });

    testWidgets('a check where it sends, a dash where it does not', (t) async {
      await pumpPair(t,
          Scaffold(body: SingleChildScrollView(child: SlotComparisonView(comparison: slotComparisonFor(kWhoopGen5)))));
      expect(_hasIcon(t, _mark('band', DeviceCapability.sleep), LucideIcons.check), isTrue);
      expect(_hasIcon(t, _mark('sensor', DeviceCapability.sleep), LucideIcons.minus), isTrue);
      expect(_hasIcon(t, _mark('sensor', DeviceCapability.sleep), LucideIcons.check), isFalse);
      expect(_hasIcon(t, _mark('sensor', DeviceCapability.workoutHeartRate), LucideIcons.check), isTrue);
    });

    testWidgets('marks say Sends or Doesn’t send to a screen reader', (t) async {
      await pumpPair(t,
          Scaffold(body: SingleChildScrollView(child: SlotComparisonView(comparison: slotComparisonFor(kWhoopGen5)))));
      expect(t.getSemantics(_mark('band', DeviceCapability.sleep)).label, 'Sends');
      expect(t.getSemantics(_mark('sensor', DeviceCapability.sleep)).label, 'Doesn’t send');
    });

    testWidgets('a conditional capability shows its reason line under the label', (t) async {
      await pumpPair(t,
          Scaffold(body: SingleChildScrollView(child: SlotComparisonView(comparison: slotComparisonFor(kWhoopGen5)))));
      expect(find.text('Skin temperature change, after a few nights'), findsOneWidget);
      // Only the conditional row carries a reason.
      expect(find.text('An estimate, not a direct reading'), findsNothing);
    });

    testWidgets('custom column headings replace Band and Sensor', (t) async {
      await pumpPair(
          t,
          Scaffold(
              body: SingleChildScrollView(
                  child: SlotComparisonView(
                      comparison: slotComparisonFor(kWhoopGen5),
                      bandHeading: 'A band',
                      sensorHeading: 'This strap'))));
      expect(find.text('A band'), findsOneWidget);
      expect(find.text('This strap'), findsOneWidget);
      expect(find.text('Band'), findsNothing);
    });

    testWidgets('a vendor-reported value says so instead of looking native', (t) async {
      await pumpPair(
          t,
          const Scaffold(
              body: SingleChildScrollView(
                  child: SlotComparisonView(
                      comparison: SlotComparison(
                          asBand: SlotSide(sends: {
                            DeviceCapability.sleep:
                                CapabilityStatus(CapabilityKind.vendorReported)
                          }, doesNotSend: {}),
                          asSensor: SlotSide(sends: {}, doesNotSend: {DeviceCapability.sleep}))))));
      expect(find.text('The device’s own reading'), findsOneWidget);
    });

    testWidgets('a device that sends nothing as a sensor says so (G2 r1 S2)', (t) async {
      // WHY: Oura is not a workout source, so its sensor column is all dashes.
      // Dashes alone would read as a bug; the card says it in words.
      expect(slotComparisonFor(kOura).asSensor.sends, isEmpty);
      await pumpPair(t,
          Scaffold(body: SingleChildScrollView(child: SlotComparisonView(comparison: slotComparisonFor(kOura)))));
      expect(find.byKey(const ValueKey('slot-sensor-sends-nothing')), findsOneWidget);
      expect(find.text('As a sensor, it sends none of these.'), findsOneWidget);
      for (final r in slotRowsFor(slotComparisonFor(kOura))) {
        expect(r.sensor, isNull, reason: r.capability.name);
      }
    });

    testWidgets('bandUnavailableReason blanks the band column and says why (B)', (t) async {
      await pumpPair(t,
          Scaffold(body: SingleChildScrollView(child: SlotComparisonView(
              comparison: slotComparisonFor(kBleHrs), bandUnavailableReason: 'Only WHOOP is supported as the main band'))));
      expect(find.byKey(const ValueKey('slot-band-unavailable')), findsOneWidget);
      expect(find.text('Only WHOOP is supported as the main band'), findsOneWidget);
      for (final k in ['sleep', 'workoutHeartRate']) {
        expect(t.getSemantics(find.byKey(ValueKey('slot-band-$k'))).label, 'Only WHOOP is supported as the main band');
      }
      // The sensor column keeps its own marks.
      expect(t.getSemantics(find.byKey(const ValueKey('slot-sensor-workoutHeartRate'))).label, 'Sends');
    });

    testWidgets('without a reason the band column is untouched', (t) async {
      await pumpPair(t,
          Scaffold(body: SingleChildScrollView(child: SlotComparisonView(comparison: slotComparisonFor(kWhoopGen5)))));
      expect(find.byKey(const ValueKey('slot-band-unavailable')), findsNothing);
      expect(t.getSemantics(find.byKey(const ValueKey('slot-band-sleep'))).label, 'Sends');
    });

    test('the two whole-WHOOP-only strings exist, non-blank, in every locale', () {
      for (final f in Directory('lib/l10n').listSync().whereType<File>().where((f) => RegExp(r'app_\w+\.arb$').hasMatch(f.path))) {
        final arb = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        for (final k in ['pairMainBandWhoopOnly', 'pairMainBandUnavailable']) {
          expect(arb[k], isA<String>(), reason: '${f.path} $k');
          expect((arb[k] as String).trim(), isNotEmpty, reason: '${f.path} $k');
        }
      }
    });

    testWidgets('a device that does send as a sensor shows no such note', (t) async {
      await pumpPair(t,
          Scaffold(body: SingleChildScrollView(child: SlotComparisonView(comparison: slotComparisonFor(kBleHrs)))));
      expect(find.byKey(const ValueKey('slot-sensor-sends-nothing')), findsNothing);
    });

    testWidgets('the note fits in German at 2x text', (t) async {
      await pumpPair(t,
          Scaffold(body: SingleChildScrollView(child: SlotComparisonView(comparison: slotComparisonFor(kCoros)))),
          locale: const Locale('de'), textScale: 2, size: const Size(360, 900));
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('slot-sensor-sends-nothing')), findsOneWidget);
    });

    testWidgets('German headings and rows render without overflow at 2x text', (t) async {
      await pumpPair(t,
          Scaffold(body: SingleChildScrollView(child: SlotComparisonView(comparison: slotComparisonFor(kWhoopGen5)))),
          locale: const Locale('de'), textScale: 2, size: const Size(360, 900));
      expect(t.takeException(), isNull);
      expect(find.text('Schlaf'), findsOneWidget);
    });
  });
}
