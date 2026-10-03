// hardware_probe_runner.dart — runs one hardware probe at a time for the
// Device lab and holds what the screen shows: which probe runs, the current
// ECG cue, the buzz probe's "how many did you feel?" question (8V) and the
// pattern probe's transcriber (8Y: the wearer plays a test, taps what they felt
// as buzz and gap lengths 1-4, may play it again).
//
// Everything a probe learns goes into the lab log as a session (so "Copy all
// logs" carries it), and the ECG probe's packets go into the lab's packet
// buffer, tagged with the probe. RAM only.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import '../notify/alert_rule.dart';
import 'hardware_probes.dart';
import 'lab_log.dart';
import 'pattern_transcript.dart';
import 'strap_event.dart';

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
  });

  final DeviceLabLog lab;
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
      sendPattern: sendPattern,
      isConnected: isConnected,
      step: lab.addStep,
    );
    _session = PatternEntrySession(probe.tests);
    _patternPlaying = false;
    final gaps =
        probe.tests.where((t) => t.style == BuzzStyle.delayed).length;
    lab.beginSession(
      method: 'Pattern probe',
      settings: '${probe.tests.length} tests, transcribed: 4 waveforms × 4 '
          'ways of sending × 2 counts, plus $gaps gap tests',
      tapAt: DateTime.now(),
    );
    notifyListeners();
  }

  /// Play the test on screen. The band gets nothing while a play runs; a play
  /// that wrote nothing is not counted.
  Future<void> playPattern() async {
    final s = _session, probe = _probe;
    if (s == null || probe == null || _patternPlaying) return;
    final at = s.testIndex;
    _patternPlaying = true;
    notifyListeners();
    try {
      final r = await probe.play(s.tests[at]);
      if (r != null && identical(_session, s)) s.notePlayed(at);
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
  void patternDelete() => _edit((s) => s.delete());
  void patternMove(int delta) => _edit((s) => s.moveCursor(delta));
  void patternRendition(int r) => _edit((s) => s.selectRendition(r));
  void patternTest(int delta) =>
      _edit((s) => s.goToTest(s.testIndex + delta));

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
    var heard = 0, plays = 0;
    for (var i = 0; i < s.tests.length; i++) {
      if (s.rendition(i, 0).length > 0 || s.rendition(i, 1).length > 0) heard++;
      plays += s.plays(i);
    }
    s.logLines().forEach(lab.addStep);
    lab.endSession(
        result: '$heard of ${s.tests.length} tests transcribed, $plays plays');
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
    _probe?.onBandEvent(e.eventId, e.receivedAt, e.effectiveTime);
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
