import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, visibleForTesting;
import 'package:clock/clock.dart' as pc;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../settings/settings_repository.dart';
import '../state/app_state.dart';
import '../state/derive_progress.dart';
import 'grammar.dart';
import 'inline_loading.dart';
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

  DateTime _now() => pc.Clock(widget.clock ?? pc.clock.now).now();

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
    final now = _now();
    final failed = s.phase == 'failed';
    final elapsed = s.busy ? s.elapsed(now) : null;
    final (icon, tint) = _mark(s, p);
    final onSync = widget.onSync;
    // The sentence is always a control: opening it shows the COMPLETE text (a
    // long localized reason or platform error is cut to two lines while the
    // card is closed) and, when there are any, the steps.
    final l = AppLocalizations.of(c);
    // The sentence keeps two lines at most (ellipsis after that) and the row
    // reserves two, so the card is the same height in every state whatever the
    // sentence says; opening the card shows the whole sentence.
    final body = F.body;
    final lineH = MediaQuery.textScalerOf(c).scale(body.fontSize!) *
        (body.height ?? 1.2);
    final rowMin = math.max(S.tap, (2 * lineH).ceilToDouble());
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
          label: l?.syncElapsedSemantics(_spoken(elapsed, l)) ??
              'Elapsed ${_spoken(elapsed, l)}',
          child: ExcludeSemantics(
            child: Text(_clock(elapsed), style: F.n17.copyWith(color: p.ink2)),
          ),
        ),
        const SizedBox(width: S.x2),
      ],
      Expanded(
        child: Text(
          syncStatusLine(s, now, l),
          maxLines: _open ? null : 2,
          overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
          style: F.body.copyWith(color: failed ? p.on(C.red) : p.ink),
        ),
      ),
    ]);
    final actionStyle =
        F.body.copyWith(color: p.on(C.blue), fontWeight: FontWeight.w600);
    final actionLabel = failed ? _retryLabel(c, l) : _syncNowLabel(c, l);
    Widget actionButton() => Pressable(
          onTap: onSync,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: S.tap, minWidth: S.tap),
            child: Center(
              widthFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: S.x2),
                // May wrap to a second line when even the line below is
                // narrower than the label (a long word at 2.0 on 320 pt); the
                // text is never scaled down.
                child: Text(actionLabel,
                    style: actionStyle,
                    maxLines: 2,
                    textAlign: TextAlign.center),
              ),
            ),
          ),
        );
    return Surface(
      pad: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x2),
      child: LayoutBuilder(builder: (c, box) {
        // Beside the sentence, or below it when the action would take more
        // than half the card. Decided from width, text scale and locale (the
        // widest label either action can show), never from the state, so the
        // reserved height is the same in every state. Never scaled to fit.
        double w(String t) => _HomeSyncStatusState._width(c, t, actionStyle);
        final widest = math.max(
            w(_retryLabel(c, l)), w(_syncNowLabel(c, l))) + 2 * S.x2;
        final below = onSync != null && widest > box.maxWidth * .5;
        // Closed: a fixed height, so the card is the same in every state.
        // Open (the person asked): it grows to hold the whole sentence.
        final rowChildren = <Widget>[
            Expanded(
              child: Semantics(
                expanded: _open,
                child: Pressable(onTap: _toggle, child: status),
              ),
            ),
            if (!below && !s.busy && onSync != null) ...[
              const SizedBox(width: S.x2),
              actionButton(),
            ],
          ];
        final statusRow = _open
            ? ConstrainedBox(
                constraints: BoxConstraints(minHeight: rowMin),
                child: Row(children: rowChildren),
              )
            : SizedBox(height: rowMin, child: Row(children: rowChildren));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            statusRow,
            if (below)
              SizedBox(
                height: rowMin,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [if (!s.busy) Flexible(child: actionButton())],
                ),
              ),
            if (_open && s.steps.isNotEmpty) ...[
              const SizedBox(height: S.x2),
              ...syncStepRows(s, now),
              const SizedBox(height: S.x1),
            ],
          ],
        );
      }),
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
({String text, bool failed})? syncProblem(SyncPresentationState s, [AppLocalizations? l]) {
  if (s.busy) return null;
  if (s.phase == 'failed') {
    return (
      text: syncFailureText(s, l) ?? (l?.syncStatusFailed ?? 'Sync failed'),
      failed: true
    );
  }
  if (s.phase == 'completed' && s.partial) {
    return (text: l?.syncStatusNeedsPass ?? 'Needs another pass', failed: false);
  }
  return null;
}

