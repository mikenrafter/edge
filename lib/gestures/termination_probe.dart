// termination_probe.dart — the Device lab's termination probe: how does the
// WHOOP 5 / MG band report that haptics STOPPED? The alarm snooze needs facts,
// not guesses: does an app pattern that runs out send HAPTICS_TERMINATED
// (event 100), with which cause; does a double tap add a gesture event (14);
// what does a native alarm report; what happens when the two overlap; and how
// precise is the strap's stamp next to the phone's receipt.
//
// Six scenarios, each run on demand, each recorded as a timeline. A short
// plain-English verdict per scenario, and a report text the page saves as a
// log file (never the clipboard: AGENTS.md invariant 16).
//
// The alarm scenarios arm a PROBE slot (never the wearer's slot: gen5 id 1),
// and ALWAYS (in `finally`: finish, cancel, leaving the screen, failure) clear
// it and put the real alarm back through the normal arm path. Nothing is
// persisted beyond the lab log's own steps.
//
// RED PHASE: every behavior below throws until the green phase.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble_state.dart';
import '../haptics/band_queue.dart';
import 'lab_log.dart';
import 'strap_event.dart';

/// The six things the probe answers, in page order.
enum TerminationScenario {
  /// 1. App pattern alone, left to finish.
  appFinishes,

  /// 2. App pattern, the wearer double-taps mid-play.
  appDoubleTap,

  /// 3. Native alarm alone, left to expire.
  alarmExpires,

  /// 4. Native alarm alone, the wearer double-taps to stop it.
  alarmDoubleTap,

  /// 5. A native alarm fires while a long app pattern plays.
  overlap,

  /// 6. Stamp precision: raw strap stamps next to phone receipt.
  stampPrecision;

  /// Button label, e.g. "1. App pattern, let it finish".
  String get title => throw UnimplementedError('red');

  /// One line telling the wearer what to do (e.g. "Do nothing" / "Double-tap
  /// the band while it buzzes").
  String get instruction => throw UnimplementedError('red');

  /// Arms a probe alarm slot (so it needs the clean-up).
  bool get usesAlarm => throw UnimplementedError('red');

  /// Asks the wearer to double-tap.
  bool get wearerTaps => throw UnimplementedError('red');
}

/// The probe's alarm slot index (the engine's probe slots are 0 and 1). Never
/// the slot the wearer's real alarm uses (index 0 = gen5 id 1).
int pickTerminationProbeSlot() => throw UnimplementedError('red');

/// Command budget reserved from the shared ledger before the first write: the
/// worst scenario (arm, 2 reads, pattern, clear, restore, a clock sync).
const int kTerminationProbeCommands = 10;

/// The probe refuses when the real alarm is this close to now (either side).
const Duration kTerminationNearReal = Duration(minutes: 10);

/// The short app pattern (the band's own pair, one loop) and the long one (8
/// effects, 3 loops: long enough to double-tap mid-play and to overlap).
const List<int> kTerminationShortPattern = <int>[47, 152];
const int kTerminationShortLoop = 1;
const List<int> kTerminationLongPattern = <int>[47, 152, 47, 152, 47, 152, 47, 152];
const int kTerminationLongLoop = 3;

/// One line of a scenario's timeline: a band event (both clocks, raw) or a
/// phone-side mark ("pattern written", "alarm armed for ...").
class TimelineEntry {
  const TimelineEntry({
    required this.label,
    required this.receivedAt,
    required this.sinceStartMs,
    this.eventId,
    this.cause,
    this.causeCode,
    this.rawEpoch,
    this.rawSubsec,
    this.convertedAt,
    this.deltaMs,
  });

  /// `HAPTICS_TERMINATED`, `DOUBLE_TAP`, `ALARM_EXECUTED (strap)`,
  /// `ALARM_EXECUTED (app)`, `ALARM_SET`, `ALARM_DISABLED`, `HAPTICS_FIRED`, or
  /// the text of a phone-side mark.
  final String label;

  /// Null for a phone-side mark.
  final int? eventId;

  /// HAPTICS_TERMINATED only: `expired`, `error`, `user_double_tap`,
  /// `code_N`. Null when the packet carried no decoded cause (never guessed).
  final String? cause;
  final int? causeCode;

  /// The strap's raw stamp: whole seconds and the 1/32768 s remainder. Null for
  /// a mark.
  final int? rawEpoch;
  final int? rawSubsec;

  /// The raw stamp in the phone's clock frame (strap instant + drift); null
  /// when the stamp is not believable (strap RTC unset) or for a mark.
  final DateTime? convertedAt;

  /// Phone receipt.
  final DateTime receivedAt;

  /// Receipt, ms after the scenario began.
  final int sinceStartMs;

  /// Receipt minus [convertedAt], ms; null with [convertedAt].
  final int? deltaMs;

  /// One text line, e.g.
  /// `+1700 ms HAPTICS_TERMINATED cause user_double_tap | raw 1791342000+16384/32768 | at 03:00:00.500 | recv +1700 ms | delta 1200 ms`.
  /// A stamp that is not believable reads `no stamp`, a missing delta `delta —`.
  String get line => throw UnimplementedError('red');
}

/// Builds one scenario's timeline from band events. Pure.
class TimelineRecorder {
  /// [start] is when the scenario began (phone clock); [driftSec] is
  /// `wall - strap` for the converted time (0 when uncorrelated).
  TimelineRecorder({required this.start, this.driftSec = 0});
  final DateTime start;
  final int driftSec;

  List<TimelineEntry> get entries => throw UnimplementedError('red');

  /// The event ids this probe records: 14, 56..60, 100.
  static bool watches(int eventId) => throw UnimplementedError('red');

