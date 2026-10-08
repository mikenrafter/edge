// moment_follow_up.dart — the Home card and the screen behind its "Answer".
//
// A moment marked with a double tap is only a minute on a day. When the
// wearer opts in ("Follow up about my marked moments"), Home asks what each one
// was. The answer is a label shown on the day timeline; a dose answer
// (caffeine, alcohol) also lands in the journal, but ONLY with an amount the
// wearer typed — a blank amount stores the label alone. A nap never invents a
// sleep window. See gestures/moment_follow_ups.dart for where each answer goes.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../compute/manual_session.dart';
import '../../data/assumed_water.dart';
import '../../data/moment_label.dart' show momentLocalTime;
import '../../data/journal_fields.dart' show kJournalFieldsByKey;
import '../../gestures/gesture_settings.dart';
import '../../gestures/moment_follow_ups.dart';
import '../../gestures/moment_review_apply.dart';
import '../../gestures/moment_review_queue.dart';
import '../../gestures/moment_review_range.dart';
import '../../gestures/moment_review_service.dart';
import '../../platform/tasker_moment_export.dart';
import '../../gestures/symptom_description.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../theme/theme_switcher.dart' show themedRoute;
import '../ui2.dart';
import '../activity/catalogue.dart';
import 'home_screen.dart' show repoOf;
import 'journal_compose.dart' show OsTextField;
import 'log_workout.dart' show ActivityTypeSheet, LogWorkout, appOf;

/// Home card for what waits for review: one line "N marked moments", one line
/// "N assumed water" (a zero line is hidden), and an Answer button. Laid out
/// like the community cards (`_AskCard` in nudges.dart) but with no dismiss or
/// snooze: it goes away only when the answers are in. The line icons are the
/// chart annotations' own, so the card and the day chart speak one language.
class MomentFollowUpCard extends StatelessWidget {
  const MomentFollowUpCard(
      {super.key,
      required this.moments,
      required this.assumedWater,
      this.onAnswer});

  /// Pending marked moments, plus started ranges that only owe their
  /// announcement (see [MomentFollowUps.reviewCounts]).
  final int moments;

  /// Assumed water glasses waiting for keep / remove.
  final int assumedWater;
  final VoidCallback? onAnswer;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    Widget line(String key, IconData icon, Color color, String text) => Row(
          key: ValueKey('$key-row'),
          children: [
            Container(
              key: ValueKey('$key-icon'),
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration:
                  BoxDecoration(color: p.wash(color), borderRadius: R.rSm),
              child: Icon(icon, size: 16, color: p.on(color)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Text(text,
                  key: ValueKey(key),
                  style: F.body
                      .copyWith(color: p.ink, fontWeight: FontWeight.w600)),
            ),
          ],
        );
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Surface(
        key: const ValueKey('moment-follow-up-card'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (moments > 0)
              line(
                  'moment-follow-up-moments',
                  annotationIcon(AnnotationKind.moment),
                  annotationColor(AnnotationKind.moment),
                  l?.momentFollowUpMomentsLine(moments) ??
                      (moments == 1
                          ? '1 marked moment'
                          : '$moments marked moments')),
            if (moments > 0 && assumedWater > 0) const SizedBox(height: S.x3),
            if (assumedWater > 0)
              line(
                  'moment-follow-up-water',
                  annotationIcon(AnnotationKind.assumedWater),
                  annotationColor(AnnotationKind.assumedWater),
                  l?.momentFollowUpAssumedWaterLine(assumedWater) ??
                      '$assumedWater assumed water'),
            const SizedBox(height: S.x3),
            BigButton(
              l?.momentFollowUpAnswer ?? 'Answer',
              key: const ValueKey('moment-follow-up-answer'),
              icon: LucideIcons.bookmark,
              onTap: onAnswer,
            ),
          ],
        ),
      ),
    );
  }
}

/// The card, or null when the setting is off or nothing is pending. Pure.
Widget? momentFollowUpCardFor({
  required bool enabled,
  required int moments,
  required int assumedWater,
  VoidCallback? onAnswer,
}) =>
    enabled && moments + assumedWater > 0
        ? MomentFollowUpCard(
            moments: moments, assumedWater: assumedWater, onAnswer: onAnswer)
        : null;

/// Home's helper: null with no AppState above (a golden), like
/// `_naturalWakeCard`.
Widget? momentFollowUpCard(BuildContext c) {
  try {
    return _HomeMomentCard(settings: c.read<AppState>().gestureSettings);
  } on ProviderNotFoundException {
    return null;
  }
}

/// Counts the pending moments for Home. Re-reads when the setting changes, when
/// Home is built again and after the follow-up screen closes — never on a
/// timer, and a read still running is not started twice.
class _HomeMomentCard extends StatefulWidget {
  const _HomeMomentCard({required this.settings});
  final GestureSettings settings;

  @override
  State<_HomeMomentCard> createState() => _HomeMomentCardState();
}

class _HomeMomentCardState extends State<_HomeMomentCard> {
  int _moments = 0, _water = 0;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_read);
    _read();
  }

  @override
  void didUpdateWidget(_HomeMomentCard old) {
    super.didUpdateWidget(old);
    if (old.settings != widget.settings) {
      old.settings.removeListener(_read);
      widget.settings.addListener(_read);
    }
    _read();
  }

  @override
  void dispose() {
    widget.settings.removeListener(_read);
    super.dispose();
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    try {
      final g = widget.settings;
      final since = g.followUpMoments ? g.followUpMomentsSince : null;
      final f = await MomentFollowUps.load(enabledSince: since);
      // A started range with only its announcement left has no pending mark,
      // but is still waiting for Save: it counts too.
      final review = MomentReviewService.shared..reload();
      final n = f.reviewCounts(DateTime.now(), review.queue);
      if (mounted && (n.moments != _moments || n.assumedWater != _water)) {
        setState(() {
          _moments = n.moments;
          _water = n.assumedWater;
        });
      }
    } catch (_) {
      // A read that failed shows no card; it does not claim there is nothing
      // to answer, and the next read tries again.
    } finally {
      _reading = false;
    }
  }

  @override
  Widget build(BuildContext c) {
    final on = widget.settings.followUpMoments;
    return momentFollowUpCardFor(
          enabled: on,
          moments: _moments,
          assumedWater: _water,
          onAnswer: () async {
            await Navigator.of(c).push(themedRoute<void>(
                (_) => const MomentFollowUpScreen(),
                name: 'MomentFollowUpScreen'));
            unawaited(_read());
          },
        ) ??
        const SizedBox.shrink();
  }
}

