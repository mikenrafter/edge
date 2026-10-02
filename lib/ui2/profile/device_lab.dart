// Device lab — a bench for the gestures the firmware does not report.
//
// The band sends a double tap and nothing else. Anything beyond it (ECG on a
// double tap, 3–5 taps counted as touches of the ECG sensor) is exploration, so
// this screen shows the evidence instead of hiding it: every band event with
// the band's own time, the phone's receipt time, the delay between them and
// whether it was live or late, plus the touch counter's steps.
//
// ECG needs a WHOOP MG. On any other band the switch is shown, disabled, with
// the reason. While the switch is on, normal double-tap actions are suspended
// and this screen's counter takes over (GestureDispatcher).

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../gestures/ecg_tap_counter.dart';
import '../../gestures/lab_log.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'profile.dart';

export '../../gestures/lab_log.dart' show DeviceLabEntry, labClock;

/// The 8I note, said on this screen and on Gestures: what extended gestures
/// need, and that 3–5 taps are a draft to try here first. Never names a
/// single tap.
const String kExtendedGesturesNote =
    'ECG on double tap and the 3–5 tap rows need a WHOOP MG. '
    'WHOOP 4.0 has no ECG sensor. '
    'The 3–5 tap rows are a draft. Try them here first: every step is '
    'logged with its timing.';

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
        entries: app.deviceLab.entries,
        steps: app.deviceLab.steps,
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
    this.entries = const [],
    this.steps = const [],
    this.thresholds,
    this.onThresholds,
  });

  final bool ecgSupported;
  final bool ecgOnDoubleTap;
  final ValueChanged<bool>? onEcgOnDoubleTap;

  /// Newest first.
  final List<DeviceLabEntry> entries;

  /// The touch counter's steps, newest first, already timestamped.
  final List<String> steps;

  final EcgTapThresholds? thresholds;
  final ValueChanged<EcgTapThresholds>? onThresholds;

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
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Surface(
                  child: Text(kExtendedGesturesNote,
                      style: F.body.copyWith(color: p.ink2, height: 1.4)),
                ),
                Section(
                  'ECG on double tap',
                  Surface(
                    pad: const EdgeInsets.symmetric(horizontal: S.x4),
                    child: Opacity(
                      opacity: ecgSupported ? 1 : .45,
                      child: SwitchRow(
                        'Toggle ECG recording on double tap',
                        ecgOnDoubleTap && ecgSupported,
                        ecgSupported ? onEcgOnDoubleTap : null,
                        sub: ecgSupported
                            ? 'A live double tap starts an ECG recording and the '
                                'band buzzes twice. Normal double-tap actions are '
                                'paused while this is on.'
                            : 'This band has no ECG sensor',
                      ),
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
                if (steps.isNotEmpty)
                  Section(
                    'Counter steps',
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
        id: 'start',
        label: 'Start threshold',
        caption: 'How long after the buzzes the first touch can begin.',
        value: thresholds.startMs,
        range: EcgTapThresholds.startRange,
        onSet: onChanged == null
            ? null
            : (v) => onChanged!(thresholds.copyWith(startMs: v)),
      ),
      _Adjuster(
        id: 'gap',
        label: 'Gap threshold',
        caption: 'Sets both how long a touch must hold to count and how long '
            'you must let go to end it.',
        value: thresholds.gapMs,
        range: EcgTapThresholds.gapRange,
        onSet: onChanged == null
            ? null
            : (v) => onChanged!(thresholds.copyWith(gapMs: v)),
      ),
      _Adjuster(
        id: 'confirm',
        label: 'Confirmation threshold',
        caption: 'Extra time after you let go for the next touch to begin '
            'before the count is final.',
        value: thresholds.confirmMs,
        range: EcgTapThresholds.confirmRange,
        onSet: onChanged == null
            ? null
            : (v) => onChanged!(thresholds.copyWith(confirmMs: v)),
      ),
    ]);
  }
}

class _Adjuster extends StatelessWidget {
  const _Adjuster({
    required this.id,
    required this.label,
    required this.caption,
    required this.value,
    required this.range,
    required this.onSet,
  });

  final String id, label, caption;
  final int value;
  final (int, int) range;
  final ValueChanged<int>? onSet;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final set = onSet;
    const step = EcgTapThresholds.stepMs;
    final canDown = set != null && value - step >= range.$1;
    final canUp = set != null && value + step <= range.$2;
    return Opacity(
      opacity: set == null ? .45 : 1,
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
            key: ValueKey('ecg-threshold:$id:-'),
            tooltip: 'Decrease $label',
            icon: const Icon(LucideIcons.minus, size: 18),
            onPressed: canDown ? () => set(value - step) : null,
          ),
          Text('$value ms', style: F.body.copyWith(color: p.ink)),
          IconButton(
            key: ValueKey('ecg-threshold:$id:+'),
            tooltip: 'Increase $label',
            icon: const Icon(LucideIcons.plus, size: 18),
            onPressed: canUp ? () => set(value + step) : null,
          ),
        ]),
      ),
    );
  }
}