/// Why the sync failed, in the reader's language when this app produced the
/// reason (it carries a [SyncFailure] code); free text from a platform or a
/// derivation is shown as it came. Null when there is no reason at all.
String? syncFailureText(SyncPresentationState s, [AppLocalizations? l]) {
  final code = s.failureCode;
  if (code != null && l != null) {
    return switch (code) {
      SyncFailure.pairBand => l.syncFailPairBand,
      SyncFailure.couldNotConnect => l.syncFailCouldNotConnect,
      SyncFailure.disconnected => l.syncFailDisconnected,
      SyncFailure.downloadStopped => l.syncFailDownloadStopped,
      SyncFailure.calculationBusy => l.syncFailCalculationBusy,
      SyncFailure.calculationStuck => l.syncFailCalculationStuck,
      SyncFailure.timedOut => l.syncFailTimedOut,
    };
  }
  return s.failureReason;
}

/// A step's note in the reader's language when the coordinator wrote it (it
/// carries a [SyncNote] code); otherwise the note as it came.
String? _noteText(SyncStep step, AppLocalizations? l) {
  final code = step.noteCode;
  if (code != null && l != null) {
    return switch (code) {
      SyncNote.alreadyConnected => l.syncNoteAlreadyConnected,
      SyncNote.notNeeded => l.syncNoteNotNeeded,
      SyncNote.notReached => l.syncNoteNotReached,
      SyncNote.moreRemains => l.syncNoteMoreRemains,
      SyncNote.donePartial => l.syncNoteDonePartial,
      SyncNote.nothingNew => l.syncNoteNothingNew,
    };
  }
  return step.note;
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
String syncStatusLine(SyncPresentationState s, DateTime now, [AppLocalizations? l]) {
  switch (s.phase) {
    case 'connecting':
      return l?.syncStatusConnecting ?? 'Connecting to the band…';
    case 'downloading':
      final step = s.step(SyncStepId.download);
      final d = step.download;
      if (d != null && d.records == 0 && step.status == SyncStepStatus.done) {
        return l?.syncStatusNothingNew ?? 'Nothing new on the band';
      }
      final backlog = d?.backlog;
      return backlog == null
          ? l?.syncStatusDownloading ?? 'Downloading…'
          : '${l?.syncStatusDownloadingLine ?? 'Downloading'} · ${l?.syncStatusGapLine(_gap(backlog, l)) ?? '${_gap(backlog, l)} of band time to go'}';
    case 'deriving':
      final calc = s.calculate;
      if (calc != null && calc.waiting) {
        // Another calculation holds the lock. The most useful true thing to say
        // is what the download did; only with no download detail is "waiting"
        // the whole story.
        return _downloadLine(s, l) ?? (l?.syncStatusWaitingCalculation ?? 'Waiting for another calculation…');
      }
      final i = calc?.dayIndex, total = calc?.dayTotal;
      return i != null && total != null && i > 0
          ? (l?.syncLineCalcDay('$i', '$total') ?? 'Calculating · day $i of $total')
          : l?.syncStatusCalculating ?? 'Calculating…';
    case 'completed':
      if (s.partial) return l?.syncStatusPartial ?? 'Synced, but some days need another pass';
      final done = s.finishedAt;
      if (done != null && now.difference(done).inSeconds < 60) {
        return l?.syncStatusJustNow ?? 'Synced just now';
      }
      return _lastSynced(s, now, offline: false, l: l);
    case 'failed':
      final why = syncFailureText(s, l)?.trim();
      return '${l?.syncStatusFailed ?? 'Sync failed'}: ${why == null || why.isEmpty ? l?.syncStatusPleaseRetry ?? 'Please retry' : why}';
    case 'offline':
      return _lastSynced(s, now, offline: true, l: l);
    default: // 'idle'
      return _lastSynced(s, now, offline: false, l: l);
  }
}

/// The live calculation line for a screen whose data waits on derivation.
/// Null unless a calculation is running. Unlike [syncStatusLine], waiting
/// says only that: the download's result belongs to the sync sheet.
String? calcProgressLine(SyncPresentationState s, [AppLocalizations? l]) {
  if (s.phase != 'deriving') return null;
  final calc = s.calculate;
  return _calcLine(l,
      waiting: calc != null && calc.waiting,
      i: calc?.dayIndex,
      total: calc?.dayTotal,
      day: calc?.day);
}

String _calcLine(AppLocalizations? l,
    {required bool waiting, int? i, int? total, String? day}) {
  if (waiting) {
    return l?.deriveProgressWaiting ?? 'Waiting for another calculation';
  }
  if (i == null || total == null || i <= 0) {
    return l?.deriveProgressCalculating ?? 'Calculating…';
  }
  return day == null
      ? (l?.deriveProgressDay('$i', '$total') ??
          'Calculating · day $i of $total')
      : (l?.deriveProgressDayOn('$i', '$total', day) ??
          'Calculating · day $i of $total · $day');
}

/// [calcProgressLine] for any derive pass, sync or not, from
/// AppState.deriveProgress: a pass after an import or a baseline rescan
/// reports here and never on the sync's own steps.
String? deriveProgressLine(DeriveProgress? p, [AppLocalizations? l]) {
  if (p == null) return null;
  return _calcLine(l,
      waiting: p.waiting, i: p.dayIndex, total: p.dayTotal, day: p.day);
}

/// An [InlineLoading] for data that waits on a calculation: its detail line
/// follows AppState.deriveProgress. Without an AppState (fixtures) it is the
/// plain status.
class CalcLoading extends StatelessWidget {
  final String status;
  const CalcLoading({super.key, required this.status});

  @override
  Widget build(BuildContext c) {
    ValueListenable<DeriveProgress?>? src;
    try {
      src = c.read<AppState>().deriveProgress;
    } on ProviderNotFoundException {
      return InlineLoading(status: status, reserveDetail: true);
    }
    return ValueListenableBuilder<DeriveProgress?>(
      valueListenable: src,
      builder: (_, p, _) => InlineLoading(
          status: status,
          detail: deriveProgressLine(p, AppLocalizations.of(c)),
          reserveDetail: true),
    );
  }
}

/// The busy face the profile button shows while a sync runs. The status
/// sentence on the same header row says what the sync is doing.
Widget syncBusyMark(Color color) => SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );

