import '../../data/sleep_ownership.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import '../../compute/nap_edits.dart';
import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/local_repository.dart';
import '../../data/read_paused.dart';
import '../../l10n/app_localizations.dart';
import '../../models/metric.dart' show whyFromNote;
import '../../state/app_state.dart';
import '../ui2.dart';
import 'home_screen.dart' show clockOfTs, hm, repoOf;
import '../../data/sleep_editor.dart';
import 'metric_detail.dart';
import 'detected_activities.dart' show NapAutoLogRow;
import '../../health/health_nap_export.dart';


// NAPS — the day's naps, and the last word on them.
//
// `nap_min` has been populated on every judged day (232 minutes on one of
// them), the `naps` block has carried the windows behind it, and neither had a
// reader. Underneath, `sleep_nap` has had `putNapEdit` and `deleteNapEdit`
// since the detector became a PROPOSAL rather than a verdict — and no caller,
// anywhere, so `applyNapEdits` replayed a table that could never have a row in
// it. sleep_detail.dart says so in as many words: "a control that appeared to
// edit naps while the edits went nowhere would be worse than the absence. It
// needs a writer first."
//
// This is that writer, and it ships with the display for one reason: showing a
// nap and letting someone correct it are the same feature. A list you cannot
// argue with is the detector asserting it was there; the person who was
// actually there gets the last word.
//
// AN EDIT IS A RECOMPUTE, NOT A REDRAW. Nap minutes are subtracted from sleep
// need and sleep debt, so every write here forces the day to derive again —
// the same machinery a sleep-window correction uses, and the engine
// force-includes nap-edit days even when they are finalized.
//
// WHAT IS DELIBERATELY NOT HERE: no stages. A 30-minute nap holds no complete
// cycle, the stager says nothing about one, and a logged nap is a REPORT, not
// an estimate — it gets no confidence, because dressing it in the detector's
// scale would imply it was inferred.



class NapsData {
  const NapsData({
    this.day,
    this.days = const [],
    this.naps = const [],
    this.napMin,
    this.note,
    this.judged = false,
    this.rejected = const [],
  });

  final String? day;
  final List<String> days;

  /// The MERGED list — detected naps with the user's edits replayed over them,
  /// which is the same list `nap_min` is summed from.
  final List<Map<String, dynamic>> naps;

  final int? napMin;

  /// The detector's own reason, when it had one. Never a sentence written here.
  final String? note;

  /// Whether the day produced a nap answer at all. An empty [naps] on a judged
  /// day is the measured "no naps"; on an unjudged day it is "we could not
  /// tell", and the two must not read the same.
  final bool judged;

  /// The windows the user has rejected — kept visible so a removal is
  /// reversible. A suppression nobody can see is one nobody can undo.
  final List<Map<String, dynamic>> rejected;

  static Future<NapsData> load(LocalRepository repo, {String? want}) async {
    final days = await repo.availableDays();
    final day = pickDay(days, want, todayLabel()) ?? todayLabel();
    final d = await repo.getDayNaps(day);
    return NapsData(
      day: day,
      days: days,
      naps: [
        for (final n in (d['naps'] as List?) ?? const [])
          (n as Map).cast<String, dynamic>(),
      ],
      napMin: (d['nap_min'] as num?)?.round(),
      note: d['note'] as String?,
      judged: d['naps'] is List,
      rejected: [
        for (final r in await LocalDb.napEdits(day))
          if (r['source'] == 'rejected') r,
      ],
    );
  }
}

class NapsScreen extends StatefulWidget {
  const NapsScreen({super.key, this.day});

  final String? day;

  @override
  State<NapsScreen> createState() => _NapsScreenState();
}

