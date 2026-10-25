// The open breakdown owns staged decisions and pagination. Durable writes go
// through the repository batch, serialized with the existing moment service.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import '../../data/day_label.dart';
import '../../data/db.dart';
import '../../data/assumed_water.dart';
import '../activity/catalogue.dart' show activityByName;
import 'detected_activities.dart' show NapProposalEditor;
import '../../data/day_review.dart';
import '../../data/local_repository.dart';
import '../../gestures/moment_follow_ups.dart';
import '../../gestures/moment_review_queue.dart';
import '../../gestures/moment_review_service.dart';
import '../../gestures/moment_review_store.dart';
import '../../l10n/app_localizations.dart';
import '../../models/activity_suggestion.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'day_timeline.dart';
import 'home_screen.dart' show repoOf, clockOfTs;
import 'log_workout.dart' show bumpInsights, LogWorkout, WorkoutDraft;
import 'moment_follow_up.dart' show MomentReviewEditor, StagedWorkoutSink;

String _activityDay(ActivitySuggestion s) => dayLabelOf(
    DateTime.fromMillisecondsSinceEpoch(s.startTs * 1000));

/// Resolves the pending day rather than sending review entries to the newest
/// derived day, which may contain nothing waiting for an answer.
class DayReviewEntry extends StatefulWidget {
  const DayReviewEntry({super.key, this.focusId, this.moments,
      this.service, this.editor, this.activities});
  final List<ActivitySuggestion>? activities;
  final String? focusId;
  final List<PendingMoment>? moments;
  final MomentReviewService? service;
  final MomentReviewEditor? editor;
  @override
  State<DayReviewEntry> createState() => _DayReviewEntryState();
}

class _DayReviewEntryState extends State<DayReviewEntry> {
  String? _day;
  List<PendingMoment>? _moments;
  @override
  void initState() {
    super.initState();
    _open();
  }
  Future<void> _open() async {
    final repo = repoOf(context);
    var marks = widget.moments;
    var day = marks?.isNotEmpty == true ? marks!.first.date :
        widget.editor?.preloadedAssumed?.firstOrNull?.date;
    try {
      if (marks == null) {
        final g = context.read<AppState>().gestureSettings;
        final f = await MomentFollowUps.load(enabledSince:
            g.followUpMoments ? g.followUpMomentsSince : null);
        marks = f.pending(widget.editor?.now ?? DateTime.now());
        if (marks.isNotEmpty) day = marks.first.date;
        day ??= f.pendingAssumed(widget.editor?.now ?? DateTime.now()).firstOrNull?.date;
      }
      final activities = widget.activities ?? await repo?.pendingActivities() ?? [];
      final focus = activities.where((s) => s.id == widget.focusId).firstOrNull;
      day = focus == null ? day ?? (activities.isEmpty ? null : _activityDay(activities.first)) : _activityDay(focus);
      day ??= (widget.service ?? MomentReviewService.shared).queue.ranges
          .where((r) => r.inProgress).firstOrNull?.startKey.split(' ').first;
      day ??= (await repo?.availableDays())?.firstOrNull;
    } catch (_) {
      // The breakdown's queue read owns the visible retry state.
    }
    if (mounted) {
      setState(() {
        _day = day ?? todayLabel();
        _moments = marks;
      });
    }
  }
  @override
  Widget build(BuildContext c) => _day == null
      ? Scaffold(body: Center(child: Text(AppLocalizations.of(c)?.loadingActivitiesToReview ??
          'Reading activities to review')))
      : DayTimelineScreen(day: _day, focusId: widget.focusId, reviewActivities: widget.activities, reviewMoments: _moments,
          reviewService: widget.service, reviewEditor: widget.editor);
}

