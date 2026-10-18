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
// it and put the real alarm back through the normal arm path (a band that
// keeps one alarm would otherwise lose the wearer's). Nothing is persisted
// beyond the lab log's own steps.
//
// What the saved report carries for every event 100 / alarm EXECUTED /
// event 14: the raw packet hex, the parsed fields, the raw strap stamp with its
// sub-second field, the converted time, the phone receipt in ms, and the
// clockRef state at the start and end of the scenario, so a question asked
// later does not need a re-run.
//
// Everything that touches the band or the app is injected, so this file is
// plain Dart. Time comes from package:clock.
//
// Two things keep the probe from hurting the real alarm's bookkeeping:
//  * the probe's own alarm events (56..60) are SWALLOWED while it runs (and
//    any stamped before its clean-up, plus a short grace): a fired probe alarm
//    would otherwise reach AppState's alarm handler, which treats "fired" as
//    "the user's alarm is spent" and wipes the real one;
//  * a band alarm the app does not know about is never overwritten: the probe
//    stops before arming anything.

import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../ble/ble_state.dart';
import '../haptics/band_queue.dart';
import '../sync/sync_policy.dart' show ClockRef;
import 'lab_log.dart';
import 'strap_event.dart';

/// The six things the probe answers, in page order.
enum TerminationScenario {
  /// 1. App pattern alone, left to finish.
  appFinishes('1. App pattern, let it finish',
      'Do nothing; the band buzzes once.'),

  /// 2. App pattern, the wearer double-taps mid-play.
  appDoubleTap('2. App pattern, double-tap mid-play',
      'Double-tap the band while the long pattern plays.',
      wearerTaps: true),

  /// 3. Native alarm alone, left to expire.
  alarmExpires('3. Alarm alone, let it expire',
      'Do nothing; the test alarm fires in about 20 seconds.',
      usesAlarm: true),

  /// 4. Native alarm alone, the wearer double-taps to stop it.
  alarmDoubleTap('4. Alarm alone, double-tap to stop it',
      'Double-tap the band when the test alarm buzzes (about 20 seconds in).',
      usesAlarm: true, wearerTaps: true),

  /// 5. A native alarm fires while a long app pattern plays.
  overlap('5. Alarm fires during a long app pattern',
      'A long pattern starts, then the test alarm fires over it. Do nothing.',
      usesAlarm: true),

  /// 6. Stamp precision: raw strap stamps next to phone receipt.
  stampPrecision('6. Stamp precision',
      'Do nothing; short buzzes, a few seconds apart.');

  const TerminationScenario(this.title, this.instruction,
      {this.usesAlarm = false, this.wearerTaps = false});

  /// Button label, e.g. "1. App pattern, let it finish".
  final String title;

  /// One line telling the wearer what to do.
  final String instruction;

  /// Arms a probe alarm slot (so it needs the clean-up).
  final bool usesAlarm;

  /// Asks the wearer to double-tap.
  final bool wearerTaps;
}

/// The wearer's alarm: engine probe slot 0 (gen5 id 1).
const int _kRealSlot = 0;

/// The probe's alarm slot index (the engine's probe slots are 0 and 1). Never
/// the slot the wearer's real alarm uses (index 0 = gen5 id 1): index 1, gen5
/// id 2.
int pickTerminationProbeSlot() => _kRealSlot == 0 ? 1 : 0;

/// Command budget reserved from the shared ledger before the first write: the
/// worst scenario (readback, arm, readback, pattern) with room for a clock
/// sync. Clean-up writes are recorded but never refused: restoring the
/// wearer's alarm outranks the budget.
const int kTerminationProbeCommands = 10;

/// The probe refuses to arm when the real alarm is this close to now.
const Duration kTerminationNearReal = Duration(minutes: 10);

