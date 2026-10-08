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

import '../../data/assumed_water.dart';
import '../../data/journal_fields.dart' show kJournalFieldsByKey;
import '../../gestures/gesture_settings.dart';
import '../../gestures/moment_follow_ups.dart';
import '../../gestures/symptom_description.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../theme/theme_switcher.dart' show themedRoute;
import '../ui2.dart';
import 'journal_compose.dart' show OsTextField;
import 'log_workout.dart' show LogWorkout;

/// "N things to review — marked moments and assumed water" with an Answer
/// button. [count] is pending moments plus assumed glasses.
class MomentFollowUpCard extends StatelessWidget {
  const MomentFollowUpCard({super.key, required this.count, this.onAnswer});
  final int count;
  final VoidCallback? onAnswer;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Surface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                l?.momentFollowUpCardTitle(count) ??
                    (count == 1
                        ? '$count thing to review — marked moments and assumed water'
                        : '$count things to review — marked moments and assumed water'),
                key: const ValueKey('moment-follow-up-card'),
                style: F.t2.copyWith(color: p.ink)),
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
  required int count,
  VoidCallback? onAnswer,
}) =>
    enabled && count > 0
        ? MomentFollowUpCard(count: count, onAnswer: onAnswer)
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
  int _count = 0;
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
      final n = f.pendingCount(DateTime.now());
      if (mounted && n != _count) setState(() => _count = n);
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
          count: _count,
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

/// Each pending moment with its quick choices and Skip.
class MomentFollowUpScreen extends StatefulWidget {
  const MomentFollowUpScreen({
    super.key,
    this.preloaded,
    this.writer = const MomentAnswerWriter(),
    this.now,
    this.preloadedAssumed,
    this.assumedWriter = const AssumedWaterWriter(),
  });

  /// Injected in tests; null reads them from the database.
  final List<PendingMoment>? preloaded;

  /// Assumed water glasses to list among the moments (RED stub: not yet
  /// shown). Null reads them from the database.
  final List<AssumedGlass>? preloadedAssumed;
  final AssumedWaterWriter assumedWriter;
  final MomentAnswerWriter writer;
  final DateTime? now;

  @override
  State<MomentFollowUpScreen> createState() => _MomentFollowUpScreenState();
}

class _MomentFollowUpScreenState extends State<MomentFollowUpScreen> {
  List<PendingMoment>? _items;
  List<AssumedGlass> _glasses = [];
  bool _failed = false;
  bool _busy = false;

  /// The choice a moment is waiting on more input for (an amount, a note, or
  /// the workout options).
  final Map<String, MomentChoice> _open = {};
  final Map<String, TextEditingController> _text = {};
  final Map<String, _SymptomDraft> _drafts = {};

  @override
  void initState() {
    super.initState();
    if (widget.preloaded != null) {
      _items = List.of(widget.preloaded!);
      _glasses = List.of(widget.preloadedAssumed ?? const []);
    } else {
      _load();
    }
  }

