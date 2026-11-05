// Slot comparison: what a device gives as the main band vs a secondary sensor.
// Capabilities come from the compute layer's eligibility rules (S6): the
// metric x device columns (canonical.dart columnFor/capabilities), the native
// WHOOP pipeline, and the workout-armed sensor set.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/slot_comparison.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart'
    show MetricClass, capabilities, columnFor, kWorkoutArmedSensors;

typedef C = DeviceCapability;
typedef K = CapabilityKind;

// The whole-day outputs a framed WHOOP gets natively (the slot). Pinned by hand
// from compute/onehz_pipeline.dart: sleep (:1938), strain (:2035), rmssd (:2026),
// readiness (recovery) and skin temperature. No all-day HR capability (DT6).
const _slot = <DeviceCapability>{C.sleep, C.recovery, C.strain, C.hrv, C.skinTemperature};

Set<DeviceCapability> _keys(SlotSide s) => s.sends.keys.toSet();

List<BandEntry> _columnEntries() =>
    [for (final e in kBandRegistry) if (columnFor(e.id) != null) e];

void main() {
  test('the slot is exactly the five native whole-day outputs', () {
    // WHY (S2): "doesn't send" is defined against this set; a drifting slot
    // silently changes every secondary sensor's list.
    expect(kBandSlotOutputs, _slot);
  });

  group('WHOOP as the main band', () {
    for (final e in [kWhoopGen4, kWhoopGen5]) {
      test('${e.id}: native sleep, recovery, strain, HRV; skin temp conditional', () {
        // WHY: the compute layer produces these for a framed WHOOP; the user is told so.
        final b = slotComparisonFor(e).asBand.sends;
        for (final c in [C.sleep, C.recovery, C.strain, C.hrv]) {
          expect(b[c]?.kind, K.native, reason: '${e.id} $c');
        }
        final t = b[C.skinTemperature];
        expect(t, isNotNull, reason: '${e.id} skin temperature');
        // DT7: needs a nightly mean, >=3 prior nights and baseline SD >=1
        // (onehz_pipeline.dart:1034); WHOOP 5's deg C needs 14 nights.
        expect(t!.kind, K.conditional, reason: '${e.id} skin temperature');
        expect(t.reasonKey?.trim() ?? '', isNotEmpty,
            reason: 'conditional needs a reason key');
        expect(b.keys.toSet().intersection(_slot), _slot);
      });

      test('${e.id}: no steps claim', () {
        // WHY: WHOOP declares no step counter.
        final b = slotComparisonFor(e).asBand.sends;
        expect(b.containsKey(C.steps), isFalse);
      });
    }
  });

  test('blood oxygen is never sent by a WHOOP, as band or sensor (S1)', () {
    // WHY: the app refuses SpO2 permanently (compute/onehz_pipeline.dart:937,
    // kSpo2Refusal): ir-red is one drifting channel, not oxygenation. Raw
    // red/IR membership must not turn into a promise.
    for (final e in [kWhoopGen4, kWhoopGen5]) {
      final cmp = slotComparisonFor(e);
      expect(cmp.asBand.sends.containsKey(C.bloodOxygen), isFalse, reason: e.id);
      expect(cmp.asSensor.sends.containsKey(C.bloodOxygen), isFalse, reason: e.id);
      expect(cmp.asBand.doesNotSend.contains(C.bloodOxygen), isFalse,
          reason: '${e.id}: not a slot output either');
    }
  });

  test('no registry entry claims blood oxygen, on either side (G2 r1 S1)', () {
    // WHY: the pairing comparison must never promise SpO2 for any device, a
    // vendor's own reading included (Oura and Garmin columns carry a device
    // spo2 row; that is the column's business, not a pairing promise).
    expect(capabilities(columnFor('garmin')!)['spo2'], MetricClass.device,
        reason: 'positive control: a column does offer a vendor spo2');
    expect(capabilities(columnFor('oura')!)['spo2'], MetricClass.device,
        reason: 'positive control');
    for (final e in kBandRegistry) {
      final cmp = slotComparisonFor(e);
      expect(cmp.asBand.sends.containsKey(C.bloodOxygen), isFalse, reason: e.id);
      expect(cmp.asSensor.sends.containsKey(C.bloodOxygen), isFalse, reason: e.id);
      expect(capabilityTrace(e, C.bloodOxygen, asBand: true), isNull, reason: e.id);
      expect(capabilityTrace(e, C.bloodOxygen, asBand: false), isNull, reason: e.id);
    }
  });

  group('as a secondary sensor (S2)', () {
    test('WHOOP as sensor sends exactly workout HR and beat-to-beat', () {
      // WHY: as a 0x180D sensor only the live HR service is read, never history.
      for (final e in [kWhoopGen4, kWhoopGen5]) {
        expect(_keys(slotComparisonFor(e).asSensor), {C.workoutHeartRate, C.workoutBeatToBeat},
            reason: e.id);
      }
    });

    test('ble_hrs lists sleep, recovery, strain, HRV and skin temp as not sent', () {
      // WHY: the central requirement. A chest strap paired without a band must
      // say it gives none of the band's whole-day outputs. The old difference
      // rule gave it an empty list.
      final s = slotComparisonFor(kBleHrs).asSensor;
      expect(s.sends.keys, contains(C.workoutHeartRate));
      expect(s.doesNotSend,
          containsAll(<DeviceCapability>{C.sleep, C.recovery, C.strain}));
      expect(s.doesNotSend, _slot.difference(_keys(s)));
      expect(s.doesNotSend.contains(C.workoutHeartRate), isFalse);
    });

    test('doesNotSend = slot minus sends, for EVERY registry entry', () {
      // WHY: the slot defines the omission, not whether this device has a band column.
      expect(kBandRegistry.length, greaterThan(10));
      for (final e in kBandRegistry) {
        final s = slotComparisonFor(e).asSensor;
        expect(s.doesNotSend, _slot.difference(_keys(s)), reason: e.id);
        expect(s.doesNotSend.intersection(_keys(s)), isEmpty, reason: e.id);
      }
    });

    test('only workout-armed sensors and a WHOOP read as a heart-rate sensor send anything (G2 r1 S2)', () {
      // WHY: canonical.dart kWorkoutArmedSensors arms only ble_hrs and
      // polar_pmd. A WHOOP confirmed as a secondary sensor is paired under
      // ble_hrs, so it gets ble_hrs's slot. Coros and Oura declare heart rate
      // and beats, but nothing arms them as a workout source.
      const both = {C.workoutHeartRate, C.workoutBeatToBeat};
      final sensors = {'ble_hrs', 'polar_pmd', 'gen4', 'gen5'};
      expect(kWorkoutArmedSensors, {'ble_hrs', 'polar_pmd'});
      for (final e in kBandRegistry) {
        final sends = slotComparisonFor(e).asSensor;
        expect(_keys(sends), sensors.contains(e.id) ? both : isEmpty,
            reason: e.id);
        if (!sensors.contains(e.id)) {
          expect(sends.doesNotSend, _slot, reason: '${e.id}: the whole slot');
        }
      }
      for (final id in ['coros', 'oura']) {
        expect(declaredSignals(id).map((s) => s.name), contains('rrIntervals'),
            reason: '$id: positive control, it does declare beats');
      }
    });
  });

  group('wearable columns (S6)', () {
    test('the six columned entries are found (control for the loops below)', () {
      // WHY: if columnFor changed ids the loops would pass over nothing.
      expect({for (final e in _columnEntries()) e.id},
          {'garmin', 'pebble', 'miband234', 'ultrahuman', 'colmi', 'oura'});
    });

    test('every mapped row exists in some column', () {
      // WHY: a typo in kCapabilityRow would make a capability silently never sent.
      final rows = {
        for (final e in _columnEntries()) ...columnFor(e.id)!.keys,
      };
      for (final r in kCapabilityRow.entries) {
        expect(rows, contains(r.value), reason: '${r.key}');
      }
    });

    test('a wearable band slot follows capabilities(column), class by class', () {
      // WHY: ours -> native, device -> vendorReported, estimated -> conditional
      // (with a reason), unavailable -> not sent. Read off the real columns.
      for (final e in _columnEntries()) {
        final col = columnFor(e.id)!;
        final cls = capabilities(col);
        final sends = slotComparisonFor(e).asBand.sends;
        for (final m in kCapabilityRow.entries) {
          final row = col[m.value];
          final c = cls[m.value]!;
          final got = sends[m.key];
          final why = '${e.id} ${m.key} ($c)';
          switch (c) {
            case MetricClass.unavailable:
              expect(got, isNull, reason: why);
            case MetricClass.device:
              expect(got?.kind, K.vendorReported, reason: why);
            case MetricClass.estimated:
              expect(got?.kind, K.conditional, reason: why);
              expect(got?.reasonKey?.trim() ?? '', isNotEmpty, reason: why);
            case MetricClass.ours:
              expect(got?.kind,
                  row!.provisionalAt != null ? K.conditional : K.native,
                  reason: why);
          }
        }
      }
    });

    test('hand-read anchors: Garmin and Mi Band', () {
      // WHY: the loop above reads the same table; these were read by hand.
      // garmin_inputs.dart:170 spo2 is the watch's own value; :176 skin temp is
      // not decoded; :164 HRV is device-reported unless a strap gave beats;
      // :183 readiness is an estimate (resting-HR only) without a strap;
      // strain is ours. miband_inputs.dart:61 spo2 is never available.
      final g = slotComparisonFor(kGarmin).asBand.sends;
      expect(g.containsKey(C.bloodOxygen), isFalse);
      expect(g.containsKey(C.skinTemperature), isFalse);
      expect(g[C.hrv]?.kind, K.vendorReported);
      expect(g[C.recovery]?.kind, K.conditional);
      expect(g[C.strain]?.kind, K.native);
      expect(slotComparisonFor(kMiBand234).asBand.sends.containsKey(C.bloodOxygen), isFalse);
    });
  });

  test('Coros is excluded from wearable compute, so its band slot sends nothing', () {
    // WHY: compute/inputs/canonical.dart:127 wearableEnabled() is false for
    // kCoros and it has no column: nothing native, nothing vendor-reported.
    final b = slotComparisonFor(kCoros).asBand;
    expect(b.sends, isEmpty);
    expect(columnFor(kCoros.id), isNull, reason: 'positive control for the rule');
  });

  test('a sensor-role entry has an empty band slot', () {
    // WHY: a chest strap cannot be the main device; do not promise sleep from it.
    for (final e in [kBleHrs, kPolarPmd, kThermometer]) {
      expect(slotComparisonFor(e).asBand.sends, isEmpty, reason: e.id);
    }
  });

  group('nothing fabricated (S6)', () {
    test('every capability claimed for every entry traces to an eligibility rule', () {
      // WHY: a claim with no rule behind it is a false promise. The trace names
      // the rule and an existing repo file; unclaimed capabilities have none.
      var claims = 0;
      for (final e in kBandRegistry) {
        final cmp = slotComparisonFor(e);
        for (final band in [true, false]) {
          final side = band ? cmp.asBand : cmp.asSensor;
          for (final c in side.sends.keys) {
            claims++;
            final t = capabilityTrace(e, c, asBand: band);
            final why = '${e.id} ${band ? "band" : "sensor"} $c';
            expect(t, isNotNull, reason: why);
            expect(t!.rule.trim(), isNotEmpty, reason: why);
            expect(File(t.source).existsSync(), isTrue,
                reason: '$why: ${t.source}');
          }
        }
      }
      expect(claims, greaterThan(10), reason: 'vacuity control');
    });

    test('a band-slot claim needs a column or the native WHOOP pipeline', () {
      // WHY: nothing else in the compute layer produces whole-day values for a band.
      for (final e in kBandRegistry) {
        final sends = slotComparisonFor(e).asBand.sends;
        final eligible = columnFor(e.id) != null || e.id == 'gen4' || e.id == 'gen5';
        if (!eligible) expect(sends, isEmpty, reason: e.id);
      }
    });

    test('a capability with no trace is not claimed', () {
      // WHY: the reverse direction; if trace says null the side must not list it.
      for (final e in kBandRegistry) {
        final cmp = slotComparisonFor(e);
        for (final c in DeviceCapability.values) {
          for (final band in [true, false]) {
            final side = band ? cmp.asBand : cmp.asSensor;
            if (capabilityTrace(e, c, asBand: band) == null) {
              expect(side.sends.containsKey(c), isFalse, reason: '${e.id} $c');
            }
          }
        }
      }
    });

    test('every capability has a clean eligibility source', () {
      // WHY: whole-day capabilities need a column row (kCapabilityRow) and
      // session ones the sensor rule (kSessionCapabilities). A new capability
      // without either would be signal guessing. DT6: all-day HR was dropped
      // for exactly that reason (no column row is all-day HR).
      expect(DeviceCapability.values.map((c) => c.name),
          isNot(contains('heartRateAllDay')));
      final unsourced = [
        for (final c in DeviceCapability.values)
          if (!kCapabilityRow.containsKey(c) &&
              !kSessionCapabilities.contains(c) &&
              c != C.bloodOxygen)
            c,
      ];
      expect(unsourced, isEmpty, reason: 'no eligibility source for $unsourced');
    });
  });

  test('every label and reason key the comparison can show has text in every locale', () {
    // WHY: a reason or label with no translation would render blank for that
    // language. Reasons are collected from the real comparison, not a list.
    final keys = <String>{...kCapabilityLabelKey.values};
    for (final e in kBandRegistry) {
      final cmp = slotComparisonFor(e);
      for (final side in [cmp.asBand, cmp.asSensor]) {
        for (final s in side.sends.values) {
          if (s.reasonKey != null) keys.add(s.reasonKey!);
        }
      }
    }
    expect(kCapabilityLabelKey.keys.toSet(), DeviceCapability.values.toSet());
    expect(keys.length, greaterThan(DeviceCapability.values.length),
        reason: 'vacuity control: some reason keys were found');
    final arbs = Directory('lib/l10n').listSync().whereType<File>().where(
        (f) => RegExp(r'app_\w+\.arb$').hasMatch(f.path));
    expect(arbs.length, 7);
    for (final f in arbs) {
      final arb = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final bad = [
        for (final k in keys)
          if (arb[k] is! String || (arb[k] as String).trim().isEmpty) k,
      ];
      expect(bad, isEmpty, reason: '${f.path}: $bad');
    }
  });
}