  /// Record [e]; null (nothing recorded) for an event not [watches]ed.
  TimelineEntry? addEvent(StrapEvent e) => throw UnimplementedError('red');

  /// Record a phone-side mark at [at].
  TimelineEntry mark(String label, DateTime at) =>
      throw UnimplementedError('red');
}

/// The short plain-English verdict for [s] from its [timeline]. Pure. States
/// only what the timeline shows; absent events are said to be absent.
String terminationVerdict(
        TerminationScenario s, List<TimelineEntry> timeline) =>
    throw UnimplementedError('red');

/// What the stamps in [timeline] show: whether the sub-second part is ever
/// non-zero, and the spread of receipt minus stamp. Pure.
String stampVerdict(List<TimelineEntry> timeline) =>
    throw UnimplementedError('red');

/// What one finished (or stopped) scenario left behind.
class TerminationResult {
  const TerminationResult({
    required this.scenario,
    required this.startedAt,
    required this.timeline,
    required this.verdict,
    required this.completed,
  });
  final TerminationScenario scenario;
  final DateTime startedAt;
  final List<TimelineEntry> timeline;
  final String verdict;

  /// The scenario ran to its end (not stopped, not failed).
  final bool completed;
}

/// The saved report: header (band family, time), then for each scenario in
/// page order its title, verdict and timeline lines (`not run` for one without
/// a result), then the stamp-precision summary over every stamped event. Pure.
String terminationReport(
  List<TerminationResult> results, {
  required String family,
  required DateTime at,
}) =>
    throw UnimplementedError('red');

/// Runs the probe and holds what its card shows.
class TerminationProbeRunner extends ChangeNotifier {
  TerminationProbeRunner({
    required this.lab,
    required this.family,
    required this.developerMode,
    required this.isConnected,
    required this.heldEpoch,
    required this.armBusy,
    required this.sendPattern,
    required this.arm,
    required this.read,
    required this.clear,
    required this.restore,
    required this.log,
    this.ledger,
    this.runExclusive,
    this.alarmLead = const Duration(seconds: 20),
    this.patternLead = const Duration(seconds: 4),
    this.window = const Duration(seconds: 45),
    this.tail = const Duration(seconds: 3),
    this.stampPlays = 3,
    this.stampGap = const Duration(seconds: 5),
  });

  final DeviceLabLog lab;

  /// `gen4`, `gen5`, or null while the link has not identified itself. Only
  /// gen5 (WHOOP 5 / MG) takes the probe.
  final String? Function() family;
  final bool Function() developerMode;
  final bool Function() isConnected;

  /// The alarm the app holds (epoch seconds), null for none.
  final int? Function() heldEpoch;

  /// A real arm pass is in flight.
  final bool Function() armBusy;

  /// One app pattern (effects, loop) written to the band; true when it landed.
  final Future<bool> Function(List<int> effects, int loop) sendPattern;

  /// SET_ALARM for probe [slot] at [when]; the alarm scenarios only ever pass
  /// [pickTerminationProbeSlot].
  final Future<AlarmSlotWrite> Function(int slot, DateTime when) arm;
  final Future<AlarmSlotRead> Function(int slot) read;
  final Future<bool> Function(int slot) clear;

  /// Put the real alarm [epoch] back through the normal arm path.
  final Future<bool> Function(int epoch) restore;
  final void Function(String line) log;
  final BandCommandLedger? ledger;
  final Future<bool> Function(Future<void> Function() body)? runExclusive;

  /// How far ahead the probe alarm is armed (scenarios 3-5).
  final Duration alarmLead;

  /// Overlap: the long app pattern starts this long before the alarm.
  final Duration patternLead;

  /// Longest a scenario waits for its events after the last write.
  final Duration window;

  /// After the last wanted event, how long it keeps listening for extras.
  final Duration tail;

  /// Stamp precision: how many short plays, and the gap between them.
  final int stampPlays;
  final Duration stampGap;

  bool get running => throw UnimplementedError('red');
  TerminationScenario? get current => throw UnimplementedError('red');
  String? get status => throw UnimplementedError('red');
  String? get note => throw UnimplementedError('red');

  /// The latest result of each scenario, page order, only those run.
  List<TerminationResult> get results => throw UnimplementedError('red');
  TerminationResult? resultOf(TerminationScenario s) =>
      throw UnimplementedError('red');

  /// The run could not confirm it left the band clean (a probe slot may still
  /// be armed, or the real alarm was not put back).
  bool get needsRecovery => throw UnimplementedError('red');

  /// A tap during a run belongs to the probe, not to the wearer's tap actions.
  bool get holdsTaps => throw UnimplementedError('red');

  /// Why [s] cannot start now; null when it can.
  String? blockedReason(TerminationScenario s) =>
      throw UnimplementedError('red');

  /// Run scenario [s]. Does nothing (and says why in [note]) when blocked.
  Future<void> run(TerminationScenario s) => throw UnimplementedError('red');

  /// Stop now: the run clears its slot and restores the real alarm, then ends.
  /// Safe to call twice, or when nothing runs.
  void cancel() => throw UnimplementedError('red');

  /// A live band event; recorded while a scenario runs.
  void onBandEvent(StrapEvent e) => throw UnimplementedError('red');

  /// Whether AppState must NOT hand [e] to its alarm handler: events 56..60
  /// while the probe runs, and any stamped before the clean-up began.
  bool swallowsEvent(StrapEvent e) => throw UnimplementedError('red');

  /// The report text (see [terminationReport]) for the file the page saves.
  String reportText({DateTime? at}) => throw UnimplementedError('red');
}