class _NapsScreenState extends State<NapsScreen>
    with PausedReadReload<NapsScreen> {
  NapsData? _d;
  String? _day;
  List<String> _navDays = const [];
  // A quick second tap on the day stepper starts a second load; the first
  // can finish last and must not paint the old day.
  int _loadToken = 0;
  bool _busy = false;
  String? _failed;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    watchPausedRead();
    _day = widget.day;
    _load();
  }

  @override
  void dispose() {
    stopWatchingPausedRead();
    super.dispose();
  }

  @override
  bool get pausedContent => _paused;

  @override
  Future<void> reloadPausedRead() async {
    if (mounted && _paused) await _load();
  }

  @override
  void focusStarted() => _load();

  /// The repository the last read used: every write goes through it, never
  /// through LocalDb directly, so the shared spacing rule applies.
  LocalRepository? _repoSeen;
  LocalRepository get _repo =>
      _repoSeen ?? (throw StateError('no repository to write a nap with'));

  /// A refused write surfaces its reason through the same path as any failed
  /// edit (the screen's failure line).
  void _must(SleepEditorOutcome out) {
    if (out is SleepRefused && out.proposal != null) {
      throw SleepMergeRequiredException(out.proposal!);
    }
    if (out is SleepRefused) throw StateError('That change was refused.');
    if (out is SleepFailed) throw out.error;
  }

  Future<bool> _load() async {
    final repo = repoOf(context);
    if (repo == null) return false;
    _repoSeen = repo;
    final token = ++_loadToken;
    try {
      final d = await NapsData.load(repo, want: _day);
      if (mounted && token == _loadToken) {
        setState(() => (_d = d, _navDays = d.days, _paused = false, _loadFailed = false));
        return true;
      }
    } on ReadPaused {
      // Import in progress: nothing to read and nothing wrong.
      if (mounted && token == _loadToken) setState(() => (_d = null, _paused = true));
    } catch (_) {
      if (mounted && token == _loadToken) {
        setState(() => (_d = null, _paused = false, _loadFailed = true));
      }
    }
    return false;
  }

  void _goDay(String day) {
    setState(() {
      _navDays = _d?.days ?? _navDays;
      _day = day;
      _d = null;
      _loadFailed = false;
    });
    _load();
  }

  /// Write, force the day to derive again, then reload from what the engine
  /// produced — never from what this screen assumed. The re-derive catches its
  /// own throw and returns early when another one is already running, so an
  /// edit that changed nothing on disk is indistinguishable from one that
  /// worked unless the screen checks, which is what the comparison below is.
  Future<void> _edit(Future<void> Function() write,{bool expectVisibleChange=true}) async {
    if (_busy) return;
    // Read BEFORE the first await: the re-derive is the second half of every
    // edit, and reaching back through `context` for it after the write has
    // already suspended is exactly the disposed-widget case.
    final app = context.read<AppState>();
    setState(() {
      _busy = true;
      _failed = null;
    });
    final before = _d?.naps.map((n) => n['start']).toList();
    String? failed;
    try {
      await write();
      await app.reanalyzeForNapEdit();
    } on ReadPaused {
      if (mounted) failed = pausedSavingText(context);
    } catch (e) {
      failed = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    final reloaded = mounted && await _load();
    if (!mounted) return;
    final after = _d?.naps.map((n) => n['start']).toList();
    // A reload that threw left `_d` as the pre-edit list, so before == after
    // says nothing about the edit; the read-failed card covers that case.
    if (failed != null || (reloaded && expectVisibleChange && '$before' == '$after')) {
      final l = AppLocalizations.of(context);
      setState(() => _failed = failed ??
          l?.napsNotReanalysed ??
              'The day was not re-analysed because another analysis was '
              'running. Your edit is saved and applies on the next analysis.');
    }
  }

  Future<void> _remove(String day, Map<String, dynamic> nap) => _edit(() async {
        // DB edit + Health delete in one critical section, so a concurrently
        // running per-day export cannot write this nap back after the delete.
        await HealthNapExporter.shared.synchronized(() async {
        final start = nap['start'] as int, end = nap['end'] as int;
        // Their own entry is DELETED; the detector's is SUPPRESSED. Storing a
        // rejection for something the user typed would leave two rows fighting
        // over the same afternoon, and re-logging it later would land on a
        // window that is still being suppressed.
        if (nap['source'] == 'manual') {
          _must(await _repo.deleteNap(day, start));
        } else {
          _must(await _repo.putNap(
              dayId: day, startTs: start, endTs: end, source: 'rejected'));
        }
        // The window is no longer a confirmed nap, so its Apple Health
        // samples go too. A failed native delete is queued by the exporter
        // (health_nap_pending_deletes) and retried by the next per-day
        // export pass, so the false result needs no handling here.
        await HealthNapExporter.deleteExportedNap(
            startTs: start, endTs: end, dayId: day);
        });
      });

  Future<void> _restore(String day, int start) => _edit(() async {
        await HealthNapExporter.shared.synchronized(() async {
          _must(await _repo.deleteNap(day, start));
          // "Put it back" restores the row as 'confirmed' — re-export it.
          final read=await _repo.readSleepEditor(day);
          final block=read.entries.where((e)=>e.startTs==start && !e.removed).firstOrNull;
          if(block?.id case final String id) await HealthNapExporter.exportNapRow(blockId:id);
        });
      });

  /// Two pickers on the day being shown. Deliberately not a duration: people
  /// remember when they lay down and when they got up, not how long it was.
  Future<void> _log(String day) async {
    final base = DateTime.tryParse(day);
    if (base == null) return;
    final l = AppLocalizations.of(context);
    final from = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 14, minute: 0),
      helpText: l?.napsFellAsleepHelp ?? 'WHEN YOU FELL ASLEEP',
    );
    if (from == null || !mounted) return;
    final to = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: (from.hour + 1) % 24, minute: from.minute),
      helpText: l?.napsWokeUpHelp ?? 'WHEN YOU WOKE UP',
    );
    if (to == null || !mounted) return;

    final start =
        DateTime(base.year, base.month, base.day, from.hour, from.minute);
    // An end at or before the start crossed midnight. `day + 1`, not a
    // Duration: this is calendar arithmetic over a possible DST boundary.
    var end = DateTime(base.year, base.month, base.day, to.hour, to.minute);
    if (!end.isAfter(start)) {
      end = DateTime(base.year, base.month, base.day + 1, to.hour, to.minute);
    }
    final s = start.millisecondsSinceEpoch ~/ 1000;
    final e = end.millisecondsSinceEpoch ~/ 1000;

    // Both refusals are the shared rules, not a second copy written here.
    if (!manualNapWindowIsValid(s, e)) {
      setState(() => _failed = l?.napsInvalidWindow ??
          'A nap is 5 minutes to 3 hours.');
      return;
    }
    if (!manualNapWindowHasEnded(
        e, DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
      setState(() => _failed = l?.napsInFuture ??
          "That nap hasn't finished yet. Log it once you're awake.");
      return;
    }
    if (napOverlapsExisting(s, e, _d?.naps ?? const [])) {
      setState(() => _failed = l?.napsOverlap ??
          'That overlaps an existing nap.');
      return;
    }
    if (!mounted) return;
    final ownerDay=SleepOwnership.dayOf(SleepBlockKind.nap,s,e);
    await _edit(() async {
      await HealthNapExporter.shared.synchronized(() async {
        _must(await _repo.putNap(
            dayId: day, startTs: s, endTs: e, source: 'manual'));
        await HealthNapExporter.exportConfirmedNap(
            dayId: ownerDay, startTs: s, endTs: e);
      });
    },expectVisibleChange:ownerDay==day);
  }

  @override
  Widget build(BuildContext c) => DayNavigationFrame(
      selectedDay: _day ?? _d?.day ?? widget.day ?? todayLabel(),
      onSelect: _goDay, child: _content(c));

  Widget _content(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final d = _d ?? NapsData(day: _day ?? todayLabel(), days: _navDays);
    if (_loadFailed) {
      return detailScaffold(c, l?.napsTitle ?? 'Naps', [
        ...dayNavRow(_day ?? d.day, d.days, _goDay),
        StatusCard(
          l?.wellnessLoadFailedTitle ?? 'This could not be read',
          l?.wellnessLoadFailedBody ??
              'Reading your stored data failed. Nothing was deleted — this is '
                  'a read that went wrong, not missing data.',
          fix: l?.homeTryAgain ?? 'Try again',
          icon: LucideIcons.databaseZap,
          onFix: _retry,
        ),
      ], framed: true);
    }
    if (_paused) {
      return detailScaffold(c, l?.napsTitle ?? 'Naps', [
        ...dayNavRow(_day ?? d.day, d.days, _goDay),
        const Padding(
          padding: EdgeInsets.only(top: S.x4),
          child: PausedOlderDays(),
        ),
      ], framed: true);
    }
    final day = d.day;

    return detailScaffold(
      c,
      l?.napsTitle ?? 'Naps',
      [
        DayNav(day: day, days: d.days, onDay: _goDay, alwaysShow: true),
        const SizedBox(height: S.x3),
        const SizedBox(height: S.x4),
        BigButton(
          key: const ValueKey('naps-primary-action'),
          _busy
              ? (l?.napsWorking ?? 'Working…')
              : (l?.napsLogANap ?? 'Log a nap'),
          icon: LucideIcons.plus,
          color: C.domHealth,
          onTap: _busy || day == null ? null : () => _log(day),
        ),
        const SizedBox(height: S.x3),
        const NapAutoLogRow(),
        AsyncListSection<Widget>(memoryKey: 'naps:${day == todayLabel() ? 'today' : 'past'}', items: _d == null ? null : [
        if (!d.judged)
          // THE DETECTOR'S OWN REASON when it left one — 'too little 1 Hz data
          // to assess naps', 'nap detection failed for this day'. The sentence
          // below is only for a day that recorded no reason at all.
          StatusCard(
            l?.napsNoReadingTitle ?? 'No nap reading for this day',
            whyFromNote(d.note, unit: 'days') ??
                l?.napsNoReadingBody ??
                    'Not enough recording to detect naps.',
            icon: LucideIcons.circleHelp,
          )
        else if (d.naps.isEmpty)
          StatusCard(
            l?.napsEmptyTitle ?? 'No naps on this day',
            l?.napsEmptyBody ??
                'No naps detected.',
            icon: LucideIcons.sun,
          )
        else ...[
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < d.naps.length; i++) ...[
                  if (i > 0) ...[
                    const SizedBox(height: S.x3),
                    Divider(color: p.line, height: 1),
                    const SizedBox(height: S.x3),
                  ],
                  _nap(c, p, day!, d.naps[i]),
                ],
              ],
            ),
          ),
          if (d.napMin != null) ...[
            const SizedBox(height: S.x3),
            Text(
              // The number that MOVES, said plainly, because that is why the
              // edit is a recompute: these minutes come off tonight's sleep
              // need and your sleep debt one for one.
              l?.napsCountsToward(hm(d.napMin)) ??
                  "${hm(d.napMin)} of nap counts toward tonight's sleep need.",
              style: F.cap.copyWith(color: p.ink3, height: 1.5),
            ),
          ],
        ],
        if (_failed != null) ...[
          const SizedBox(height: S.x3),
          StatusCard(l?.napsNotAppliedTitle ?? 'That has not been applied',
              _failed!,
              icon: LucideIcons.triangleAlert),
        ],
        if (d.rejected.isNotEmpty) ...[
          Section(
            l?.napsRemovedSection ?? 'Removed',
            Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in d.rejected) ...[
                    Row(children: [
                      Expanded(
                        child: Text(
                          '${clockOfTs(r['start_ts'] as num)} – '
                          '${clockOfTs(r['end_ts'] as num)}',
                          style: F.body.copyWith(color: p.ink2),
                        ),
                      ),
                      Pressable(
                        onTap: _busy
                            ? null
                            : () => _restore(
                                day!, (r['start_ts'] as num).toInt()),
                        semanticLabel:
                            l?.napsPutBackSemantic ?? 'Put this nap back',
                        child: Text(l?.napsPutBackLabel ?? 'Put it back',
                            style: F.cap.copyWith(
                                color: p.on(C.blue),
                                fontWeight: FontWeight.w600)),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ],
        ], visibleRows: 3, rowHeight: 96,
          itemBuilder: (_, child) => child,
          emptyBuilder: (_) => const SizedBox.shrink()),

      ].map((child) => child is DayNav ? child : PendingContent(pending: _d == null,
        child: child)).toList(), framed: true,
    );
  }

  Widget _nap(BuildContext c, P p, String day, Map<String, dynamic> nap) {
    final l = AppLocalizations.of(c);
    final mine = nap['source'] == 'manual';
    final mins = nap['duration_min'] as int?;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: S.x1),
          child: Icon(mine ? LucideIcons.userCheck : LucideIcons.moon,
              size: 16, color: p.on(mine ? C.green : C.indigo)),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '${clockOfTs(nap['start'] as num)} – '
              '${clockOfTs(nap['end'] as num)}',
              style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: S.x1),
            Text(
              // A logged nap has no measured asleep/in-bed split, so it says
              // what it is instead of borrowing the detector's language.
              // `hm(null)` is the empty string, and a row whose only caption
              // is ' · detected' is the silent nothing this app does not do.
              mins == null
                  ? (mine
                      ? (l?.napsYouLoggedThis ?? 'You logged this')
                      : (l?.napsDetected ?? 'Detected'))
                  : (mine
                      ? (l?.napsLoggedWithMins(hm(mins)) ??
                          '${hm(mins)} · you logged this')
                      : (l?.napsDetectedWithMins(hm(mins)) ??
                          '${hm(mins)} asleep · detected')),
              style: F.cap.copyWith(color: p.ink3),
            ),
          ]),
        ),
        const SizedBox(width: S.x2),
        Pressable(
          onTap: _busy ? null : () => _remove(day, nap),
          semanticLabel: mine
              ? (l?.napsDeleteSemantic ?? 'Delete this nap')
              : (l?.napsNotANapSemantic ?? 'This was not a nap'),
          child: Text(
              mine
                  ? (l?.napsDeleteLabel ?? 'Delete')
                  : (l?.napsNotANapLabel ?? 'Not a nap'),
              style: F.cap
                  .copyWith(color: p.on(C.blue), fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }


  /// The last read threw. Shown as a retryable card: uncaught, `_d` stayed
  /// null and the screen sat on its spinner with no way out.
  bool _loadFailed = false;

  void _retry() {
    setState(() {
      _loadFailed = false;
      _d = null;
    });
    _load();
  }
}