class DayReviewController extends ChangeNotifier {
  DayReviewController(this.repo, this.day, {MomentReviewService? service,
      this.moments, this.editor, this.enabledSince, this.activities}) : service = service ?? MomentReviewService.shared {
    _drafts.addAll(this.service.queue.decisions);
    _ranges.addAll(this.service.queue.ranges.where((r) =>
        r.startKey.startsWith('$day ')));
    for (final r in _ranges.where((r) => r.inProgress)) {
      _choices[ReviewKey.range(r)] = true;
      _choices['moment:${r.startKey}'] = true;
      _choices['moment:${r.endKey}'] = true;
    }
  }
  final List<ActivitySuggestion>? activities;
  final LocalRepository repo;
  final String day;
  final MomentReviewService service;
  final List<PendingMoment>? moments;
  final DateTime? enabledSince;
  final MomentReviewEditor? editor;
  List<ActivitySuggestion> _activities = [];
  List<PendingMoment> _marks = [];
  List<PendingMoment> _pendingMarks = [];
  List<AssumedGlass> _glasses = [];
  final List<ReviewRange> _ranges = [];
  final Map<String, ActivityDecision> _activityEdits = {};
  final Map<String, WorkoutDraft> _momentWorkouts = {};
  final Map<String, bool> _choices = {};
  final trayScroll = ScrollController();
  int savedRevision = 0;
  final Map<String, ReviewDecision> _drafts = {};
  bool loading = true, loadFailed = false, saveFailed = false;
  bool followUpFailed = false, busy = false, _disposed = false;
  int page = 0, _generation = 0;
  bool get hasChanges => _choices.isNotEmpty;
  bool get canEdit => !loading && !loadFailed && !busy;
  /// Review mode: something waits for an answer (staged or not).
  bool get reviewing => ids.isNotEmpty;
  /// Whether the tray has anything to say; false on a plain breakdown.
  bool get trayShown => !loading &&
      (reviewing || loadFailed || saveFailed || followUpFailed);
  List<String> get ids => [
    for (final s in _activities) 'activity:${s.id}',
    for (final m in _marks)
      if (!_ranges.any((r) => r.inProgress &&
          (r.startKey == m.key || r.endKey == m.key))) ReviewKey.moment(m),
    for (final r in _ranges) if (r.inProgress) ReviewKey.range(r),
    for (final g in _glasses) ReviewKey.glass(g),
  ];
  int get pages => (ids.length + 2) ~/ 3;
  List<String> get pageIds => ids.skip(page * 3).take(3).toList();
  bool needsReview(String id) => ids.contains(id);
  bool isStarted(String id) => _ranges.any((r) => r.inProgress &&
      (ReviewKey.range(r) == id || 'moment:${r.startKey}' == id ||
          'moment:${r.endKey}' == id));
  bool? choice(String id) => _choices[id];
  @override
  void dispose() { trayScroll.dispose(); _disposed = true; _generation++; super.dispose(); }
  void _changed() { if (!_disposed) notifyListeners(); }

