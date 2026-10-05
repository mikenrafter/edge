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

  final _ticker = _SyncTicker();
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

  void _syncTicker() => _ticker.update(
    busy: widget.state.busy,
    needsClock: widget.state.busy || widget.state.lastSuccess != null,
    onTick: () {
      if (mounted) setState(() {});
    },
  );

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
    _ticker.dispose();
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
            ...syncStepRows(s, now),
            const SizedBox(height: S.x1),
          ],
        ],
      ),
    );
  }
}

/// A second-by-second clock while a sync runs, and a slow one while a "synced
/// 12 min ago" sentence is on screen, so it does not go stale. Real seconds,
/// so this is [Motion.tick] and not [motion]. A readout with nothing to count
/// holds no timer.
class _SyncTicker {
  Timer? _timer;
  bool _busy = false;

  void update({
    required bool busy,
    required bool needsClock,
    required VoidCallback onTick,
  }) {
    if (!needsClock) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer != null && _busy == busy) return;
    _timer?.cancel();
    _busy = busy;
    _timer = Timer.periodic(busy ? Motion.tick : Motion.slowTick, (_) => onTick());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// The step rows (connect, download, calculate, done) for [s] at [now]. The
/// band page's inline list and Home's bottom sheet draw the same rows.
List<Widget> syncStepRows(SyncPresentationState s, DateTime now) =>
    [for (final step in s.steps) _StepRow(step: step, now: now)];

/// The short problem a settled sync left behind, or null when there is none.
/// A sync that is running has no problem yet, and "offline" is the band being
/// away, which the connection line already says.
({String text, bool failed})? syncProblem(SyncPresentationState s) {
  if (s.busy) return null;
  if (s.phase == 'failed') return (text: 'Sync failed', failed: true);
  if (s.phase == 'completed' && s.partial) {
    return (text: 'Needs another pass', failed: false);
  }
  return null;
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

/// The first clause of [syncStatusLine]: "Downloading…", "Calculating", "Sync
/// failed". The header says it without the backlog or the day count, which the
/// details sheet carries.
String syncStatusHeadline(SyncPresentationState s, DateTime now) {
  final line = syncStatusLine(s, now);
  final i = line.indexOf(' · ');
  return i < 0 ? line : line.substring(0, i);
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

/// Home's sync status: the center line of the greeting header, with the sync UI
/// on it. Same `SyncCoordinator` state as [SyncControl], so there is still one
/// idea of whether a sync is running.
///
///     Synced through 15:33          1 h ago [Sync now]      idle
///     Downloading… · 0:42 · Show details                    syncing
///     Sync failed · Show details         1 h ago [Retry]    problem
///
/// [through] is the data edge ("how far are we?") and stays Home's own text;
/// [throughShort] ("Through 15:33") replaces it when the line would not fit.
/// While a status shows (a running sync, or a problem) the status leads and
/// "Synced through" is left off the line entirely: it is a back-seat fact, it
/// is in the details sheet, and keeping it would wrap this line at 360 pt. The
/// status is the first clause of [syncStatusLine] (no backlog, no day count);
/// the timer is the running time; "Show details" opens [showSyncDetails]. The
/// spinner is not here: Home puts it in the settings button. Never a
/// percentage or an estimate. With no AppState above it (a golden) it is just
/// the data edge.
///
/// The line is a [HitOverhang], so its 44 pt targets do not add height to the
/// header.
class HomeSyncStatus extends StatefulWidget {
  final String through, throughShort;
  const HomeSyncStatus({
    super.key,
    required this.through,
    required this.throughShort,
  });

  @override
  State<HomeSyncStatus> createState() => _HomeSyncStatusState();
}

class _HomeSyncStatusState extends State<HomeSyncStatus> {
  final _ticker = _SyncTicker();

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  static Size _measure(BuildContext c, String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: DefaultTextStyle.of(c).style.merge(style)),
      textDirection: Directionality.of(c),
      textScaler: MediaQuery.textScalerOf(c),
      maxLines: 1,
    )..layout();
    final size = tp.size;
    tp.dispose();
    return size;
  }

  static double _width(BuildContext c, String text, TextStyle style) =>
      _measure(c, text, style).width;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final base = F.cap.copyWith(color: p.ink3);
    final SyncPresentationState s;
    try {
      s = c.watch<AppState>().syncPresentation;
    } on ProviderNotFoundException {
      return Text(widget.through, style: base);
    }
    final now = DateTime.now();
    _ticker.update(
      busy: s.busy,
      needsClock: s.busy || s.lastSuccess != null,
      onTick: () {
        if (mounted) setState(() {});
      },
    );
    final elapsed = s.busy ? s.elapsed(now) : null;
    final problem = syncProblem(s);
    final last = s.lastSuccess;
    final ago = s.busy || last == null ? null : _ago(now.difference(last));
    final failed = s.phase == 'failed';
    final action = failed ? 'Retry' : 'Sync now';
    final timerText = elapsed == null ? null : _clock(elapsed);
    final status = s.busy ? syncStatusHeadline(s, now) : null;
    final link = F.cap.copyWith(color: p.on(C.blue), fontWeight: FontWeight.w600);
    final button = F.cap.copyWith(color: p.on(C.blue), fontWeight: FontWeight.w600);
    final hasStatus = status != null || problem != null;

    return HitOverhang(
      visual: _measure(c, 'Ag', base).height,
      child: LayoutBuilder(builder: (c, box) {
        // What the right-hand end needs, so the left can decide between the
        // full label and the short one before anything has to wrap or clip.
        final right = s.busy
            ? 0.0
            : (ago == null ? 0.0 : _width(c, ago, base) + S.x2) +
                (_width(c, action, button) + 2 * S.x2).clamp(S.tap, double.infinity);
        final room = box.maxWidth - right - S.x2;
        // A few px of slack: a measured width can differ from the laid-out one
        // by a fraction.
        final through = _width(c, widget.through, base) + 4 <= room
            ? widget.through
            : widget.throughShort;

        Widget seg(String text, TextStyle style, {bool dot = true}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(text, style: style)),
            if (dot) Text(' ·', style: base),
          ],
        );

        final lead = <Widget>[
          if (!hasStatus) seg(through, base, dot: false),
          if (status != null)
            seg(status, F.cap.copyWith(color: p.ink2)),
          if (timerText != null)
            Semantics(
              label: 'Elapsed ${_spoken(elapsed!)}',
              child: ExcludeSemantics(child: seg(timerText, base)),
            ),
          if (hasStatus)
            Pressable(
              onTap: () => showSyncDetails(c, c.read<AppState>()),
              // A Wrap, not a Row: at large text it breaks between the problem
              // and the link instead of overflowing.
              child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (problem != null) ...[
                  Text(problem.text,
                      style: F.cap.copyWith(
                          color: p.on(problem.failed ? C.red : C.orange))),
                  Text(' · ', style: base),
                ],
                Text('Show details', style: link),
              ]),
            ),
        ];

