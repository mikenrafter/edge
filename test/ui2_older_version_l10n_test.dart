// The note is localized END TO END: the sentence template through the ARB key,
// and the reason sentence through the same presentation table every other
// absence reason uses. No English prose inside a localized note.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/app_localizations_de.dart';
import 'package:openstrap_edge/l10n/presentation_text.dart';
import 'package:openstrap_edge/ui2/older_version.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

import 'support/older_version_fixtures.dart';

// English reads "This metric needs your age, which is not on file." For other
// languages the app's own translated table holds the equivalent sentence for
// the four profile inputs; a reason with no translation is left out of the note
// (the version alone is still true), never pasted in English.
const _ageDe = 'Your age is not on file, and this is worked out from it.';

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
    final translated = presentationText(de, _ageDe);
    expect(translated, isNot(_ageDe), reason: 'the table knows it in German');
    expect(find.text(de.olderVersionNote(104, translated)), findsOneWidget);
    expect(find.textContaining(kReasonSentence), findsNothing);
  });

  testWidgets('the same through the mark\'s tap note', (t) async {
    await t.pumpWidget(MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildTheme(Brightness.light),
      home: const Scaffold(
          body: OlderVersionMark(id: 'x', version: 104, reason: kReasonRaw)),
    ));
    await t.tap(olderMark('x'));
    await t.pumpAndSettle();
    expect(find.textContaining(kReasonSentence), findsNothing);
    expect(find.text(de.olderVersionNote(104, presentationText(de, _ageDe))),
        findsOneWidget);
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