  Future<void> load() async {
    final generation = ++_generation;
    loading = true;
    loadFailed = false;
    _changed();
    try {
      final activities = this.activities ?? await repo.pendingActivities();
      // Supplied marks passed the setting/window policy, but their answered
      // state may have changed since the entry opened.
      final now = editor?.now ?? DateTime.now();
      final f = moments == null || editor?.preloadedAssumed == null
          ? await MomentFollowUps.load(enabledSince: enabledSince, now: now) : null;
      final dates = [for (final m in moments ?? const <PendingMoment>[]) m.date]..sort();
      // An empty snapshot has no answered state to refresh. Activity-only
      // review must not depend on a separate moment-label read.
      final answered = dates.isEmpty ? const <String>{} : {
        for (final l in await LocalDb.momentLabels(
            sinceDate: dates.first)) l.key,
      };
      final marks = {for (final m in moments ?? f!.pending(now))
        if (!answered.contains(m.key)) m.key: m}.values.toList();
      final glasses = editor?.preloadedAssumed ?? f!.pendingAssumed(now);
      if (_disposed || generation != _generation) return;
      _activities = activities.where((s) => _activityDay(s) == day).toList();
      _activityEdits.removeWhere((id, edit) => !_activities.any((s) =>
          'activity:${s.id}' == id && s.revision == edit.suggestion.revision));
      _marks = marks.where((m) => m.date == day).toList();
      _pendingMarks = marks;
      _glasses = glasses.where((g) => g.date == day).toList();
      page = page.clamp(0, pages > 0 ? pages - 1 : 0);
    } catch (_) {
      if (!_disposed && generation == _generation) loadFailed = true;
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        _changed();
      }
    }
  }

  String title(BuildContext c, String id) {
    final l = AppLocalizations.of(c);
    if (id.startsWith('range:')) {
      return _ranges.singleWhere((r) => ReviewKey.range(r) == id).choice.localized(l);
    }
    if (id.startsWith('activity:')) {
      final s = _activities.singleWhere((s) => 'activity:${s.id}' == id);
      return s.kind == ActivityKind.nap
          ? (l?.activityPossibleNap ?? 'Possible nap')
          : (l?.activityPossibleWorkout ?? 'Possible workout');
    }
    if (ReviewKey.isGlass(id)) return MomentChoice.water.localized(l);
    final draft = _drafts[id];
    return draft?.choice?.localized(l) ??
        (l?.dayReviewMarkedMoment ?? 'Marked moment');
  }
  /// The line under a list row's title: the row already carries the clock, so
  /// nothing here repeats a time it shows.
  String listDetail(BuildContext c, String id) {
    final l = AppLocalizations.of(c);
    if (id.startsWith('activity:')) {
      final s = _activities.singleWhere((s) => 'activity:${s.id}' == id);
      final edit = _activityEdits[id];
      final minutes = ((edit?.endTs ?? s.endTs) - (edit?.startTs ?? s.startTs)) ~/ 60;
      return l?.activityLengthMinutes(minutes) ?? '$minutes min';
    }
    if (id.startsWith('range:') || ReviewKey.isGlass(id)) return '';
    return _drafts[id]?.note ?? '';
  }
  String detail(BuildContext c, String id) {
    final l = AppLocalizations.of(c);
    if (id.startsWith('range:')) {
      final r = _ranges.singleWhere((r) => ReviewKey.range(r) == id);
      return '${r.startKey} – ${r.endKey}';
    }
    if (id.startsWith('activity:')) {
      final s = _activities.singleWhere((s) => 'activity:${s.id}' == id);
      final edit = _activityEdits[id];
      final minutes = ((edit?.endTs ?? s.endTs) - (edit?.startTs ?? s.startTs)) ~/ 60;
      return '${clockOfTs(edit?.startTs ?? s.startTs)} – ${clockOfTs(edit?.endTs ?? s.endTs)} · '
          '${l?.activityLengthMinutes(minutes) ?? '$minutes min'}';
    }
    if (ReviewKey.isGlass(id)) {
      return _glasses.singleWhere((g) => ReviewKey.glass(g) == id).hhmm;
    }
    final m = _marks.singleWhere((m) => ReviewKey.moment(m) == id);
    return [m.hhmm, ?_drafts[id]?.note].join(' · ');
  }
  List<({String id, Moment moment})> pendingRows(BuildContext c) => [
    for (final r in _ranges)
      if (r.inProgress && r.startSec != null)
        (id: ReviewKey.range(r), moment: Moment(at: r.startSec!,
            title: r.choice.localized(AppLocalizations.of(c)),
            detail: '', icon: LucideIcons.link,
            color: C.domMind)),
    for (final s in _activities)
      (id: 'activity:${s.id}', moment: Moment(at: _activityEdits['activity:${s.id}']?.startTs ?? s.startTs,
          title: title(c, 'activity:${s.id}'), detail: listDetail(c, 'activity:${s.id}'),
          icon: s.kind == ActivityKind.nap ? LucideIcons.moon : LucideIcons.activity,
          color: C.domMove)),
    for (final m in _marks)
      (id: ReviewKey.moment(m), moment: Moment(at: m.sec,
          title: title(c, ReviewKey.moment(m)), detail: listDetail(c, ReviewKey.moment(m)),
          icon: LucideIcons.bookmark, color: C.domMind)),
    for (final g in _glasses)
      (id: ReviewKey.glass(g), moment: Moment(
          at: g.local.millisecondsSinceEpoch ~/ 1000,
          title: title(c, ReviewKey.glass(g)), detail: '',
          icon: LucideIcons.droplet, color: C.blue)),
  ];
  void choose(String id, bool keep) {
    if (!canEdit || !needsReview(id)) return;
    if (id.startsWith('range:')) {
      if (!keep) return;
      final r = _ranges.singleWhere((r) => ReviewKey.range(r) == id);
      if (_choices[id] == true) {
        _choices.remove(id);
        _choices.remove('moment:${r.startKey}');
        _choices.remove('moment:${r.endKey}');
      } else {
        _choices[id] = true;
        _choices['moment:${r.startKey}'] = true;
        _choices['moment:${r.endKey}'] = true;
      }
      saveFailed = false;
      _changed();
      return;
    }
    final undo = _choices[id] == keep;
    if (ReviewKey.isMoment(id)) {
      final pairs = _ranges.where((r) => r.startKey == ReviewKey.plainOf(id) ||
          r.endKey == ReviewKey.plainOf(id)).toList();
      for (final pair in pairs) {
        _ranges.remove(pair);
        _choices.remove('moment:${pair.startKey}');
        _choices.remove('moment:${pair.endKey}');
      }
    }
    if (undo) { _choices.remove(id); } else { _choices[id] = keep; }
    saveFailed = false;
    _changed();
  }
  /// Brings [id] up in the tray (a tap on its list row).
  void showInTray(String id) {
    final at = ids.indexOf(id);
    if (at < 0) return;
    page = at ~/ 3;
    if (trayScroll.hasClients) trayScroll.jumpTo(0);
    _changed();
  }
  void move(int delta) {
    if (!canEdit) return;
    page = (page + delta).clamp(0, pages > 0 ? pages - 1 : 0);
    if (trayScroll.hasClients) trayScroll.jumpTo(0);
    _changed();
  }
  Future<void> discardDraft() async {
    final touched = _choices.keys.where(ReviewKey.isMoment).toList();
    await service.edit((q) {
      for (final id in touched) { q = q.without(id); }
      return q;
    });
    _choices.clear();
  }
  Future<void> editActivity(BuildContext c, String id) async {
    if (!canEdit) return;
    final s = _activities.singleWhere((s) => 'activity:${s.id}' == id);
    ActivityDecision? edit;
    if (s.kind == ActivityKind.nap) {
      final window = await Navigator.of(c).push<(int, int)>(MaterialPageRoute(
          builder: (_) => NapProposalEditor(suggestion: s, stageOnly: true)));
      if (window != null) {
        edit = ActivityDecision(s, keep: true,
            startTs: window.$1, endTs: window.$2);
      }
    } else {
      final window = await Navigator.of(c).push<WorkoutDraft>(MaterialPageRoute(
          builder: (_) => LogWorkout(suggestion: s, stageOnly: true,
            start: DateTime.fromMillisecondsSinceEpoch(s.startTs * 1000),
            end: DateTime.fromMillisecondsSinceEpoch(s.endTs * 1000),
            activity: activityByName(s.sport))));
      if (window != null) {
        edit = ActivityDecision(s, keep: true,
            startTs: window.startTs, endTs: window.endTs, workoutType: window.type);
      }
    }
    if (_disposed || edit == null) return;
    _activityEdits[id] = edit;
    _choices[id] = true;
    _changed();
  }
  Future<void> editMoment(BuildContext c, String id) async {
    if (!canEdit) return;
    final paired = {for (final r in _ranges)
      ...['moment:${r.startKey}', 'moment:${r.endKey}']};
    final scope = {
      for (final m in _pendingMarks) ReviewKey.moment(m),
      for (final g in _glasses) ReviewKey.glass(g),
      for (final r in _ranges) ...[ReviewKey.range(r),
        'moment:${r.startKey}', 'moment:${r.endKey}'],
    };
    final local = MomentReviewService(store: _DraftStore(MomentReviewQueue(
        decisions: {for (final key in scope)
          if ((ReviewKey.isMoment(key) || ReviewKey.isGlass(key)) &&
              !paired.contains(key) &&
              (_drafts.containsKey(key) || _choices.containsKey(key)))
            key: _choices[key] == false
                ? (ReviewKey.isGlass(key) ? const ReviewDecision.removeGlass() :
                    const ReviewDecision.skip())
                : _drafts[key] ?? (ReviewKey.isGlass(key)
                    ? const ReviewDecision.keepGlass() :
                    const ReviewDecision.label(MomentChoice.other))},
        ranges: List.of(_ranges))));
    final workoutDrafts = _StagedWorkouts();
    try {
      final result = await Navigator.of(c).push<MomentReviewQueue>(
        MaterialPageRoute(builder: (_) => MomentReviewEditor(
          preloaded: _pendingMarks, preloadedAssumed: _glasses, service: local,
          writer: editor?.writer ?? const MomentAnswerWriter(),
          now: editor?.now, stageOnly: true,
          stagedWorkouts: workoutDrafts,
        ))) ?? local.queue;
      if (_disposed) return;
      // Back hands the local queue to the batch too. Replacing its whole
      // scope also carries Undo, including an entirely empty editor queue.
      _drafts.removeWhere((key, _) => scope.contains(key));
      _choices.removeWhere((key, _) => scope.contains(key));
      _momentWorkouts.removeWhere((key, _) => scope.contains(key) &&
          result.decisions[key]?.choice != MomentChoice.workout);
      _momentWorkouts.addAll(workoutDrafts.drafts);
      _ranges..clear()..addAll(result.ranges);
      for (final r in _ranges) {
        _choices['moment:${r.startKey}'] = true;
        _choices['moment:${r.endKey}'] = true;
      }
      for (final e in result.decisions.entries) {
        _drafts[e.key] = e.value;
        _choices[e.key] = e.value.kind != ReviewDecisionKind.skip &&
            e.value.kind != ReviewDecisionKind.removeGlass;
      }
      _changed();
    } finally {
      local.dispose();
    }
  }
  Future<void> save(BuildContext c) async {
    if (!canEdit || !hasChanges) return;
    busy = true;
    saveFailed = false;
    _changed();
    final staged = Map.of(_choices);
    final selectedRanges = _ranges.where((r) =>
        staged['moment:${r.startKey}'] == true &&
        staged['moment:${r.endKey}'] == true).toList();
    final applied = <String, ReviewDecision>{};
    final marks = <MomentDecision>[];
    for (final m in _pendingMarks) {
      final id = ReviewKey.moment(m), keep = staged[ReviewKey.moment(m)];
      if (keep == null || selectedRanges.any((r) =>
          r.startKey == m.key || r.endKey == m.key)) {
        continue;
      }
      final decision = keep ? (_drafts[id] ??
          const ReviewDecision.label(MomentChoice.other)) : const ReviewDecision.skip();
      applied[id] = decision;
      marks.add(MomentDecision(m, decision));
    }
    try {
      final receipt = await service.commitDay(_SaveDay(repo,
        activities: [for (final s in _activities)
          if (staged['activity:${s.id}'] case final keep?)
            keep ? (_activityEdits['activity:${s.id}'] ?? ActivityDecision(s,
                keep: true, workoutType: activityByName(s.sport)?.typeKey ?? 'other'))
              : ActivityDecision(s, keep: false)],
        moments: marks, ranges: selectedRanges,
        workouts: [for (final m in marks)
          if (m.decision.choice == MomentChoice.workout &&
              _momentWorkouts.containsKey(ReviewKey.moment(m.moment)))
            MomentWorkoutDecision(m.moment, _momentWorkouts[ReviewKey.moment(m.moment)]!)],
        glasses: {for (final g in _glasses)
          g: ?staged[ReviewKey.glass(g)]},
      ), {
        ...applied.keys,
        for (final r in selectedRanges) ...['moment:${r.startKey}', 'moment:${r.endKey}'],
        for (final g in _glasses)
          if (staged.containsKey(ReviewKey.glass(g))) ReviewKey.glass(g),
      });
      if (_disposed) return;
      followUpFailed = receipt.followUpFailed;
      _activities.removeWhere((s) => staged.containsKey('activity:${s.id}'));
      _marks.removeWhere((m) => staged.containsKey(ReviewKey.moment(m)));
      _pendingMarks.removeWhere((m) => staged.containsKey(ReviewKey.moment(m)));
      _glasses.removeWhere((g) => staged.containsKey(ReviewKey.glass(g)));
      _ranges.removeWhere(selectedRanges.contains);
      _drafts.removeWhere((key, _) => staged.containsKey(key));
      _choices.clear();
      savedRevision++;
      page = 0;
      if (c.mounted) bumpInsights(c);
    } catch (error) {
      if (error is ActivityReviewException && !_disposed) await load();
      if (!_disposed) {
        saveFailed = true;
        if (trayScroll.hasClients) trayScroll.jumpTo(0);
      }
    } finally {
      busy = false;
      _changed();
    }
  }
}

