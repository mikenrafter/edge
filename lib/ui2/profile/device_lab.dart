// Device lab — a bench for the gestures the firmware does not report.
//
// The band sends a double tap and nothing else. Anything beyond it (ECG on a
// double tap, 3–5 taps counted as touches of the ECG sensor, or as more double
// taps in a row) is exploration, so this screen shows the evidence instead of
// hiding it: every band event with the band's own time, the phone's receipt
// time, the delay between them and whether it was live or late, plus the step
// by step trace of each counting session, with the time of every line, the time
// since the tap and the time since the line before.
//
// ECG needs a WHOOP MG. On any other band the switch is shown, disabled, with
// the reason. While a lab switch is on, normal double-tap actions are suspended
// and this screen's counter takes over (GestureDispatcher). "Copy all logs" at
// the bottom copies everything on this screen as plain text, plus the kept ECG
// packets (raw, for replay off the band).
//
// Hardware probes (8V): a buzz-spacing probe and a cued ECG touch probe, each
// started only here, bounded and stoppable ([HardwareProbePanel]).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../gestures/ecg_tap_counter.dart';
import '../../gestures/gesture_settings.dart';
import '../../gestures/hardware_probe_runner.dart';
import '../../gestures/hardware_probes.dart';
import '../../gestures/lab_log.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'pattern_probe_page.dart';
import 'profile.dart';

export '../../gestures/lab_log.dart' show DeviceLabEntry, labClock;

/// The 8I note, said on this screen and on Gestures: what extended gestures
/// need, and that the extra-tap rows are a draft to try here first. Never names
/// a single tap.
const String kExtendedGesturesNote =
    'ECG on double tap and counting touches on the ECG sensor need a WHOOP MG. '
    'WHOOP 4.0 has no ECG sensor, so it counts extra double taps instead. '
    'The 3–5 tap rows are a draft, and so are the 2–4 double taps rows. '
    'Try them first in the Device lab, under your band in Devices: it logs '
    'every step with its timing.';

class DeviceLab extends StatelessWidget {
  const DeviceLab({super.key});

  @override
  Widget build(BuildContext c) {
    final app = c.read<AppState>();
    final g = app.gestureSettings;
    // The text "Copy all logs" copies, read when asked: the lab's own button
    // and the pattern probe's end screen share it.
    String logText() => labLogText(
      entries: app.deviceLab.entries,
      steps: app.deviceLab.steps,
      sessions: app.deviceLab.sessionSummaries,
      packets: app.deviceLab.packets,
    );
    return ListenableBuilder(
      listenable: Listenable.merge([g, app.deviceLab]),
      builder: (c, _) => DeviceLabView(
        ecgSupported: app.pairedIsMaverick,
        ecgOnDoubleTap: g.ecgOnDoubleTap,
        onEcgOnDoubleTap: g.setEcgOnDoubleTap,
        repeatLab: g.repeatTapsLab,
        onRepeatLab: g.setRepeatTapsLab,
        repeatWindowMs: g.repeatTapWindowMs,
        onRepeatWindowMs: g.setRepeatTapWindowMs,
        entries: app.deviceLab.entries,
        steps: app.deviceLab.steps,
        sessions: app.deviceLab.sessionSummaries,
        packets: app.deviceLab.packets,
        thresholds: g.ecgTapThresholds,
        onThresholds: g.setEcgTapThresholds,
        logText: logText,
        probes: HardwareProbePanel(runner: app.hardwareProbes, logText: logText),
      ),
    );
  }
}

class DeviceLabView extends StatelessWidget {
  const DeviceLabView({
    super.key,
    required this.ecgSupported,
    this.ecgOnDoubleTap = false,
    this.onEcgOnDoubleTap,
    this.repeatLab = false,
    this.onRepeatLab,
    this.repeatWindowMs,
    this.onRepeatWindowMs,
    this.entries = const [],
    this.steps = const [],
    this.sessions = const [],
    this.thresholds,
    this.onThresholds,
    this.packets = const [],
    this.probes,
    this.logText,
  });

  final bool ecgSupported;
  final bool ecgOnDoubleTap;
  final ValueChanged<bool>? onEcgOnDoubleTap;

