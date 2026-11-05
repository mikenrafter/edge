// What a device gives as the main band vs as a secondary sensor. Capabilities
// come from the compute layer's eligibility rules (S6), never from raw-signal
// membership.
import '../compute/inputs/canonical.dart'
    show Cell, MetricClass, capabilities, columnFor, kWorkoutArmedSensors;
import 'adapters/_registry.dart';

enum DeviceCapability {
  sleep,
  recovery,
  strain,
  hrv,
  skinTemperature,
  bloodOxygen,
  workoutHeartRate,
  workoutBeatToBeat,
  steps,
}

/// How a capability is delivered.
/// native: this app computes it. conditional: only when [CapabilityStatus.reasonKey]
/// holds (an l10n-able key). vendorReported: the device's own number, shown as
/// the device's (never passed off as native, RULES B2).
enum CapabilityKind { native, conditional, vendorReported }

class CapabilityStatus {
  final CapabilityKind kind;

  /// Required (nonblank) when [kind] is conditional, else null.
  final String? reasonKey;
  const CapabilityStatus(this.kind, {this.reasonKey});
}

class SlotSide {
  final Map<DeviceCapability, CapabilityStatus> sends;

  /// Slot-defined (S2): [kBandSlotOutputs] minus [sends]' keys. Never "what
  /// this device's band column lacks".
  final Set<DeviceCapability> doesNotSend;
  const SlotSide({required this.sends, required this.doesNotSend});
}

class SlotComparison {
  /// What the entry gives as the main band; empty `sends` when it gives
  /// nothing (Coros, a chest strap).
  final SlotSide asBand;

  /// What the sensor path (ble_hrs, workout-armed) gives for this device.
  final SlotSide asSensor;
  const SlotComparison({required this.asBand, required this.asSensor});
}

/// The SLOT: whole-day outputs this app computes from a band (WHOOP's native
/// pipeline, compute/onehz_pipeline.dart). A secondary sensor "doesn't send"
/// these minus what it sends as a sensor.
const Set<DeviceCapability> kBandSlotOutputs = <DeviceCapability>{
  DeviceCapability.sleep,
  DeviceCapability.recovery,
  DeviceCapability.strain,
  DeviceCapability.hrv,
  DeviceCapability.skinTemperature,
};

/// THE mapping from a whole-day capability to its row in the compute layer's
/// metric x device columns (`columnFor`, compute/inputs/canonical.dart). A
/// capability's status for a wearable is read off `capabilities(column)[row]`.
/// There is no all-day heart-rate capability (DT6): no column row is all-day
/// HR. A later "heart-rate history" one may trace to series.hr_curve
/// (onehz_pipeline.dart:1379), with its coverage disclosed.
const Map<DeviceCapability, String> kCapabilityRow = <DeviceCapability, String>{
  DeviceCapability.sleep: 'sleep_window',
  DeviceCapability.recovery: 'readiness',
  DeviceCapability.strain: 'strain',
  DeviceCapability.hrv: 'hrv',
  DeviceCapability.skinTemperature: 'skin_temp',
  DeviceCapability.steps: 'steps',
};

// Blood oxygen is never claimed by a pairing comparison, for any device: the
// app refuses its own SpO2 (onehz_pipeline.dart kSpo2Refusal), and a vendor's
// reading is not a promise made at pairing. It is not in [kCapabilityRow].
// (The enum value and its label stay so the absence can be asserted.)

/// Capabilities decided per workout session, not per day: the sensor path
/// (`kWorkoutArmedSensors`, canonical.dart:339; `HrsLink.deriveTier`).
const Set<DeviceCapability> kSessionCapabilities = <DeviceCapability>{
  DeviceCapability.workoutHeartRate,
  DeviceCapability.workoutBeatToBeat,
};

/// Where a claimed capability comes from: [rule] names the eligibility rule,
/// [source] is the repo file that holds it.
typedef CapabilityTrace = ({String rule, String source});

/// l10n keys (lib/l10n/app_*.arb) of the one-line reasons a conditional
/// capability carries.
const String kReasonSkinTempNights = 'capReasonSkinTempNights';
const String kReasonEstimated = 'capReasonEstimated';
const String kReasonEarly = 'capReasonEarly';

/// l10n key of each capability's user-facing name.
const Map<DeviceCapability, String> kCapabilityLabelKey = <DeviceCapability, String>{
  DeviceCapability.sleep: 'capLabelSleep',
  DeviceCapability.recovery: 'capLabelRecovery',
  DeviceCapability.strain: 'capLabelStrain',
  DeviceCapability.hrv: 'capLabelHrv',
  DeviceCapability.skinTemperature: 'capLabelSkinTemperature',
  DeviceCapability.bloodOxygen: 'capLabelBloodOxygen',
  DeviceCapability.workoutHeartRate: 'capLabelWorkoutHeartRate',
  DeviceCapability.workoutBeatToBeat: 'capLabelWorkoutBeatToBeat',
  DeviceCapability.steps: 'capLabelSteps',
};

