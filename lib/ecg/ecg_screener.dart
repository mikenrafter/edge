// The content of the ECG screener page (ecg-features): every state a reading
// can end in, what it means in plain words, and its references. Pure Dart.
//
// THE RULES THIS CONTENT IS UNDER (lib/ui2/screens/beats.dart header): this is
// a SCREEN, never a diagnosis and never AF detection. No arrhythmia vocabulary
// (no "afib", "a-fib", "atrial fibrillation", "arrhythmia", "ectopic", "you
// have"), no "normal rhythm", "no issues", "looks healthy", no percentage of
// anything, no severity words. "Not screened" (the band could not read it, the
// recording stopped early, the link failed) is a different thing from "nothing
// flagged" and the text says so; a result with nothing flagged never says the
// wearer is cleared. No diagnosis words at all, the disclaimer included: it
// says "This is a screen, not a medical test."

import 'dart:ui' show Locale;

import '../l10n/app_localizations.dart';

/// One state on the page.
class EcgScreenerEntry {
  const EcgScreenerEntry({
    required this.id,
    required this.title,
    required this.meaning,
    required this.screened,
  });

  /// An [EcgCategory] name, or 'partial' / 'failed'.
  final String id;

  /// The screen-framed name ("Irregular rhythm flagged"), never the
  /// category's own wording ("Possible AFib").
  final String title;

  /// What it means, in plain language, in the screen framing.
  final String meaning;

  /// False for the states where nothing was screened (unreadable, failed,
  /// partial); their text says "not screened" and never reads like a clear.
  final bool screened;
}

/// Every state, in page order: the eight band categories, then 'partial' and
/// 'failed'. One entry per [EcgCategory] value plus those two. The category
/// titles are the same words as the ECG screens' labels (app_*.arb
/// ecgCategory*), so a result and its explanation read alike.
///
/// The text lives in the ARBs (`ecgScreener*` keys, six locales); [l] is the
/// language to read it in, English when omitted.
List<EcgScreenerEntry> ecgScreenerEntries([AppLocalizations? l]) {
  final s = l ?? lookupAppLocalizations(const Locale('en'));
  return [
    EcgScreenerEntry(
      id: 'sinusRhythm',
      title: s.ecgCategorySinus,
      meaning: s.ecgScreenerSinusMeaning,
      screened: true,
    ),
    EcgScreenerEntry(
      id: 'lowHeartRate',
      title: s.ecgCategoryLowHr,
      meaning: s.ecgScreenerLowHrMeaning,
      screened: true,
    ),
    EcgScreenerEntry(
      id: 'possibleAfib',
      title: s.ecgCategoryPossibleAfib,
      meaning: s.ecgScreenerPossibleAfibMeaning,
      screened: true,
    ),
    EcgScreenerEntry(
      id: 'afibHighHeartRate',
      title: s.ecgCategoryAfibHighHr,
      meaning: s.ecgScreenerAfibHighHrMeaning,
      screened: true,
    ),
    EcgScreenerEntry(
      id: 'highHeartRate',
      title: s.ecgCategoryHighHr,
      meaning: s.ecgScreenerHighHrMeaning,
      screened: true,
    ),
    EcgScreenerEntry(
      id: 'highHeartRateNoAfib',
      title: s.ecgCategoryHighHrNoAfib,
      meaning: s.ecgScreenerHighHrNoAfibMeaning,
      screened: true,
    ),
    EcgScreenerEntry(
      id: 'inconclusive',
      title: s.ecgCategoryInconclusive,
      meaning: s.ecgScreenerInconclusiveMeaning,
      screened: true,
    ),
    EcgScreenerEntry(
      id: 'unreadable',
      title: s.ecgOutcomeNotReadable,
      meaning: s.ecgScreenerUnreadableMeaning,
      screened: false,
    ),
    EcgScreenerEntry(
      id: 'partial',
      title: s.ecgStoppedEarly,
      meaning: s.ecgScreenerPartialMeaning,
      screened: false,
    ),
    EcgScreenerEntry(
      id: 'failed',
      title: s.ecgFailedTitle,
      meaning: s.ecgScreenerFailedMeaning,
      screened: false,
    ),
  ];
}

/// The lines at the top of the screener page: a screen, not a diagnosis; a
/// result with nothing flagged is not a clearance; what the app does and does
/// not check; it ends in a person.
String ecgScreenerIntro([AppLocalizations? l]) =>
    (l ?? lookupAppLocalizations(const Locale('en'))).ecgScreenerIntro;
