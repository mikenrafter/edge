// bedtime_screen.dart — the developer-only screen for "Bedtime breathing cues".
//
// Bedtime breathing cues, with an optional stop when the band estimates sleep.
// Evidence: Tsai et al. 2015, doi:10.1111/psyp.12333.
//
// The screen says what it knows and no more: the sleep stop often will not
// trigger (the band needs about 20 minutes of data), a missing estimate reads
// "unavailable" and never "awake", and no minutes-to-sleep figure is shown. It
// drives the session's ticks itself, holds the display awake while it runs, and
// ends the session when the app is paused: the cues are paced by this
// foreground timer, so they cannot continue in the background.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../gps/screen_wake.dart';
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../state/prefs.dart';
import '../../ui2/ui2.dart';
import '../../stress/breath_phases.dart' show BreathPhaseKindLabel;
import 'bedtime_pacing_policy.dart';
import 'bedtime_session_controller.dart';

const String _title = 'Bedtime breathing cues';
const String _subtitle =
    'Bedtime breathing cues, with an optional stop when the band estimates sleep.';
const String _stopHelper =
    'The band needs about 20 minutes of data before it can estimate sleep, so this often won\'t trigger';
const String _keepOpen = 'Keep the app open; leaving it ends the session.';

/// The screen-wake owner name (see lib/gps/screen_wake.dart).
const String _wakeOwner = 'bedtime';

/// How often the screen asks the session to step. A phase lasts seconds, so
/// this only bounds how late a cue can be.
const Duration _tickEvery = Duration(milliseconds: 500);

/// How much a taper slows down by, in breaths per minute.
const double _taperStepBpm = 1.0;

const _reasonText = {
  BedtimeStopReason.durationCap: 'Stopped: the time limit was reached',
  BedtimeStopReason.sleepEstimated: 'Stopped: the band estimated sleep',
  BedtimeStopReason.userStopped: 'Stopped: you stopped the session',
  BedtimeStopReason.deliveryFailing:
      'Stopped: the band was not receiving the cues',
  BedtimeStopReason.disconnected: 'Stopped: the band disconnected',
};

String _bpm(double v) =>
    v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

class BedtimeScreen extends StatefulWidget {
  const BedtimeScreen({super.key, required this.controller});
  final BedtimeSessionController controller;

  @override
  State<BedtimeScreen> createState() => _BedtimeScreenState();
}