/// The day's staged decisions as one repository write, for commitDay.
class _SaveDay implements DayCommit<DayReviewReceipt> {
  _SaveDay(this.repo, {required this.activities, required this.moments,
      required this.ranges, required this.workouts, required this.glasses});
  final LocalRepository repo;
  final List<ActivityDecision> activities;
  final List<MomentDecision> moments;
  final List<ReviewRange> ranges;
  final List<MomentWorkoutDecision> workouts;
  final Map<AssumedGlass, bool> glasses;
  @override
  Future<DayReviewReceipt> commit() => repo.saveDayReview(activities: activities,
      moments: moments, ranges: ranges, workouts: workouts, glasses: glasses);
}

class _StagedWorkouts implements StagedWorkoutSink {
  final drafts = <String, WorkoutDraft>{};
  @override
  void stagedWorkout(PendingMoment moment, WorkoutDraft draft) =>
      drafts[ReviewKey.moment(moment)] = draft;
}

class _DraftStore extends MomentReviewStore {
  _DraftStore(this.queue);
  MomentReviewQueue queue;
  @override
  MomentReviewQueue load() => queue;
  @override
  Future<bool> save(MomentReviewQueue q) async { queue = q; return true; }
}

/// One semantics node per action, including disabled and selected state. A
/// labelled button is a dense [BigButton]: filled when [selected], soft
/// otherwise, dimmed when it cannot be pressed. With [icon] it is bare (pager).
Widget reviewButton(BuildContext c, String key, String label, VoidCallback? tap,
    {bool selected = false, Widget? icon, IconData? glyph,
    Color color = C.blue, bool primary = false}) => Semantics(
  key: ValueKey(key), button: true, enabled: tap != null, selected: selected,
  label: label, onTap: tap, excludeSemantics: true,
  child: icon != null
      ? Pressable(onTap: tap, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: S.x2), child: icon))
      : Opacity(opacity: tap == null ? .4 : 1, child: BigButton(label,
          dense: !primary, icon: glyph, color: color,
          soft: !primary && !selected, onTap: tap)),
);