/// The first clause of [syncStatusLine]: "Downloading…", "Calculating", "Sync
/// failed". The header says it without the backlog or the day count, which the
/// details sheet carries.
String syncStatusHeadline(SyncPresentationState s, DateTime now, [AppLocalizations? l]) {
  final line = syncStatusLine(s, now, l);
  final i = line.indexOf(' · ');
  return i < 0 ? line : line.substring(0, i);
}

/// What the download did, for the line shown while the calculation waits its
/// turn. Null when the download left no detail.
String? _downloadLine(SyncPresentationState s, [AppLocalizations? l]) {
  final d = s.download;
  if (d == null) return null;
  if (d.records == 0) return l?.syncStatusNothingNew ?? 'Nothing new on the band';
  if (d.backlog case final backlog?) {
    return l?.syncDownloadGapLine(_gap(backlog, l)) ?? '${_gap(backlog, l)} of band time still to fetch';
  }
  if (d.syncedThrough case final through?) {
    return '${l?.syncLineDownloaded ?? 'Downloaded'} · ${l?.syncLineSyncedThrough(formatDayTime(through.toLocal(), l)) ?? 'synced through ${formatDayTime(through.toLocal())}'}';
  }
  return l?.syncLineDownloaded ?? 'Downloaded';
}

/// "Synced 12 min ago", "Not synced yet", and when the band is away "Band not
/// connected · synced 3 h ago".
String _lastSynced(SyncPresentationState s, DateTime now,
    {required bool offline, AppLocalizations? l}) {
  final last = s.lastSuccess;
  final synced = last == null ? (l?.syncStatusNotYetLower ?? 'not synced yet')
      : '${l?.syncStatusSyncedLower ?? 'synced'} ${_ago(now.difference(last), l)}';
  if (offline) return '${l?.syncStatusOffline ?? 'Band not connected'} · $synced';
  return last == null ? (l?.syncStatusNotYet ?? 'Not synced yet') : '${l?.syncStatusSynced ?? 'Synced'} ${_ago(now.difference(last), l)}';
}