/// Each pending moment with its quick choices and Skip. Choices are QUEUED:
/// each card keeps showing its pending decision (undoable) and nothing is
/// written until Save, which applies the whole queue (see
/// `gestures/moment_review_apply.dart`). The queue persists in
/// `MomentReviewStore`.
class MomentFollowUpScreen extends StatefulWidget {
  const MomentFollowUpScreen({
    super.key,
    this.preloaded,
    this.writer = const MomentAnswerWriter(),
    this.now,
    this.preloadedAssumed,
    this.assumedWriter = const AssumedWaterWriter(),
    this.service,
    this.rangeWriter,
    this.exporter,
  });

  /// Injected in tests; null reads them from the database.
  final List<PendingMoment>? preloaded;

  /// Assumed water glasses to list among the moments. Null reads them from the
  /// database.
  final List<AssumedGlass>? preloadedAssumed;
  final AssumedWaterWriter assumedWriter;
  final MomentAnswerWriter writer;
  final DateTime? now;

  /// The shared owner of the queue (edits, Saves, storage). Null is the
  /// app-wide one; tests pass their own.
  final MomentReviewService? service;

  /// Where a nap / workout range lands; null builds the real one from the
  /// app's repository and state.
  final ReviewRangeWriter? rangeWriter;

  /// The Tasker export Save feeds; null is the default `TaskerMomentExport()`.
  final TaskerMomentExport? exporter;

  @override
  State<MomentFollowUpScreen> createState() => _MomentFollowUpScreenState();
}

class _MomentFollowUpScreenState extends State<MomentFollowUpScreen> {
  List<PendingMoment>? _items;
  List<AssumedGlass> _glasses = [];
  late final MomentReviewService _svc;
  MomentReviewQueue get _queue => _svc.queue;
  bool _failed = false;
  bool _busy = false;

  /// The choice a moment is waiting on more input for (an amount, a note, or
  /// the workout options). Not yet part of the queue.
  final Map<String, MomentChoice> _open = {};
  final Map<String, TextEditingController> _text = {};
  final Map<String, _SymptomDraft> _drafts = {};

  /// Review key -> why that item was not saved by the last Save. It stays
  /// queued; editing it clears the note.
  final Map<String, Object> _itemErrors = {};

  /// Plain moment key -> why a pairing started from that card was refused.
  final Map<String, String> _pairErrors = {};

  /// Plain moment keys whose typed amount was refused.
  final Set<String> _amountErrors = {};

