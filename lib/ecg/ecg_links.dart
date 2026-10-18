// The outbound references of the ECG screener page (ecg-features), in ONE
// constant so a test and scripts/check_ecg_links.sh read the same list. Pure
// Dart.
//
// Every entry is ONE line `EcgLink.doi('<state id>', '<doi>')` or
// `EcgLink.layman('<state id>', '<https url>')`; the script greps exactly
// those, so keep that shape. A DOI is checked against
// https://api.crossref.org/works/<doi> (publishers answer a bare curl with 403,
// so doi.org itself cannot be the check); a layman page is fetched with curl
// following redirects and must end 2xx. Run `scripts/check_ecg_links.sh`
// before adding or changing one. Verified 2026-10-07.
//
// A state id is an [EcgCategory] name or 'partial' / 'failed'. Layman pages
// are MedlinePlus (US NIH) and the NHS; heart.org answers a bare curl with 403
// and is not listed.

/// One reference for one screener state.
class EcgLink {
  const EcgLink._(this.stateId, this.kind, this.ref);

  /// A scholarly reference by DOI (e.g. '10.1161/CIR.0000000000000628').
  const EcgLink.doi(String stateId, String doi) : this._(stateId, 'doi', doi);

  /// A plain-language page from a reputable health source (an https URL).
  const EcgLink.layman(String stateId, String url)
    : this._(stateId, 'layman', url);

  final String stateId;

  /// 'doi' or 'layman'.
  final String kind;

  /// The DOI (kind 'doi') or the URL (kind 'layman').
  final String ref;

  bool get isDoi => kind == 'doi';

  /// What to open: the doi.org address of the DOI, or the page itself.
  String get url => isDoi ? 'https://doi.org/$ref' : ref;
}

const List<EcgLink> kEcgLinks = [
  EcgLink.doi('sinusRhythm', '10.1161/CIRCULATIONAHA.106.180201'),
  EcgLink.layman('sinusRhythm', 'https://medlineplus.gov/lab-tests/electrocardiogram/'),
  EcgLink.layman('sinusRhythm', 'https://www.nhs.uk/tests-and-treatments/electrocardiogram/'),
  EcgLink.doi('lowHeartRate', '10.1161/CIR.0000000000000628'),
  EcgLink.layman('lowHeartRate', 'https://medlineplus.gov/arrhythmia.html'),
  EcgLink.doi('possibleAfib', '10.1093/eurheartj/ehaa612'),
  EcgLink.layman('possibleAfib', 'https://medlineplus.gov/atrialfibrillation.html'),
  EcgLink.layman('possibleAfib', 'https://www.nhs.uk/conditions/atrial-fibrillation/'),
  EcgLink.doi('afibHighHeartRate', '10.1161/CIR.0000000000001193'),
  EcgLink.layman('afibHighHeartRate', 'https://medlineplus.gov/atrialfibrillation.html'),
  EcgLink.doi('highHeartRate', '10.1161/CIR.0000000000000311'),
  EcgLink.layman('highHeartRate', 'https://www.nhs.uk/conditions/supraventricular-tachycardia-svt/'),
  EcgLink.doi('highHeartRateNoAfib', '10.1161/CIR.0000000000000311'),
  EcgLink.layman('highHeartRateNoAfib', 'https://medlineplus.gov/arrhythmia.html'),
  EcgLink.doi('inconclusive', '10.22489/CinC.2017.065-469'),
  EcgLink.layman('inconclusive', 'https://www.nhs.uk/tests-and-treatments/electrocardiogram/'),
  EcgLink.doi('unreadable', '10.1088/0967-3334/33/9/1419'),
];