/// `just now`, `12 min ago`, `3 h ago`, `2 d ago`. A time in the future (a
/// clock moved) reads as just now rather than a negative span.
String _ago(Duration d, [AppLocalizations? l]) {
  final min = d.inMinutes;
  if (min < 1) return l?.syncAgoJustNow ?? 'just now';
  if (min < 60) return l?.syncAgoMinutes(min) ?? '$min min ago';
  if (min < 1440) return l?.syncAgoHours(min ~/ 60) ?? '${min ~/ 60} h ago';
  return l?.syncAgoDays(min ~/ 1440) ?? '${min ~/ 1440} d ago';
}

class _StepRow extends StatelessWidget {
  final SyncStep step;
  final DateTime now;
  const _StepRow({required this.step, required this.now});

  static String _label(SyncStepId id, AppLocalizations? l) => switch (id) {
    SyncStepId.connect => l?.syncStepConnect ?? 'Connect',
    SyncStepId.download => l?.syncStepDownload ?? 'Download',
    SyncStepId.calculate => l?.syncStepCalculate ?? 'Calculate',
    SyncStepId.done => l?.syncStepDone ?? 'Done',
  };

  /// One or two lines that say what this step is doing or did. Counts are the
  /// ones the engine and derivation reported; nothing is estimated.
  List<String> _lines(BuildContext c) {
    final note = step.note;
    final l = AppLocalizations.of(c);
    switch (step.status) {
      case SyncStepStatus.waiting:
        return [l?.syncLineWaiting ?? 'Waiting'];
      case SyncStepStatus.skipped:
        return [_noteText(step, l) ?? (l?.syncLineSkipped ?? 'Skipped')];
      case SyncStepStatus.failed:
        // What it did bank before it stopped is still true and still useful.
        final d = step.download;
        return [
          l?.syncLineFailed ?? 'Failed',
          if (d != null && d.records > 0) _banked(d, l),
        ];
      case SyncStepStatus.running || SyncStepStatus.done:
        break;
    }
    final running = step.status == SyncStepStatus.running;
    switch (step.id) {
      case SyncStepId.connect:
        return [running ? (l?.syncStatusConnecting ?? 'Connecting to the band…') : (l?.syncLineConnected ?? 'Connected')];
      case SyncStepId.download:
        final d = step.download;
        if (d == null) return [running ? (l?.syncStatusDownloading ?? 'Downloading…') : (l?.syncLineDownloaded ?? 'Downloaded')];
        final backlog = d.backlog;
        return [
          d.records == 0
              ? (running ? (l?.syncLineNoRecords ?? 'No records yet') : (l?.syncStatusNothingNew ?? 'Nothing new on the band'))
              : _banked(d, l),
          if (d.syncedThrough case final through?)
            l?.homeSyncedThrough(formatDayTime(through.toLocal(), l)) ?? 'Synced through ${formatDayTime(through.toLocal())}',
          if (running && backlog != null)
            l?.syncLineGap(_gap(backlog, l)) ?? 'Band time still to fetch: ${_gap(backlog, l)}',
          // A download that stopped early says so, and what to do about it.
          if (!running && note != null) _noteText(step, l)!,
        ];
      case SyncStepId.calculate:
        final d = step.calculate;
        if (d != null && d.waiting) {
          return [l?.syncStepWaitingCalculation ?? 'Waiting for another calculation to finish'];
        }
        if (d?.dayIndex case final i? when d?.dayTotal != null) {
          final day = d!.day;
          return [
            l?.syncLineDay('$i', '${d.dayTotal}', day == null ? '' : ' · $day') ?? 'Day $i of ${d.dayTotal}${day == null ? '' : ' · $day'}',
          ];
        }
        return [running ? (l?.syncLineWorking ?? 'Working it out…') : (l?.syncLineFinished ?? 'Finished')];
      case SyncStepId.done:
        return [_noteText(step, l) ?? (l?.syncLineFinished ?? 'Finished')];
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
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
    final label = _label(step.id, l);
    return Semantics(
      container: true,
      label: '$label, ${_localizedStepStatus(step.status, l)}. ${lines.join('. ')}',
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
                            _took(took, l),
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
String _banked(SyncDownloadDetail d, [AppLocalizations? l]) =>
    '${l?.syncCountRecords(d.records) ?? '${_count(d.records)} ${d.records == 1 ? 'record' : 'records'}'}'
    ' · ${l?.syncCountChunks(d.chunks) ?? '${_count(d.chunks)} ${d.chunks == 1 ? 'chunk' : 'chunks'}'}';

/// `1:05`, `12:09`, `1:02:03` — the running total.
String _clock(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

String _spoken(Duration d, [AppLocalizations? l]) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = s ~/ 60;
  return m == 0 ? (l?.syncSpokenSeconds(s) ?? '$s seconds') : (l?.syncSpokenMinutes(m, s % 60) ?? '$m minutes ${s % 60} seconds');
}

String _localizedStepStatus(SyncStepStatus status, AppLocalizations? l) => switch (status) {
  SyncStepStatus.waiting => l?.syncSemWaiting ?? 'waiting',
  SyncStepStatus.skipped => l?.syncSemSkipped ?? 'skipped',
  SyncStepStatus.failed => l?.syncSemFailed ?? 'failed',
  SyncStepStatus.running => l?.syncSemRunning ?? 'running',
  SyncStepStatus.done => l?.syncSemDone ?? 'done',
};

/// How long a step took: `2 s`, `1 min 13 s`, `1 h 4 min`.
String _took(Duration d, [AppLocalizations? l]) {
  final s = d.inSeconds;
  if (d.inMilliseconds < 1000) return l?.syncDurationUnderSecond ?? '<1 s';
  if (s < 60) return l?.syncDurationSeconds(s) ?? '$s s';
  if (s < 3600) {
    final m = s ~/ 60, r = s % 60;
    return r == 0 ? (l?.syncDurationMinutesOnly(m) ?? '$m min') : (l?.syncDurationMinutes(m, r) ?? '$m min $r s');
  }
  return l?.syncDurationHours(s ~/ 3600, (s % 3600) ~/ 60) ?? '${s ~/ 3600} h ${(s % 3600) ~/ 60} min';
}

/// A span of band time: `45 min`, `2 h 10 min`, `2 d 3 h`.
String _gap(Duration d, [AppLocalizations? l]) {
  final min = d.inMinutes;
  if (min < 1) return l?.syncGapMinutes(0) ?? 'under 1 min';
  if (min < 60) return l?.syncGapMinutes(min) ?? '$min min';
  if (min < 1440) return l?.syncGapHours(min ~/ 60, min % 60) ?? '${min ~/ 60} h ${min % 60} min';
  return l?.syncGapDays(min ~/ 1440, (min % 1440) ~/ 60) ?? '${min ~/ 1440} d ${(min % 1440) ~/ 60} h';
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

/// Home's sync status: row 1 of the greeting header, with the sync UI on it.
/// Same `SyncCoordinator` state as [SyncControl], so there is still one idea of
/// whether a sync is running.
///
///     Sunday, 4 October             1 h ago [Sync now]  (gear)   idle
///     Downloading…              0:42 · Show details     (gear)   syncing
///     Sync failed     1 h ago [Show details] [Retry]    (gear)   problem
///
/// The left is one line of text that ellipsizes first when the width runs out:
/// [through] (Home passes the date; the no-day path the data edge) when idle,
/// the status while a sync runs (the first clause of [syncStatusLine], no
/// backlog or day count) and the problem sentence after a failure.
/// [throughShort] ("Through 15:33") replaces [through] when it would not fit.
/// The right is right-aligned, just left of [end] (the settings button): the
/// time since the last good sync (the first thing dropped when the row
/// crowds), the running time, "Show details" (opens
/// [showSyncDetails]) and Sync now / Retry. The row is as tall as [end], so
/// the text is centred on the button. Never a percentage or an estimate. The
/// spinner is not here: Home puts it in the settings button. With no AppState
/// above (a golden) the left is just [through].
///
/// The row is a [HitOverhang], so its 44 pt targets (and the button's) do not
/// add height to the header. It must be a direct child of the header Column.
class HomeSyncStatus extends StatefulWidget {
  final String through, throughShort;

  /// The buttons at the right end of the row, centred on it. Null for the
  /// no-day path, which has no settings button.
  final Widget? end;

  /// The space between the right-aligned cluster and [end].
  static const endGap = S.x1;

  /// Space before the left text, to line up with the status line's padding.
  final double inset;

  /// The height the row reports (its targets still overhang it); null is the
  /// text's own height. The status line passes its slot height.
  final double? slot;

  /// How many reserved lines the actions get under row 1 (see
  /// [syncActionLines]): 0 inline, 1 all actions on one line, 2 one action per
  /// line. Decided by width, text scale and locale alone, so it is the same in
  /// every state. At large scales the localized compact labels are used; the
  /// text itself is never scaled down.
  final int actionLines;

  /// Test-facing: how many times any sync row has built.
  @visibleForTesting
  static int debugBuilds = 0;

  const HomeSyncStatus({
    super.key,
    required this.through,
    required this.throughShort,
    this.end,
    this.inset = 0,
    this.slot,
    this.actionLines = 0,
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
    HomeSyncStatus.debugBuilds++;
    final p = P.of(c);
    final base = F.cap.copyWith(color: p.ink3);
    final end = widget.end;
    final visual = _measure(c, 'Ag', base).height;
    final SyncPresentationState s;
    try {
      // Only the fields this row draws, so an unrelated notification (live
      // HR, a pref) does not rebuild it and re-measure its text. The idle
      // view is a fresh object every read, hence fields, not the object.
      c.select<AppState, Object>((a) {
        final v = a.syncPresentation;
        return (v.busy, v.phase, v.lastSuccess, v.startedAt, v.finishedAt,
            v.failureReason, v.partial, v.steps);
      });
      s = c.read<AppState>().syncPresentation;
    } on ProviderNotFoundException {
      final text = Padding(
          padding: EdgeInsets.only(left: widget.inset),
          child: Text(widget.through, style: base,
              maxLines: 1, overflow: TextOverflow.ellipsis));
      if (end == null) return text;
      return HitOverhang(
        visual: visual,
        child: Row(children: [
          Expanded(child: text),
          const SizedBox(width: S.x2),
          end,
        ]),
      );
    }
    final now = pc.clock.now();
    // A parked tab (TickerMode off) keeps no visual timer; showing it again
    // rebuilds this row (TickerMode is an inherited dependency), which
    // re-reads the clock and restarts the timer.
    final visible = TickerMode.valuesOf(c).enabled;
    _ticker.update(
      busy: s.busy,
      needsClock: visible && (s.busy || s.lastSuccess != null),
      onTick: () {
        if (mounted) setState(() {});
      },
    );
    final elapsed = s.busy ? s.elapsed(now) : null;
    final problem = syncProblem(s, AppLocalizations.of(c));
    final last = s.lastSuccess;
    final ago = s.busy || last == null ? null : _ago(now.difference(last), AppLocalizations.of(c));
    final failed = s.phase == 'failed';
    final l = AppLocalizations.of(c);
    final action = failed ? _retryLabel(c, l) : _syncNowLabel(c, l);
    final timerText = elapsed == null ? null : _clock(elapsed);
    final status = s.busy ? syncStatusHeadline(s, now, AppLocalizations.of(c)) : null;
    final link = F.cap.copyWith(color: p.on(C.blue), fontWeight: FontWeight.w600);
    final hasStatus = status != null || problem != null;

    // The row's height is a policy of text scale alone, never of the state:
    // the hit targets overhang it, the content cannot grow it.
    final rowH = math.max(S.tap, widget.slot ?? visual);
    final row = LayoutBuilder(builder: (c, box) {
      // The right-hand end first, so the left can decide between the full
      // label and the short one before anything has to wrap or clip.
      // Pressables are at least S.tap wide.
      final maxRight = box.maxWidth * .6;
      final two = widget.actionLines > 0;
      // With their own line the actions take no room on this one.
      final details = hasStatus && !two
          ? _width(c, _detailsLabel(c, l), link) + S.x1
          : 0.0;
      final timerW = timerText == null ? 0.0 : _width(c, '$timerText ·', base);
      // The cluster's gap sits between the timer and Show details too.
      final showTimer = timerText != null &&
          !two &&
          timerW + (details > 0 ? S.x1 : 0) + details <= maxRight;
      final act = s.busy || two
          ? 0.0
          : math.max(_width(c, action, link) + 2 * S.x1, S.tap);
      final fixed = [if (showTimer) timerW, details, act].where((w) => w > 0).toList();
      double sum(List<double> ws) =>
          ws.fold(0.0, (a, w) => a + w) + math.max(0, ws.length - 1) * S.x1;
      // With the actions on their own line the age and timer are dropped too
      // (they go first). "N h ago" is the first thing to go when even the
      // clickables crowd the
      // row, in every state (a problem included): the status and the
      // clickables matter more.
      final agoW = ago == null ? 0.0 : _width(c, ago, base);
      final showAgo = ago != null && !two && sum([agoW, ...fixed]) <= maxRight;
      final right = sum([if (showAgo) agoW, ...fixed]);
      final room = box.maxWidth - right - S.x2;
      // A few px of slack: a measured width can differ from the laid-out one
      // by a fraction.
      final through = _width(c, widget.through, base) + 4 <= room
          ? widget.through
          : widget.throughShort;

      final left = status != null
          ? Text(status, style: F.cap.copyWith(color: p.ink2),
              maxLines: 1, overflow: TextOverflow.ellipsis)
          : problem != null
              ? Text(problem.text,
                  style: F.cap.copyWith(
                      color: p.on(problem.failed ? C.red : C.orange)),
                  maxLines: 1, overflow: TextOverflow.ellipsis)
              : Text(through, style: base,
                  maxLines: 1, overflow: TextOverflow.ellipsis);

      // Nothing while syncing but the timer and Show details: the spinner is in
      // the settings button, and a second Sync now beside a running sync is
      // what this header replaced.
      List<Widget> actions(BuildContext c) => [
            if (hasStatus)
              Pressable(
                onTap: () => showSyncDetails(c, c.read<AppState>()),
                child: Text(_detailsLabel(c, AppLocalizations.of(c)), style: link),
              ),
            if (!s.busy)
              Pressable(
                onTap: () => c.read<AppState>().syncNow(),
                child: Text(action, style: link),
              ),
          ];
      final trail = <Widget>[
        if (showAgo) Text(ago, style: base),
        if (showTimer)
          Semantics(
            label: AppLocalizations.of(c)?.syncElapsedSemantics(_spoken(elapsed!, AppLocalizations.of(c))) ?? 'Elapsed ${_spoken(elapsed!, AppLocalizations.of(c))}',
            child: ExcludeSemantics(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(timerText, style: base),
                Text(' ·', style: base),
              ]),
            ),
          ),
        if (!two) ...actions(c),
      ];

      final line = Row(children: [
        Expanded(
            child: Padding(
                padding: EdgeInsets.only(left: widget.inset), child: left)),
        if (trail.isNotEmpty) ...[
          const SizedBox(width: S.x2),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxRight),
            // Unscaled and never wrapped: the fit above has already dropped
            // the age and timer, and what still does not fit has its own line.
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < trail.length; i++) ...[
                if (i > 0) const SizedBox(width: S.x1),
                trail[i],
              ],
            ]),
          ),
        ],
      ]);
      if (!two) return line;
      final own = actions(c);
      // One line holds the whole cluster; when even that is too wide for this
      // width, scale and locale, each action gets a line of its own. The count
      // is fixed by [syncActionLines], never by the state, so every state
      // reserves the same height (an unused line is just empty).
      return Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: rowH, child: line),
        if (widget.actionLines == 1)
          SizedBox(
            height: S.tap,
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: own),
          )
        else
          for (var i = 0; i < 2; i++)
            SizedBox(
              height: S.tap,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [if (i < own.length) own[i]],
              ),
            ),
      ]);
    });

    final total = rowH + widget.actionLines * S.tap;
    return HitOverhang(
      visual: widget.actionLines > 0 ? total : widget.slot ?? visual,
      child: SizedBox(
        height: total,
        child: end == null
            ? row
            : Row(children: [
                Expanded(child: row),
                const SizedBox(width: HomeSyncStatus.endGap),
                end,
              ]),
      ),
    );
  }
}

