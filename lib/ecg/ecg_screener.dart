// The content of the ECG screener page (ecg-features): every state a reading
// can end in, what it means in plain words, and its references. Pure Dart.
//
// RED STUB: [ecgScreenerEntries] throws until the green phase.
//
// THE RULES THIS CONTENT IS UNDER (lib/ui2/screens/beats.dart header): this is
// a SCREEN, never a diagnosis and never AF detection. No arrhythmia vocabulary
// (no "afib", "a-fib", "atrial fibrillation", "arrhythmia", "ectopic", "you
// have"), no "normal rhythm", "no issues", "looks healthy", no percentage of
// anything, no severity words. "Not screened" (the band could not read it, the
// recording stopped early, the link failed) is a different thing from "nothing
// flagged" and the text says so; a result with nothing flagged never says the
// wearer is cleared. The one place the word "diagnos" may occur is the
// disclaimer ("cannot diagnose", "not a diagnosis").

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
/// 'failed'. One entry per [EcgCategory] value plus those two.
List<EcgScreenerEntry> ecgScreenerEntries() =>
    throw UnimplementedError('ecgScreenerEntries');