  /// Try the repeated-double-tap method (any band).
  final bool repeatLab;
  final ValueChanged<bool>? onRepeatLab;

  /// The pause between repeated double taps; the adjuster shows only when
  /// [onRepeatWindowMs] is given.
  final int? repeatWindowMs;
  final ValueChanged<int>? onRepeatWindowMs;

  /// Newest first.
  final List<DeviceLabEntry> entries;

  /// The sessions' steps, newest first, already formatted (time, time since the
  /// tap, time since the line before, text).
  final List<String> steps;

  /// One summary line per finished session, newest first.
  final List<String> sessions;

  final EcgTapThresholds? thresholds;
  final ValueChanged<EcgTapThresholds>? onThresholds;

  /// Kept ECG packets, oldest first; copied with the log.
  final List<LabPacket> packets;

  /// The hardware probes section, when the screen has a runner for it.
  final Widget? probes;

  /// What "Copy all logs" copies; built from the fields above when not given.
  final String Function()? logText;

  Future<void> _copy(BuildContext c) async {
    await Clipboard.setData(ClipboardData(
      text: logText?.call() ??
          labLogText(
              entries: entries,
              steps: steps,
              sessions: sessions,
              packets: packets),
    ));
    if (!c.mounted) return;
    ScaffoldMessenger.of(c).showSnackBar(
      const SnackBar(content: Text('Log copied')),
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar('Device lab'),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x4),
              children: [
                Surface(
                  child: Text(kExtendedGesturesNote,
                      style: F.body.copyWith(color: p.ink2, height: 1.4)),
                ),
                Section(
                  'ECG on double tap',
                  Surface(
                    pad: const EdgeInsets.symmetric(horizontal: S.x4),
                    child: SwitchRow(
                      'Toggle ECG recording on double tap',
                      ecgOnDoubleTap && ecgSupported,
                      onEcgOnDoubleTap,
                      enabled: ecgSupported,
                      sub: ecgSupported
                          ? 'A live double tap starts an ECG recording. Once '
                              'the sensor is ready the band buzzes three times '
                              'if a finger is on it, or twice to stop at two '
                              'taps. Normal double-tap actions are paused '
                              'while this is on.'
                          : 'This band has no ECG sensor',
                    ),
                  ),
                ),
                Section(
                  'Touch windows',
                  Surface(
                    child: EcgThresholdAdjusters(
                      thresholds: thresholds ?? EcgTapThresholds(),
                      onChanged: ecgSupported ? onThresholds : null,
                    ),
                  ),
                ),
                Section(
                  'Repeated double taps',
                  Surface(
                    child: Column(children: [
                      SwitchRow(
                        'Try repeated double taps',
                        repeatLab,
                        onRepeatLab,
                        sub: 'Works on every band, no ECG needed. Double tap '
                            'again before the pause ends; each one buzzes '
                            'once. Up to 5 are counted and no action runs '
                            'while this is on.',
                      ),
                      if (onRepeatWindowMs != null)
                        RepeatWindowAdjuster(
                          windowMs: repeatWindowMs ??
                              GestureSettings.defaultRepeatWindowMs,
                          onChanged: onRepeatWindowMs,
                        ),
                    ]),
                  ),
                ),
                if (probes != null) Section('Hardware probes', probes!),
                if (sessions.isNotEmpty)
                  Section(
                    'Sessions',
                    Surface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final s in sessions)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: S.x1),
                              child:
                                  Text(s, style: F.cap.copyWith(color: p.ink)),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (steps.isNotEmpty)
                  Section(
                    'Step by step',
                    Surface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final s in steps)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: S.x1),
                              child: Text(s,
                                  style: F.cap.copyWith(color: p.ink2)),
                            ),
                        ],
                      ),
                    ),
                  ),
                Section(
                  'Band events',
                  Surface(
                    child: entries.isEmpty
                        ? Text('No band events yet.',
                            style: F.body.copyWith(color: p.ink3))
                        : Column(children: [
                            for (var i = 0; i < entries.length; i++) ...[
                              if (i > 0) Divider(color: p.line, height: 1),
                              _EntryRow(entries[i]),
                            ],
                          ]),
                  ),
                ),
              ],
            ),
          ),
          // Pinned to the bottom, so it is one tap away however long the log is.
          Padding(
            padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x3),
            child: BigButton(
              'Copy all logs',
              key: const ValueKey('lab-copy-all'),
              icon: LucideIcons.copy,
              soft: true,
              color: C.blue,
              onTap: () => _copy(c),
            ),
          ),
        ]),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow(this.e);
  final DeviceLabEntry e;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: S.x2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Event ${e.eventId} · ${e.live ? 'Live' : 'Late'} · ${e.delayLabel}',
            style: F.body.copyWith(color: p.ink)),
        Text('Happened ${labClock(e.eventTime)}',
            style: F.cap.copyWith(color: p.ink3)),
        Text('Received ${labClock(e.receivedAt)}',
            style: F.cap.copyWith(color: p.ink3)),
        if (e.actions.isNotEmpty)
          Text('Ran ${e.actions.join(', ')}',
              style: F.cap.copyWith(color: p.ink3)),
      ]),
    );
  }
}

