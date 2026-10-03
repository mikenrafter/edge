// hardware_probe_runner.dart — runs one hardware probe at a time for the
// Device lab and holds what the screen shows: which probe runs, the current
// ECG cue, the buzz probe's "how many did you feel?" question (8V) and the
// pattern probe's transcriber (8Y/8Z: the wearer plays a test, taps what they
// felt as note and rest lengths, may play it again).
//
// Everything a probe learns goes into the lab log as a session (so "Copy all
// logs" carries it), and the ECG probe's packets go into the lab's packet
// buffer, tagged with the probe. RAM only.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import '../haptics/band_queue.dart';
import '../notify/alert_rule.dart';
import 'hardware_probes.dart';
import 'lab_log.dart';
import 'pattern_transcript.dart';
import 'strap_event.dart';

// The reason type of [HardwareProbeRunner.patternRefusal].
export 'hardware_probes.dart' show PatternRefusal;

enum ProbeKind { buzz, ecg, pattern }

/// The buzz probe's dispatcher rule: band only, live link, its own id so a
/// probe buzz never shares a claim with a real alert.
const hardwareProbeRule = AlertRule(
  id: 'hardware_probe',
  kind: 'hardwareProbe',
  destinations: AlertRule.band,
  executionMode: AlertExecutionMode.phoneLive,
  staleAfter: Duration(seconds: 10),
  channelPolicyId: 'hardware_probe',
);

class HardwareProbeRunner extends ChangeNotifier {
  HardwareProbeRunner({
    required this.lab,
    required this.sendBuzz,
    required this.sendPattern,
    required this.isConnected,
    required this.ecgSupported,
    required this.ecgBusy,
    required this.beginEcg,
    required this.endEcg,
    required this.isEcgAlive,
    BandCommandLedger? ledger,
  }) : ledger = ledger ?? BandCommandLedger();

  final DeviceLabLog lab;

  /// The band's rolling command limit (30 in 2 minutes), shared with the alert
  /// queue (8AC): the probe's writes count in it and alert commands count
  /// against the probe's limit. Kept here so closing and reopening the screen
  /// does not reset it.
  final BandCommandLedger ledger;
  final Future<bool> Function(void Function(String? status, int ms) onReply)
      sendBuzz;

  /// One custom Maverick pattern (the pattern probe, 8W).
  final Future<bool> Function(List<int> effects, int loop,
      void Function(String? status, int ms) onReply) sendPattern;
  final bool Function() isConnected;
  final bool Function() ecgSupported;

  /// Something else holds the ECG stream (a gesture, a reading).
  final bool Function() ecgBusy;
  final Future<bool> Function() beginEcg;
  final Future<void> Function() endEcg;
  final bool Function() isEcgAlive;

  ProbeKind? _running;
  EcgCue? _cue;
  HapticTrial? _question;
  int _questionIndex = 0;
  Completer<int?>? _answer;
  HapticProbe? _haptic;
  PatternProbe? _probe;
  PatternEntrySession? _session;
  bool _patternPlaying = false;
  int _patternPlays = 0;
  DateTime? _patternPlayWrittenAt;
  EcgTouchProbe? _touch;
  String? _note;

  ProbeKind? get running => _running;

  /// The ECG cue to show now (null when none).
  EcgCue? get cue => _cue;

  /// The buzz probe's open question, and which trial it is about.
  HapticTrial? get question => _question;
  int get questionIndex => _questionIndex;
  int get trialCount => HapticProbe.defaultTrials.length;

  /// The open pattern transcriber (null when the pattern probe is closed).
  PatternEntrySession? get pattern => _session;
  bool get patternPlaying => _patternPlaying;

  /// Why the latest play was refused (null: none, or the probe is closed).
  PatternRefusal? get patternRefusal => _probe?.lastRefusal;

  /// How long the band still rests after a "resting" refusal; null when not
  /// resting or ready.
  Duration? get patternRestRemaining => _probe?.restRemaining(clock.now());

  /// Commands the band may still be sent now (30 minus those in the rolling
  /// window, never below 0). Holds while the screen is closed.
  int get patternCommandsLeft => ledger.commandsLeft(clock.now());

  /// Time until the oldest command leaves the window; null when it is empty.
  Duration? get patternNextFreeIn => ledger.nextFreeIn(clock.now());

  /// Plays started so far; the page restarts its metronome when it grows.
  int get patternPlays => _patternPlays;