/// What a list row says about its review: still to do, or the staged answer.
/// Nothing for a row that needs no review. The tray holds the controls.
class DayReviewRowState extends StatelessWidget {
  const DayReviewRowState({super.key, required this.controller, required this.id});
  final DayReviewController? controller;
  final String id;
  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c), r = controller;
    if (r == null || r.loading) return const SizedBox.shrink();
    final keep = r.choice(id);
    final pill = keep == true
        ? Pill(l?.assumedWaterKeep ?? 'Keep', C.green, icon: LucideIcons.check)
        : keep == false
            ? Pill(l?.dayReviewDiscard ?? 'Discard', C.red, icon: LucideIcons.x)
            : r.needsReview(id)
                ? Pill(l?.dayReviewPending ?? 'To review', C.orange,
                    icon: LucideIcons.circleDot)
                : null;
    if (pill == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: S.x3),
      child: KeyedSubtree(key: ValueKey('apk2-day-state:$id'), child: pill));
  }
}

/// The tray's controls for one item: Keep, Discard and Edit where they apply.
class DayReviewActions extends StatelessWidget {
  const DayReviewActions({super.key, required this.controller, required this.id});
  final DayReviewController? controller;
  final String id;
  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c), r = controller;
    final enabled = r?.needsReview(id) == true && r?.canEdit == true;
    final range = id.startsWith('range:');
    final edit = !ReviewKey.isGlass(id) && !range;
    Widget slot(Widget w) => Expanded(child: Padding(
        padding: const EdgeInsets.only(right: S.x2), child: w));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        slot(reviewButton(c, 'apk2-review-keep:$id',
          l?.assumedWaterKeep ?? 'Keep', enabled ? () => r!.choose(id, true) : null,
          selected: r?.choice(id) == true, glyph: LucideIcons.check,
          color: C.green)),
        if (!range)
          slot(reviewButton(c, 'apk2-review-discard:$id',
            l?.dayReviewDiscard ?? 'Discard',
            enabled ? () => r!.choose(id, false) : null,
            selected: r?.choice(id) == false, glyph: LucideIcons.x,
            color: C.red)),
        if (edit)
          slot(reviewButton(c, 'day-review-label:$id', l?.activityEdit ?? 'Edit',
              enabled ? () => id.startsWith('activity:')
                  ? r!.editActivity(c, id) : r!.editMoment(c, id) : null,
              glyph: LucideIcons.pencil)),
      ]),
      if (r?.isStarted(id) == true)
        Padding(padding: const EdgeInsets.only(top: S.x1),
          child: Text(l?.momentReviewResume ??
              'Saved so far. Press Save to finish this pair.',
            key: ValueKey('apk2-day-review-reason:$id'),
            style: F.cap.copyWith(color: P.of(c).ink2))),
    ]);
  }
}

