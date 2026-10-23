// The one shared marker and note for a value served from an older calculation
// (owner decision 2026-10-22, RULES B.2): an asterisk beside the number, and a
// note "From an older calculation (v104): <reason>". Every surface that prints
// such a value uses these two widgets; nothing formats its own.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/app_localizations.dart';
import '../l10n/presentation_text.dart';
import '../models/metric.dart';
import 'theme.dart';

/// English form of the note, for the callers with no localizations in scope.
String olderVersionNoteText(int version, String? reason) {
  final why = whyFromNote(reason);
  return 'From an older calculation (v$version)${why == null ? '' : ': $why'}';
}

/// English spoken form.
String olderVersionSemantics(int version) =>
    'From an older calculation (v$version)';

/// The reason as a sentence in the reader's language, or null when there is
/// none that can be said in it. The four profile inputs a calculation can be
/// missing have their own translated sentences; any other reason is [whyFromNote]
/// in English and the app's translated table elsewhere. A reason no table knows
/// is left out (the version alone is still true), never pasted in English.
String? olderVersionReasonText(AppLocalizations? l, String? reason) {
  final why = whyFromNote(reason);
  if (why == null) return null;
  if (l != null) {
    final name = RegExp(r'^need_input:name=([a-z0-9_]+)')
        .firstMatch(reason ?? '')
        ?.group(1);
    switch (name) {
      case 'age':
        return l.olderVersionReasonAge;
      case 'weight_kg':
        return l.olderVersionReasonWeight;
      case 'height_cm':
        return l.olderVersionReasonHeight;
      case 'sex':
        return l.olderVersionReasonSex;
    }
  }
  if (l == null || l.localeName == 'en') return why;
  final translated = presentationText(l, why);
  return translated == why ? null : translated;
}

/// The note, localized: template through the ARB key, reason through
/// [olderVersionReasonText].
String olderVersionNoteLocalized(
    AppLocalizations? l, int version, String? reason) {
  final why = olderVersionReasonText(l, reason);
  return why == null
      ? (l?.olderVersionNoteNoReason(version) ??
          olderVersionNoteText(version, null))
      : (l?.olderVersionNote(version, why) ??
          olderVersionNoteText(version, reason));
}

/// The asterisk beside a number. Key: `older-version-mark:<id>`. Renders
/// nothing without a [version]. Plain text, spoken as "from an older
/// calculation": it is never tappable and takes no room beyond the glyph, so it
/// sits tight against the number on every surface. The note is
/// [OlderVersionNote], printed by the surfaces that have room for it.
class OlderVersionMark extends StatelessWidget {
  final String id;
  final int? version;
  final String? reason;

  /// False where the parent already speaks the version (a card's merged label)
  /// or a note beside it does: the status is then announced from one place.
  final bool speak;
  const OlderVersionMark(
      {super.key,
      required this.id,
      required this.version,
      this.reason,
      this.speak = true});

  @override
  Widget build(BuildContext context) {
    final v = version;
    if (v == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    // Line height 1: the glyph keeps its size but never makes its line
    // taller than the number or caption it sits beside.
    final star = Text('*',
        key: ValueKey('older-version-mark:$id'),
        style: DefaultTextStyle.of(context).style.copyWith(height: 1));
    if (!speak) return ExcludeSemantics(child: star);
    return Semantics(
      label: l?.olderVersionSemantics(v) ?? olderVersionSemantics(v),
      child: star,
    );
  }
}

/// The visible note. Key: `older-version-note:<id>`. Plain wrapping text, so a
/// long reason or a large text size never overflows its parent.
class OlderVersionNote extends StatelessWidget {
  final String id;
  final int? version;
  final String? reason;
  const OlderVersionNote(
      {super.key, required this.id, required this.version, this.reason});

  @override
  Widget build(BuildContext context) {
    final v = version;
    if (v == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    // The text IS the spoken form: "From an older calculation (v104): …".
    return Text(olderVersionNoteLocalized(l, v, reason),
        key: ValueKey('older-version-note:$id'));
  }
}

/// The reason, anchored at the foot of a card and there from the first frame: a
/// thin divider, the history icon, then the note. One strip per card however
/// many of its values are older; each distinct version and reason is listed
/// once. Takes no room when nothing is older. Note key: `older-version-note:<id>`
/// (suffixed `:<n>` after the first when a card has several distinct reasons).
class OlderVersionStrip extends StatelessWidget {
  final String id;
  final List<({int? version, String? reason})> items;
  const OlderVersionStrip({super.key, required this.id, required this.items});

  @override
  Widget build(BuildContext context) {
    final seen = <({int version, String? reason})>[
      for (final i in items)
        if (i.version != null) (version: i.version!, reason: i.reason),
    ].toSet().toList();
    if (seen.isEmpty) return const SizedBox.shrink();
    final p = P.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: S.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(height: .5, color: p.line),
        const SizedBox(height: S.x3),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(LucideIcons.history, size: 16, color: p.ink3),
          ),
          const SizedBox(width: S.x2),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var k = 0; k < seen.length; k++)
                    DefaultTextStyle.merge(
                      style: F.cap.copyWith(color: p.ink3, height: 1.4),
                      child: OlderVersionNote(
                          id: k == 0 ? id : '$id:$k',
                          version: seen[k].version,
                          reason: seen[k].reason),
                    ),
                ]),
          ),
        ]),
      ]),
    );
  }
}

/// A run of days as short text: "Sun–Mon" for [weekdays] (a window of a week or
/// less), else "Oct 12–15" (or "Sep 28–Oct 2" across a month). One day names
/// itself. [locale] is the ambient locale's name.
String olderRunText(String locale, DateTime first, DateTime last,
    {bool weekdays = false}) {
  final same = first.year == last.year &&
      first.month == last.month &&
      first.day == last.day;
  if (weekdays) {
    final e = _dateFormat('E', locale);
    return same ? e.format(first) : '${e.format(first)}–${e.format(last)}';
  }
  final md = _dateFormat('MMMd', locale);
  if (same) return md.format(first);
  final sameMonth = first.year == last.year && first.month == last.month;
  return '${md.format(first)}–'
      '${sameMonth ? _dateFormat('d', locale).format(last) : md.format(last)}';
}

/// [pattern] in [locale], or in English where the locale has no date data.
DateFormat _dateFormat(String pattern, String locale) {
  try {
    return DateFormat(pattern, locale);
  } catch (_) {
    return DateFormat(pattern, 'en');
  }
}

/// The label of a run of older days: "<days>: older calculation (v104),
/// <reason>". English is the short form; another language reuses the
/// localized note so it never prints English.
String olderRangeLabel(
    AppLocalizations? l, String days, int version, String? reason) {
  if (l != null && l.localeName != 'en') {
    return '$days: ${olderVersionNoteLocalized(l, version, reason)}';
  }
  final why = olderVersionReasonText(l, reason);
  return '$days: older calculation (v$version)${why == null ? '' : ', $why'}';
}

/// What a slider says of the selected day when its value is from an older
/// calculation: the short fact only. The full "From an older calculation
/// (vN): reason" has ONE spoken source, the on-load strip, so a scrub never
/// repeats it. Other languages say the localized full form.
String olderVersionSpokenShort(AppLocalizations? l, int version) =>
    l == null || l.localeName == 'en'
        ? 'older calculation'
        : (l.olderVersionSemantics(version));
