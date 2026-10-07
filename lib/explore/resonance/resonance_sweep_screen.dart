// The developer-only "Pacing rates compared" screen and its Device lab entry.
//
// Wording rule: this compares rates and may name a tentative practice rate.
// It never says "resonance frequency" and makes no health claim.
//
// Evidence:
//   Lehrer, Vaschillo & Vaschillo 2000, doi 10.1023/A:1009554825745
//   Shaffer & Meehan 2020, doi 10.3389/fnins.2020.570400
//
// The screen owns the controller it is given: it ticks it while it runs,
// stops it when the app is backgrounded (a ticker is muted there, so the
// pacing would silently stop while the clock ran on) and disposes it, which
// releases the live streams.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../gps/screen_wake.dart';
import '../../state/app_state.dart';
import '../../state/capabilities.dart';
import '../../state/capabilities_scope.dart';
import '../../state/prefs.dart';
import '../../stress/breath_phases.dart' show BreathPhaseKindLabel;
import '../../ui2/profile/profile.dart' show SetRow;
import '../../ui2/screens/calm_breathing.dart' show BreathCircle, breathScale;
import '../../ui2/ui2.dart';
import 'resonance_analyzer.dart';
import 'resonance_history.dart';
import 'resonance_sweep_controller.dart';

const String _stopText = 'Stop if you feel dizzy or short of breath';
const String _wakeOwner = 'resonance_sweep';

// DOIs checked against Crossref (first author, title, year) on 2026-10-07.
const String _doiLehrer = '10.1023/A:1009554825745';
const String _doiShaffer = '10.3389/fnins.2020.570400';

class ResonanceSweepScreen extends StatefulWidget {
  const ResonanceSweepScreen({
    super.key,
    required this.controller,
    required this.history,
  });

  final ResonanceSweepController controller;
  final ResonanceHistoryStore history;

  @override
  State<ResonanceSweepScreen> createState() => _ResonanceSweepScreenState();
}

