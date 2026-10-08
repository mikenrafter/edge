// The ONE ECG outcome (design 04, R1): what a saved reading means, decided in
// one place. Capture, history, detail, export and the coach all read
// [ecgOutcome]; none of them re-derive a verdict from the stored category.
//
// Nothing here looks at the waveform: the inputs are the band's own bytes
// (result code, average heart rate, the reason mask) and whether the recording
// stopped early. The app adds exactly one thing, the override: any band-reported
// problem, an unknown code, a missing or out-of-table heart rate withholds the
// rhythm label (AGENTS 3.3).

import 'ecg_models.dart';

/// Version of the code->category table plus the outcome matrix below. Stamped
/// on every new reading (`capture_table_version`); NULL on a legacy row, which
/// Details shows as "not recorded" and never infers.
const int kEcgOutcomeTableVersion = 2;

enum EcgOutcomeKind {
  /// A band-reported rhythm label, with the quality caveat. The only kind that
  /// carries a rhythm label.
  bandResult,

  /// The band itself could not conclude (result 6).
  inconclusive,

  /// Nothing may be said about rhythm: a band-reported problem, an unknown
  /// code, a missing heart rate or a rate outside the table.
  notReadable,

  /// Stopped early: no rhythm label, whatever the band bytes say.
  partial,
}

/// Stable reason ids. The words live in the ARBs; an id plus its argument is
/// also what an export prints.
abstract final class EcgReasonId {
  static const lowAmplitude = 'low_amplitude';
  static const significantNoise = 'significant_noise';
  static const unstableSignal = 'unstable_signal';
  static const notEnoughData = 'not_enough_data';

  /// arg = the bit index 4..7.
  static const unknownBandReasonBit = 'unknown_band_reason_bit';

  /// arg = the result code the app does not know.
  static const unknownResultCode = 'unknown_result_code';

  /// Result code 0 or 2 (the band says unreadable); arg = the code.
  static const bandUnreadableResult = 'band_unreadable_result';

  /// The mapping needs a heart rate and the band gave 0/255/none.
  static const noHeartRate = 'no_heart_rate';

  /// A heart rate outside the range the table accepts for this code; arg = hr.
  static const heartRateOutOfRange = 'heart_rate_out_of_range';
}

class EcgReason {
  const EcgReason(this.id, [this.arg]);
  final String id;
  final int? arg;

  @override
  bool operator ==(Object other) =>
      other is EcgReason && other.id == id && other.arg == arg;

  @override
  int get hashCode => Object.hash(id, arg);

  /// `id` or `id:arg` - the form an export prints.
  @override
  String toString() => arg == null ? id : '$id:$arg';
}

enum EcgCaveat {
  /// "band-reported; the app has not checked this recording's quality yet".
  bandReportedQualityUnchecked,
}

class EcgOutcome {
  const EcgOutcome({
    required this.kind,
    this.bandResult,
    this.reasons = const [],
    this.caveats = const [],
    required this.resultCode,
    required this.avgHr,
    required this.mask,
  });

  final EcgOutcomeKind kind;

  /// The band's rhythm category; non-null ONLY for [EcgOutcomeKind.bandResult].
  final EcgCategory? bandResult;

  /// Why nothing (or something less) may be said, in a fixed order: set mask
  /// bits in bit order (bits 4-7 as unknown), then the code / heart-rate
  /// reason.
  final List<EcgReason> reasons;
  final List<EcgCaveat> caveats;

  /// The raw band values the decision read, preserved untouched.
  final int resultCode;
  final int? avgHr;

  /// `mask_any | unreadable_mask`: every band reason bit seen.
  final int mask;
}

/// The band's category for a result code and average heart rate: the stored
/// `category` of a new reading. It is the raw band value (a set mask does not
/// change it; [ecgOutcomeOf] decides what is SHOWN). The one place outside the
/// table itself that reads [categoryFor].
EcgCategory ecgBandCategory(int resultCode, int? avgHr) =>
    categoryFor(resultCode, _rate(avgHr) ?? 0);

/// 0, 255 and absent all mean "the band gave no heart rate".
int? _rate(int? hr) => (hr == null || hr <= 0 || hr >= 255) ? null : hr;

const _maskBitIds = [
  EcgReasonId.lowAmplitude,
  EcgReasonId.significantNoise,
  EcgReasonId.unstableSignal,
  EcgReasonId.notEnoughData,
];

/// Result codes whose category depends on a heart rate (0 and 2 say unreadable,
/// 6 inconclusive, whatever the rate).
const _needsRate = {1, 3, 4, 5};

/// The reasons a band reason [mask] names, in bit order: bits 0-3 by name,
/// bits 4-7 as "unknown band reason bit n" (never given a meaning). Empty for
/// mask 0. The one place a mask becomes reasons: the outcome and the Details
/// both read it.
List<EcgReason> ecgMaskReasons(int mask) => [
  for (var bit = 0; bit < 8; bit++)
    if (mask & (1 << bit) != 0)
      bit < _maskBitIds.length
          ? EcgReason(_maskBitIds[bit])
          : EcgReason(EcgReasonId.unknownBandReasonBit, bit),
];

/// The decision matrix (design 04 R1 with R1' / R1''), on raw band values.
/// [mask] is the OR of every mask the capture saw; [avgHr] null = none.
EcgOutcome ecgOutcomeOf({
  required int resultCode,
  required int? avgHr,
  required int mask,
  bool partial = false,
}) {
  EcgOutcome out(
    EcgOutcomeKind kind, {
    EcgCategory? band,
    List<EcgReason> reasons = const [],
    List<EcgCaveat> caveats = const [],
  }) => EcgOutcome(
    kind: kind,
    bandResult: band,
    reasons: reasons,
    caveats: caveats,
    resultCode: resultCode,
    avgHr: avgHr,
    mask: mask,
  );

  // Stopped early: whatever the band bytes say, nothing was concluded.
  if (partial) return out(EcgOutcomeKind.partial);

  final reasons = ecgMaskReasons(mask);

  if (resultCode == 0 || resultCode == 2) {
    reasons.add(EcgReason(EcgReasonId.bandUnreadableResult, resultCode));
  } else if (_needsRate.contains(resultCode)) {
    final hr = _rate(avgHr);
    if (hr == null) {
      reasons.add(const EcgReason(EcgReasonId.noHeartRate));
    } else if (categoryFor(resultCode, hr) == EcgCategory.unreadable) {
      reasons.add(EcgReason(EcgReasonId.heartRateOutOfRange, hr));
    }
  } else if (resultCode != 6) {
    reasons.add(EcgReason(EcgReasonId.unknownResultCode, resultCode));
  }

  if (reasons.isNotEmpty) {
    return out(EcgOutcomeKind.notReadable, reasons: reasons);
  }
  if (resultCode == 6) return out(EcgOutcomeKind.inconclusive);
  return out(
    EcgOutcomeKind.bandResult,
    band: categoryFor(resultCode, _rate(avgHr)!),
    caveats: const [EcgCaveat.bandReportedQualityUnchecked],
  );
}

/// The outcome of a saved reading. Uses `mask_any | unreadable_mask` (a legacy
/// row has only the terminal mask) and `avg_hr`; never the stored category.
EcgOutcome ecgOutcome(EcgReading r) => ecgOutcomeOf(
  resultCode: r.resultCode,
  avgHr: r.avgHr,
  mask: (r.maskAny ?? 0) | r.unreadableMask,
  partial: r.status == EcgReadingStatus.partial,
);