/// After a run, alarm events stamped up to this long past the clean-up are
/// still the probe's (a late burst); the 10-minute guard keeps the real
/// alarm clear of it.
const Duration kTerminationSwallowGrace = Duration(minutes: 2);

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
    this.hex = '',
    this.fields = const {},
    this.driftSec,
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

  /// The raw packet as hex ('' when the source kept none), the parsed fields
  /// the protocol decoded from it, and the clockRef drift used for
  /// [convertedAt]. Events only.
  final String hex;
  final Map<String, dynamic> fields;
  final int? driftSec;

  /// One text line, e.g.
  /// `+1700 ms HAPTICS_TERMINATED cause user_double_tap | raw 1791342000+16384/32768 | at 03:00:00.500 | recv +1700 ms | delta 1200 ms`.
  /// A stamp that is not believable reads `no stamp`, a missing delta `delta —`.
  String get line {
    final b = StringBuffer('+$sinceStartMs ms $label');
    if (eventId == 100) {
      b.write(cause != null ? ' cause $cause' : ' cause not decoded');
    }
    if (eventId != null) {
      if (rawEpoch != null) b.write(' | raw $rawEpoch+${rawSubsec ?? 0}/32768');
      final at = convertedAt;
      b.write(at != null ? ' | at ${labClock(at)}' : ' | no stamp');
      b.write(' | recv +$sinceStartMs ms');
      b.write(' | delta ${deltaMs != null ? '$deltaMs ms' : '—'}');
    }
    return b.toString();
  }

  /// The extra lines the report prints under [line] for a band event: the raw
  /// packet and every parsed field. Empty for a mark.
  List<String> get detailLines {
    if (eventId == null) return const [];
    final f = fields.entries.map((e) => '${e.key}=${e.value}').join(', ');
    return [
      'packet hex: ${hex.isEmpty ? 'not available' : hex}',
      'parsed: event $eventId, raw stamp ${rawEpoch ?? '-'}'
          '+${rawSubsec ?? '-'}/32768, '
          'fields {${f.isEmpty ? 'none' : f}}, '
          'drift used ${driftSec ?? 0} s, '
          'receipt ${receivedAt.toUtc().toIso8601String()}',
    ];
  }
}

/// Builds one scenario's timeline from band events. Pure.
class TimelineRecorder {
  /// [start] is when the scenario began (phone clock); [driftSec] is
  /// `wall - strap` for the converted time (0 when uncorrelated).
  TimelineRecorder({required this.start, this.driftSec = 0});
  final DateTime start;

  /// Refreshed by the runner when the strap clock is re-correlated.
  int driftSec;
  final List<TimelineEntry> _entries = [];

  List<TimelineEntry> get entries => List.unmodifiable(_entries);

  static const Map<int, String> _names = {
    14: 'DOUBLE_TAP',
    56: 'ALARM_SET',
    57: 'ALARM_EXECUTED (strap)',
    58: 'ALARM_EXECUTED (app)',
    59: 'ALARM_DISABLED',
    60: 'HAPTICS_FIRED',
    100: 'HAPTICS_TERMINATED',
  };

  /// The event ids this probe records: 14, 56..60, 100.
  static bool watches(int eventId) => _names.containsKey(eventId);

  /// Record [e]; null (nothing recorded) for an event not [watches]ed.
  TimelineEntry? addEvent(StrapEvent e) {
    final label = _names[e.eventId];
    if (label == null) return null;
    final code = e.decoded['haptics_termination_code'];
    final cause = e.decoded['haptics_termination'];
    final converted = e.plausible
        ? e.strapTime.add(Duration(seconds: driftSec))
        : null;
    final entry = TimelineEntry(
      label: label,
      eventId: e.eventId,
      cause: e.eventId == 100 && cause is String ? cause : null,
      causeCode: e.eventId == 100 && code is num ? code.toInt() : null,
      rawEpoch: e.tsEpoch,
      rawSubsec: e.tsSubsec,
      convertedAt: converted,
      receivedAt: e.receivedAt,
      sinceStartMs: e.receivedAt.difference(start).inMilliseconds,
      deltaMs: converted == null
          ? null
          : e.receivedAt.toUtc().difference(converted.toUtc()).inMilliseconds,
      hex: e.hex,
      fields: Map<String, dynamic>.of(e.decoded),
      driftSec: driftSec,
    );
    _entries.add(entry);
    return entry;
  }

  /// Record a phone-side mark at [at].
  TimelineEntry mark(String label, DateTime at) {
    final entry = TimelineEntry(
      label: label,
      receivedAt: at,
      sinceStartMs: at.difference(start).inMilliseconds,
    );
    _entries.add(entry);
    return entry;
  }
}

// ── verdicts ────────────────────────────────────────────────────────────────