/// The pause between repeated double taps, 250 ms steps from 1000 to 5000 ms.
/// Shared by the Device lab and the Gestures screen.
class RepeatWindowAdjuster extends StatelessWidget {
  const RepeatWindowAdjuster({super.key, required this.windowMs, this.onChanged});

  final int windowMs;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext c) => _Adjuster(
        keyBase: 'repeat-window',
        label: 'Pause between double taps',
        caption: 'How long to wait for another double tap. Each one starts '
            'the pause again.',
        value: windowMs,
        range: GestureSettings.repeatWindowRange,
        step: GestureSettings.repeatWindowStepMs,
        onSet: onChanged,
      );
}

/// The three touch windows (8L), 50 ms steps within their ranges. Shared by the
/// Device lab and the Gestures screen. With [onChanged] null every button is
/// inert (no ECG sensor).
class EcgThresholdAdjusters extends StatelessWidget {
  const EcgThresholdAdjusters(
      {super.key, required this.thresholds, this.onChanged});

  final EcgTapThresholds thresholds;
  final ValueChanged<EcgTapThresholds>? onChanged;

  @override
  Widget build(BuildContext c) {
    return Column(children: [
      _Adjuster(
        keyBase: 'ecg-threshold:start',
        label: 'Start threshold',
        caption: 'How long the first touch can take to begin once the sensor '
            'is ready. A finger already on the sensor counts.',
        value: thresholds.startMs,
        range: EcgTapThresholds.startRange,
        step: EcgTapThresholds.stepMs,
        onSet: onChanged == null
            ? null
            : (v) => onChanged!(thresholds.copyWith(startMs: v)),
      ),
      _Adjuster(
        keyBase: 'ecg-threshold:gap',
        label: 'Gap threshold',
        caption: 'Sets both how long a touch must hold to count and how long '
            'you must let go to end it.',
        value: thresholds.gapMs,
        range: EcgTapThresholds.gapRange,
        step: EcgTapThresholds.stepMs,
        onSet: onChanged == null
            ? null
            : (v) => onChanged!(thresholds.copyWith(gapMs: v)),
      ),
      _Adjuster(
        keyBase: 'ecg-threshold:confirm',
        label: 'Confirmation threshold',
        caption: 'Extra time after you let go for the next touch to begin '
            'before the count is final.',
        value: thresholds.confirmMs,
        range: EcgTapThresholds.confirmRange,
        step: EcgTapThresholds.stepMs,
        onSet: onChanged == null
            ? null
            : (v) => onChanged!(thresholds.copyWith(confirmMs: v)),
      ),
      SwitchRow(
        key: const ValueKey('ecg-threshold:extra-sensitive'),
        'Extra sensitive subsequent tap detection',
        thresholds.extraSensitive,
        onChanged == null
            ? null
            : (v) => onChanged!(thresholds.copyWith(extraSensitive: v)),
        enabled: onChanged != null,
        sub: 'Off: the band sends its sensor readings about once a second, '
            'and within each batch everything from the first to the last '
            'reading with contact counts as one touch. A lift and re-touch '
            'inside the same second counts as one tap. '
            'On: every reading counts on its own, so quicker taps can be '
            'told apart. But the heart signal crosses zero now and then, and '
            'a single zero reading while a touch is starting restarts its '
            'hold time, so taps can be missed, counted late, or split in two.',
      ),
      SwitchRow(
        key: const ValueKey('ecg-threshold:tolerant-startup'),
        'Tolerant startup',
        thresholds.tolerantStartup,
        onChanged == null
            ? null
            : (v) => onChanged!(thresholds.copyWith(tolerantStartup: v)),
        enabled: onChanged != null,
        sub: 'On: waits for the sensor to settle (about 2.5 s), so a finger '
            'placed during startup still counts. Off: decides a plain double '
            'tap from the first ECG packet, about 2 s sooner, but a finger '
            'placed after that packet is missed.',
      ),
      SwitchRow(
        key: const ValueKey('ecg-threshold:fallback'),
        'Fall back to the double-tap action',
        thresholds.fallbackToDoubleTap,
        onChanged == null
            ? null
            : (v) => onChanged!(thresholds.copyWith(fallbackToDoubleTap: v)),
        enabled: onChanged != null,
        sub: 'On: if the ECG cannot start or stops before any touch is '
            'counted, the double-tap action runs. Off: the ECG is tried once '
            'more instead. Either way the band gives one long buzz when the '
            'ECG fails.',
      ),
    ]);
  }
}

