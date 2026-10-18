// alarm_slot_probe_card.dart — the Device lab's alarm-slot probe: can the band
// hold more than one alarm at once? A developer tool: the card is not there
// with developer mode off. The probe replaces the wearer's armed alarm for a
// few minutes, so the button asks first (a sheet that says so), the card keeps
// Stop in view while it runs, and leaving the screen ends it (which restores
// the alarm).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../gestures/alarm_slot_probe.dart';
import '../ui2.dart';
import 'profile.dart';

class AlarmSlotProbeCard extends StatefulWidget {
  const AlarmSlotProbeCard({super.key, required this.runner});
  final AlarmSlotProbeRunner runner;

  @override
  State<AlarmSlotProbeCard> createState() => _AlarmSlotProbeCardState();
}

class _AlarmSlotProbeCardState extends State<AlarmSlotProbeCard> {
  @override
  void initState() {
    super.initState();
    widget.runner.addListener(_changed);
  }

  @override
  void dispose() {
    widget.runner.removeListener(_changed);
    // Leaving the screen ends the probe: its run clears the probe alarms and
    // restores the real one, then finishes on its own.
    widget.runner.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _confirmAndRun() async {
    final r = widget.runner;
    final p = P.of(context);
    final held = r.heldEpoch();
    final go = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: p.card,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          key: const ValueKey('alarm-slot-confirm'),
          padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Test more than one alarm?',
                  style: F.t1.copyWith(color: p.ink)),
              const SizedBox(height: S.x2),
              Text(
                'This will replace your armed alarm for a few minutes. The '
                'probe arms two short, gentle test alarms, A in 2 minutes '
                'and B in 3, so the band buzzes up to twice. When it ends, '
                'or the moment you tap Stop or leave this screen, it clears '
                'the test alarms and restores your alarm'
                '${held == null ? ' (you have none armed)' : ' (the one at ${_hhmm(held)})'}'
                '. Keep the band on and stay here for about 4 minutes.',
                style: F.body.copyWith(color: p.ink, height: 1.4),
              ),
              const SizedBox(height: S.x3),
              BigButton(
                'Run probe',
                key: const ValueKey('alarm-slot-confirm-run'),
                icon: LucideIcons.alarmClock,
                onTap: () => Navigator.of(sheet).pop(true),
              ),
              const SizedBox(height: S.x2),
              BigButton(
                'Cancel',
                key: const ValueKey('alarm-slot-confirm-cancel'),
                soft: true,
                color: C.blue,
                onTap: () => Navigator.of(sheet).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
    if (go != true || !mounted) return;
    unawaited(r.run());
  }

  static String _hhmm(int epochSec) {
    final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }

  Widget _feltRow(AlarmSlotProbeRunner r) {
    final ev = r.evidence;
    Widget chip(String label, String key, int slot, bool? on) => Expanded(
          child: BigButton(
            label,
            key: ValueKey(key),
            soft: true,
            color: on == true ? C.green : C.blue,
            onTap: () => r.markFelt(slot, on == true ? null : true),
          ),
        );
    return Row(children: [
      chip('I felt A', 'alarm-slot-felt-a', 0, ev?.feltA),
      const SizedBox(width: S.x2),
      chip('I felt B', 'alarm-slot-felt-b', 1, ev?.feltB),
    ]);
  }

  @override
  Widget build(BuildContext c) {
    final r = widget.runner;
    if (!r.developerMode()) return const SizedBox.shrink();
    final p = P.of(c);
    final running = r.running;
    final verdict = r.verdict;
    final reason = running ? null : r.blockedReason;
    final note = r.note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsAccordion('Alarm slots (developer)',
            id: 'device_lab_alarm_slots',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Finds out whether the band can keep more than one '
                      'alarm at once. It arms two short test alarms on top '
                      'of yours, reads each back, watches which ones fire, '
                      'then puts yours back and clears its own. It does not '
                      'run within 10 minutes of your alarm.',
                      style: F.cap.copyWith(color: p.ink2, height: 1.4),
                    ),
                    if (!running) ...[
                      const SizedBox(height: S.x3),
                      BigButton(
                        'Run alarm slot probe',
                        key: const ValueKey('probe-alarm-slots'),
                        icon: LucideIcons.alarmClock,
                        soft: true,
                        color: C.blue,
                        onTap: reason == null ? _confirmAndRun : null,
                      ),
                      if (reason != null)
                        Padding(
                          padding: const EdgeInsets.only(top: S.x1),
                          child: Text(reason,
                              key: const ValueKey('alarm-slot-reason'),
                              style: F.cap.copyWith(color: p.ink2, height: 1.4)),
                        ),
                    ],
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
                      key: const ValueKey('alarm-slot-status'),
                      style: F.body.copyWith(color: p.ink)),
                  const SizedBox(height: S.x2),
                  for (final l in r.lines.reversed.take(5))
                    Text(l, style: F.cap.copyWith(color: p.ink2)),
                  const SizedBox(height: S.x3),
                  Text('Tick what the band actually did on your wrist:',
                      style: F.cap.copyWith(color: p.ink2)),
                  const SizedBox(height: S.x1),
                  _feltRow(r),
                  const SizedBox(height: S.x3),
                  BigButton(
                    'Stop and restore my alarm',
                    key: const ValueKey('alarm-slot-cancel'),
                    icon: LucideIcons.square,
                    soft: true,
                    color: C.red,
                    onTap: r.cancel,
                  ),
                ],
              ),
            ),
          ),
        if (!running && verdict != null)
          Padding(
            padding: const EdgeInsets.only(top: S.x3),
            child: Surface(
              key: const ValueKey('alarm-slot-result'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(verdict.headline, style: F.t1.copyWith(color: p.ink)),
                  const SizedBox(height: S.x2),
                  for (final l in verdict.evidence)
                    Padding(
                      padding: const EdgeInsets.only(bottom: S.x1),
                      child: Text(l, style: F.cap.copyWith(color: p.ink2)),
                    ),
                  const SizedBox(height: S.x2),
                  Text('Tick any buzz you felt; the result updates:',
                      style: F.cap.copyWith(color: p.ink2)),
                  const SizedBox(height: S.x1),
                  _feltRow(r),
                ],
              ),
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
}
