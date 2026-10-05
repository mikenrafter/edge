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
// and this screen's counter takes over (GestureDispatcher). "Save lab log file"
// at the bottom saves everything on this screen as a plain text file through
// the share sheet, plus the kept ECG packets (raw, for replay off the band).
// Never the clipboard: a big pasted log locked up a second device.
//
// Hardware probes: a buzz-spacing probe and a cued ECG touch probe, each
// started only here, bounded and stoppable ([HardwareProbePanel]).
//
// Laid out as sub-tabs like Haptics and Gestures, each tab a set of
// accordions: Taps (the tap tools, behind FeatureFlag.tapClassifiers), Probes,
// Live (the live streams of each connected device) and Logs (sessions, steps,
// band events, and the save button). The tab used last is remembered
// ([kDeviceLabTabPref]); a tab with nothing to show is not offered. A future
// Motion tab (the gyroscope recorder) is one more [LabTab] value, one more
// content argument of [DeviceLabView] and one more case in its rows.

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
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../state/prefs.dart';
import '../../util/log_file.dart';
import '../activity/share.dart' show shareOrigin;
import '../ui2.dart';
import 'live_devices.dart' show LiveDevices;
import 'pattern_probe_page.dart';
import 'profile.dart';

export '../../gestures/lab_log.dart' show DeviceLabEntry, labClock;

/// The note said on this screen and on Gestures (developer mode): what
/// extended gestures need, and where to see every step of them. Never names a
/// single tap.
const String kExtendedGesturesNote =
    'ECG on double tap and counting touches on the ECG sensor need a WHOOP MG. '
    'WHOOP 4.0 has no ECG sensor, so it counts extra double taps instead. '
    'The Device lab, in Settings under Developer mode, logs every step with '
    'its timing.';

/// Where the tab last used is kept (a [LabTab] id), in the app prefs with the
/// other UI selections.
const String kDeviceLabTabPref = 'ui.device_lab_tab';

/// The lab's sub-tabs, in order. [id] is what is remembered and what a caller
/// passes to open one; never the label.
enum LabTab {
  taps('taps', 'Taps'),
  probes('probes', 'Probes'),
  live('live', 'Live'),
  logs('logs', 'Logs');

  const LabTab(this.id, this.label);
  final String id;
  final String label;
}

class DeviceLab extends StatelessWidget {
  const DeviceLab({super.key});

  @override
  Widget build(BuildContext c) =>
      LabSession(runner: c.read<AppState>().hardwareProbes, child: _labBody(c));

  Widget _labBody(BuildContext c) {
    final app = c.read<AppState>();
    final caps = c.caps;
    final g = app.gestureSettings;
    // The text "Save lab log file" saves, read when asked: the lab's own button
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
        ecgSupported: caps.has(Feature.ecgTouchTaps),
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
        // The lab is now reached from Settings > Developer, so the entry no
        // longer carries the flag: the tap tools inside do.
        tapTools: caps.has(Feature.deviceLabTapTools),
        probes: HardwareProbePanel(runner: app.hardwareProbes, logText: logText),
        live: const LiveDevices(embedded: true),
      ),
    );
  }
}

/// Marks the Device lab as open for as long as it is on screen: the band queue
/// holds real alerts while it is, and lets them go when it closes.
class LabSession extends StatefulWidget {
  const LabSession({super.key, required this.runner, required this.child});
  final HardwareProbeRunner runner;
  final Widget child;

  @override
  State<LabSession> createState() => _LabSessionState();
}

class _LabSessionState extends State<LabSession> {
  // Kept so dispose does not need the widget (or a context).
  late final HardwareProbeRunner _runner = widget.runner;

  @override
  void initState() {
    super.initState();
    _runner.openLab();
  }