  /// When the current (or latest) play's first write landed, phone clock; null
  /// until it lands, cleared when the next play starts and on close.
  DateTime? get patternPlayWrittenAt => _patternPlayWrittenAt;
  int get patternTestCount => PatternProbe.defaultTests.length;

  /// One line about why a probe could not start (or how it ended).
  String? get note => _note;

  bool get canRunBuzz => _running == null && isConnected();
  bool get canRunEcg =>
      _running == null && isConnected() && ecgSupported() && !ecgBusy();

  bool get canRunPattern =>
      _running == null && isConnected() && ecgSupported();

  Future<void> runBuzz() async {
    if (!canRunBuzz) {
      _say(isConnected() ? 'A probe is already running.' : 'Connect the band first.');
      return;
    }
    _running = ProbeKind.buzz;
    _note = null;
    final probe = _haptic = HapticProbe(
      sendOne: sendBuzz,
      askFelt: _ask,
      isConnected: isConnected,
      step: lab.addStep,
    );
    lab.beginSession(
      method: 'Buzz probe',
      settings: '${probe.trials.length} trials of '
          '${probe.trials.first.commands} buzzes',
      tapAt: DateTime.now(),
    );
    notifyListeners();
    try {
      final results = await probe.run();
      lab.endSession(result: '${results.length} trials');
    } catch (e) {
      lab.addStep('Buzz probe failed: $e');
      lab.endSession(result: 'failed');
    } finally {
      _haptic = null;
      _running = null;
      _closeQuestion(null);
      notifyListeners();
    }
  }

  /// Open the pattern transcriber: custom Maverick patterns the wearer plays
  /// on demand and writes down. MG only (the other bands have no Maverick
  /// buzz). Nothing is sent until [playPattern].
  Future<void> openPattern() async {
    if (!canRunPattern) {
      _say(_running != null
          ? 'A probe is already running.'
          : !isConnected()
              ? 'Connect the band first.'
              : 'This band cannot play custom patterns.');
      return;
    }
    _running = ProbeKind.pattern;
    _note = null;
    final probe = _probe = PatternProbe(
      sendPattern: (effects, loop, onReply) async {
        final ok = await sendPattern(effects, loop, onReply);
        if (ok && _patternPlaying && _patternPlayWrittenAt == null) {
          _patternPlayWrittenAt = DateTime.now();
          notifyListeners();
        }
        return ok;
      },
      isConnected: isConnected,
      step: lab.addStep,
      now: clock.now,
      writeLog: ledger.writeLog,
    );
    _session = PatternEntrySession(probe.tests);
    _patternPlaying = false;
    _patternPlayWrittenAt = null;
    final gaps =
        probe.tests.where((t) => t.style == BuzzStyle.delayed).length;
    lab.beginSession(
      method: 'Pattern probe',
      settings: '${probe.tests.length} tests, transcribed: 4 waveforms × 4 '
          'ways of sending × 2 counts, plus $gaps gap tests',
      tapAt: DateTime.now(),
    );
    lab.addStep('Pattern probe set: $kWhoopMgPatternProbeSetId');
    notifyListeners();
  }

  /// Play the test on screen. The band gets nothing while a play runs; a play
  /// that wrote nothing is not counted.
  Future<void> playPattern() async {
    final s = _session, probe = _probe;
    if (s == null || probe == null || _patternPlaying) return;
    final at = s.testIndex;
    _patternPlaying = true;
    _patternPlayWrittenAt = null;
    try {
      // The probe decides a refusal before its first await: a refused play
      // is no play, so the count (the page's metronome cue) moves only on an
      // accepted one.
      final pending = probe.play(s.tests[at]);
      if (probe.lastRefusal == null) _patternPlays++;
      notifyListeners();
      final r = await pending;
      if (r != null && identical(_session, s)) {
        s.notePlayed(at);
        final span = r.spanMs, lead = r.leadMs;
        if (span != null) s.noteMeasured(at, span);
        if (lead != null) s.noteLead(lead);
      }
    } catch (e) {
      lab.addStep('Pattern probe play failed: $e');
    } finally {
      if (identical(_session, s)) {
        _patternPlaying = false;
        notifyListeners();
      }
    }
  }