class _Adjuster extends StatelessWidget {
  const _Adjuster({
    required this.keyBase,
    required this.label,
    required this.caption,
    required this.value,
    required this.range,
    required this.step,
    required this.onSet,
  });

  /// The buttons are keyed "$keyBase:-" and "$keyBase:+".
  final String keyBase, label, caption;
  final int value, step;
  final (int, int) range;
  final ValueChanged<int>? onSet;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final set = onSet;
    final canDown = set != null && value - step >= range.$1;
    final canUp = set != null && value + step <= range.$2;
    return Opacity(
      opacity: set == null ? kDisabledOpacity : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x2),
        child: Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: F.body.copyWith(color: p.ink)),
              Text(caption, style: F.over.copyWith(color: p.ink3)),
            ]),
          ),
          IconButton(
            key: ValueKey('$keyBase:-'),
            tooltip: 'Decrease $label',
            icon: const Icon(LucideIcons.minus, size: 18),
            onPressed: canDown ? () => set(value - step) : null,
          ),
          Text('$value ms', style: F.body.copyWith(color: p.ink)),
          IconButton(
            key: ValueKey('$keyBase:+'),
            tooltip: 'Increase $label',
            icon: const Icon(LucideIcons.plus, size: 18),
            onPressed: canUp ? () => set(value + step) : null,
          ),
        ]),
      ),
    );
  }
}


/// The Device lab's hardware probes (8V). Reads [HardwareProbeRunner]; the
/// phone vibrates on every ECG cue so the wearer can watch the band, not the
/// screen. Leaving the screen stops a running probe.
class HardwareProbePanel extends StatefulWidget {
  const HardwareProbePanel({
    super.key,
    required this.runner,
    required this.logText,
  });
  final HardwareProbeRunner runner;

  /// The text of the lab's "Copy all logs", for the pattern probe's end
  /// screen.
  final String Function() logText;

  @override
  State<HardwareProbePanel> createState() => _HardwareProbePanelState();
}

class _HardwareProbePanelState extends State<HardwareProbePanel> {
  EcgCue? _lastCue;

  @override
  void initState() {
    super.initState();
    widget.runner.addListener(_changed);
  }

  @override
  void dispose() {
    widget.runner.removeListener(_changed);
    widget.runner.stop();
    super.dispose();
  }

  void _changed() {
    final cue = widget.runner.cue;
    if (cue != null && !identical(cue, _lastCue)) {
      if (cue.kind == EcgCueKind.touch) {
        HapticFeedback.heavyImpact();
      } else if (cue.kind != EcgCueKind.rest) {
        HapticFeedback.selectionClick();
      }
    }
    _lastCue = cue;
    if (mounted) setState(() {});
  }