bool _isExec(TimelineEntry e) => e.eventId == 57 || e.eventId == 58;
String _causeOf(TimelineEntry e) =>
    e.cause != null ? 'cause ${e.cause}' : 'cause not decoded';

String _deltaText(TimelineEntry e) => e.deltaMs == null
    ? 'no usable stamp'
    : 'receipt minus stamp ${e.deltaMs} ms';

/// The sentence about the double-tap event and a termination's cause.
String _tapSentence(List<TimelineEntry> taps, TimelineEntry? term) {
  final b = StringBuffer();
  if (term != null && term.cause == 'user_double_tap') {
    b.write('The double tap ended it (user_double_tap). ');
    b.write(taps.isNotEmpty
        ? 'A double-tap event (14) also arrived.'
        : 'No separate double-tap event (14) arrived.');
  } else if (term != null) {
    b.write('The pattern did not end by a double tap (${_causeOf(term)}). ');
    b.write(taps.isNotEmpty
        ? 'A double-tap event (14) arrived.'
        : 'No double-tap event (14) arrived.');
  }
  return b.toString();
}

/// The short plain-English verdict for [s] from its [timeline]. Pure. States
/// only what the timeline shows; absent events are said to be absent.
String terminationVerdict(
    TerminationScenario s, List<TimelineEntry> timeline) {
  final terms = [for (final e in timeline) if (e.eventId == 100) e];
  final taps = [for (final e in timeline) if (e.eventId == 14) e];
  final execs = [for (final e in timeline) if (_isExec(e)) e];
  switch (s) {
    case TerminationScenario.appFinishes:
      if (terms.isEmpty) {
        return 'No HAPTICS_TERMINATED arrived after the pattern finished.';
      }
      final t = terms.first;
      return 'HAPTICS_TERMINATED arrived (${_causeOf(t)}), '
          '${t.sinceStartMs} ms after the start; ${_deltaText(t)}.'
          '${terms.length > 1 ? ' ${terms.length} arrived in all.' : ''}';
    case TerminationScenario.appDoubleTap:
      if (terms.isEmpty) {
        return 'No HAPTICS_TERMINATED arrived. '
            '${taps.isNotEmpty ? 'A double-tap event (14) arrived. ' : ''}'
            'Run it again and double-tap while it buzzes.';
      }
      return 'HAPTICS_TERMINATED arrived (${_causeOf(terms.first)}). '
          '${_tapSentence(taps, terms.first)}';
    case TerminationScenario.alarmExpires:
    case TerminationScenario.alarmDoubleTap:
      if (execs.isEmpty) {
        return 'The alarm never reported EXECUTED (event 57 or 58) within '
            'the window.${terms.isEmpty ? '' : ' ${terms.length} '
                'HAPTICS_TERMINATED arrived anyway (${_causeOf(terms.first)}).'}';
      }
      final ran = 'The alarm reported EXECUTED (event ${execs.first.eventId})';
      final after = [
        for (final e in timeline.skipWhile((e) => !_isExec(e)))
          if (e.eventId == 100) e
      ];
      if (after.isEmpty) {
        return '$ran. No HAPTICS_TERMINATED arrived after it.'
            '${taps.isNotEmpty ? ' A double-tap event (14) arrived.' : ''}';
      }
      final t = after.first;
      if (s == TerminationScenario.alarmExpires) {
        return '$ran, then HAPTICS_TERMINATED arrived (${_causeOf(t)}); '
            '${_deltaText(t)}.'
            '${taps.isNotEmpty ? ' A double-tap event (14) arrived.' : ''}';
      }
      return '$ran, then HAPTICS_TERMINATED arrived (${_causeOf(t)}). '
          '${_tapSentence(taps, t)}';
    case TerminationScenario.overlap:
      final b = StringBuffer();
      if (execs.isEmpty) {
        b.write('The alarm never reported EXECUTED (event 57 or 58), so the '
            'overlap was not shown');
        b.write(terms.isEmpty
            ? '.'
            : '; the pattern may have ended before the alarm fired. ');
      }
      b.write(terms.isEmpty
          ? ' No HAPTICS_TERMINATED arrived.'
          : '${terms.length} HAPTICS_TERMINATED arrived '
              '(${terms.map((t) => t.cause ?? 'cause not decoded').join(', then ')}).');
      if (execs.isNotEmpty && terms.isNotEmpty) {
        final firstExec = timeline.indexWhere(_isExec);
        final firstTerm = timeline.indexWhere((e) => e.eventId == 100);
        b.write(firstTerm < firstExec
            ? ' The first stop came before the alarm EXECUTED was reported: '
                'the pattern ended before the alarm.'
            : ' No stop was reported before the alarm EXECUTED, so the '
                'pattern kept playing through the alarm start.');
        b.write(' The band does not label which stop belongs to the pattern '
            'and which to the alarm: read the order and stamps.');
      }
      if (execs.isNotEmpty && terms.isEmpty) b.write(' Nothing reported a stop.');
      return b.toString().trim();
    case TerminationScenario.stampPrecision:
      return stampVerdict(timeline);
  }
}

