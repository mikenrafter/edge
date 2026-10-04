import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../settings/settings_repository.dart';
import '../state/app_state.dart';
import 'grammar.dart';
import 'profile/devices.dart' show formatDayTime;
import 'profile/profile.dart' show accordionPrefKey;
import 'theme.dart';

/// THE sync control. Home and the primary band detail both render this, from
/// the one `SyncCoordinator` state, so there is never a second button with its
/// own idea of whether a sync is running.
///
/// It is ONE row: a mark (a spinner while a sync runs), the running time while
/// one does, one sentence about where the sync is, and at most one action. Tap
/// the sentence to open the four steps inline; whether they are open is
/// remembered between visits like an accordion (key `sync-details`). It never
/// draws a percentage or an estimate: the band does not say how much it holds,
/// so a figure is shown only when the band or the derivation reported it.
class SyncControl extends StatefulWidget {
  final SyncPresentationState state;
  final VoidCallback? onSync;

  /// The time source for the elapsed readout; tests and goldens pin it.
  final DateTime Function()? clock;
  const SyncControl({
    super.key,
    required this.state,
    this.onSync,
    this.clock,
  });

  @override
  State<SyncControl> createState() => _SyncControlState();
}

class _SyncControlState extends State<SyncControl> {
  /// The accordion id the open or closed state is stored under.
  static const _detailsId = 'sync-details';

  Timer? _tick;
  bool _tickBusy = false;
  bool _open = false;

  /// Set once the person has toggled it: a stored answer that arrives after
  /// that must not undo what they just did.
  bool _toggled = false;

  @override
  void initState() {
    super.initState();
    _syncTicker();
    _restore();
  }

  @override
  void didUpdateWidget(SyncControl old) {
    super.didUpdateWidget(old);
    _syncTicker();
  }