  void _onService() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _svc = widget.service ?? MomentReviewService.shared;
    _svc.reload();
    if (widget.preloaded != null) {
      _items = List.of(widget.preloaded!);
      _glasses = List.of(widget.preloadedAssumed ?? const []);
      _adoptQueue();
    } else {
      _load();
    }
    _svc.addListener(_onService);
  }

  @override
  void dispose() {
    _svc.removeListener(_onService);
    for (final t in _text.values) {
      t.dispose();
    }
    for (final d in _drafts.values) {
      d.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(String key) =>
      _text.putIfAbsent(key, TextEditingController.new);

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      DateTime? since;
      try {
        final g = context.read<AppState>().gestureSettings;
        since = g.followUpMoments ? g.followUpMomentsSince : null;
      } on ProviderNotFoundException {
        since = null;
      }
      final f = await MomentFollowUps.load(enabledSince: since);
      if (mounted) {
        final at = widget.now ?? DateTime.now();
        setState(() {
          _items = f.pending(at);
          _glasses = f.pendingAssumed(at);
        });
        _adoptQueue();
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Drops every stored draft whose moment or glass is no longer waiting
  /// (answered elsewhere, or older than the window). A range Save already
  /// started is kept: it is finished, not dropped.
  void _adoptQueue() {
    final pending = {
      for (final m in _items ?? const <PendingMoment>[]) ReviewKey.moment(m),
      for (final g in _glasses) ReviewKey.glass(g),
    };
    unawaited(_svc.adopt(pending));
  }

  /// Edit the shared queue (it persists at once, a kill must not lose it) and
  /// clear the failure / pairing notes of [touched] review keys.
  void _edit(MomentReviewQueue Function(MomentReviewQueue q) f,
      {Iterable<String> touched = const []}) {
    setState(() {
      for (final k in touched) {
        _itemErrors.remove(k);
        if (ReviewKey.isMoment(k)) {
          final plain = ReviewKey.plainOf(k);
          _pairErrors.remove(plain);
          _amountErrors.remove(plain);
          final r = _queue.rangeOf(plain);
          if (r != null) _itemErrors.remove(ReviewKey.range(r));
        }
      }
    });
    unawaited(_svc.edit(f));
  }

  void _queueMoment(PendingMoment m, ReviewDecision d) {
    final k = ReviewKey.moment(m);
    setState(() => _open.remove(m.key));
    _edit((q) => q.withDecision(k, d), touched: [k]);
  }

  void _queueGlass(AssumedGlass g, ReviewDecision d) {
    final k = ReviewKey.glass(g);
    _edit((q) => q.withDecision(k, d), touched: [k]);
  }

  void _undoMoment(PendingMoment m) {
    final k = ReviewKey.moment(m);
    // A range Save has started cannot be taken back (its window is saved): it
    // can only be finished.
    if (_queue.rangeOf(m.key)?.inProgress == true) return;
    setState(() => _open.remove(m.key));
    _edit((q) => q.without(k), touched: [k]);
  }

  void _choose(PendingMoment m, MomentChoice c) {
    // Water is one tap, one glass: it asks for nothing.
    final needsMore =
        (c.journalField != null && c != MomentChoice.water) ||
        c == MomentChoice.other ||
        c == MomentChoice.symptom ||
        c == MomentChoice.workout;
    if (needsMore) {
      _field(m.key).clear();
      if (c == MomentChoice.symptom) _drafts[m.key] ??= _SymptomDraft();
      setState(() => _open[m.key] = c);
      return;
    }
    _queueMoment(m, ReviewDecision.label(c));
  }

  /// "Done" on the amount / note / symptom form: queue it.
  void _confirm(PendingMoment m, MomentChoice c) {
    if (c == MomentChoice.symptom) {
      // Nothing is queued until severity, kind and area are said; a half
      // description is never stored.
      final d = _drafts[m.key]?.build();
      if (d == null) return;
      _queueMoment(m, ReviewDecision.symptom(d));
      return;
    }
    final raw = _field(m.key).text.trim();
    if (c == MomentChoice.other) {
      _queueMoment(
          m, ReviewDecision.label(c, note: raw.isEmpty ? null : raw));
      return;
    }
    // A number only when one was typed; text that is not a number is no amount,
    // never a guessed one. A number that cannot be used (not finite, zero or
    // negative, above the field's maximum) is refused here, where it can still
    // be fixed, rather than failing at Save.
    final v = double.tryParse(raw.replaceAll(',', '.'));
    final max = c.journalField == null
        ? null
        : kJournalFieldsByKey[c.journalField]?.max;
    if (v != null && (!v.isFinite || v <= 0 || (max != null && v > max))) {
      setState(() => _amountErrors.add(m.key));
      return;
    }
    _queueMoment(m, ReviewDecision.label(c, value: v));
  }

  /// The "Log a workout at this time" form saves a workout on its own, so the
  /// moment is answered right away (it is not part of the queue).
  Future<void> _logWorkout(PendingMoment m) async {
    final now = widget.now ?? DateTime.now();
    final w = workoutPrefillFor(m, now);
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      builder: (_) => LogWorkout(start: w.start, end: w.end, now: widget.now),
    ));
    if (saved != true || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      // Through the queue owner, in its one critical section with Saves.
      await _svc.answerDirect(
          m, () => widget.writer.answer(m, MomentChoice.workout, now: now));
      if (!mounted) return;
      _open.remove(m.key);
      _items?.removeWhere((x) => x.key == m.key);
      setState(() {
        _itemErrors.remove(ReviewKey.moment(m));
        _pairErrors.remove(m.key);
      });
    } catch (_) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l?.momentFollowUpSaveFailed ??
              'Could not save that answer. Try again.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  ReviewRangeWriter _rangeWriter() =>
      widget.rangeWriter ??
      ReviewRangeWriter(repo: repoOf(context), app: appOf(context));

  /// The choice a card is working on: the open form, else the queued label.
  MomentChoice? _effectiveChoice(PendingMoment m) =>
      _open[m.key] ?? _queue.decisionFor(ReviewKey.moment(m))?.choice;

  Future<void> _pair(PendingMoment m) async {
    final choice = _effectiveChoice(m);
    if (choice == null || !isRangeChoice(choice)) return;
    final candidates = [
      for (final o in _items ?? const <PendingMoment>[])
        if (o.key != m.key &&
            !o.ambiguous &&
            _queue.decisionFor(ReviewKey.moment(o)) == null &&
            _queue.rangeOf(o.key) == null)
          o,
    ];
    final picked = await showModalBottomSheet<({PendingMoment other, String type})>(
      context: context,
      isScrollControlled: true,
      // Up to most of the screen; the candidates scroll inside it.
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      backgroundColor: P.of(context).card,
      shape: const RoundedRectangleBorder(borderRadius: R.rXl),
      builder: (_) => _PairSheet(
          moment: m, candidates: candidates, workout: choice == MomentChoice.workout),
    );
    if (picked == null || !mounted) return;
    final first = m.sec > picked.other.sec ? picked.other : m;
    final second = identical(first, m) ? picked.other : m;
    final l = AppLocalizations.of(context);
    final writer = _rangeWriter();
    String? refusal;
    try {
      final err = await checkReviewRange(writer,
          choice: choice,
          start: first.local,
          end: second.local,
          now: widget.now ?? DateTime.now());
      if (err != null) refusal = _rangeMessage(l, choice, err);
    } catch (_) {
      refusal = l?.momentReviewRangeCheckFailed ??
          'Could not check this pair. Try again.';
    }
    if (!mounted) return;
    if (refusal != null) {
      setState(() => _pairErrors[m.key] = refusal!);
      return;
    }
    setState(() {
      _open.remove(m.key);
      _open.remove(picked.other.key);
    });
    _edit(
        (q) => q.withRange(m, picked.other, choice,
            workoutType: picked.type == 'other' ? null : picked.type),
        touched: [ReviewKey.moment(m), ReviewKey.moment(picked.other)]);
  }

  Future<void> _save() async {
    if (_busy || _queue.isEmpty) return;
    setState(() => _busy = true);
    ReviewSaveReport? report;
    try {
      final applier = MomentReviewApplier(
          writer: widget.writer,
          assumedWriter: widget.assumedWriter,
          ranges: _rangeWriter(),
          exporter: widget.exporter);
      // Through the shared owner: it runs after any Save already running, on
      // the queue as it is then, and merges the outcome into the queue as it is
      // when it ends (a newer screen's drafts are never overwritten).
      report = await _svc.save(applier,
          moments: List.of(_items ?? const []),
          glasses: List.of(_glasses),
          now: widget.now ?? DateTime.now());
    } catch (_) {
      report = null; // the applier reports per item; this is a surprise
    } finally {
      // Never left set, whatever happened above.
      if (mounted) _busy = false;
    }
    if (!mounted) return;
    setState(() {
      if (report == null) {
        final l = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(l?.momentFollowUpSaveFailed ??
                'Could not save that answer. Try again.')));
        return;
      }
      _itemErrors
        ..clear()
        ..addAll(report.failed);
      for (final key in [...report.applied, ...report.alreadyAnswered]) {
        if (key.startsWith('range:')) {
          final r = key.substring('range:'.length).split('|');
          for (final k in r) {
            _items?.removeWhere((x) => x.key == k);
            _open.remove(k);
          }
        } else if (ReviewKey.isMoment(key)) {
          _items?.removeWhere((x) => x.key == ReviewKey.plainOf(key));
          _open.remove(ReviewKey.plainOf(key));
        } else {
          _glasses.removeWhere((g) => ReviewKey.glass(g) == key);
        }
      }
    });
  }

  String _rangeMessage(AppLocalizations? l, MomentChoice c, ManualWindowError e) {
    final nap = c == MomentChoice.nap;
    return switch (e) {
      ManualWindowError.endNotAfterStart => l?.momentReviewRangeEnd ??
          'The end has to be after the start.',
      ManualWindowError.tooShort || ManualWindowError.tooLong => nap
          ? (l?.napsInvalidWindow ??
              'A nap must be between 5 minutes and 6 hours. Longer periods '
                  'count as night sleep, which shows sleep stages.')
          : (l?.momentReviewRangeWorkoutLength ??
              'A workout has to last between 1 minute and 24 hours.'),
      ManualWindowError.inFuture => l?.momentReviewRangeFuture ??
          "A range can't end in the future.",
      ManualWindowError.overlapsExisting => nap
          ? (l?.napsOverlap ??
              'This overlaps a nap already logged on this day. Remove that '
                  'nap first.')
          : (l?.momentReviewRangeWorkoutOverlap ??
              'That overlaps a workout already in your log.'),
    };
  }

  String _failureText(AppLocalizations? l, Object? error, MomentChoice? c) {
    if (error is ManualWindowException) {
      return _rangeMessage(l, c ?? MomentChoice.nap, error.error);
    }
    if (error is ProgressNotPersistedException) {
      return l?.momentReviewProgressNotSaved ??
          'Could not record progress on this pair, so it was stopped. Press '
              'Save to try again.';
    }
    if (error is AmbiguousMarkException) {
      return l?.momentReviewAmbiguous ??
          'This time came round twice when the clocks went back, so it cannot '
              'be paired with another mark.';
    }
    return l?.momentReviewItemFailed ??
        'Not saved. It is still queued — press Save to try again.';
  }

  /// What a queued decision will do, for the card ("Caffeine · 80 mg").
  String _what(AppLocalizations? l, ReviewDecision d) {
    switch (d.kind) {
      case ReviewDecisionKind.skip:
        return l?.momentFollowUpSkip ?? 'Skip';
      case ReviewDecisionKind.symptom:
        return d.symptom!.describe(l);
      case ReviewDecisionKind.keepGlass:
        return l?.assumedWaterKeep ?? 'Keep';
      case ReviewDecisionKind.removeGlass:
        return l?.assumedWaterRemove ?? 'Remove';
      case ReviewDecisionKind.label:
        final c = d.choice!;
        final parts = [c.localized(l)];
        final v = d.value;
        if (v != null) {
          final unit = c.journalField == null
              ? null
              : kJournalFieldsByKey[c.journalField]?.unit;
          final num_ = v == v.roundToDouble() ? v.round().toString() : '$v';
          parts.add(unit == null ? num_ : '$num_ $unit');
        }
        if (d.note != null && d.note!.isNotEmpty) parts.add(d.note!);
        return parts.join(' · ');
    }
  }

  String _pending(AppLocalizations? l, ReviewDecision d) {
    final what = _what(l, d);
    return l?.momentReviewPending(what) ?? 'Will save: $what';
  }

  String _rangeText(AppLocalizations? l, ReviewRange r) {
    final s = momentLocalTime(
        r.startKey.split(' ').first, r.startKey.split(' ').last)!;
    final e = momentLocalTime(
        r.endKey.split(' ').first, r.endKey.split(' ').last)!;
    final sameDay = s.year == e.year && s.month == e.month && s.day == e.day;
    final endLabel =
        sameDay ? r.endKey.split(' ').last : r.endKey;
    var what = r.choice.localized(l);
    final t = r.workoutType;
    if (t != null && t != 'other') {
      what = '$what (${_activityName(l, t)})';
    }
    final start = r.startKey.split(' ').last;
    return l?.momentReviewRange(what, start, endLabel) ??
        '$what: $start to $endLabel';
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final items = _items;
    final orphans = items == null
        ? const <ReviewRange>[]
        : _queue.orphanRanges({for (final m in items) m.key});
    final nothingLeft =
        items != null && items.isEmpty && _glasses.isEmpty && orphans.isEmpty;
    final showSave = !_failed && items != null && !nothingLeft;
    final n = _queue.length;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l?.momentFollowUpTitle ?? 'Marked moments',
                sub: l?.momentFollowUpSub ?? 'FOLLOW UP',
                onBack: () => Navigator.of(c).maybePop()),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x6),
              children: [
                if (_failed)
                  StatusCard(
                    l?.logWorkoutReadFailedTitle ?? 'Could not read your moments',
                    l?.logWorkoutReadFailedBody ??
                        'The local database did not respond. Nothing was changed.',
                    fix: l?.logWorkoutTryAgain ?? 'Try again',
                    icon: LucideIcons.refreshCw,
                    onFix: _load,
                  )
                else if (items == null)
                  const NoData(message: '…')
                else if (nothingLeft)
                  KeyedSubtree(
                    key: const ValueKey('moment-follow-up-empty'),
                    child: StatusCard(
                      l?.momentFollowUpEmptyTitle ?? 'Nothing to follow up on',
                      l?.momentFollowUpEmptyBody ??
                          'Moments you mark show up here until you answer them or a '
                              'week goes by.',
                      icon: LucideIcons.circleCheck,
                    ),
                  )
                else ...[
                  if (_svc.persistFailed)
                    Padding(
                      key: const ValueKey('moment-persist-failed'),
                      padding: const EdgeInsets.only(bottom: S.x3),
                      child: Text(
                          l?.momentReviewPersistFailed ??
                              'Could not store your choices on this phone. '
                                  'They are kept while the app is open but may '
                                  'be lost if it closes.',
                          style: F.cap.copyWith(color: p.ink)),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: S.x3),
                    child: Text(
                        l?.momentReviewHint ??
                            'Your choices are queued. Nothing is saved until '
                                'you press Save.',
                        style: F.cap.copyWith(color: p.ink2)),
                  ),
                  for (final e in _chronological(items, _glasses)) ...[
                    if (e.glass case final g?)
                      _AssumedRow(
                        key: ValueKey('assumed-water:${g.key}'),
                        glass: g,
                        busy: _busy,
                        pending: _queue.decisionFor(ReviewKey.glass(g)) == null
                            ? null
                            : _pending(l, _queue.decisionFor(ReviewKey.glass(g))!),
                        failure: _itemErrors.containsKey(ReviewKey.glass(g))
                            ? _failureText(l, _itemErrors[ReviewKey.glass(g)], null)
                            : null,
                        onKeep: () => _queueGlass(g, const ReviewDecision.keepGlass()),
                        onRemove: () =>
                            _queueGlass(g, const ReviewDecision.removeGlass()),
                        onUndo: () => _edit((q) => q.without(ReviewKey.glass(g)),
                            touched: [ReviewKey.glass(g)]),
                      )
                    else if (e.moment case final m?)
                      _momentRow(c, l, m),
                    const SizedBox(height: S.x3),
                  ],
                  // Started ranges with nothing left to answer: only their
                  // announcement is owed. Save is what finishes them.
                  for (final r in orphans) ...[
                    _OrphanRangeCard(
                      key: ValueKey('moment-range-orphan:${r.startKey}|${r.endKey}'),
                      text: _rangeText(l, r),
                      note: _itemErrors.containsKey(ReviewKey.range(r))
                          ? _failureText(
                              l, _itemErrors[ReviewKey.range(r)], r.choice)
                          : (l?.momentReviewResume ??
                              'Saved so far. Press Save to finish this pair.'),
                    ),
                    const SizedBox(height: S.x3),
                  ],
                ],
              ],
            ),
          ),
          if (showSave)
            Padding(
              padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
              child: BigButton(
                  l?.momentReviewSaveCount(n) ??
                      (n == 0
                          ? 'Save'
                          : n == 1
                              ? 'Save 1 answer'
                              : 'Save $n answers'),
                  key: const ValueKey('review-save'),
                  icon: LucideIcons.check,
                  color: C.domMind,
                  onTap: _busy || n == 0 ? null : _save),
            ),
        ]),
      ),
    );
  }

  Widget _momentRow(BuildContext c, AppLocalizations? l, PendingMoment m) {
    final k = ReviewKey.moment(m);
    final d = _queue.decisionFor(k);
    final r = _queue.rangeOf(m.key);
    final choice = _effectiveChoice(m);
    final err = _itemErrors[k] ?? (r == null ? null : _itemErrors[ReviewKey.range(r)]);
    return _MomentRow(
      key: ValueKey('moment-follow-up:${m.key}'),
      moment: m,
      open: _open[m.key],
      controller: _field(m.key),
      draft: _drafts[m.key],
      onDraft: () => setState(() {}),
      busy: _busy,
      pending: r == null && d != null ? _pending(l, d) : null,
      rangeText: r == null ? null : _rangeText(l, r),
      failure: err == null
          ? null
          : _failureText(l, err, r?.choice ?? d?.choice),
      pairError: _pairErrors[m.key],
      canPair: r == null &&
          !m.ambiguous &&
          choice != null &&
          isRangeChoice(choice),
      ambiguousNote: m.ambiguous && choice != null && isRangeChoice(choice),
      amountError: _amountErrors.contains(m.key),
      resumeNote: r != null && r.inProgress && err == null,
      canUndo: r?.inProgress != true,
      locked: r?.inProgress == true,
      onChoose: (ch) => _choose(m, ch),
      onSave: (ch) => _confirm(m, ch),
      onSkip: () => _queueMoment(m, const ReviewDecision.skip()),
      onUndo: () => _undoMoment(m),
      onPair: () => _pair(m),
      onLogWorkout: () => _logWorkout(m),
      onLabelWorkout: () =>
          _queueMoment(m, const ReviewDecision.label(MomentChoice.workout)),
    );
  }
}