/// What the stamps in [timeline] show: whether the sub-second part is ever
/// non-zero, and the spread of receipt minus stamp. Pure.
String stampVerdict(List<TimelineEntry> timeline) {
  final stamped = [
    for (final e in timeline)
      if (e.rawEpoch != null && e.convertedAt != null) e
  ];
  if (stamped.isEmpty) {
    return 'No stamped events were received, so the stamp precision is '
        'unknown.';
  }
  final n = stamped.length;
  final nonZero = stamped.where((e) => (e.rawSubsec ?? 0) != 0).length;
  final deltas = [for (final e in stamped) if (e.deltaMs != null) e.deltaMs!];
  final spread = deltas.isEmpty
      ? ''
      : ' Receipt minus stamp ranged from ${deltas.reduce(math.min)} ms to '
          '${deltas.reduce(math.max)} ms.';
  if (nonZero == 0) {
    return 'The strap stamps are whole seconds: the sub-second field was 0 '
        'in every one of $n stamped events.$spread';
  }
  return '$nonZero of $n stamped events carry a non-zero sub-second field '
      '(units of 1/32768 s).$spread';
}

/// What one finished (or stopped) scenario left behind.
class TerminationResult {
  const TerminationResult({
    required this.scenario,
    required this.startedAt,
    required this.timeline,
    required this.verdict,
    required this.completed,
    this.clockStart,
    this.clockEnd,
  });
  final TerminationScenario scenario;
  final DateTime startedAt;
  final List<TimelineEntry> timeline;
  final String verdict;

  /// The scenario ran to its end (not stopped, not failed).
  final bool completed;

  /// The strap-clock correlation (clockRef) when the scenario began and when
  /// it ended, as text.
  final String? clockStart, clockEnd;
}