        // Nothing while syncing: the spinner is in the settings button, and a
        // second Sync now beside a running sync is what this header replaced.
        final trail = <Widget>[
          if (!s.busy) ...[
            if (ago != null) Text(ago, style: base),
            Pressable(
              onTap: () => c.read<AppState>().syncNow(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: S.x2),
                child: Text(action, style: button),
              ),
            ),
          ],
        ];

        return Row(children: [
          Expanded(
            child: Wrap(
              spacing: S.x1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: lead,
            ),
          ),
          if (trail.isNotEmpty) ...[
            const SizedBox(width: S.x2),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * .6),
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: S.x2,
                children: trail,
              ),
            ),
          ],
        ]);
      }),
    );
  }
}

/// The four steps and the running time, in a bottom sheet. It reads [app] live,
/// so a sync that finishes while the sheet is open updates it in place. Opened
/// from a tap, with [app] read before the sheet exists: nothing here touches a
/// BuildContext after an await.
Future<void> showSyncDetails(BuildContext c, AppState app) {
  final p = P.of(c);
  return showModalBottomSheet<void>(
    context: c,
    backgroundColor: p.card,
    showDragHandle: true,
    builder: (_) => _SyncDetailsSheet(app: app),
  );
}

class _SyncDetailsSheet extends StatefulWidget {
  final AppState app;
  const _SyncDetailsSheet({required this.app});

  @override
  State<_SyncDetailsSheet> createState() => _SyncDetailsSheetState();
}

class _SyncDetailsSheetState extends State<_SyncDetailsSheet> {
  final _ticker = _SyncTicker();

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return ListenableBuilder(
      listenable: widget.app,
      builder: (c, _) {
        final s = widget.app.syncPresentation;
        final now = DateTime.now();
        _ticker.update(
          busy: s.busy,
          needsClock: s.busy,
          onTick: () {
            if (mounted) setState(() {});
          },
        );
        final elapsed = s.startedAt == null ? null : s.elapsed(now);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text('Sync', style: F.head.copyWith(color: p.ink)),
                  ),
                  if (elapsed != null)
                    Semantics(
                      label: 'Elapsed ${_spoken(elapsed)}',
                      child: ExcludeSemantics(
                        child: Text(_clock(elapsed),
                            style: F.n17.copyWith(color: p.ink2)),
                      ),
                    ),
                ]),
                const SizedBox(height: S.x1),
                Text(
                  syncStatusLine(s, now),
                  style: F.body.copyWith(
                      color: s.phase == 'failed' ? p.on(C.red) : p.ink),
                ),
                const SizedBox(height: S.x2),
                ...syncStepRows(s, now),
              ],
            ),
          ),
        );
      },
    );
  }
}
