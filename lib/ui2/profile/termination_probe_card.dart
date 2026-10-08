// termination_probe_card.dart — the Device lab's termination probe card
// (developer mode): one button per scenario, the running view with Stop, each
// scenario's timeline and verdict, and "Save report file" (the log-file path,
// never the clipboard). Leaving the screen stops the probe, which clears its
// alarm slot and restores the real alarm.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../gestures/termination_probe.dart';
import '../../util/log_file.dart';
import '../activity/share.dart' show shareOrigin;
import '../ui2.dart';
import 'profile.dart';

class TerminationProbeCard extends StatefulWidget {
  const TerminationProbeCard({super.key, required this.runner, this.saveLog});
  final TerminationProbeRunner runner;

  /// How the report is saved; null is [saveLogFile] (the platform share sheet).
  final LogFileSaver? saveLog;

  @override
  State<TerminationProbeCard> createState() => _TerminationProbeCardState();
}

class _TerminationProbeCardState extends State<TerminationProbeCard> {
  // Kept so dispose does not need the widget (or a context).
  late final TerminationProbeRunner _runner = widget.runner;

  /// null: not tried since the last run; true / false: the last save.
  bool? _saved;

  @override
  void initState() {
    super.initState();
    _runner.addListener(_changed);
  }

  @override
  void dispose() {
    _runner.removeListener(_changed);
    // Leaving the screen ends the probe: its run clears the probe alarm and
    // restores the real one, then finishes on its own.
    _runner.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    // Read before the await: they read the tree.
    final origin = shareOrigin(context);
    final save = widget.saveLog ?? (n, t) => saveLogFile(n, t, origin: origin);
    var ok = false;
    try {
      ok = await save(
        logFileName('termination-probe', DateTime.now()),
        _runner.reportText(),
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() => _saved = ok);
  }

  Widget _result(P p, TerminationResult r) => Padding(
        padding: const EdgeInsets.only(top: S.x3),
        child: Surface(
          key: ValueKey('term-result-${r.scenario.name}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(r.scenario.title, style: F.cap.copyWith(color: p.ink2)),
              const SizedBox(height: S.x1),
              Text(r.verdict, style: F.t1.copyWith(color: p.ink)),
              if (!r.completed)
                Padding(
                  padding: const EdgeInsets.only(top: S.x1),
                  child: Text('Not completed.',
                      style: F.cap.copyWith(color: p.ink2)),
                ),
              const SizedBox(height: S.x2),
              for (final e in r.timeline)
                Padding(
                  padding: const EdgeInsets.only(bottom: S.x1),
                  child: Text(e.line, style: F.cap.copyWith(color: p.ink2)),
                ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext c) {
    final r = _runner;
    if (!r.developerMode()) return const SizedBox.shrink();
    final p = P.of(c);
    final running = r.running;
    final results = r.results;
    final note = r.note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsAccordion('Haptics stop events (developer)',
            id: 'device_lab_termination',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Finds out how the WHOOP 5 / MG band reports that a '
                      'buzz stopped: when it ran out, when you double-tap, '
                      'and when an alarm and a pattern overlap. Each test '
                      'records every event with the strap stamp and the '
                      'phone receipt. The alarm tests arm one short test '
                      'alarm in a spare slot, then clear it and put your '
                      'alarm back, and do not run within 10 minutes of '
                      'yours. Save the report as a file to share it.',
                      style: F.cap.copyWith(color: p.ink2, height: 1.4),
                    ),
                    for (final s in TerminationScenario.values)
                      _scenarioRow(p, s, running),
                  ],
                ),
              ),
            ]),
        if (running)
          Padding(
            padding: const EdgeInsets.only(top: S.x3),
            child: Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(r.status ?? 'Working…',
                      key: const ValueKey('term-status'),
                      style: F.body.copyWith(color: p.ink)),
                  const SizedBox(height: S.x3),
                  BigButton(
                    'Stop and clean up',
                    key: const ValueKey('term-stop'),
                    icon: LucideIcons.square,
                    soft: true,
                    color: C.red,
                    onTap: r.cancel,
                  ),
                ],
              ),
            ),
          ),
        for (final res in results) _result(p, res),
        if (results.isNotEmpty && !running)
          Padding(
            padding: const EdgeInsets.only(top: S.x3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigButton(
                  'Save report file',
                  key: const ValueKey('term-save'),
                  icon: LucideIcons.fileDown,
                  soft: true,
                  color: C.blue,
                  onTap: _save,
                ),
                if (_saved != null)
                  Padding(
                    padding: const EdgeInsets.only(top: S.x1),
                    child: Text(
                        _saved! ? 'Report file saved' : 'Could not save the log file.',
                        style: F.cap.copyWith(color: p.ink2)),
                  ),
              ],
            ),
          ),
        if (note != null && !running)
          Padding(
            padding: const EdgeInsets.only(top: S.x2),
            child: Text(note, style: F.cap.copyWith(color: p.ink2)),
          ),
      ],
    );
  }

  Widget _scenarioRow(P p, TerminationScenario s, bool running) {
    final reason = running ? null : _runner.blockedReason(s);
    final enabled = !running && reason == null;
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BigButton(
            s.title,
            key: ValueKey('term-run-${s.name}'),
            icon: s.usesAlarm ? LucideIcons.alarmClock : LucideIcons.vibrate,
            soft: true,
            color: C.blue,
            onTap: enabled
                ? () {
                    setState(() => _saved = null);
                    unawaited(_runner.run(s));
                  }
                : null,
          ),
          Padding(
            padding: const EdgeInsets.only(top: S.x1),
            child: Text(s.instruction,
                style: F.cap.copyWith(color: p.ink2, height: 1.4)),
          ),
          if (reason != null)
            Padding(
              padding: const EdgeInsets.only(top: S.x1),
              child: Text(reason,
                  key: ValueKey('term-reason-${s.name}'),
                  style: F.cap.copyWith(color: p.ink2, height: 1.4)),
            ),
        ],
      ),
    );
  }
}
