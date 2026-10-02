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
// the bottom copies everything on this screen as plain text.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../gestures/ecg_tap_counter.dart';
import '../../gestures/gesture_settings.dart';
import '../../gestures/lab_log.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
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
        thresholds: g.ecgTapThresholds,
        onThresholds: g.setEcgTapThresholds,
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

  Future<void> _copy(BuildContext c) async {
    await Clipboard.setData(ClipboardData(
      text: labLogText(entries: entries, steps: steps, sessions: sessions),
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
                          ? 'A live double tap starts an ECG recording and the '
                              'band buzzes twice once the sensor is ready. '
                              'Normal double-tap actions are paused while this '
                              'is on.'
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
        caption: 'How long after the buzzes the first touch can begin.',
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