typedef _Claim = ({CapabilityStatus status, CapabilityTrace trace});

const String _canonical = 'lib/compute/inputs/canonical.dart';
const String _pipeline = 'lib/compute/onehz_pipeline.dart';

bool _nativeWhoop(BandEntry e) => e.id == kWhoopGen4.id || e.id == kWhoopGen5.id;

/// Every capability [e] gives in a slot, each with the rule behind it. The one
/// place claims are made, so a claim cannot exist without its trace.
Map<DeviceCapability, _Claim> _claims(BandEntry e, {required bool asBand}) {
  final out = <DeviceCapability, _Claim>{};
  if (!asBand) {
    // The sensor slot follows the real workout-source rule: only the sensors
    // in kWorkoutArmedSensors (ble_hrs, polar_pmd) are session sources. A
    // WHOOP confirmed as a secondary sensor is paired under ble_hrs, so it
    // gets ble_hrs's slot. Everything else (Coros, Oura, ...) declares heart
    // rate and beats but is never armed for a workout: it sends nothing here.
    final slotId = _nativeWhoop(e) ? kBleHrs.id : e.id;
    if (!kWorkoutArmedSensors.contains(slotId)) return out;
    final sig = declaredSignals(slotId).map((s) => s.name).toSet();
    const rule = 'workout session sensor (kWorkoutArmedSensors)';
    if (sig.contains('hr1Hz') || sig.contains('hrSparse')) {
      out[DeviceCapability.workoutHeartRate] = (
        status: const CapabilityStatus(CapabilityKind.native),
        trace: (rule: rule, source: _canonical),
      );
    }
    if (sig.contains('rrIntervals')) {
      out[DeviceCapability.workoutBeatToBeat] = (
        status: const CapabilityStatus(CapabilityKind.native),
        trace: (rule: rule, source: _canonical),
      );
    }
    return out;
  }
  if (_nativeWhoop(e)) {
    // The native pipeline (onehz_pipeline.dart): sleep, rmssd, strain,
    // readiness. Skin temperature needs a nightly mean, >= 3 prior nights and
    // a baseline spread >= 1 (:1034); WHOOP 5's deg C needs 14 nights.
    for (final c in kBandSlotOutputs) {
      out[c] = (
        status: c == DeviceCapability.skinTemperature
            ? const CapabilityStatus(CapabilityKind.conditional,
                reasonKey: kReasonSkinTempNights)
            : const CapabilityStatus(CapabilityKind.native),
        trace: (rule: 'native WHOOP pipeline (${c.name})', source: _pipeline),
      );
    }
    return out;
  }
  final col = columnFor(e.id);
  if (col == null) return out; // Coros, sensors, scales: no column, no claim.
  final cls = capabilities(col);
  for (final m in kCapabilityRow.entries) {
    final cell = col[m.value];
    final status = _statusOf(cls[m.value], cell);
    if (status == null) continue;
    out[m.key] = (
      status: status,
      trace: (rule: 'metric x device column row ${m.value}', source: _canonical),
    );
  }
  return out;
}

CapabilityStatus? _statusOf(MetricClass? cls, Cell? cell) => switch (cls) {
  null || MetricClass.unavailable => null,
  MetricClass.device => const CapabilityStatus(CapabilityKind.vendorReported),
  MetricClass.estimated => const CapabilityStatus(CapabilityKind.conditional,
      reasonKey: kReasonEstimated),
  MetricClass.ours => cell?.provisionalAt != null
      ? const CapabilityStatus(CapabilityKind.conditional,
          reasonKey: kReasonEarly)
      : const CapabilityStatus(CapabilityKind.native),
};

/// The rule behind [c] for [e] on the band or sensor side, or null when no
/// eligibility rule supports the claim.
CapabilityTrace? capabilityTrace(
  BandEntry e,
  DeviceCapability c, {
  required bool asBand,
}) => _claims(e, asBand: asBand)[c]?.trace;

SlotSide _side(BandEntry e, {required bool asBand}) {
  final sends = {
    for (final m in _claims(e, asBand: asBand).entries) m.key: m.value.status,
  };
  return SlotSide(
    sends: sends,
    doesNotSend: kBandSlotOutputs.difference(sends.keys.toSet()),
  );
}

SlotComparison slotComparisonFor(BandEntry e) =>
    SlotComparison(asBand: _side(e, asBand: true), asSensor: _side(e, asBand: false));
