// The note is localized END TO END: the sentence template through the ARB key,
// and the reason sentence through the same presentation table every other
// absence reason uses. No English prose inside a localized note.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_de.dart';
import 'package:openstrap_edge/ui2/older_version.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

import 'support/older_version_fixtures.dart';

// English reads "This metric needs your age, which is not on file." The four
// profile inputs have their own translated sentences (olderVersionReason*); a
// reason with no translation is left out of the note (the version alone is
// still true), never pasted in English.

void main() {
  final de = AppLocalizationsDe();

  testWidgets('the reason sentence is translated, not pasted in English',
      (t) async {
    await t.pumpWidget(MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      home: const Scaffold(
          body: OlderVersionNote(id: 'x', version: 104, reason: kReasonRaw)),
    ));
    final translated = de.olderVersionReasonAge;
    expect(translated, isNot(kReasonSentence));
    expect(find.text(de.olderVersionNote(104, translated)), findsOneWidget);
    expect(find.textContaining(kReasonSentence), findsNothing);
  });

  testWidgets('the mark is spoken in German and not tappable', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      home: const Scaffold(
          body: OlderVersionMark(id: 'x', version: 104, reason: kReasonRaw)),
    ));
    expectSpokenNotTappable(t, olderMark('x'),
        label: contains(de.olderVersionSemantics(104)));
    h.dispose();
  });

  testWidgets('a reason with no translation: the version alone, no English',
      (t) async {
    await t.pumpWidget(MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      home: const Scaffold(
          body: OlderVersionNote(
              id: 'x', version: 104, reason: 'need_input:name=wake_hr')),
    ));
    expect(find.text(de.olderVersionNoteNoReason(104)), findsOneWidget);
    expect(find.textContaining('waking heart rate'), findsNothing);
  });
}
