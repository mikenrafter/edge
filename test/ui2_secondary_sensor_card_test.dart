// The secondary sensor card (S5) and how a secondary sensor reads on the
// sources list and its detail page.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/slot_comparison.dart';
import 'package:openstrap_edge/ui2/pairing/pair_text.dart';
import 'package:openstrap_edge/ui2/pairing/secondary_sensor_card.dart';
import 'package:openstrap_edge/ui2/profile/devices.dart';

import 'support/pair_ui_support.dart';

HealthSource _src(String family, {String name = 'Polar H10', bool isBand = false}) =>
    HealthSource(
      name: name,
      kind: 'Bluetooth heart rate sensor',
      tier: SourceTier.beatToBeat,
      icon: LucideIcons.heartPulse,
      isBand: isBand,
      deviceId: '$family-0a1b2c3d',
      family: family,
    );

Widget _card(BandEntry e, {bool experimental = false}) => Scaffold(
    body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SecondarySensorCard(entry: e, experimental: experimental)));

bool _icon(WidgetTester t, Finder within, IconData icon) => t
    .widgetList<Icon>(find.descendant(of: within, matching: find.byType(Icon)))
    .any((i) => i.icon == icon);

void main() {
  group('which sources get the card', () {
    test('a heart-rate strap and a Polar sensor, not a band or a scale', () {
      expect(secondarySensorEntry(_src('ble_hrs'))?.id, 'ble_hrs');
      expect(secondarySensorEntry(_src('polar_pmd'))?.id, 'polar_pmd');
      expect(secondarySensorEntry(_src('oura')), isNull);
      expect(secondarySensorEntry(_src('thermometer')), isNull);
      expect(secondarySensorEntry(_src('miscale2')), isNull);
      // The primary band is never a secondary sensor.
      expect(secondarySensorEntry(_src('gen5', isBand: true)), isNull);
      // The phone has no device row.
      expect(
          secondarySensorEntry(const HealthSource(
              name: 'This phone',
              kind: 'Motion coprocessor',
              tier: SourceTier.phone,
              icon: Icons.phone_android)),
          isNull);
    });
  });

  group('SecondarySensorCard', () {
    testWidgets('names the role, then what it sends and what it does not', (t) async {
      await pumpPair(t, _card(kBleHrs), size: const Size(412, 1100));
      expect(find.text('Secondary sensor · heart rate during workouts'), findsOneWidget);
      expect(find.text('You paired a secondary sensor.'), findsOneWidget);
      expect(find.text('Sends'), findsOneWidget);
      expect(find.text('Doesn’t send'), findsOneWidget);
    });

    testWidgets('every claim comes from the slot comparison, with a check or a cross', (t) async {
      await pumpPair(t, _card(kBleHrs), size: const Size(412, 1100));
      final cmp = slotComparisonFor(kBleHrs).asSensor;
      final l = pairL10n(t.element(find.byType(SecondarySensorCard)));
      expect(cmp.sends, isNotEmpty);
      for (final k in cmp.sends.keys) {
        final row = find.byKey(ValueKey('secondary-sends-${k.name}'));
        expect(row, findsOneWidget, reason: k.name);
        expect(find.descendant(of: row, matching: find.text(capabilityLabel(l, k))), findsOneWidget);
        expect(_icon(t, row, LucideIcons.check), isTrue, reason: k.name);
      }
      expect(cmp.doesNotSend, containsAll([DeviceCapability.sleep, DeviceCapability.recovery, DeviceCapability.strain]));
      for (final k in cmp.doesNotSend) {
        final row = find.byKey(ValueKey('secondary-doesnt-${k.name}'));
        expect(row, findsOneWidget, reason: k.name);
        expect(_icon(t, row, LucideIcons.x), isTrue, reason: k.name);
      }
    });

    testWidgets('workout heart rate is a Sends line, sleep is a Doesn’t send line', (t) async {
      await pumpPair(t, _card(kBleHrs), size: const Size(412, 1100));
      expect(find.byKey(const ValueKey('secondary-sends-workoutHeartRate')), findsOneWidget);
      expect(find.byKey(const ValueKey('secondary-doesnt-sleep')), findsOneWidget);
      expect(find.byKey(const ValueKey('secondary-sends-sleep')), findsNothing);
    });

    testWidgets('Experimental is a small footnote only when the sensor is experimental', (t) async {
      await pumpPair(t, _card(kBleHrs, experimental: true), size: const Size(412, 1100));
      expect(find.text('Experimental: workout readings from this sensor are still being checked.'), findsOneWidget);
      await pumpPair(t, _card(kBleHrs), size: const Size(412, 1100));
      expect(find.textContaining('Experimental'), findsNothing);
    });

    testWidgets('no Tier wording in the card', (t) async {
      await pumpPair(t, _card(kBleHrs, experimental: true), size: const Size(412, 1100));
      expect(find.textContaining('Tier'), findsNothing);
    });

    testWidgets('German at 2x text does not overflow', (t) async {
      await pumpPair(t, _card(kPolarPmd, experimental: true),
          locale: const Locale('de'), textScale: 2, size: const Size(360, 1800));
      expect(t.takeException(), isNull);
      expect(find.text('Du hast einen zusätzlichen Sensor gekoppelt.'), findsOneWidget);
    });
  });

  group('on the sources list', () {
    testWidgets('a secondary sensor row has no Tier pill and no Experimental word', (t) async {
      await pumpPair(t, Scaffold(body: SourceRow(_src('ble_hrs'))), size: const Size(412, 600));
      expect(find.textContaining('Tier'), findsNothing);
      expect(find.text('Experimental'), findsNothing);
      expect(find.text('Waiting for a workout'), findsOneWidget);
    });

    testWidgets('another kind of row keeps its Tier pill', (t) async {
      await pumpPair(
          t,
          const Scaffold(
              body: SourceRow(HealthSource(
                  name: 'Oura Ring',
                  kind: 'Ring',
                  tier: SourceTier.wristOptical,
                  icon: Icons.circle,
                  deviceId: 'oura-1',
                  family: 'oura'))),
          size: const Size(412, 600));
      expect(find.textContaining('Tier'), findsOneWidget);
    });
  });

  group('on its detail page', () {
    testWidgets('the card replaces the tier row and the Experimental support row', (t) async {
      await pumpPair(t, DeviceDetailView(_src('ble_hrs')), size: const Size(412, 2000));
      expect(find.byKey(const ValueKey('secondary-sensor-card')), findsOneWidget);
      expect(find.textContaining('Tier'), findsNothing);
      // Experimental shows once, as the card's footnote, not as a Support row.
      expect(find.text('Experimental'), findsNothing);
      expect(find.textContaining('Experimental:'), findsOneWidget);
    });

    testWidgets('a band’s page does not get the card', (t) async {
      await pumpPair(
          t,
          DeviceDetailView(const HealthSource(
              name: 'WHOOP 5',
              kind: 'WHOOP',
              tier: SourceTier.wristOptical,
              icon: Icons.watch,
              isBand: true)),
          size: const Size(412, 2000));
      expect(find.byKey(const ValueKey('secondary-sensor-card')), findsNothing);
    });
  });
}