/// The name of the activity with this `sessions.type` key.
String _activityName(AppLocalizations? l, String typeKey) {
  for (final a in allActivities) {
    if (a.typeKey == typeKey) return a.name;
  }
  return MomentChoice.other.localized(l);
}

class _MomentRow extends StatelessWidget {
  const _MomentRow({
    super.key,
    required this.moment,
    required this.open,
    required this.controller,
    required this.draft,
    required this.onDraft,
    required this.busy,
    required this.pending,
    required this.rangeText,
    required this.failure,
    required this.pairError,
    required this.canPair,
    required this.ambiguousNote,
    required this.amountError,
    required this.resumeNote,
    required this.canUndo,
    required this.locked,
    required this.onChoose,
    required this.onSave,
    required this.onSkip,
    required this.onUndo,
    required this.onPair,
    required this.onLogWorkout,
    required this.onLabelWorkout,
  });

  final PendingMoment moment;
  final MomentChoice? open;
  final TextEditingController controller;

  /// The symptom being described, when Symptom is the open choice.
  final _SymptomDraft? draft;
  final VoidCallback onDraft;
  final bool busy;

  /// "Will save: …" for a queued decision, or the range line when paired.
  final String? pending, rangeText, failure, pairError;
  final bool canPair;

  /// The mark's minute happened twice and its real time is unknown: no pairing,
  /// and the card says why.
  final bool ambiguousNote;