/// The saved report: header (band family, time), then for each scenario in
/// page order its title, verdict and timeline lines with the raw packet and
/// parsed fields of every band event (`not run` for one without a result),
/// then the stamp-precision summary over every stamped event. Pure.
String terminationReport(
  List<TerminationResult> results, {
  required String family,
  required DateTime at,
}) {
  final b = StringBuffer()
    ..writeln('OpenStrap termination probe report')
    ..writeln('Band family: $family')
    ..writeln('Report time: ${at.toLocal().toIso8601String()}')
    ..writeln('Raw stamp = the strap clock (whole seconds + a 1/32768 s '
        'remainder); converted time = stamp + clockRef drift; delta = phone '
        'receipt minus converted time.')
    ..writeln();
  final all = <TimelineEntry>[];
  for (final s in TerminationScenario.values) {
    final r = results.where((r) => r.scenario == s).lastOrNull;
    b.writeln('== ${s.title} ==');
    if (r == null) {
      b.writeln('Result: not run.');
      b.writeln();
      continue;
    }
    all.addAll(r.timeline);
    b.writeln(r.completed
        ? 'Result: completed.'
        : 'Result: stopped before the end (partial).');
    b.writeln('Started: ${r.startedAt.toLocal().toIso8601String()}');
    b.writeln('Verdict: ${r.verdict}');
    if (r.clockStart != null) b.writeln('clockRef at start: ${r.clockStart}');
    if (r.clockEnd != null) b.writeln('clockRef at end: ${r.clockEnd}');
    b.writeln('Timeline (${r.timeline.length} lines):');
    for (final e in r.timeline) {
      b.writeln('  ${e.line}');
      for (final d in e.detailLines) {
        b.writeln('      $d');
      }
    }
    b.writeln();
  }
  b.writeln('== Stamp precision across all runs ==');
  b.writeln(stampVerdict(all));
  return b.toString();
}

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
    this.runLab,
    this.clockRef,
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

  /// Runs an alarm scenario alone on the band and clear of a real arm pass;
  /// false when the band could not be had (the body never ran).
  final Future<bool> Function(Future<void> Function() body)? runExclusive;

  /// Runs an app-only scenario as a lab job in the band queue.
  final Future<bool> Function(Future<void> Function() body)? runLab;

  /// The strap-clock correlation now (null: none yet; drift is taken as 0).
  final ClockRef? Function()? clockRef;

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

  static const Duration _poll = Duration(milliseconds: 250);

  bool _running = false;
  TerminationScenario? _current;
  Completer<void>? _cancelSignal;
  TimelineRecorder? _rec;
  final Map<TerminationScenario, TerminationResult> _results = {};
  bool _touched = false;
  bool _clearFailed = false;
  bool? _restoreOk;
  String? _note;
  String? _status;
  int? _cutoffSec;

  bool get running => _running;
  TerminationScenario? get current => _current;
  String? get status => _status;
  String? get note => _note;

  /// The latest result of each scenario, page order, only those run.
  List<TerminationResult> get results => [
        for (final s in TerminationScenario.values)
          if (_results[s] != null) _results[s]!
      ];
  TerminationResult? resultOf(TerminationScenario s) => _results[s];

  /// The run could not confirm it left the band clean (a probe slot may still
  /// be armed, or the real alarm was not put back).
  bool get needsRecovery => _touched && (_restoreOk == false || _clearFailed);

  /// A tap during a run belongs to the probe, not to the wearer's tap actions.
  bool get holdsTaps => _running;

  /// Why [s] cannot start now; null when it can.
  String? blockedReason(TerminationScenario s) {
    if (!developerMode()) return 'Developer mode is off.';
    if (_running) return 'The termination probe is running.';
    if (!isConnected()) return 'Connect the band first.';
    final f = family();
    if (f != 'gen5') {
      return 'The termination probe is for the WHOOP 5 / MG band; this band '
          'is ${f ?? 'not identified yet'}.';
    }
    if (s.usesAlarm) {
      if (armBusy()) {
        return 'An alarm write is in progress. Try again in a moment.';
      }
      final held = heldEpoch();
      if (held != null &&
          (held * 1000 - clock.now().millisecondsSinceEpoch).abs() <
              kTerminationNearReal.inMilliseconds) {
        return 'Your alarm (${_hhmm(held)}) is within 10 minutes of now. Try '
            'again later, so the test alarm cannot get in the way.';
      }
    }
    if (ledger != null &&
        ledger!.commandsLeft(clock.now()) < kTerminationProbeCommands) {
      return 'The band is resting (${ledger!.limitNow} commands per 2 '
          'minutes, a limit we set). Try again in a moment.';
    }
    return null;
  }

  /// Run scenario [s]. Does nothing (and says why in [note]) when blocked.
  Future<void> run(TerminationScenario s) async {
    final why = blockedReason(s);
    if (why != null) {
      _say(why);
      return;
    }
    final room = ledger?.reserve(kTerminationProbeCommands, clock.now());
    if (ledger != null && room == null) {
      _say('The band is resting. Try again in a moment.');
      return;
    }
    final held = heldEpoch();
    _running = true;
    _current = s;
    _cancelSignal = Completer<void>();
    _touched = false;
    _clearFailed = false;
    _restoreOk = null;
    _note = null;
    _status = 'Starting';
    lab.beginSession(
      method: 'Termination probe',
      settings: s.title,
      tapAt: DateTime.now(),
    );
    notifyListeners();
    var bodyRan = false;
    final prior = _results[s];
    try {
      Future<void> body() {
        bodyRan = true;
        return _scenario(s, held, room);
      }

      final exclusive = s.usesAlarm ? runExclusive : runLab;
      if (exclusive == null) {
        await body();
      } else if (!await exclusive(body)) {
        _note = 'The band is busy. Try again in a moment.';
      }
    } catch (e) {
      // _scenario handles its own failures; this is the last net, so the
      // running flag can never stick.
      _step('probe failed: $e');
    } finally {
      room?.release();
      _running = false;
      _current = null;
      _status = null;
      _rec = null;
      lab.endSession(
        result: !bodyRan
            ? 'not run'
            : (_results[s] != prior ? _results[s]!.verdict : 'not run'),
      );
      notifyListeners();
    }
  }

  /// Stop now: the run clears its slot and restores the real alarm, then ends.
  /// Safe to call twice, or when nothing runs.
  void cancel() {
    if (!_running) return;
    final c = _cancelSignal;
    if (c == null || c.isCompleted) return;
    _step('stopped: cleaning up now');
    c.complete();
  }

  /// A live band event; recorded while a scenario runs.
  void onBandEvent(StrapEvent e) {
    final rec = _rec;
    if (!_running || rec == null) return;
    final entry = rec.addEvent(e);
    if (entry == null) return;
    _step(entry.line);
  }

  /// Whether AppState must NOT hand [e] to its alarm handler: events 56..60
  /// while the probe runs, and any stamped before the clean-up began (plus
  /// [kTerminationSwallowGrace]).
  bool swallowsEvent(StrapEvent e) {
    if (e.eventId < 56 || e.eventId > 60) return false;
    if (_running) return true;
    final c = _cutoffSec;
    return c != null && e.tsEpoch < c;
  }

  /// The report text (see [terminationReport]) for the file the page saves.
  String reportText({DateTime? at}) => terminationReport(
        results,
        family: family() ?? 'unknown',
        at: at ?? clock.now(),
      );

  // ── the run ────────────────────────────────────────────────────────────────

  bool get _cancelled => _cancelSignal?.isCompleted ?? false;

  Future<void> _sleep(Duration d) async {
    final end = clock.now().add(d);
    while (!_cancelled) {
      final left = end.difference(clock.now());
      if (left <= Duration.zero) return;
      await Future<void>.delayed(left < _poll ? left : _poll);
    }
  }

  /// Waits until [done], [max] runs out or the run is cancelled; once [done],
  /// listens [tail] more for stragglers.
  Future<void> _until(bool Function() done, Duration max) async {
    final end = clock.now().add(max);
    while (!_cancelled && !done() && clock.now().isBefore(end)) {
      final left = end.difference(clock.now());
      await Future<void>.delayed(left < _poll ? left : _poll);
    }
    if (!_cancelled && done()) await _sleep(tail);
  }

  int _count(TimelineRecorder r, bool Function(TimelineEntry) f) =>
      r.entries.where(f).length;
  bool _isTerm(TimelineEntry e) => e.eventId == 100;

  String _clockText() {
    final r = clockRef?.call();
    if (r == null) {
      return 'none (no strap-clock correlation yet; drift taken as 0 s)';
    }
    return 'device ${r.device}, wall ${r.wall}, drift ${r.driftSec} s '
        '(strap ${r.driftSec >= 0 ? 'behind' : 'ahead of'} the phone)';
  }

  int _drift() => clockRef?.call()?.driftSec ?? 0;

  TimelineEntry _mark(TimelineRecorder rec, String label) {
    final e = rec.mark(label, clock.now());
    _step(e.line);
    return e;
  }

  Future<void> _scenario(
      TerminationScenario s, int? held, BandReservation? room) async {
    final start = clock.now();
    final rec = _rec = TimelineRecorder(start: start, driftSec: _drift());
    final clockStart = _clockText();
    var completed = false;
    var store = true;
    String? failure;
    try {
      switch (s) {
        case TerminationScenario.appFinishes:
          final ok = await _appPattern(rec, room, kTerminationShortPattern,
              kTerminationShortLoop);
          failure = ok ? null : 'The pattern did not reach the band.';
          if (ok) {
            _status = 'Waiting for the band to report the end';
            notifyListeners();
            await _until(() => _count(rec, _isTerm) >= 1, window);
          }
          completed = ok && !_cancelled;
        case TerminationScenario.appDoubleTap:
          final ok = await _appPattern(rec, room, kTerminationLongPattern,
              kTerminationLongLoop);
          failure = ok ? null : 'The pattern did not reach the band.';
          if (ok) {
            _status = 'Double-tap the band now';
            notifyListeners();
            await _until(() => _count(rec, _isTerm) >= 1, window);
          }
          completed = ok && !_cancelled;
        case TerminationScenario.stampPrecision:
          completed = await _stamps(rec, room);
          if (!completed && !_cancelled) {
            failure = 'A pattern did not reach the band.';
          }
        case TerminationScenario.alarmExpires:
        case TerminationScenario.alarmDoubleTap:
        case TerminationScenario.overlap:
          final r = await _alarmFlow(s, rec, held, room);
          if (r == null) {
            store = false; // refused before arming anything
          } else {
            completed = r.completed;
            failure = r.failure;
          }
      }
    } catch (e) {
      _step('scenario error: $e');
      failure = 'The run failed: $e';
    } finally {
      final endClock = _clockText();
      final cutoffAt = clock.now();
      _rec = null; // the timeline is the scenario; clean-up is in the lab log
      if (_touched) await _cleanup(held, rec);
      if (_touched) {
        _cutoffSec = cutoffAt.add(kTerminationSwallowGrace)
                .millisecondsSinceEpoch ~/
            1000 -
            rec.driftSec;
      }
      if (store) {
        var verdict = terminationVerdict(s, rec.entries);
        if (failure != null) verdict = '$failure $verdict';
        if (!completed && _cancelled) {
          verdict = '$verdict The run was stopped early, so this is partial.';
        }
        _results[s] = TerminationResult(
          scenario: s,
          startedAt: start,
          timeline: rec.entries,
          verdict: verdict,
          completed: completed,
          clockStart: clockStart,
          clockEnd: endClock,
        );
        _step('result: $verdict');
      }
    }
  }

  Future<bool> _appPattern(TimelineRecorder rec, BandReservation? room,
      List<int> effects, int loop) async {
    _status = 'Playing the pattern';
    notifyListeners();
    _spend(room);
    final ok = await sendPattern(effects, loop);
    _mark(
        rec,
        ok
            ? 'pattern written (${effects.length} effects, loop $loop)'
            : 'pattern write FAILED');
    return ok;
  }

  Future<bool> _stamps(TimelineRecorder rec, BandReservation? room) async {
    for (var i = 0; i < stampPlays && !_cancelled; i++) {
      final before = _count(rec, _isTerm);
      final wrote = clock.now();
      if (!await _appPattern(rec, room, kTerminationShortPattern,
          kTerminationShortLoop)) {
        return false;
      }
      _status = 'Short buzz ${i + 1} of $stampPlays';
      notifyListeners();
      await _until(() => _count(rec, _isTerm) > before, const Duration(seconds: 10));
      await _sleep(stampGap - clock.now().difference(wrote));
    }
    return !_cancelled;
  }

  /// The three alarm scenarios. Null: refused before touching the band's
  /// alarm. Otherwise whether it completed, and why not if it failed.
  Future<({bool completed, String? failure})?> _alarmFlow(TerminationScenario s,
      TimelineRecorder rec, int? held, BandReservation? room) async {
    final slot = pickTerminationProbeSlot();
    _status = 'Reading your alarm';
    notifyListeners();
    final before = await _read(_kRealSlot, 'your slot before', room);
    final onBand = before.epoch;
    if (held == null &&
        onBand != null &&
        before.active != false &&
        onBand * 1000 > clock.now().millisecondsSinceEpoch) {
      _note = 'The band holds an alarm the app does not know about '
          '(${_hhmm(onBand)}). The probe would overwrite it, so it did not '
          'run. Save your alarm in the app first.';
      _step(_note!);
      return null;
    }
    final alarmAt = clock.now().add(alarmLead);
    _status = 'Arming the test alarm';
    notifyListeners();
    _spend(room);
    // Set before the write: a write that errors midway may still have
    // landed, and the clean-up must run for it.
    _touched = true;
    final w = await arm(slot, alarmAt);
    rec.driftSec = _drift();
    final taken = w.written && !w.rejected;
    _mark(
        rec,
        'alarm armed for ${labClock(alarmAt)} (probe slot id '
        '${AlarmPayloads.gen5Slot + slot}): '
        '${!w.written ? 'NOT WRITTEN' : !w.answered ? 'sent, no reply' : w.rejected ? 'REFUSED' : 'accepted'}'
        ' (alarm_status ${w.alarmStatus} ${w.alarmStatusName ?? '-'}), '
        'wall epoch ${w.wallSec}, strap epoch ${w.strapSec}, '
        'drift ${w.driftSec} s');
    if (!taken) {
      return (
        completed: false,
        failure: w.written
            ? 'The band refused the test alarm, so nothing was tested.'
            : 'The test alarm never reached the band, so nothing was tested.'
      );
    }
    await _read(slot, 'probe slot after arming', room);
    String? failure;
    if (s == TerminationScenario.overlap) {
      _status = 'Waiting to start the long pattern';
      notifyListeners();
      await _sleep(alarmAt.difference(clock.now()) - patternLead);
      if (!_cancelled &&
          !await _appPattern(rec, room, kTerminationLongPattern,
              kTerminationLongLoop)) {
        failure = 'The long pattern did not reach the band.';
      }
    }
    _status = s == TerminationScenario.alarmDoubleTap
        ? 'Double-tap the band when the test alarm buzzes'
        : 'Waiting for the test alarm';
    notifyListeners();
    bool exec() => rec.entries.any(_isExec);
    bool stopAfterExec() => rec.entries.skipWhile((e) => !_isExec(e)).any(_isTerm);
    final untilAlarm = alarmAt.difference(clock.now());
    final max = (untilAlarm > Duration.zero ? untilAlarm : Duration.zero) + window;
    if (s == TerminationScenario.overlap) {
      await _until(() => exec() && _count(rec, _isTerm) >= 2, max);
    } else {
      await _until(() => exec() && stopAfterExec(), max);
    }
    return (completed: failure == null && !_cancelled, failure: failure);
  }

  /// A readback. A throw is an unanswered read, never a failed run.
  Future<AlarmSlotRead> _read(int slot, String what, BandReservation? room,
      {bool cleanup = false}) async {
    try {
      if (cleanup) {
        ledger?.record(1, clock.now());
      } else {
        _spend(room);
      }
      final r = await read(slot);
      _step('readback $what: ${r.answered ? 'epoch ${r.epoch}'
          '${r.active == null ? '' : ', active ${r.active}'}' : 'no reply'}');
      return r;
    } catch (e) {
      _step('readback $what failed: $e');
      return const AlarmSlotRead.silent();
    }
  }

  void _spend(BandReservation? room) {
    if (room != null && !room.take(clock.now())) {
      throw StateError('the command budget reserved for the probe is used up');
    }
  }

  /// Clear the probe's slot and put the real alarm back. Every step is
  /// guarded on its own: one failing must not skip the next.
  Future<void> _cleanup(int? held, TimelineRecorder rec) async {
    _status = 'Cleaning up';
    notifyListeners();
    final slot = pickTerminationProbeSlot();
    try {
      ledger?.record(1, clock.now());
      final ok = await clear(slot);
      if (!ok) _clearFailed = true;
      _step('cleared probe slot id ${AlarmPayloads.gen5Slot + slot}: '
          '${ok ? 'sent' : 'FAILED'}');
    } catch (e) {
      _clearFailed = true;
      _step('clearing the probe slot FAILED: $e');
    }
    if (held != null) {
      var ok = false;
      try {
        ledger?.record(1, clock.now());
        ok = await restore(held);
      } catch (e) {
        _step('restoring your alarm threw: $e');
      }
      _restoreOk = ok;
      _step(ok
          ? 'restored your alarm (${_hhmm(held)}, epoch $held)'
          : 'your alarm was NOT restored. The band may hold a test alarm or '
              'none: open the Alarm screen and save it again.');
    }
    final after = await _read(slot, 'probe slot after the clear', null,
        cleanup: true);
    if (after.active == true) {
      _clearFailed = true;
      _step('the probe slot still reads active after the clear');
    }
    await _read(_kRealSlot, 'your slot after the restore', null,
        cleanup: true);
  }

  void _say(String line) {
    _note = line;
    _step(line, notify: false);
    notifyListeners();
  }

  void _step(String line, {bool notify = true}) {
    lab.addStep(line);
    log('[termination] $line');
    if (notify) notifyListeners();
  }
}

String _hhmm(int epochSec) {
  final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}
