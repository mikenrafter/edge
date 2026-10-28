import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../compute/nap_edits.dart';
import '../../models/activity_suggestion.dart';
import '../../state/app_state.dart';
import '../../theme/theme_switcher.dart' show themedRoute;
import '../ui2.dart';
import 'home_screen.dart';
import 'day_review.dart';
import 'day_timeline.dart' show DayTimelineScreen;
import 'moment_follow_up.dart' show pendingMomentReviews;

/// Compatibility entry for older callers. All review lives in the breakdown.
class DetectedActivitiesScreen extends StatelessWidget {
  const DetectedActivitiesScreen({super.key, this.focusId, this.preloaded});
  final String? focusId;
  final List<ActivitySuggestion>? preloaded;
  @override
  Widget build(BuildContext c) => DayReviewEntry(
      focusId: focusId, activities: preloaded);
}

/// Routes inherit the app's theme and reduced-motion policy.
Route<T> themedActivityRoute<T>(Widget child) =>
    themedRoute<T>((_) => child, name: child.runtimeType.toString());

class ActivityProposalCard extends StatelessWidget {
  const ActivityProposalCard({
    super.key,
    required this.suggestion,
    this.highlighted = false,
    this.onConfirm,
    this.onEdit,
    this.onDiscard,
  });
  final ActivitySuggestion suggestion;
  final bool highlighted;
  final VoidCallback? onConfirm, onEdit, onDiscard;

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final p = P.of(c);
    final nap = suggestion.kind == ActivityKind.nap;
    final meal = suggestion.kind == ActivityKind.meal;
    final track = suggestion.kind == ActivityKind.track;
    final prompt = track && suggestion.isPrompt;
    final trackName = suggestion.details['track_name'] as String? ??
        suggestion.trackId ?? '';
    final accent = nap ? C.domHealth : C.domMove;
    final start = DateTime.fromMillisecondsSinceEpoch(
      suggestion.startTs * 1000,
    );
    final end = DateTime.fromMillisecondsSinceEpoch(suggestion.endTs * 1000);
    final material = MaterialLocalizations.of(c);
    String when(DateTime value) =>
        '${material.formatMediumDate(value)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(value), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(c))}';
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                nap ? LucideIcons.moon : meal ? LucideIcons.utensils
                    : prompt ? LucideIcons.circleHelp
                    : track ? LucideIcons.tag : LucideIcons.activity,
                color: p.on(accent),
                size: 20,
              ),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(
                  prompt
                      ? (l?.activityTrackDidYouOn(
                              trackName,
                              material.formatMediumDate(start),
                            ) ??
                          'Did you have or do "$trackName" on ${material.formatMediumDate(start)}?')
                      : track
                      ? (l?.activityPossibleTrack(trackName) ??
                          'Possible: $trackName')
                      : meal ? (l?.activityPossibleMeal ?? 'Possible meal') : nap
                      ? (l?.activityPossibleNap ?? 'Possible nap')
                      : (l?.activityPossibleWorkout ?? 'Possible workout'),
                  style: F.head.copyWith(color: p.ink),
                ),
              ),
              if (highlighted)
                Icon(LucideIcons.bell, color: p.on(accent), size: 20),
            ],
          ),
          const SizedBox(height: S.x2),
          // A minimum-count question has no observed time to show.
          if (!prompt) ...[
            Text(
              '${when(start)} – ${when(end)}',
              style: F.body.copyWith(color: p.ink2),
            ),
            Text(
              l?.activityLengthMinutes(suggestion.durationMin) ??
                  '${suggestion.durationMin} min',
              style: F.cap.copyWith(color: p.ink3),
            ),
          ],
          if (track && !prompt)
            Text(
              _trackEvidence(l, suggestion),
              style: F.cap.copyWith(color: p.ink3),
            ),
          if (track)
            Text(
              prompt
                  ? (l?.activityTrackPromptNoteDay ??
                      'Yes adds an entry with no time or amount for that day. No records that none happened that day.')
                  : (l?.activityTrackNote ??
                      'A hint from your body signals, not a diagnosis. Confirming adds an entry with no amount. The thresholds behind it are unvalidated.'),
              style: F.cap.copyWith(color: p.ink3),
            ),
          const SizedBox(height: S.x3),
          Wrap(
            spacing: S.x4,
            runSpacing: S.x2,
            children: [
              _action(
                c,
                prompt
                    ? (l?.activityTrackYes ?? 'Yes')
                    : (l?.activityConfirm ?? 'Confirm'),
                onConfirm,
                accent,
              ),
              // The workout editor is where the sport is picked, so it says
              // that; a nap only has times to edit.
              if (!prompt)
              _action(
                c,
                nap || meal || track
                    ? (l?.activityEdit ?? 'Edit')
                    : (l?.activityChangeSport ?? 'Change sport'),
                onEdit,
                accent,
              ),
              // Same words as the correction on a logged nap and a night, so
              // "this was wrong" reads the same wherever the detection shows.
              // A discard is kept by window and wins over every re-detection.
              _action(
                c,
                prompt
                    ? (l?.activityTrackNo ?? 'No')
                    : track
                    ? (l?.activityTrackNotHappened ?? 'Did not happen')
                    : meal ? (l?.activityNotAMeal ?? 'Not a meal') : nap
                    ? (l?.napsNotANapLabel ?? 'Not a nap')
                    : (l?.activityNotAWorkout ?? 'Not a workout'),
                onDiscard,
                C.red,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The stored English text wins when present; otherwise the code is localized.
  static String _trackEvidence(AppLocalizations? l, ActivitySuggestion s) {
    final text = s.details['evidence'];
    if (text is String && text.isNotEmpty) return text;
    return switch (s.details['evidence_kind']) {
      'early_sleep_hr_hrv' => l?.activityTrackEvidenceSleep ??
          'Early sleep heart rate rose while HRV fell compared with your usual nights.',
      'resting_hr_jump' => l?.activityTrackEvidenceRestingHr ??
          'Resting heart rate rose well above your usual level without movement.',
      _ => l?.activityTrackEvidenceLearned ??
          'Matches the pattern learned from your logged days.',
    };
  }

  Widget _action(
    BuildContext c,
    String label,
    VoidCallback? tap,
    Color accent,
  ) => Pressable(
    onTap: tap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: S.x2),
      child: Text(
        label,
        style: F.body.copyWith(
          color: P.of(c).on(accent),
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

/// Home's review card: ALWAYS there. With something to review (activities,
/// marked moments, assumed water) it reads "Review activities" and the count,
/// in green, and opens the review. With nothing it is "Breakdown of your day"
/// in grey and opens the plain breakdown. Same icon either way.
class DetectedActivitiesCard extends StatefulWidget {
  const DetectedActivitiesCard(
      {super.key, this.pendingCount, this.loadFailed = false, this.day});
  final int? pendingCount;

  /// The caller's own read of the count failed: show the retry text from the
  /// first paint rather than a second read that lands the card a frame late.
  final bool loadFailed;

  /// The day the plain breakdown opens on; null is the newest.
  final String? day;
  @override
  State<DetectedActivitiesCard> createState() => _DetectedActivitiesCardState();
}

class _DetectedActivitiesCardState extends State<DetectedActivitiesCard>
    with RevisionReload {
  int? _count;
  int _moments = 0;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _count = widget.pendingCount;
    _failed = widget.loadFailed;
    reload();
  }

  @override
  void reload() {
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = context.read<AppState>().gestureSettings;
      final moments = await pendingMomentReviews(settings);
      if (mounted && moments != _moments) setState(() => _moments = moments);
    } on ProviderNotFoundException {
      // No AppState (a golden): no moments to count.
    }
    try {
      if (!mounted || widget.pendingCount != null || widget.loadFailed) return;
      final repo = repoOf(context);
      if (repo == null) return;
      final count = await repo.pendingActivityCount();
      if (mounted) {
        setState(() {
          _count = count;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final n = (_count ?? 0) + _moments;
    if (!_failed && n <= 0) {
      return Padding(
        padding: const EdgeInsets.only(bottom: S.x3),
        child: ActionCard(
          l?.homeBreakdownTitle ?? 'Breakdown of your day',
          l?.homeBreakdownSubtitle ?? 'Hour by hour',
          l?.homeBreakdownOpen ?? 'Open',
          LucideIcons.radar,
          C.n500,
          onTap: () => go(c, DayTimelineScreen(day: widget.day)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: S.x3),
      child: ActionCard(
        l?.homeReviewActivities ?? 'Review activities',
        _failed
            ? (l?.activityLoadFailed ?? 'Could not load activities. Try again.')
            : (l?.activityPending(n) ?? '$n to review'),
        l?.activityReview ?? 'Review',
        LucideIcons.radar,
        C.domHome,
        onTap: () => go(c, const DayReviewEntry()),
      ),
    );
  }
}

class NapProposalEditor extends StatefulWidget {
  const NapProposalEditor({super.key, required this.suggestion, this.stageOnly = false});
  final bool stageOnly;
  final ActivitySuggestion suggestion;
  @override
  State<NapProposalEditor> createState() => _NapProposalEditorState();
}

class _NapProposalEditorState extends State<NapProposalEditor> {
  late DateTime _start, _end;
  @override
  void initState() {
    super.initState();
    _start = DateTime.fromMillisecondsSinceEpoch(
      widget.suggestion.startTs * 1000,
    );
    _end = DateTime.fromMillisecondsSinceEpoch(widget.suggestion.endTs * 1000);
  }

  Future<void> _pick(bool start) async {
    final value = start ? _start : _end;
    final day = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(value),
    );
    if (time == null || !mounted) return;
    final picked = DateTime(
      day.year,
      day.month,
      day.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (start) {
        _start = picked;
      } else {
        _end = picked;
      }
    });
  }

  @override
  Widget build(BuildContext c) {
    final l = AppLocalizations.of(c);
    final valid =
        manualNapWindowIsValid(
          _start.millisecondsSinceEpoch ~/ 1000,
          _end.millisecondsSinceEpoch ~/ 1000,
        ) &&
        !_end.isAfter(DateTime.now());
    final material = MaterialLocalizations.of(c);
    String label(DateTime d) =>
        '${material.formatMediumDate(d)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(c))}';
    return Scaffold(
      backgroundColor: P.of(c).bg,
      body: SafeArea(
        child: Column(children: [
          NavBar(l?.activityEditNap ?? 'Edit nap'),
          Expanded(
            child: ListView(
          padding: pad,
          children: [
            ActionCard(
              l?.activityStart ?? 'Start',
              label(_start),
              l?.activityEdit ?? 'Edit',
              LucideIcons.clock,
              C.domHealth,
              onTap: () => _pick(true),
            ),
            const SizedBox(height: S.x3),
            ActionCard(
              l?.activityEnd ?? 'End',
              label(_end),
              l?.activityEdit ?? 'Edit',
              LucideIcons.clock,
              C.domHealth,
              onTap: () => _pick(false),
            ),
            const SizedBox(height: S.x4),
            if (!valid)
              StatusCard(
                l?.activityCheckTimes ?? 'Check the times',
                l?.activityNapWindow ??
                    'Choose a past window between 5 minutes and 6 hours.',
              ),
            BigButton(
              widget.stageOnly ? (l?.momentReviewQueueIt ?? 'Queue this answer') :
                  (l?.activitySaveConfirm ?? 'Save and confirm'),
              icon: LucideIcons.check,
              onTap: valid
                  ? () => Navigator.of(c).pop((
                      _start.millisecondsSinceEpoch ~/ 1000,
                      _end.millisecondsSinceEpoch ~/ 1000,
                    ))
                  : null,
            ),
          ],
        ),
          ),
        ]),
      ),
    );
  }
}