class _ResonanceSweepScreenState extends State<ResonanceSweepScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker((_) => widget.controller.tick());
  bool _recorded = false;
  bool _wakeHeld = false;
  double? _suggestion;
  double? _savedRate;
  double? _pick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onChange);
    _reconcile();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onChange);
    _ticker.dispose();
    _releaseWake();
    widget.controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused &&
        widget.controller.state == SweepState.running) {
      unawaited(widget.controller.stop());
    }
  }

  void _onChange() {
    _reconcile();
    if (mounted) setState(() {});
  }

  // Ticker, screen hold and the one-time history write follow the controller.
  void _reconcile() {
    final c = widget.controller;
    final running = c.state == SweepState.running;
    if (running && !_ticker.isActive) {
      _ticker.start();
      _wakeHeld = true;
      unawaited(ScreenWake.hold(_wakeOwner));
    } else if (!running && _ticker.isActive) {
      _ticker.stop();
    }
    if (!running) _releaseWake();
    final result = c.result;
    if (!_recorded &&
        result != null &&
        (c.state == SweepState.finished || c.state == SweepState.stopped)) {
      _recorded = true;
      unawaited(_record(result));
    }
  }

  void _releaseWake() {
    if (!_wakeHeld) return;
    _wakeHeld = false;
    unawaited(ScreenWake.releaseOwner(_wakeOwner));
  }

  Future<void> _record(SweepComparison r) async {
    try {
      await widget.history.add(SweepSessionRecord(
        at: DateTime.now(),
        outcome: r.outcome,
        rateBpm: r.rateBpm,
        range: r.range,
        blocks: r.blocks,
      ));
      final all = await widget.history.load();
      final saved = await widget.history.preferredRate();
      if (!mounted) return;
      setState(() {
        _suggestion = suggestedPracticeRate(all);
        _savedRate = saved;
      });
    } catch (_) {
      // History is a convenience; the result on screen does not depend on it.
    }
  }

  Future<void> _savePick() async {
    final rate = _pick;
    if (rate == null) return;
    try {
      await widget.history.setPreferredRate(rate);
      if (!mounted) return;
      setState(() => _savedRate = rate);
    } catch (_) {
      // Left as it was; the saved line only ever shows what was stored.
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ctl = widget.controller;
    final running = ctl.state == SweepState.running;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar('Pacing rates compared'),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(S.x4),
              child: switch (ctl.state) {
                SweepState.idle => _intro(c),
                SweepState.running => _running(c),
                SweepState.failed => _failed(c),
                SweepState.finished || SweepState.stopped => _result(c),
              },
            ),
          ),
          // Pinned outside the scroll area: always reachable.
          Padding(
            padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
            child: BigButton(
              _stopText,
              key: const ValueKey('sweep-stop'),
              icon: LucideIcons.square,
              soft: true,
              color: C.red,
              onTap: running ? () => unawaited(ctl.stop()) : null,
            ),
          ),
        ]),
      ),
    );
  }

  // ── before start ──────────────────────────────────────────────────────────

  Widget _intro(BuildContext c) {
    final p = P.of(c);
    final plan = widget.controller.plan;
    final minutes = (plan.total.inSeconds / 60).round();
    final rates = [for (final b in plan.blocks) b.rateBpm.toStringAsFixed(1)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Breathe gently at each pace. No deep or forced breaths.',
            style: F.t2.copyWith(color: p.ink)),
        const SizedBox(height: S.x3),
        Text(
          'You will breathe along to ${rates.length} paces one after another '
          '(${rates.join(', ')} breaths per minute), about $minutes minutes '
          'in all. The first part of each pace is for settling in; only the '
          'rest is measured. Afterwards you see how much your heart rate '
          'rose and fell with each breath at each pace.',
          style: F.cap.copyWith(color: p.ink2, height: 1.5),
        ),
        const SizedBox(height: S.x3),
        Text(
          'Experimental. Sit still and keep your band on. The band buzzes to '
          'mark each breath in and out.',
          style: F.cap.copyWith(color: p.ink2, height: 1.5),
        ),
        const SizedBox(height: S.x6),
        BigButton(
          'Start',
          key: const ValueKey('sweep-start'),
          icon: LucideIcons.wind,
          onTap: () => unawaited(widget.controller.start()),
        ),
      ],
    );
  }

  // ── while running ─────────────────────────────────────────────────────────

  Widget _running(BuildContext c) {
    final p = P.of(c);
    final ctl = widget.controller;
    final plan = ctl.plan;
    final block = ctl.currentBlock;
    final at = block == null ? null : plan.phaseAt(ctl.elapsed);
    if (block == null || at == null) {
      return Padding(
        padding: const EdgeInsets.only(top: S.x8),
        child: Text('Scoring your breaths…',
            textAlign: TextAlign.center, style: F.t2.copyWith(color: p.ink)),
      );
    }
    final index = plan.blocks.indexOf(block);
    final measuring = plan.inMeasureWindow(ctl.elapsed);
    final left = block.end - ctl.elapsed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: S.x4),
        BreathCircle(
          t: breathScale(at.phase.kind, at.progress),
          label: at.phase.kind.label,
        ),
        const SizedBox(height: S.x4),
        Text('${block.rateBpm.toStringAsFixed(1)} breaths/min',
            key: const ValueKey('sweep-rate'),
            style: F.t1.copyWith(color: p.ink)),
        const SizedBox(height: S.x1),
        Text('Rate ${index + 1} of ${plan.blocks.length}',
            key: const ValueKey('sweep-progress'),
            style: F.body.copyWith(color: p.ink2)),
        const SizedBox(height: S.x3),
        Pill(measuring ? 'Measuring' : 'Settling',
            measuring ? C.green : C.blue),
        const SizedBox(height: S.x2),
        Text(
          measuring
              ? 'Keep breathing gently with the ring.'
              : 'Settling in. Nothing is measured yet.',
          textAlign: TextAlign.center,
          style: F.cap.copyWith(color: p.ink2),
        ),
        const SizedBox(height: S.x1),
        Text('${_clock(left)} left at this pace',
            style: F.cap.copyWith(color: p.ink3)),
      ],
    );
  }

  // ── failed ────────────────────────────────────────────────────────────────

  Widget _failed(BuildContext c) {
    final p = P.of(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: S.x6),
        Text(widget.controller.error ?? 'The session could not run.',
            style: F.t2.copyWith(color: p.ink)),
        const SizedBox(height: S.x3),
        Text('Nothing was measured. Close this screen and open it again to '
            'retry.',
            style: F.cap.copyWith(color: p.ink2, height: 1.5)),
      ],
    );
  }

  // ── result ────────────────────────────────────────────────────────────────

  Widget _result(BuildContext c) {
    final p = P.of(c);
    final ctl = widget.controller;
    final r = ctl.result;
    if (r == null) {
      return Text('No result.', style: F.t2.copyWith(color: p.ink));
    }
    final (headline, detail) = _outcomeText(r);
    final suggestion = _suggestion;
    final tested = ctl.plan.testedRates;
    final selected = _pick == null ? -1 : tested.indexOf(_pick!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(headline,
            key: const ValueKey('sweep-outcome'),
            style: F.t1.copyWith(color: p.ink)),
        const SizedBox(height: S.x1),
        Text(detail, style: F.cap.copyWith(color: p.ink2, height: 1.5)),
        if (suggestion != null) ...[
          const SizedBox(height: S.x3),
          Text(
            'Suggested from your last two sessions, which agree: about '
            '${suggestion.toStringAsFixed(1)} breaths/min.',
            key: const ValueKey('sweep-suggestion'),
            style: F.body.copyWith(color: p.ink),
          ),
        ],
        const SizedBox(height: S.x5),
        Text('Heart rate swing per breath, in bpm',
            style: F.cap.copyWith(color: p.ink2)),
        const SizedBox(height: S.x2),
        Surface(
          child: Column(children: [
            for (final row in _rows(r, ctl))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x1),
                child: Row(children: [
                  SizedBox(
                    width: 84,
                    child: Text('${row.rate.toStringAsFixed(1)}/min',
                        style: F.body.copyWith(color: p.ink)),
                  ),
                  Expanded(
                    child: Text(row.text,
                        textAlign: TextAlign.right,
                        style: F.body.copyWith(
                            color: row.measured ? p.ink : p.ink3)),
                  ),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: S.x5),
        Text('My comfortable pace', style: F.head.copyWith(color: p.ink)),
        const SizedBox(height: S.x1),
        Text(
          'Your own choice, kept apart from the measurement above. Pick the '
          'pace that felt easiest.',
          style: F.cap.copyWith(color: p.ink2, height: 1.5),
        ),
        const SizedBox(height: S.x2),
        SubTabs(
          [for (final rate in tested) rate.toStringAsFixed(1)],
          selected,
          (i) => setState(() => _pick = tested[i]),
          semanticLabels: [
            for (final rate in tested)
              '${rate.toStringAsFixed(1)} breaths per minute',
          ],
        ),
        const SizedBox(height: S.x2),
        BigButton(
          'Save as my comfortable pace',
          key: const ValueKey('sweep-save-pace'),
          soft: true,
          color: C.blue,
          onTap: _pick == null ? null : () => unawaited(_savePick()),
        ),
        if (_savedRate != null)
          Padding(
            padding: const EdgeInsets.only(top: S.x1),
            child: Text('Saved pace: ${_savedRate!.toStringAsFixed(1)}/min',
                key: const ValueKey('sweep-saved'),
                style: F.cap.copyWith(color: p.ink3)),
          ),
        const SizedBox(height: S.x5),
        _evidence(c),
        const SizedBox(height: S.x2),
        Text('Movement was not checked in this prototype.',
            style: F.over.copyWith(color: p.ink3)),
        const SizedBox(height: S.x2),
      ],
    );
  }

  (String, String) _outcomeText(SweepComparison r) {
    switch (r.outcome) {
      case ComparisonOutcome.tentativeRate:
        final rate = r.rateBpm;
        if (rate == null) return _noRate;
        return (
          'Tentative practice rate ${rate.toStringAsFixed(1)} breaths/min',
          'One session is only a hint. Run it again on another day to see '
              'whether it holds.',
        );
      case ComparisonOutcome.tiedRange:
        final range = r.range;
        if (range == null) return _noRate;
        return (
          'Range ${range.lo.toStringAsFixed(1)}–'
              '${range.hi.toStringAsFixed(1)} breaths/min',
          'These paces gave about the same swing, so none stands out.',
        );
      case ComparisonOutcome.inconclusiveTooFewBlocks:
        return (
          'Inconclusive',
          'Too few paces gave a usable reading. See the reason beside each '
              'pace.',
        );
      case ComparisonOutcome.inconclusiveFlat:
        return (
          'Inconclusive',
          'Your heart rate swung by about the same amount at every pace.',
        );
      case ComparisonOutcome.inconclusiveBoundary:
        return (
          'Inconclusive',
          'The biggest swing was at the edge of the paces tried, so a better '
              'pace may lie outside them.',
        );
      case ComparisonOutcome.stoppedEarly:
        return (
          'Stopped early',
          'Only paces you finished are shown. No practice rate is given.',
        );
    }
  }

  static const (String, String) _noRate = (
    'Inconclusive',
    'No pace could be named from this session.',
  );

  // One row per pace the plan ran, in run order; a pace never reached says so.
  List<({double rate, String text, bool measured})> _rows(
    SweepComparison r,
    ResonanceSweepController ctl,
  ) {
    final out = <({double rate, String text, bool measured})>[
      for (final b in r.blocks)
        (
          rate: b.rateBpm,
          text: _blockText(b),
          measured: b.admitted,
        ),
    ];
    for (final block in ctl.plan.blocks) {
      final seen = r.blocks.any((b) => (b.rateBpm - block.rateBpm).abs() < 1e-9);
      if (!seen) {
        out.add((rate: block.rateBpm, text: 'Not reached', measured: false));
      }
    }
    return out;
  }

  // A rejected pace says why, in words. It never carries a number.
  String _blockText(BlockResult b) {
    final rejection = b.rejection;
    if (rejection != null) {
      return switch (rejection) {
        BlockRejection.lowCoverage => 'Too few beats picked up',
        BlockRejection.artifacts => 'Too many unreliable beats',
        BlockRejection.movement => 'Too much movement',
        BlockRejection.missedCues => 'Missed band buzzes',
        BlockRejection.tooFewCycles => 'Too few full breaths',
      };
    }
    final amp = b.amplitudeBpm;
    return amp == null ? 'No reading' : '${amp.toStringAsFixed(1)} bpm';
  }

  Widget _evidence(BuildContext c) {
    final p = P.of(c);
    final style = F.over.copyWith(color: p.ink3);
    final link = style.copyWith(
      color: p.on(C.blue),
      decoration: TextDecoration.underline,
    );
    Widget doi(String id) => Pressable(
          link: true,
          semanticLabel: 'doi $id',
          onTap: () => unawaited(open3rdPartyLink('https://doi.org/$id')),
          child: ExcludeSemantics(child: Text(id, style: link)),
        );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Evidence: ', style: style),
        doi(_doiLehrer),
        Text(' · ', style: style),
        doi(_doiShaffer),
      ],
    );
  }

  static String _clock(Duration d) {
    final s = d.isNegative ? 0 : d.inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// The Device lab row that opens the screen. Present only when developer mode
/// is on AND [Prefs.exploreResonance] is true. Reads nothing from AppState at
/// build time.
class ResonanceSweepEntry extends StatelessWidget {
  const ResonanceSweepEntry({super.key});

  @override
  Widget build(BuildContext context) {
    if (!context.caps.has(Feature.developerMode) ||
        !Prefs.getBool(Prefs.exploreResonance, false)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: SetRow(
        LucideIcons.wind,
        C.green,
        'Pacing rates compared',
        sub: 'Experimental. Breathe at a few paces and see which moves your '
            'heart rate most.',
        onTap: () => _open(context),
      ),
    );
  }

  // The controller is made on tap (a read, not a build-time dependency) and
  // handed to the screen, which owns and disposes it.
  void _open(BuildContext context) {
    final controller = context.read<AppState>().buildResonanceSweep();
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ResonanceSweepScreen(
        controller: controller,
        history: const ResonanceHistoryStore(),
      ),
    ));
  }
}
