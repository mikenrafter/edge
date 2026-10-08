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
List<EcgScreenerEntry> ecgScreenerEntries() => const [
  EcgScreenerEntry(
    id: 'sinusRhythm',
    title: 'Regular rhythm, nothing flagged',
    meaning:
        'The band screened a good recording and flagged nothing, at a heart '
        'rate between 51 and 99 beats per minute. This does not mean you were '
        'cleared: the screen cannot rule anything out, and it looks at one '
        'short recording only.',
    screened: true,
  ),
  EcgScreenerEntry(
    id: 'lowHeartRate',
    title: 'Low heart rate',
    meaning:
        'The recording was clean and the average heart rate was 50 beats per '
        'minute or lower. A low rate can be ordinary for some people, and '
        'this screen says nothing about the cause. If you feel faint, dizzy '
        'or unwell, see a clinician.',
    screened: true,
  ),
  EcgScreenerEntry(
    id: 'possibleAfib',
    title: 'Irregular rhythm flagged',
    meaning:
        'The band\'s screen flagged an irregular rhythm in this recording, at '
        'a heart rate between 51 and 99 beats per minute. A flag is a prompt '
        'for a proper test, not a finding. One short recording from a wrist '
        'band cannot tell a lasting pattern from a passing one, so see a '
        'clinician for an ECG, especially with symptoms.',
    screened: true,
  ),
  EcgScreenerEntry(
    id: 'afibHighHeartRate',
    title: 'Irregular rhythm flagged, high heart rate',
    meaning:
        'The band\'s screen flagged an irregular rhythm together with a heart '
        'rate from 100 to 150 beats per minute. A flag is a prompt for a '
        'proper test, not a finding. See a clinician for an ECG, and soon if '
        'you feel unwell, short of breath or have chest pain.',
    screened: true,
  ),
  EcgScreenerEntry(
    id: 'highHeartRate',
    title: 'High heart rate',
    meaning:
        'The heart rate was between 151 and 200 beats per minute. At this '
        'rate the screen does not tell a regular rhythm from an irregular '
        'one. Exercise, fever, caffeine and stress all raise it. If it stays '
        'high at rest or you feel unwell, see a clinician.',
    screened: true,
  ),
  EcgScreenerEntry(
    id: 'highHeartRateNoAfib',
    title: 'High heart rate, no irregular rhythm flagged',
    meaning:
        'The heart rate was between 100 and 150 beats per minute and the '
        'screen flagged no irregular rhythm. This does not mean you were '
        'cleared: the screen cannot rule anything out. If a high rate stays '
        'at rest or you feel unwell, see a clinician.',
    screened: true,
  ),
  EcgScreenerEntry(
    id: 'inconclusive',
    title: 'Inconclusive',
    meaning:
        'The band could not reach a result from this recording; the signal '
        'may have been too noisy or too short. It says nothing either way. '
        'Try again with your arm resting and your fingers still. A reading '
        'you start within 10 minutes replaces this one.',
    screened: true,
  ),
  EcgScreenerEntry(
    id: 'unreadable',
    title: 'Unreadable',
    meaning:
        'The band could not read the signal: low amplitude, noise, an '
        'unstable signal or not enough data. This recording was not screened '
        'and nothing is saved. Not screened is not the same as nothing '
        'flagged.',
    screened: false,
  ),
  EcgScreenerEntry(
    id: 'partial',
    title: 'Stopped early',
    meaning:
        'The recording stopped before it finished, because the app went to '
        'the background, it timed out or the band connection dropped. What '
        'was recorded is saved as a partial reading. It was not screened, so '
        'no rhythm result is given. Heart rate and signal quality appear '
        'only if at least 10 seconds of signal were recorded.',
    screened: false,
  ),
  EcgScreenerEntry(
    id: 'failed',
    title: 'Reading failed',
    meaning:
        'The reading could not be completed: the band would not start it, or '
        'the connection was lost before any signal came in. It was not '
        'screened and nothing is saved. Check that the band is connected and '
        'worn snugly, then try again.',
    screened: false,
  ),
];

/// The lines at the top of the screener page: a screen, not a diagnosis; a
/// result with nothing flagged is not a clearance; it ends in a person.
const String kEcgScreenerIntro =
    'This is a screen, not a medical test.\n\n'
    'A result with nothing flagged does not mean you were cleared, and the '
    'screen cannot rule anything out. A result that was not screened says '
    'nothing at all.\n\n'
    'With symptoms, see a clinician for a proper test.';