class _BedtimeScreenState extends State<BedtimeScreen>
    with WidgetsBindingObserver {
  Timer? _timer;

  BedtimeSessionController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c.addListener(_onChange);
  }

  @override
  void didUpdateWidget(BedtimeScreen old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_onChange);
    _release();
    // Leaving the screen ends a running session (stop is idempotent).
    unawaited(_c.stop());
    super.dispose();
  }

  /// Foreground pacing cannot continue in the background: end the session.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(_c.stop());
  }

  void _onChange() {
    if (_c.state == BedtimeState.ended) _release();
    if (mounted) setState(() {});
  }

  /// Stops the tick timer and lets the display sleep again. Idempotent; it runs
  /// on every way out (ended, stopped, screen disposed).
  void _release() {
    _timer?.cancel();
    _timer = null;
    unawaited(ScreenWake.releaseOwner(_wakeOwner));
  }

  Future<void> _begin() async {
    unawaited(ScreenWake.hold(_wakeOwner));
    await _c.start();
    if (!mounted) return;
    if (_c.state != BedtimeState.running) {
      _release();
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(_tickEvery, (_) => unawaited(_c.tick()));
  }

  void _setPlan({double? start, double? end, Duration? duration, bool? stop}) {
    final p = _c.plan;
    final s = start ?? p.startBpm;
    _c.setPlan(BedtimePlan(
      startBpm: s,
      endBpm: end ?? (start != null ? s : p.endBpm),
      duration: duration ?? p.duration,
      stopOnSleep: stop ?? p.stopOnSleep,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(_title),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Text(_subtitle, style: F.body.copyWith(color: p.ink2)),
                const SizedBox(height: S.x4),
                switch (_c.state) {
                  BedtimeState.idle => _setup(context, p),
                  BedtimeState.running => _running(context, p),
                  BedtimeState.ended => _ended(context, p),
                },
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _setup(BuildContext c, P p) {
    final plan = _c.plan;
    final taper = plan.endBpm < plan.startBpm;
    final minutes = plan.duration.inMinutes;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Section(
        'Pace',
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SubTabs(const ['Fixed pace', 'Taper'], taper ? 1 : 0, (i) {
            if (i == 1) {
              final start = plan.startBpm;
              _setPlan(
                  end: (start - _taperStepBpm)
                      .clamp(kBedtimeMinBpm, start)
                      .toDouble());
            } else {
              _setPlan(end: plan.startBpm);
            }
          }),
          const SizedBox(height: S.x2),
          Text(
            taper
                ? 'Starts at ${_bpm(plan.startBpm)} breaths a minute and slows '
                    'to ${_bpm(plan.endBpm)} over the session.'
                : '${_bpm(plan.startBpm)} breaths a minute throughout.',
            style: F.cap.copyWith(color: p.ink3),
          ),
        ]),
      ),
      Section(
        'Duration',
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$minutes min', style: F.body.copyWith(color: p.ink)),
          Slider(
            min: kBedtimeMinDuration.inMinutes.toDouble(),
            max: kBedtimeMaxDuration.inMinutes.toDouble(),
            divisions:
                kBedtimeMaxDuration.inMinutes - kBedtimeMinDuration.inMinutes,
            value: minutes.toDouble(),
            onChanged: (v) => _setPlan(duration: Duration(minutes: v.round())),
          ),
        ]),
      ),
      Section(
        'Automatic stop',
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('Stop when the band estimates sleep',
                  style: F.body.copyWith(color: p.ink)),
            ),
            Switch(
              value: plan.stopOnSleep,
              onChanged: (v) => _setPlan(stop: v),
            ),
          ]),
          Text(_stopHelper, style: F.cap.copyWith(color: p.ink3)),
        ]),
      ),
      const SizedBox(height: S.x4),
      Text(_keepOpen, style: F.cap.copyWith(color: p.ink3)),
      const SizedBox(height: S.x3),
      BigButton('Start', icon: LucideIcons.play, onTap: _begin),
    ]);
  }

  Widget _running(BuildContext c, P p) {
    final phase = _c.phase;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x8),
        child: Text(
          phase?.label ?? 'Starting',
          textAlign: TextAlign.center,
          style: F.t1.copyWith(color: p.ink),
        ),
      ),
      if (_c.plan.stopOnSleep)
        Text('Sleep estimate: ${_c.sleepEstimate}',
            textAlign: TextAlign.center,
            style: F.body.copyWith(color: p.ink2)),
      if (_c.cuesMissed > 0)
        Text('Cues the band did not receive: ${_c.cuesMissed}',
            textAlign: TextAlign.center, style: F.cap.copyWith(color: p.ink3)),
      const SizedBox(height: S.x4),
      Text(_keepOpen,
          textAlign: TextAlign.center, style: F.cap.copyWith(color: p.ink3)),
      const SizedBox(height: S.x3),
      BigButton('Stop',
          icon: LucideIcons.square,
          color: C.red,
          soft: true,
          onTap: () => unawaited(_c.stop())),
    ]);
  }

  Widget _ended(BuildContext c, P p) {
    final why = _c.stopReason;
    return Surface(
      child: Text(why == null ? 'Stopped' : _reasonText[why]!,
          style: F.head.copyWith(color: p.ink)),
    );
  }
}

/// The door to the screen. Present only with Feature.developerMode AND
/// Prefs.exploreBedtime (default off); otherwise it builds nothing.
class BedtimeEntry extends StatelessWidget {
  const BedtimeEntry({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    if (!context.caps.has(Feature.developerMode) ||
        !Prefs.getBool(Prefs.exploreBedtime, false)) {
      return const SizedBox.shrink();
    }
    final p = P.of(context);
    // The gap above is part of the entry, so a hidden entry leaves none.
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Surface(
        onTap: onOpen,
        semanticLabel: _title,
        child: Row(children: [
          Icon(LucideIcons.wind, size: 20, color: p.ink2),
          const SizedBox(width: S.x3),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_title, style: F.body.copyWith(color: p.ink)),
              Text('Paced cues on the band at bedtime',
                  style: F.over.copyWith(color: p.ink3)),
            ]),
          ),
          Icon(LucideIcons.chevronRight, size: 18, color: p.ink3),
        ]),
      ),
    );
  }
}