String _scaleAwareLabel(
  BuildContext c,
  AppLocalizations? l, {
  required String full,
  required String compact,
}) {
  if (l == null) return full;
  final fontSize = F.cap.fontSize!;
  final scale = MediaQuery.textScalerOf(c).scale(fontSize) / fontSize;
  if (scale >= 1.5) return compact;
  return full;
}

String _syncNowLabel(BuildContext c, AppLocalizations? l) => _scaleAwareLabel(
      c,
      l,
      full: l?.devicesSyncNow ?? 'Sync now',
      compact: l?.syncActionSyncCompact ?? 'Sync',
    );

String _detailsLabel(BuildContext c, AppLocalizations? l) => _scaleAwareLabel(
      c,
      l,
      full: l?.syncActionShowDetails ?? 'Show details',
      compact: l?.syncActionDetailsCompact ?? 'Details',
    );

String _retryLabel(BuildContext c, AppLocalizations? l) => _scaleAwareLabel(
      c,
      l,
      full: l?.syncActionRetry ?? 'Retry',
      compact: l?.syncActionRetryCompact ?? 'Retry',
    );

/// How many reserved action lines [width] needs: 0 when the widest cluster any
/// state renders fits the right 60 % of row 1; 1 when it does not but the
/// whole cluster fits one full-width line; 2 when even that is too wide (a
/// long localized pair at a large text scale), so each action gets a line.
/// A function of width, text scale and locale ONLY, never of the state, so row
/// 1 and the block are the same height in idle, syncing, failed and importing.
/// The labels are never scaled to fit.
int syncActionLines(BuildContext c, double width, [AppLocalizations? l]) {
  l ??= AppLocalizations.of(c);
  final link = F.cap.copyWith(
      color: P.of(c).on(C.blue), fontWeight: FontWeight.w600);
  double w(String t) => _HomeSyncStatusState._width(c, t, link);
  double act(String t) => math.max(w(t) + 2 * S.x1, S.tap);
  final details = w(_detailsLabel(c, l)) + S.x1;
  // Every combination a state can render: Sync now alone (idle), Show details
  // alone (syncing), Show details + Retry (failed) and Show details + Sync now
  // (a finished sync with more to do). Padding, gaps and the 44 pt minimum
  // width are in each term; the widest decides.
  final pair = math.max(
    details + S.x1 + act(_retryLabel(c, l)),
    details + S.x1 + act(_syncNowLabel(c, l)),
  );
  final worst = [act(_syncNowLabel(c, l)), details, pair].reduce(math.max);
  // Leave room for the row's trailing control and spacing, which are outside
  // the width measured by HeaderRows' parent constraint.
  if (worst <= math.max(0, width - S.tap - HomeSyncStatus.endGap) * .6) {
    return 0;
  }
  return pair <= width ? 1 : 2;
}

/// Whether the sync actions leave row 1 at all (see [syncActionLines]).
bool syncActionsNeedOwnLine(BuildContext c, double width,
        [AppLocalizations? l]) =>
    syncActionLines(c, width, l) > 0;

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
        final now = pc.clock.now();
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
                    child: Text(AppLocalizations.of(c)?.syncSheetTitle ?? 'Sync', style: F.head.copyWith(color: p.ink)),
                  ),
                  if (elapsed != null)
                    Semantics(
                      label: AppLocalizations.of(c)?.syncElapsedSemantics(_spoken(elapsed, AppLocalizations.of(c))) ?? 'Elapsed ${_spoken(elapsed, AppLocalizations.of(c))}',
                      child: ExcludeSemantics(
                        child: Text(_clock(elapsed),
                            style: F.n17.copyWith(color: p.ink2)),
                      ),
                    ),
                ]),
                const SizedBox(height: S.x1),
                Text(
                  syncStatusLine(s, now, AppLocalizations.of(c)),
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