  @override
  void dispose() {
    _runner.closeLab();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
    this.saveLog,
    this.tapTools = true,
    this.live,
    this.initialTab,
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

  /// Kept ECG packets, oldest first; saved with the log.
  final List<LabPacket> packets;

  /// The hardware probes section, when the screen has a runner for it.
  final Widget? probes;

  /// What "Save lab log file" saves; built from the fields above when not
  /// given.
  final String Function()? logText;

  /// How the log is saved; null is [saveLogFile] (the platform share sheet).
  final LogFileSaver? saveLog;

  /// FeatureFlag.tapClassifiers. False hides the ECG, touch-window and
  /// repeated-double-tap tools, which the dispatcher ignores while the flag is
  /// off; the probes and the logs stay.
  final bool tapTools;

  /// The Live tab's content (the live devices, without a screen of their
  /// own); the tab is offered only when it is given.
  final Widget? live;

  /// Opens this tab over the remembered one, when it is offered.
  final LabTab? initialTab;

  /// The tabs this lab offers: one with nothing to show is left out.
  List<LabTab> get _tabs => [
    if (tapTools) LabTab.taps,
    if (probes != null) LabTab.probes,
    if (live != null) LabTab.live,
    LabTab.logs,
  ];

  Future<void> _save(BuildContext c) async {
    // Both read the tree, so both are read before the await.
    final messenger = ScaffoldMessenger.of(c);
    final origin = shareOrigin(c);
    final save = saveLog ?? (n, t) => saveLogFile(n, t, origin: origin);
    var ok = false;
    try {
      ok = await save(
        logFileName('device-lab', DateTime.now()),
        logText?.call() ??
            labLogText(
                entries: entries,
                steps: steps,
                sessions: sessions,
                packets: packets),
      );
    } catch (_) {}
    if (!c.mounted) return;
    // Lifted clear of the pinned button, so a retry is not blocked by it; a
    // retry replaces the last message instead of queueing behind it.
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, 88),
      content: Text(ok ? 'Log file saved' : 'Could not save the log file.'),
    ));
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final tabs = _tabs;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: _TabHost(
          tabs: tabs,
          initial: initialTab,
          builder: (c, tab, select) => Column(children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar('Device lab'),
            ),
            // One tab left (the logs) needs no row to choose between.
            if (tabs.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(S.x4, S.x1, S.x4, 0),
                child: SubTabs(
                  [for (final t in tabs) t.label],
                  tabs.indexOf(tab),
                  (i) => select(tabs[i]),
                  color: C.blue,
                  dense: true,
                  itemKeys: [
                    for (final t in tabs) ValueKey('device-lab-tab:${t.id}'),
                  ],
                  semanticLabels: [
                    for (final t in tabs) '${t.label}, Device lab',
                  ],
                ),
              ),
            Expanded(
              child: ListView(
                // A tab starts at its top, not where the last one was left.
                key: ValueKey('device-lab-tab-body:${tab.id}'),
                padding: EdgeInsets.fromLTRB(
                    S.x4, 0, S.x4, tab == LabTab.logs ? S.x4 : S.x10),
                children: _rows(c, p, tab),
              ),
            ),
            // Pinned to the bottom of the logs, so it is one tap away however
            // long they are.
            if (tab == LabTab.logs)
              Padding(
                padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x3),
                child: BigButton(
                  'Save lab log file',
                  key: const ValueKey('lab-copy-all'),
                  icon: LucideIcons.download,
                  soft: true,
                  color: C.blue,
                  onTap: () => _save(c),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  List<Widget> _rows(BuildContext c, P p, LabTab tab) => switch (tab) {
    LabTab.taps => [
      Padding(
        padding: const EdgeInsets.only(top: S.x3),
        child: Surface(
          child: Text(kExtendedGesturesNote,
              style: F.body.copyWith(color: p.ink2, height: 1.4)),
        ),
      ),
      SettingsAccordion('ECG on double tap',
          id: 'device_lab_ecg_double_tap',
          children: [
            SwitchRow(
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
          ]),
      SettingsAccordion('Touch windows',
          id: 'device_lab_touch_windows',
          children: [
            EcgThresholdAdjusters(
              thresholds: thresholds ?? EcgTapThresholds(),
              onChanged: ecgSupported ? onThresholds : null,
            ),
          ]),
      SettingsAccordion('Repeated double taps',
          id: 'device_lab_repeated_taps',
          children: [
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
                windowMs:
                    repeatWindowMs ?? GestureSettings.defaultRepeatWindowMs,
                onChanged: onRepeatWindowMs,
              ),
          ]),
    ],
    // The panel is the accordion: folding it must not stop a running probe.
    LabTab.probes => [
      Padding(padding: const EdgeInsets.only(top: S.x3), child: probes!),
    ],
    LabTab.live => [
      Padding(padding: const EdgeInsets.only(top: S.x3), child: live!),
    ],
    LabTab.logs => [
      if (sessions.isNotEmpty)
        SettingsAccordion('Sessions',
            id: 'device_lab_sessions',
            summary: _count(sessions.length, 'session'),
            children: [_lines(p, sessions, p.ink)]),
      if (steps.isNotEmpty)
        SettingsAccordion('Step by step',
            id: 'device_lab_steps',
            summary: _count(steps.length, 'step'),
            children: [_lines(p, steps, p.ink2)]),
      SettingsAccordion('Band events',
          id: 'device_lab_band_events',
          summary: entries.isEmpty ? null : _count(entries.length, 'event'),
          children: [
            entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: S.x3),
                    child: Text('No band events yet.',
                        style: F.body.copyWith(color: p.ink3)),
                  )
                : Column(children: [
                    for (var i = 0; i < entries.length; i++) ...[
                      if (i > 0) Divider(color: p.line, height: 1),
                      _EntryRow(entries[i]),
                    ],
                  ]),
          ]),
    ],
  };

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  /// The log lines as one block, so the accordion draws no hairline between
  /// them.
  static Widget _lines(P p, List<String> lines, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x1),
                child: Text(s, style: F.cap.copyWith(color: color)),
              ),
          ],
        ),
      );
}