class DayReviewTray extends StatelessWidget {
  const DayReviewTray({super.key, this.controller, this.maxHeight = 420});
  final DayReviewController? controller;
  /// The tray is as tall as its content, up to this; its items then scroll.
  final double maxHeight;
  @override
  Widget build(BuildContext c) {
    final p = P.of(c), r = controller;
    final l = AppLocalizations.of(c);
    final page = r == null || r.pages == 0 ? 0 : r.page + 1;
    final pages = r?.pages ?? 0;
    final items = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (r?.saveFailed == true)
          Text(l?.momentFollowUpSaveFailed ?? 'Could not save that answer. Try again.',
            key: const ValueKey('apk2-review-save-error'),
            style: F.cap.copyWith(color: p.ink)),
        if (r == null || r.loading)
          Text(l?.loadingActivitiesToReview ?? 'Reading activities to review',
              style: F.cap.copyWith(color: p.ink2))
        else if (r.loadFailed) ...[
          Text(l?.activityLoadFailed ?? 'Could not load activities. Try again.',
            key: const ValueKey('apk2-review-load-error'),
            style: F.cap.copyWith(color: p.ink)),
          reviewButton(c, 'apk2-review-retry', l?.homeTryAgain ?? 'Try again', r.load),
        ] else if (r.ids.isEmpty)
          Text(l?.activityNothing ?? 'Nothing to review',
            key: const ValueKey('apk2-review-empty'),
            style: F.body.copyWith(color: p.ink))
        else
          for (final id in r.pageIds)
            Container(key: ValueKey('apk2-review-item:$id'),
              padding: const EdgeInsets.symmetric(vertical: S.x2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.title(c, id), style: F.body.copyWith(
                      color: p.ink, fontWeight: FontWeight.w600)),
                  Text(r.detail(c, id), style: F.cap.copyWith(color: p.ink2)),
                  const SizedBox(height: S.x2),
                  DayReviewActions(controller: r, id: id),
                ])),
        if (r?.followUpFailed == true)
          Text(l?.dayReviewFollowUpFailed ??
              'Decisions saved. Could not refresh or export every item.',
              style: F.cap.copyWith(color: p.ink)),
      ]);
    final pager = Row(children: [
      reviewButton(c, 'apk2-review-previous', l?.dayReviewPrevious ?? 'Previous page',
        r != null && r.canEdit && r.page > 0 ? () => r.move(-1) : null,
        icon: SizedBox(height: S.tap, child: Icon(LucideIcons.chevronLeft, color: p.ink))),
      Expanded(child: Text(l?.dayReviewPage(page, pages) ?? '$page of $pages',
        key: const ValueKey('apk2-review-page'), textAlign: TextAlign.center,
        style: F.cap.copyWith(color: p.ink))),
      reviewButton(c, 'apk2-review-next', l?.dayReviewNext ?? 'Next page',
        r != null && r.canEdit && r.page + 1 < r.pages ? () => r.move(1) : null,
        icon: SizedBox(height: S.tap, child: Icon(LucideIcons.chevronRight, color: p.ink))),
    ]);
    final save = reviewButton(c, 'apk2-review-save', l?.dayReviewSave ?? 'Save',
      r != null && r.canEdit && r.hasChanges ? () => r.save(c) : null,
      primary: true, glyph: LucideIcons.save);
    return Container(
      key: const ValueKey('apk2-review-tray'),
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(color: p.card,
          border: Border(top: BorderSide(color: p.line)),
          // Upward: the tray's top edge is the one that has to read as raised.
          boxShadow: [for (final s in p.el(3)) BoxShadow(color: s.color,
              blurRadius: s.blurRadius, offset: -s.offset)]),
      padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x4, S.x3),
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${l?.dayReviewPending ?? 'To review'} · ${r?.ids.length ?? 0}',
            key: const ValueKey('apk2-review-heading'),
            style: F.over.copyWith(color: p.ink3)),
          const SizedBox(height: S.x1),
          Flexible(child: SingleChildScrollView(controller: r?.trayScroll,
              child: items)),
          pager,
          save,
        ]),
    );
  }
}