  /// The typed amount was refused.
  final bool amountError;

  /// A started range waiting to be finished (no undo).
  final bool resumeNote;
  final bool canUndo;

  /// The mark belongs to a range Save has started: it is finished as part of
  /// that range, so its own answer / Skip / pairing controls are inert.
  final bool locked;
  final ValueChanged<MomentChoice> onChoose, onSave;
  final VoidCallback onSkip, onUndo, onPair, onLogWorkout, onLabelWorkout;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final k = moment.key;
    final choice = open;
    final spec = choice?.journalField == null
        ? null
        : kJournalFieldsByKey[choice!.journalField];
    final queued = rangeText ?? pending;
    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${moment.date} · ${moment.hhmm}',
            style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
        if (queued != null) ...[
          const SizedBox(height: S.x2),
          Row(
            key: ValueKey(
                rangeText != null ? 'moment-range:$k' : 'moment-pending:$k'),
            children: [
              Icon(LucideIcons.clock, size: 16, color: p.on(C.domMind)),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(queued,
                    style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (canUndo)
          Align(
            alignment: Alignment.centerLeft,
            child: Pressable(
              key: ValueKey('moment-undo:$k'),
              onTap: busy ? null : onUndo,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x2),
                child: Text(l?.momentReviewUndo ?? 'Undo',
                    style: F.cap.copyWith(color: p.ink2)),
              ),
            ),
          ),
        ],
        if (resumeNote)
          Padding(
            key: ValueKey('moment-range-resume:$k'),
            padding: const EdgeInsets.only(bottom: S.x2),
            child: Text(
                l?.momentReviewResume ??
                    'Saved so far. Press Save to finish this pair.',
                style: F.cap.copyWith(color: p.ink2)),
          ),
        if (failure != null)
          Padding(
            key: ValueKey('moment-save-failed:$k'),
            padding: const EdgeInsets.only(bottom: S.x2),
            child: Text(failure!, style: F.cap.copyWith(color: p.ink2)),
          ),
        const SizedBox(height: S.x1),
        Wrap(spacing: S.x2, runSpacing: S.x2, children: [
          for (final ch in MomentChoice.values)
            Pressable(
              key: ValueKey('moment-choice:$k:${ch.id}'),
              onTap: busy || locked ? null : () => onChoose(ch),
              child: Pill(ch.localized(l), choice == ch ? C.domMind : C.blue),
            ),
        ]),
        if (spec != null) ...[
          const SizedBox(height: S.x3),
          OsTextField(
            key: ValueKey('moment-value:$k'),
            controller: controller,
            label: spec.label,
            hint: l?.momentFollowUpAmountHint(spec.unit) ??
                'Amount in ${spec.unit} (optional)',
            keyboard: const TextInputType.numberWithOptions(decimal: true),
          ),
          if (amountError)
            Padding(
              key: ValueKey('moment-amount-error:$k'),
              padding: const EdgeInsets.only(top: S.x1),
              child: Text(
                  l?.momentReviewAmountInvalid ??
                      'Type a number above 0 (within the usual range), or '
                          'leave it empty.',
                  style: F.cap.copyWith(color: p.ink2)),
            ),
        ],
        if (choice == MomentChoice.other) ...[
          const SizedBox(height: S.x3),
          OsTextField(
            key: ValueKey('moment-note:$k'),
            controller: controller,
            label: MomentChoice.other.localized(l),
            hint: l?.momentFollowUpNoteHint ?? 'Note (optional)',
            lines: 3,
          ),
        ],
        if (choice == MomentChoice.symptom && draft != null) ...[
          const SizedBox(height: S.x3),
          _SymptomDescriber(
              key: ValueKey('symptom-describer:$k'),
              momentKey: k,
              draft: draft!,
              onChanged: onDraft),
        ],
        if (choice != null && choice != MomentChoice.workout) ...[
          const SizedBox(height: S.x3),
          BigButton(l?.momentReviewQueueIt ?? 'Queue this answer',
              key: ValueKey('moment-save:$k'),
              icon: LucideIcons.check,
              color: C.domMind,
              onTap: busy || locked ? null : () => onSave(choice)),
        ],
        if (choice == MomentChoice.workout) ...[
          const SizedBox(height: S.x3),
          BigButton(l?.momentFollowUpLogWorkout ?? 'Log a workout at this time',
              key: ValueKey('moment-log-workout:$k'),
              icon: LucideIcons.dumbbell,
              onTap: busy || locked ? null : onLogWorkout),
          const SizedBox(height: S.x2),
          BigButton(l?.momentFollowUpLabelOnly ?? 'Just label it',
              key: ValueKey('moment-label-only:$k'),
              color: C.blue,
              soft: true,
              onTap: busy || locked ? null : onLabelWorkout),
        ],
        if (canPair) ...[
          const SizedBox(height: S.x2),
          BigButton(l?.momentReviewPair ?? 'Pair with another mark…',
              key: ValueKey('moment-pair:$k'),
              icon: LucideIcons.link,
              color: C.blue,
              soft: true,
              onTap: busy || locked ? null : onPair),
        ],
        if (ambiguousNote)
          Padding(
            key: ValueKey('moment-pair-ambiguous:$k'),
            padding: const EdgeInsets.only(top: S.x2),
            child: Text(
                l?.momentReviewAmbiguous ??
                    'This time came round twice when the clocks went back, so '
                        'it cannot be paired with another mark.',
                style: F.cap.copyWith(color: p.ink2)),
          ),
        if (pairError != null)
          Padding(
            key: ValueKey('moment-range-error:$k'),
            padding: const EdgeInsets.only(top: S.x2),
            child: Text(pairError!, style: F.cap.copyWith(color: p.ink2)),
          ),
        const SizedBox(height: S.x2),
        Align(
          alignment: Alignment.centerLeft,
          child: Pressable(
            key: ValueKey('moment-skip:$k'),
            onTap: busy || locked ? null : onSkip,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: S.x2),
              child: Text(l?.momentFollowUpSkip ?? 'Skip',
                  style: F.cap.copyWith(color: p.ink2)),
            ),
          ),
        ),
      ]),
    );
  }
}