/// Holds the selected tab: the one asked for, else the one used last (kept in
/// the app prefs, read from the start-up cache so the first frame is already
/// on it), else the first offered. A remembered tab that is not offered now
/// shows the first, and the memory is left alone.
class _TabHost extends StatefulWidget {
  const _TabHost({
    required this.tabs,
    required this.initial,
    required this.builder,
  });

  final List<LabTab> tabs;
  final LabTab? initial;
  final Widget Function(
    BuildContext context,
    LabTab tab,
    ValueChanged<LabTab> select,
  )
  builder;

  @override
  State<_TabHost> createState() => _TabHostState();
}

class _TabHostState extends State<_TabHost> {
  late LabTab? _tab = widget.initial ?? _remembered();

  static LabTab? _remembered() {
    final id = Prefs.getString(kDeviceLabTabPref, '');
    for (final t in LabTab.values) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _select(LabTab t) {
    if (t == _tab) return;
    setState(() => _tab = t);
    // A UI selection: a write that did not land only costs the memory of it.
    Prefs.setString(kDeviceLabTabPref, t.id);
  }

  @override
  Widget build(BuildContext c) {
    final tab = widget.tabs.contains(_tab) ? _tab! : widget.tabs.first;
    return widget.builder(c, tab, _select);
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

/// The three touch windows, 50 ms steps within their ranges. Shared by the
/// Device lab and the Gestures screen. With [onChanged] null every button is
/// inert (no ECG sensor). [timingsOnly] leaves out the three switches under
/// the windows (the Gestures screen draws only the timings).
class EcgThresholdAdjusters extends StatelessWidget {
  const EcgThresholdAdjusters(
      {super.key,
      required this.thresholds,
      this.onChanged,
      this.timingsOnly = false});

  final EcgTapThresholds thresholds;
  final ValueChanged<EcgTapThresholds>? onChanged;
  final bool timingsOnly;

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
      if (!timingsOnly) ...[
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
      ],
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


/// The Device lab's hardware probes. Reads [HardwareProbeRunner]; the
/// phone vibrates on every ECG cue so the wearer can watch the band, not the
/// screen. Leaving the screen, or the Probes tab, stops a running probe.
class HardwareProbePanel extends StatefulWidget {
  const HardwareProbePanel({
    super.key,
    required this.runner,
    required this.logText,
    this.saveLog,
  });
  final HardwareProbeRunner runner;

  /// The text of the lab's "Save lab log file", for the pattern probe's end
  /// screen.
  final String Function() logText;

  /// Forwarded to the pattern probe page; null is [saveLogFile].
  final LogFileSaver? saveLog;

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
      PatternProbePage(
        runner: r,
        logText: widget.logText,
        saveLog: widget.saveLog,
      ),
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
    // The idle part (what the probes are, and the buttons) folds. A running
    // probe's cue, question and Stop sit outside it, so folding the section
    // can never hide the control that ends the probe.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsAccordion('Hardware probes',
            id: 'device_lab_probes',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Measure what the band can do. The buzz probe sends up to '
                      '${HapticProbe.maxCommands} short buzzes in groups of '
                      'three, with a rest after each group, and asks how many '
                      'you felt. The ECG probe streams for at most '
                      '${EcgTouchProbe.maxStream.inSeconds} s and tells you '
                      'when to touch and lift the sensor (the phone vibrates '
                      'on each cue). Stop ends either at once. Results go into '
                      'the log, on the Logs tab.',
                      style: F.cap.copyWith(color: p.ink2, height: 1.4),
                    ),
                    if (running == null) ...[
                      const SizedBox(height: S.x3),
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
                        'MG only. Opens a screen where you play custom buzz '
                        'patterns and tap out what you felt as buzz and gap '
                        'lengths, at most ${PatternProbe.maxCommandsPerWindow} '
                        'commands in any 2 minutes. Leaving the screen ends '
                        'it.',
                        style: F.cap.copyWith(color: p.ink2, height: 1.4),
                      ),
                    ],
                  ],
                ),
              ),
            ]),
        if (running != null)
          Padding(
            padding: const EdgeInsets.only(top: S.x3),
            child: Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (running == ProbeKind.ecg)
                    Container(
                      key: const ValueKey('probe-cue'),
                      padding: const EdgeInsets.symmetric(vertical: S.x5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: p.wash(
                            cue?.kind == EcgCueKind.touch ? C.green : C.blue),
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
              ),
            ),
          ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: S.x2),
            child: Text(note, style: F.cap.copyWith(color: p.ink2)),
          ),
      ],
    );
  }
}