  @override
  void dispose() {
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
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Keep / Remove one assumed glass. The row leaves only once the write has
  /// landed; a failed write keeps it and says so.
  Future<void> _storeGlass(AssumedGlass g, Future<void> Function() write) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await write();
      if (!mounted) return;
      setState(() => _glasses.removeWhere((x) => x.key == g.key));
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

  Future<void> _store(PendingMoment m,
      Future<MomentAnswerResult> Function() write) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await write();
      if (!mounted) return;
      setState(() {
        _items?.removeWhere((x) => x.key == m.key);
        _open.remove(m.key);
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
    _store(m, () => widget.writer.answer(m, c, now: widget.now));
  }

  void _save(PendingMoment m, MomentChoice c) {
    if (c == MomentChoice.symptom) {
      // Nothing is saved until severity, kind and area are said; a half
      // description is never stored.
      final d = _drafts[m.key]?.build();
      if (d == null) return;
      _store(m, () => widget.writer.answerSymptom(m, d, now: widget.now));
      return;
    }
    final raw = _field(m.key).text.trim();
    if (c == MomentChoice.other) {
      _store(m,
          () => widget.writer.answer(m, c,
              note: raw.isEmpty ? null : raw, now: widget.now));
      return;
    }
    // A number only when one was typed; anything else is no amount, never a
    // guessed one.
    final v = double.tryParse(raw.replaceAll(',', '.'));
    _store(m, () => widget.writer.answer(m, c, value: v, now: widget.now));
  }

  Future<void> _logWorkout(PendingMoment m) async {
    final now = widget.now ?? DateTime.now();
    final w = workoutPrefillFor(m, now);
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      builder: (_) => LogWorkout(start: w.start, end: w.end, now: widget.now),
    ));
    if (saved == true && mounted) {
      await _store(
          m, () => widget.writer.answer(m, MomentChoice.workout, now: now));
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final items = _items;
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
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
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
                else if (items.isEmpty && _glasses.isEmpty)
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
                else
                  for (final e in _chronological(items, _glasses)) ...[
                    if (e.glass case final g?)
                      _AssumedRow(
                        key: ValueKey('assumed-water:${g.key}'),
                        glass: g,
                        busy: _busy,
                        onKeep: () => _storeGlass(
                            g, () => widget.assumedWriter.keep(g)),
                        onRemove: () => _storeGlass(
                            g, () => widget.assumedWriter.remove(g)),
                      )
                    else if (e.moment case final m?)
                    _MomentRow(
                      key: ValueKey('moment-follow-up:${m.key}'),
                      moment: m,
                      open: _open[m.key],
                      controller: _field(m.key),
                      draft: _drafts[m.key],
                      onDraft: () => setState(() {}),
                      busy: _busy,
                      onChoose: (ch) => _choose(m, ch),
                      onSave: (ch) => _save(m, ch),
                      onSkip: () =>
                          _store(m, () => widget.writer.skip(m, now: widget.now)),
                      onLogWorkout: () => _logWorkout(m),
                      onLabelWorkout: () => _store(
                          m,
                          () => widget.writer
                              .answer(m, MomentChoice.workout, now: widget.now)),
                    ),
                    const SizedBox(height: S.x3),
                  ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
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
    required this.onChoose,
    required this.onSave,
    required this.onSkip,
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
  final ValueChanged<MomentChoice> onChoose, onSave;
  final VoidCallback onSkip, onLogWorkout, onLabelWorkout;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final k = moment.key;
    final choice = open;
    final spec = choice?.journalField == null
        ? null
        : kJournalFieldsByKey[choice!.journalField];
    return Surface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${moment.date} · ${moment.hhmm}',
            style: F.body.copyWith(color: p.ink, fontWeight: FontWeight.w600)),
        const SizedBox(height: S.x3),
        Wrap(spacing: S.x2, runSpacing: S.x2, children: [
          for (final ch in MomentChoice.values)
            Pressable(
              key: ValueKey('moment-choice:$k:${ch.id}'),
              onTap: busy ? null : () => onChoose(ch),
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
          BigButton(l?.momentFollowUpSave ?? 'Save',
              key: ValueKey('moment-save:$k'),
              icon: LucideIcons.check,
              color: C.domMind,
              onTap: busy ? null : () => onSave(choice)),
        ],
        if (choice == MomentChoice.workout) ...[
          const SizedBox(height: S.x3),
          BigButton(l?.momentFollowUpLogWorkout ?? 'Log a workout at this time',
              key: ValueKey('moment-log-workout:$k'),
              icon: LucideIcons.dumbbell,
              onTap: busy ? null : onLogWorkout),
          const SizedBox(height: S.x2),
          BigButton(l?.momentFollowUpLabelOnly ?? 'Just label it',
              key: ValueKey('moment-label-only:$k'),
              color: C.blue,
              soft: true,
              onTap: busy ? null : onLabelWorkout),
        ],
        const SizedBox(height: S.x2),
        Align(
          alignment: Alignment.centerLeft,
          child: Pressable(
            key: ValueKey('moment-skip:$k'),
            onTap: busy ? null : onSkip,
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
/// Keep acknowledges it (it stays in the water total and leaves this list);
/// Remove subtracts exactly that glass. It offers none of the moment choices.
class _AssumedRow extends StatelessWidget {
  const _AssumedRow({
    super.key,
    required this.glass,
    required this.busy,
    required this.onKeep,
    required this.onRemove,
  });

  final AssumedGlass glass;
  final bool busy;
  final VoidCallback onKeep, onRemove;

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