/// A started range none of whose marks is left to answer: it shows what it is
/// and that Save finishes it (the owed announcement, nothing else).
class _OrphanRangeCard extends StatelessWidget {
  const _OrphanRangeCard({super.key, required this.text, required this.note});
  final String text, note;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(LucideIcons.clock, size: 16, color: p.on(C.domMind)),
          const SizedBox(width: S.x2),
          Expanded(
            child: Text(text,
                style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: S.x1),
        Text(note, style: F.cap.copyWith(color: p.ink2)),
      ]),
    );
  }
}

/// The moments this one can be paired with, and (for a workout) its type.
class _PairSheet extends StatefulWidget {
  const _PairSheet(
      {required this.moment, required this.candidates, required this.workout});
  final PendingMoment moment;
  final List<PendingMoment> candidates;
  final bool workout;

  @override
  State<_PairSheet> createState() => _PairSheetState();
}

class _PairSheetState extends State<_PairSheet> {
  /// `sessions.type` key; "other" until the wearer picks one.
  String _type = 'other';

  Future<void> _pickType() async {
    final a = await showModalBottomSheet<Activity>(
      context: context,
      isScrollControlled: true,
      backgroundColor: P.of(context).card,
      shape: const RoundedRectangleBorder(borderRadius: R.rXl),
      builder: (_) => const ActivityTypeSheet(),
    );
    if (a != null && mounted) setState(() => _type = a.typeKey);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final k = widget.moment.key;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(S.x4),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l?.momentReviewPairTitle ?? 'Pair with another marked moment',
                  style: F.t2.copyWith(color: p.ink)),
              const SizedBox(height: S.x3),
              if (widget.workout) ...[
                Pressable(
                  key: ValueKey('moment-pair-type:$k'),
                  onTap: _pickType,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: S.x2),
                    child: Text(
                        l?.momentReviewPairType(_activityName(l, _type)) ??
                            'Workout type: ${_activityName(l, _type)}',
                        style: F.body.copyWith(color: p.ink)),
                  ),
                ),
                const SizedBox(height: S.x2),
              ],
              if (widget.candidates.isEmpty)
                Text(l?.momentReviewPairNone ??
                    'No other unanswered moment to pair with.'),
              // A week of marks can be longer than the screen: scroll.
              Flexible(
                child: ListView(
                  key: const ValueKey('moment-pair-list'),
                  shrinkWrap: true,
                  children: [
                    for (final o in widget.candidates)
                      Pressable(
                        key: ValueKey('moment-pair-target:$k:${o.key}'),
                        onTap: () =>
                            Navigator.of(c).pop((other: o, type: _type)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: S.x3),
                          child: Text('${o.date} · ${o.hhmm}',
                              style: F.body.copyWith(color: p.ink)),
                        ),
                      ),
                  ],
                ),
              ),
            ]),
      ),
    );
  }
}

