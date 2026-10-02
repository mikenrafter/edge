import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'grammar.dart';
import 'profile/devices.dart' show formatDayTime;
import 'theme.dart';

/// THE sync control. Home and the primary band detail both render this, from
/// the one `SyncCoordinator` state, so there is never a second button with its
/// own idea of whether a sync is running.
///
/// While a sync runs it is a status panel, not a spinner: the four steps with
/// their state and time, what the download has banked so far, which day the
/// calculation is on, and the total time ticking. It never draws a percentage:
/// the band does not say how much it holds, so there is nothing true to divide
/// by. After a failure it says why, in words, and the button becomes Retry.
class SyncControl extends StatefulWidget {
  final SyncPresentationState state;
  final VoidCallback? onSync;

  /// The time source for the elapsed readout; tests and goldens pin it.
  final DateTime Function()? clock;

  /// The band is sending data although no manual sync is running (a
  /// background or reconnect drain). Said, never styled as a sync.
  final bool bandSending;
  const SyncControl({
    super.key,
    required this.state,
    this.onSync,
    this.clock,
    this.bandSending = false,
  });

  @override
  State<SyncControl> createState() => _SyncControlState();
}

class _SyncControlState extends State<SyncControl> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(SyncControl old) {
    super.didUpdateWidget(old);
    _syncTicker();
  }

  /// A clock only while there is something to count; a settled control holds
  /// no timer. Real seconds, so this is [Motion.tick] and not [motion].
  void _syncTicker() {
    if (widget.state.busy) {
      _tick ??= Timer.periodic(Motion.tick, (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final s = widget.state;
    final now = (widget.clock ?? DateTime.now)();
    final failed = s.phase == 'failed';
    final elapsed = s.elapsed(now);
    final title = switch (s.phase) {
      'connecting' || 'downloading' || 'deriving' => 'Syncing with your band',
      'completed' => 'Sync completed',
      'failed' => 'Sync failed',
      _ => 'Band sync',
    };
    final last = s.lastSuccess;
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(title, style: F.head.copyWith(color: p.ink)),
              ),
              if (elapsed != null) ...[
                const SizedBox(width: S.x2),
                Semantics(
                  label: 'Elapsed ${_spoken(elapsed)}',
                  child: ExcludeSemantics(
                    child: Text(
                      _clock(elapsed),
                      style: F.n17.copyWith(color: p.ink2),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (s.steps.isEmpty && !failed) ...[
            const SizedBox(height: S.x1),
            // The honest offline line: a refresh that never touched the band
            // says so, in the words it has always used.
            Text(s.description, style: F.cap.copyWith(color: p.ink2)),
          ],
          if (s.steps.isNotEmpty) ...[
            const SizedBox(height: S.x3),
            for (final step in s.steps) _StepRow(step: step, now: now),
          ],
          if (failed) ...[
            const SizedBox(height: S.x2),
            Text(
              s.failureReason ?? s.error ?? 'Please retry.',
              style: F.cap.copyWith(color: p.on(C.red)),
            ),
          ],
          if (widget.bandSending && !s.busy) ...[
            const SizedBox(height: S.x2),
            Text(
              'The band is sending data now.',
              style: F.cap.copyWith(color: p.ink2),
            ),
          ],
          if (last != null) ...[
            const SizedBox(height: S.x2),
            Text(
              'Last successful sync: '
              '${TimeOfDay.fromDateTime(last.toLocal()).format(c)}',
              style: F.cap.copyWith(color: p.ink3),
            ),
          ],
          const SizedBox(height: S.x3),
          Opacity(
            opacity: s.busy ? .55 : 1,
            child: BigButton(
              failed ? 'Retry' : 'Sync now',
              icon: failed ? LucideIcons.rotateCw : LucideIcons.refreshCw,
              soft: s.busy,
              onTap: s.busy ? null : widget.onSync,
            ),
          ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final SyncStep step;
  final DateTime now;
  const _StepRow({required this.step, required this.now});

  static String _label(SyncStepId id) => switch (id) {
    SyncStepId.connect => 'Connect',
    SyncStepId.download => 'Download',
    SyncStepId.calculate => 'Calculate',
    SyncStepId.done => 'Done',
  };

  /// One or two lines that say what this step is doing or did. Counts are the
  /// ones the engine and derivation reported; nothing is estimated.
  List<String> _lines(BuildContext c) {
    final note = step.note;
    switch (step.status) {
      case SyncStepStatus.waiting:
        return const ['Waiting'];
      case SyncStepStatus.skipped:
        return [note ?? 'Skipped'];
      case SyncStepStatus.failed:
        // What it did bank before it stopped is still true and still useful.
        final d = step.download;
        return [
          'Failed',
          if (d != null && d.records > 0) _banked(d),
        ];
      case SyncStepStatus.running || SyncStepStatus.done:
        break;
    }
    final running = step.status == SyncStepStatus.running;
    switch (step.id) {
      case SyncStepId.connect:
        return [running ? 'Connecting to the band…' : 'Connected'];
      case SyncStepId.download:
        final d = step.download;
        if (d == null) return [running ? 'Downloading…' : 'Downloaded'];
        final backlog = d.backlog;
        return [
          d.records == 0
              ? (running ? 'No records yet' : 'Nothing new on the band')
              : _banked(d),
          if (d.syncedThrough case final through?)
            'Synced through ${formatDayTime(through.toLocal())}',
          if (running && backlog != null)
            'Band time still to fetch: ${_span(backlog)}',
        ];
      case SyncStepId.calculate:
        final d = step.calculate;
        if (d != null && d.waiting) {
          return const ['Waiting for another calculation to finish'];
        }
        if (d?.dayIndex case final i? when d?.dayTotal != null) {
          final day = d!.day;
          return [
            'Day $i of ${d.dayTotal}${day == null ? '' : ' · $day'}',
          ];
        }
        return [running ? 'Working it out…' : 'Finished'];
      case SyncStepId.done:
        return const ['Finished'];
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final (icon, color) = switch (step.status) {
      SyncStepStatus.done => (LucideIcons.circleCheck, p.on(C.green)),
      SyncStepStatus.running => (LucideIcons.loader, p.on(C.blue)),
      SyncStepStatus.failed => (LucideIcons.circleX, p.on(C.red)),
      SyncStepStatus.skipped => (LucideIcons.circleMinus, p.ink3),
      SyncStepStatus.waiting => (LucideIcons.circle, p.ink3),
    };
    final took = step.status == SyncStepStatus.skipped
        ? null
        : step.duration(now);
    final lines = _lines(c);
    final label = _label(step.id);
    return Semantics(
      container: true,
      label: '$label, ${step.status.name}. ${lines.join('. ')}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: S.x1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: S.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: S.x2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          label,
                          style: F.body.copyWith(
                            color: step.status == SyncStepStatus.waiting
                                ? p.ink3
                                : p.ink,
                          ),
                        ),
                        if (took != null)
                          Text(
                            _took(took),
                            style: F.cap.copyWith(color: p.ink3),
                          ),
                      ],
                    ),
                    for (final line in lines)
                      Text(line, style: F.cap.copyWith(color: p.ink2)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `12,400 records · 31 chunks`.
String _banked(SyncDownloadDetail d) =>
    '${_count(d.records)} ${d.records == 1 ? 'record' : 'records'}'
    ' · ${_count(d.chunks)} ${d.chunks == 1 ? 'chunk' : 'chunks'}';

/// `1:05`, `12:09`, `1:02:03` — the running total.
String _clock(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

String _spoken(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = s ~/ 60;
  return m == 0 ? '$s seconds' : '$m minutes ${s % 60} seconds';
}

/// How long a step took: `2 s`, `1 min 13 s`, `1 h 4 min`.
String _took(Duration d) {
  final s = d.inSeconds;
  if (d.inMilliseconds < 1000) return '<1 s';
  if (s < 60) return '$s s';
  if (s < 3600) {
    final r = s % 60;
    return r == 0 ? '${s ~/ 60} min' : '${s ~/ 60} min $r s';
  }
  return '${s ~/ 3600} h ${(s % 3600) ~/ 60} min';
}

/// A span of band time: `45 m`, `10 h 30 m`, `2 d 3 h`.
String _span(Duration d) {
  final min = d.inMinutes;
  if (min < 1) return 'under 1 m';
  if (min < 60) return '$min m';
  if (min < 1440) return '${min ~/ 60} h ${min % 60} m';
  return '${min ~/ 1440} d ${(min % 1440) ~/ 60} h';
}

/// 12400 → `12,400`.
String _count(int n) {
  final raw = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    if (i > 0 && (raw.length - i) % 3 == 0) out.write(',');
    out.write(raw[i]);
  }
  return out.toString();
}

class HomeSyncControl extends StatelessWidget {
  const HomeSyncControl({super.key});
  @override
  Widget build(BuildContext context) {
    AppState? app;
    try {
      app = context.watch<AppState>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    final SyncPresentationState state = app.syncPresentation;
    return SyncControl(
      state: state,
      onSync: app.syncNow,
      bandSending: app.syncingNow,
    );
  }
}
