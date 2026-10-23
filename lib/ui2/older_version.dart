// The one shared marker and note for a value served from an older calculation
// (owner decision 2026-10-22, RULES B.2): an asterisk beside the number, and a
// note "From an older calculation (v104): <reason>". Every surface that prints
// such a value uses these two widgets; nothing formats its own.
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/presentation_text.dart';
import '../models/metric.dart';
import 'grammar.dart' show Pressable;

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
/// nothing without a [version]. Tapping it opens the note in a dialog (unless
/// the surface prints the note itself: [showNote] false), so a compact tile or
/// ring never has to make room for a sentence.
class OlderVersionMark extends StatelessWidget {
  final String id;
  final int? version;
  final String? reason;
  final bool showNote;
  const OlderVersionMark(
      {super.key,
      required this.id,
      required this.version,
      this.reason,
      this.showNote = true});

  @override
  Widget build(BuildContext context) {
    final v = version;
    if (v == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    return Semantics(
      label: l?.olderVersionSemantics(v) ?? olderVersionSemantics(v),
      button: showNote,
      child: Pressable(
        key: ValueKey('older-version-mark:$id'),
        onTap: showNote
            ? () => showDialog<void>(
                  context: context,
                  builder: (c) => AlertDialog(
                    content: OlderVersionNote(id: id, version: v, reason: reason),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.of(c).pop(),
                          child: Text(MaterialLocalizations.of(c).okButtonLabel)),
                    ],
                  ),
                )
            : null,
        child: const Text('*'),
      ),
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