/// One row of the follow-up list: a pending moment or an assumed glass.
typedef _Entry = ({DateTime at, PendingMoment? moment, AssumedGlass? glass});

/// Pending moments and assumed glasses in one list, oldest first.
List<_Entry> _chronological(
    List<PendingMoment> moments, List<AssumedGlass> glasses) {
  final out = <_Entry>[
    for (final m in moments) (at: m.local, moment: m, glass: null),
    for (final g in glasses) (at: g.local, moment: null, glass: g),
  ]..sort((a, b) => a.at.compareTo(b.at));
  return out;
}

/// An assumed glass of water, labelled as such, with Keep and Remove.
///
/// Keep and Remove are QUEUED (shown as pending, undoable); on Save, Keep
/// acknowledges it (it stays in the water total and leaves this list) and
/// Remove subtracts exactly that glass. It offers none of the moment choices.
class _AssumedRow extends StatelessWidget {
  const _AssumedRow({
    super.key,
    required this.glass,
    required this.busy,
    required this.pending,
    required this.failure,
    required this.onKeep,
    required this.onRemove,
    required this.onUndo,
  });

  final AssumedGlass glass;
  final bool busy;
  final String? pending, failure;
  final VoidCallback onKeep, onRemove, onUndo;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final amount = waterText(c, glass.ml);
    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${glass.date} · ${glass.hhmm}',
            style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
        const SizedBox(height: S.x2),
        Row(children: [
          Icon(LucideIcons.glassWater, size: 16, color: p.on(C.blue)),
          const SizedBox(width: S.x2),
          Expanded(
            child: Text(l?.assumedWaterTitle ?? 'Assumed glass of water',
                style: F.body.copyWith(color: p.ink)),
          ),
        ]),
        const SizedBox(height: S.x1),
        Text(
            l?.assumedWaterBody(amount) ??
                'Adds $amount to the water you drank, assumed from your water '
                    'reminder. Keep it or remove it.',
            style: F.cap.copyWith(color: p.ink2)),
        if (pending != null) ...[
          const SizedBox(height: S.x2),
          Row(
            key: ValueKey('assumed-pending:${glass.key}'),
            children: [
              Icon(LucideIcons.clock, size: 16, color: p.on(C.domMind)),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(pending!,
                    style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Pressable(
              key: ValueKey('assumed-undo:${glass.key}'),
              onTap: busy ? null : onUndo,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: S.x2),
                child: Text(l?.momentReviewUndo ?? 'Undo',
                    style: F.cap.copyWith(color: p.ink2)),
              ),
            ),
          ),
        ],
        if (failure != null)
          Padding(
            key: ValueKey('assumed-save-failed:${glass.key}'),
            padding: const EdgeInsets.only(top: S.x1),
            child: Text(failure!, style: F.cap.copyWith(color: p.ink2)),
          ),
        const SizedBox(height: S.x3),
        Row(children: [
          Expanded(
            child: BigButton(l?.assumedWaterKeep ?? 'Keep',
                key: ValueKey('assumed-keep:${glass.key}'),
                icon: LucideIcons.check,
                color: C.domMind,
                onTap: busy ? null : onKeep),
          ),
          const SizedBox(width: S.x2),
          Expanded(
            child: BigButton(l?.assumedWaterRemove ?? 'Remove',
                key: ValueKey('assumed-remove:${glass.key}'),
                icon: LucideIcons.trash2,
                color: C.blue,
                soft: true,
                onTap: busy ? null : onRemove),
          ),
        ]),
      ]),
    );
  }
}