  /// A second-by-second clock while a sync runs, and a slow one while a "synced
  /// 12 min ago" sentence is on screen, so it does not go stale. Real seconds,
  /// so this is [Motion.tick] and not [motion]. A control with nothing to count
  /// holds no timer.
  void _syncTicker() {
    final busy = widget.state.busy;
    final needsClock = busy || widget.state.lastSuccess != null;
    if (!needsClock) {
      _tick?.cancel();
      _tick = null;
      return;
    }
    if (_tick != null && _tickBusy == busy) return;
    _tick?.cancel();
    _tickBusy = busy;
    _tick = Timer.periodic(busy ? Motion.tick : Motion.slowTick, (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _restore() async {
    bool? stored;
    try {
      stored =
          await SettingsRepository.instance.appBool(accordionPrefKey(_detailsId));
    } catch (_) {
      return; // Unreadable: stay collapsed.
    }
    if (!mounted || _toggled || stored == null || stored == _open) return;
    setState(() => _open = stored!);
  }

  Future<void> _toggle() async {
    final open = !_open;
    setState(() {
      _toggled = true;
      _open = open;
    });
    try {
      await SettingsRepository.instance.update(
        (d) => d.setBool(accordionPrefKey(_detailsId), open),
        sections: const {},
      );
    } catch (_) {
      // It still opened on screen; it just will not be remembered.
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
    final elapsed = s.busy ? s.elapsed(now) : null;
    final (icon, tint) = _mark(s, p);
    final onSync = widget.onSync;
    // With no steps (a fresh launch, a refresh that never touched the band)
    // there is nothing to open, so the sentence is not a control.
    final canOpen = s.steps.isNotEmpty;
    final status = Row(children: [
      if (s.busy)
        SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: p.on(C.blue)),
        )
      else
        Icon(icon, size: 20, color: tint),
      const SizedBox(width: S.x3),
      if (elapsed != null) ...[
        Semantics(
          label: 'Elapsed ${_spoken(elapsed)}',
          child: ExcludeSemantics(
            child: Text(_clock(elapsed), style: F.n17.copyWith(color: p.ink2)),
          ),
        ),
        const SizedBox(width: S.x2),
      ],
      Expanded(
        child: Text(
          syncStatusLine(s, now),
          style: F.body.copyWith(color: failed ? p.on(C.red) : p.ink),
        ),
      ),
    ]);
    return Surface(
      pad: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: S.tap),
            child: Row(children: [
              Expanded(
                child: canOpen
                    ? Semantics(
                        expanded: _open,
                        child: Pressable(onTap: _toggle, child: status),
                      )
                    : status,
              ),
              if (!s.busy && onSync != null) ...[
                const SizedBox(width: S.x2),
                Pressable(
                  onTap: onSync,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: S.x2),
                    child: Text(
                      failed ? 'Retry' : 'Sync now',
                      style: F.body.copyWith(
                          color: p.on(C.blue), fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ]),
          ),
          if (_open && canOpen) ...[
            const SizedBox(height: S.x2),
            for (final step in s.steps) _StepRow(step: step, now: now),
            const SizedBox(height: S.x1),
          ],
        ],
      ),
    );
  }
}

/// The mark in front of the sentence when no sync is running.
(IconData, Color) _mark(SyncPresentationState s, P p) =>
    switch (s.phase) {
      'failed' => (LucideIcons.circleX, p.on(C.red)),
      'offline' => (LucideIcons.unplug, p.ink3),
      'completed' when s.partial => (LucideIcons.circleAlert, p.on(C.orange)),
      _ when s.lastSuccess == null => (LucideIcons.refreshCw, p.ink3),
      _ => (LucideIcons.circleCheck, p.on(C.green)),
    };

/// The one sentence for [s] at [now]. Pure, so every phase is pinned by a test
/// without a widget. A count or a span appears only when the band or the
/// derivation reported it; everything else says what is happening and no more.
String syncStatusLine(SyncPresentationState s, DateTime now) {
  switch (s.phase) {
    case 'connecting':
      return 'Connecting to the band…';
    case 'downloading':
      final step = s.step(SyncStepId.download);
      final d = step.download;
      if (d != null && d.records == 0 && step.status == SyncStepStatus.done) {
        return 'Nothing new on the band';
      }
      final backlog = d?.backlog;
      return backlog == null
          ? 'Downloading…'
          : 'Downloading · ${_gap(backlog)} of band time to go';
    case 'deriving':
      final calc = s.calculate;
      if (calc != null && calc.waiting) {
        // Another calculation holds the lock. The most useful true thing to say
        // is what the download did; only with no download detail is "waiting"
        // the whole story.
        return _downloadLine(s) ?? 'Waiting for another calculation…';
      }
      final i = calc?.dayIndex, total = calc?.dayTotal;
      return i != null && total != null && i > 0
          ? 'Calculating · day $i of $total'
          : 'Calculating…';
    case 'completed':
      if (s.partial) return 'Synced, but some days need another pass';
      final done = s.finishedAt;
      if (done != null && now.difference(done).inSeconds < 60) {
        return 'Synced just now';
      }
      return _lastSynced(s, now, offline: false);
    case 'failed':
      final why = s.failureReason?.trim();
      return 'Sync failed: ${why == null || why.isEmpty ? 'Please retry' : why}';
    case 'offline':
      return _lastSynced(s, now, offline: true);
    default: // 'idle'
      return _lastSynced(s, now, offline: false);
  }
}

/// What the download did, for the line shown while the calculation waits its
/// turn. Null when the download left no detail.
String? _downloadLine(SyncPresentationState s) {
  final d = s.download;
  if (d == null) return null;
  if (d.records == 0) return 'Nothing new on the band';
  if (d.backlog case final backlog?) {
    return '${_gap(backlog)} of band time still to fetch';
  }
  if (d.syncedThrough case final through?) {
    return 'Downloaded · synced through ${formatDayTime(through.toLocal())}';
  }
  return 'Downloaded';
}

/// "Synced 12 min ago", "Not synced yet", and when the band is away "Band not
/// connected · synced 3 h ago".
String _lastSynced(SyncPresentationState s, DateTime now,
    {required bool offline}) {
  final last = s.lastSuccess;
  final synced = last == null
      ? 'not synced yet'
      : 'synced ${_ago(now.difference(last))}';
  if (offline) return 'Band not connected · $synced';
  return last == null ? 'Not synced yet' : 'Synced ${_ago(now.difference(last))}';
}

/// `just now`, `12 min ago`, `3 h ago`, `2 d ago`. A time in the future (a
/// clock moved) reads as just now rather than a negative span.
String _ago(Duration d) {
  final min = d.inMinutes;
  if (min < 1) return 'just now';
  if (min < 60) return '$min min ago';
  if (min < 1440) return '${min ~/ 60} h ago';
  return '${min ~/ 1440} d ago';
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
            'Band time still to fetch: ${_gap(backlog)}',
          // A download that stopped early says so, and what to do about it.
          if (!running && note != null) note,
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
        return [note ?? 'Finished'];
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

/// A span of band time: `45 min`, `2 h 10 min`, `2 d 3 h`.
String _gap(Duration d) {
  final min = d.inMinutes;
  if (min < 1) return 'under 1 min';
  if (min < 60) return '$min min';
  if (min < 1440) return '${min ~/ 60} h ${min % 60} min';
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
    );
  }
}