  /// The pattern probe is a page of its own; it closes the probe when it goes.
  Future<void> _openPattern() async {
    final r = widget.runner;
    await r.openPattern();
    if (!mounted || r.pattern == null) return;
    await goto(
      context,
      PatternProbePage(runner: r, logText: widget.logText),
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final r = widget.runner;
    final running = r.running;
    final cue = r.cue;
    final q = r.question;
    final note = r.note;
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Measure what the band can do. The buzz probe sends up to '
            '${HapticProbe.maxCommands} short buzzes in groups of three, '
            'with a rest after each group, and asks how many you felt. The '
            'ECG probe streams for at most '
            '${EcgTouchProbe.maxStream.inSeconds} s and tells you when to '
            'touch and lift the sensor (the phone vibrates on each cue). '
            'Stop ends either at once. Results go into the log below.',
            style: F.cap.copyWith(color: p.ink2, height: 1.4),
          ),
          const SizedBox(height: S.x3),
          if (running == null) ...[
            BigButton(
              'Run buzz probe',
              key: const ValueKey('probe-buzz'),
              icon: LucideIcons.vibrate,
              soft: true,
              color: C.blue,
              onTap: r.canRunBuzz ? r.runBuzz : null,
            ),
            const SizedBox(height: S.x2),
            BigButton(
              'Run ECG touch probe',
              key: const ValueKey('probe-ecg'),
              icon: LucideIcons.heartPulse,
              soft: true,
              color: C.blue,
              onTap: r.canRunEcg ? r.runEcg : null,
            ),
            const SizedBox(height: S.x2),
            BigButton(
              'Run pattern probe',
              key: const ValueKey('probe-pattern'),
              icon: LucideIcons.audioWaveform,
              soft: true,
              color: C.blue,
              onTap: r.canRunPattern ? _openPattern : null,
            ),
            const SizedBox(height: S.x1),
            Text(
              'MG only. Opens a screen where you play custom buzz patterns and '
              'tap out what you felt as buzz and gap lengths, at most '
              '${PatternProbe.maxCommandsPerWindow} commands in any 2 '
              'minutes. Leaving the screen ends it.',
              style: F.cap.copyWith(color: p.ink2, height: 1.4),
            ),
          ] else ...[
            if (running == ProbeKind.ecg)
              Container(
                key: const ValueKey('probe-cue'),
                padding: const EdgeInsets.symmetric(vertical: S.x5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: p.wash(cue?.kind == EcgCueKind.touch ? C.green : C.blue),
                  borderRadius: R.rLg,
                ),
                child: Text(
                  cue?.text ?? 'Starting the ECG stream…',
                  textAlign: TextAlign.center,
                  style: F.t1.copyWith(color: p.ink),
                ),
              ),
            if (running == ProbeKind.buzz && q == null)
              Text('Buzzing… keep the band on and count the buzzes.',
                  style: F.body.copyWith(color: p.ink)),
            if (q != null) ...[
              Text(
                'Group ${r.questionIndex + 1} of ${r.trialCount}: '
                '${q.commands} buzzes sent ${q.spacingMs} ms apart. '
                'How many bzz-bzz did you feel? (One buzz command is one '
                'bzz-bzz.)',
                style: F.body.copyWith(color: p.ink),
              ),
              const SizedBox(height: S.x2),
              Row(children: [
                for (var n = 0; n <= q.commands; n++) ...[
                  Expanded(
                    child: BigButton(
                      '$n',
                      key: ValueKey('probe-felt-$n'),
                      soft: true,
                      color: C.blue,
                      onTap: () => r.answer(n),
                    ),
                  ),
                  const SizedBox(width: S.x2),
                ],
                Expanded(
                  flex: 2,
                  child: BigButton(
                    'Not sure',
                    key: const ValueKey('probe-felt-skip'),
                    soft: true,
                    color: C.blue,
                    onTap: () => r.answer(null),
                  ),
                ),
              ]),
            ],
            const SizedBox(height: S.x3),
            BigButton(
              'Stop',
              key: const ValueKey('probe-stop'),
              icon: LucideIcons.square,
              soft: true,
              color: C.red,
              onTap: r.stop,
            ),
          ],
          if (note != null) ...[
            const SizedBox(height: S.x2),
            Text(note, style: F.cap.copyWith(color: p.ink2)),
          ],
        ],
      ),
    );
  }
}