/// What the wearer has picked so far for a Symptom answer.
class _SymptomDraft {
  SymptomSeverity? severity;
  SymptomSide? side;
  SymptomKind? kind;
  SymptomArea? area;
  final kindOther = TextEditingController();
  final areaOther = TextEditingController();
  final note = TextEditingController();

  /// The description, or null until severity, kind and area are said (and the
  /// free text, for "other"). Side and note are optional.
  SymptomDescription? build() {
    final sev = severity, k = kind, a = area;
    if (sev == null || k == null || a == null) return null;
    final ko = kindOther.text.trim(), ao = areaOther.text.trim(), n = note.text.trim();
    if (k == SymptomKind.other && ko.isEmpty) return null;
    if (a == SymptomArea.other && ao.isEmpty) return null;
    return SymptomDescription(
      severity: sev,
      side: side,
      kind: k,
      kindOther: k == SymptomKind.other ? ko : null,
      area: a,
      areaOther: a == SymptomArea.other ? ao : null,
      note: n.isEmpty ? null : n,
    );
  }

  void dispose() {
    kindOther.dispose();
    areaOther.dispose();
    note.dispose();
  }
}

String _cap(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Severity, optional side, kind and body area as tap choices, free text for
/// "other", an optional note and the sentence it will read as.
class _SymptomDescriber extends StatelessWidget {
  const _SymptomDescriber({
    super.key,
    required this.momentKey,
    required this.draft,
    required this.onChanged,
  });

  final String momentKey;
  final _SymptomDraft draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final k = momentKey;

    Widget group<T extends Enum>(String title, String prefix, List<T> values,
        String Function(T) label, T? picked, void Function(T) pick) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title.toUpperCase(), style: F.over.copyWith(color: p.ink3)),
        const SizedBox(height: S.x2),
        Wrap(spacing: S.x2, runSpacing: S.x2, children: [
          for (final v in values)
            Pressable(
              key: ValueKey('$prefix:$k:${v.name}'),
              onTap: () {
                pick(v);
                onChanged();
              },
              child: Pill(_cap(label(v)), picked == v ? C.domMind : C.blue),
            ),
        ]),
        const SizedBox(height: S.x3),
      ]);
    }

    final sentence = draft.build()?.describe(l);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      group<SymptomSeverity>(
          l?.symptomDescriberSeverity ?? 'How strong?',
          'symptom-severity',
          SymptomSeverity.values,
          (v) => v.localized(l),
          draft.severity,
          (v) => draft.severity = v),
      // Optional: tapping the chosen side again clears it.
      group<SymptomSide>(
          l?.symptomDescriberSide ?? 'Which side? (optional)',
          'symptom-side',
          SymptomSide.values,
          (v) => v.localized(l),
          draft.side,
          (v) => draft.side = draft.side == v ? null : v),
      group<SymptomKind>(
          l?.symptomDescriberKind ?? 'What kind?',
          'symptom-kind',
          SymptomKind.values,
          (v) => v.localized(l),
          draft.kind,
          (v) => draft.kind = v),
      if (draft.kind == SymptomKind.other) ...[
        OsTextField(
          key: ValueKey('symptom-kind-other:$k'),
          controller: draft.kindOther,
          label: SymptomKind.other.localized(l),
          hint: l?.symptomDescriberKindOtherHint ?? 'Describe the kind',
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: S.x3),
      ],
      group<SymptomArea>(
          l?.symptomDescriberArea ?? 'Where?',
          'symptom-area',
          SymptomArea.values,
          (v) => v.localized(l),
          draft.area,
          (v) => draft.area = v),
      if (draft.area == SymptomArea.other) ...[
        OsTextField(
          key: ValueKey('symptom-area-other:$k'),
          controller: draft.areaOther,
          label: SymptomArea.other.localized(l),
          hint: l?.symptomDescriberAreaOtherHint ?? 'Describe the place',
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: S.x3),
      ],
      OsTextField(
        key: ValueKey('symptom-note:$k'),
        controller: draft.note,
        label: l?.symptomDescriberNoteHint ?? 'Note (optional)',
        hint: l?.symptomDescriberNoteHint ?? 'Note (optional)',
        lines: 2,
      ),
      if (sentence != null) ...[
        const SizedBox(height: S.x3),
        Padding(
          key: ValueKey('symptom-preview:$k'),
          padding: EdgeInsets.zero,
          child: Text(sentence,
              style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
        ),
      ],
    ]);
  }
}