  void patternTap(int len) => _edit((s) => s.tap(len));
  void patternToggleDot() => _edit((s) => s.toggleDot());
  void patternToggleKind() => _edit((s) => s.toggleKind());
  void patternDynamicTempo(bool on) => _edit((s) => s.dynamicTempo = on);
  void patternDynamic(PatternDynamic d) => _edit((s) => s.setDynamic(d));
  void patternToggleUnstable() => _edit((s) => s.toggleUnstable());
  void patternDelete() => _edit((s) => s.delete());
  void patternMove(int delta) => _edit((s) => s.moveCursor(delta));
  void patternRendition(int r) => _edit((s) => s.selectRendition(r));
  void patternTest(int delta) =>
      _edit((s) => s.goToTest(s.testIndex + delta));

  /// Put a transcription made from taps (8AD) into the active rendition of
  /// the open test, and say so in the log.
  void patternSetRendition(List<PatternEntry> entries) => _edit((s) {
        s.setActive(entries);
        lab.addStep('Pattern probe: test ${s.testIndex + 1} rendition '
            '${s.activeRendition == 0 ? 'A' : 'B'} from taps: ${s.active.code}');
      });

  void _edit(void Function(PatternEntrySession s) change) {
    final s = _session;
    if (s == null) return;
    change(s);
    notifyListeners();
  }

  /// Stop the pattern probe, write what was transcribed into the lab log and
  /// end its session. Does nothing when it is not open.
  void closePattern() {
    final s = _session;
    if (s == null) return;
    _probe?.stop();
    _probe = null;
    _session = null;
    _patternPlaying = false;
    _patternPlayWrittenAt = null;
    s.logLines().forEach(lab.addStep);
    lab.endSession(
        result: '${s.testsTranscribed} of ${s.tests.length} tests '
            'transcribed, ${s.totalPlays} plays');
    _running = null;
    notifyListeners();
  }

  Future<void> runEcg() async {
    if (!canRunEcg) {
      _say(!ecgSupported()
          ? 'This band has no ECG sensor.'
          : !isConnected()
              ? 'Connect the band first.'
              : 'The ECG is in use (a gesture, a reading or a probe).');
      return;
    }
    _running = ProbeKind.ecg;
    _note = null;
    final tagAt = DateTime.now();
    final tag = 'ECG touch probe ${labClock(tagAt)}';
    final probe = _touch = EcgTouchProbe(
      beginStream: beginEcg,
      endStream: endEcg,
      isStreamAlive: isEcgAlive,
      onCue: (c) {
        _cue = c;
        notifyListeners();
      },
      step: lab.addStep,
      onPacket: (r, at) => lab.addPacket(r, at, tag: tag),
    );
    lab.beginSession(
      method: 'ECG touch probe',
      settings: '${probe.script.length} cues',
      tapAt: tagAt,
    );
    notifyListeners();
    try {
      await probe.run();
      lab.endSession(result: '${probe.cues.length} cues shown');
    } catch (e) {
      lab.addStep('ECG touch probe failed: $e');
      lab.endSession(result: 'failed');
    } finally {
      _touch = null;
      _cue = null;
      _running = null;
      notifyListeners();
    }
  }

  /// The wearer's answer to the open question (null: not sure / skip).
  void answer(int? felt) => _closeQuestion(felt);

  /// Stop whichever probe runs. The ECG stream is stopped by the probe itself.
  void stop() {
    _haptic?.stop();
    closePattern();
    _touch?.stop();
    _closeQuestion(null);
  }

  void onFrame(LabradorR17 r) => _touch?.onFrame(r);

  void onBandEvent(StrapEvent e) {
    _haptic?.onBandEvent(e.eventId, e.receivedAt, e.effectiveTime);
    // The pattern probe measures spans and leads on [clock] (the same as
    // DateTime.now outside tests); move the event's times onto it.
    final skew = clock.now().difference(DateTime.now());
    _probe?.onBandEvent(
      e.eventId,
      e.receivedAt.add(skew),
      e.effectiveTime.add(skew),
    );
  }

  Future<int?> _ask(HapticTrial trial, int index) {
    final c = _answer = Completer<int?>();
    _question = trial;
    _questionIndex = index;
    notifyListeners();
    return c.future;
  }

  void _closeQuestion(int? felt) {
    final c = _answer;
    _answer = null;
    _question = null;
    if (c != null && !c.isCompleted) c.complete(felt);
    notifyListeners();
  }

  void _say(String line) {
    _note = line;
    notifyListeners();
  }
}
