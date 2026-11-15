// WHY: results that land far from the focus were silent: a reply from the
// coach, a pairing outcome, the end of a sync the user asked for (inventory
// 4.04-4.06). The owner's rule (2026-11-15): only what the USER started is
// announced when it ends; background refreshes stay quiet.
//
// CLAIM(A11Y-ANNOUNCE): announcements are polite and in the ambient text
// direction; AnnounceOnChange speaks changes, not the first build;
// AnnounceLoadEnd speaks only user-started loads; Sync now says how it ended.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/coach.dart' show coachSpokenFirstSentence;
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/header_rows_fakes.dart';

Widget _app(Widget child, {TextDirection dir = TextDirection.ltr}) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Directionality(textDirection: dir, child: Scaffold(body: child)),
    );

class _SyncApp extends HeaderApp {
  _SyncApp(this.ends);
  final SyncPresentationState ends;
  @override
  Future<void> syncNow() async {
    syncs++;
    pres = ends;
  }
}

void main() {
  testWidgets('announce is polite and follows the text direction', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(_app(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }), dir: TextDirection.rtl));
    announce(ctx, 'Done');
    final a = t.takeAnnouncements().single;
    expect(a.message, 'Done');
    expect(a.textDirection, TextDirection.rtl, reason: "base say() hard-coded ltr");
    expect(a.assertiveness, Assertiveness.polite);
  });

  testWidgets('AnnounceOnChange: not on the first build, then on each change', (t) async {
    Widget at(String? m) => _app(AnnounceOnChange(message: m, child: const Text('x')));
    await t.pumpWidget(at('Searching'));
    await t.pump();
    expect(t.takeAnnouncements(), isEmpty, reason: 'opening a screen is not a change');
    await t.pumpWidget(at('Paired'));
    await t.pump();
    expect(t.takeAnnouncements().map((a) => a.message), ['Paired']);
    await t.pumpWidget(at('Paired'));
    await t.pump();
    expect(t.takeAnnouncements(), isEmpty, reason: 'the same message is not repeated');
    await t.pumpWidget(at(null));
    await t.pump();
    expect(t.takeAnnouncements(), isEmpty, reason: 'nothing to say is silence');
  });

  testWidgets('AnnounceLoadEnd: a load the user started says it ended; a background one does not', (t) async {
    Widget at(bool loading, bool user) => _app(AnnounceLoadEnd(
        loading: loading, userStarted: user, done: 'Sleep loaded', child: const Text('x')));
    await t.pumpWidget(at(true, true));
    await t.pumpWidget(at(false, true));
    await t.pump();
    expect(t.takeAnnouncements().map((a) => a.message), ['Sleep loaded']);
    await t.pumpWidget(at(true, false));
    await t.pumpWidget(at(false, false));
    await t.pump();
    expect(t.takeAnnouncements(), isEmpty, reason: 'background refreshes stay quiet');
  });

  for (final (name, ends, says) in [
    ('finished', const SyncPresentationState(phase: 'completed'), 'Sync finished'),
    ('failed', const SyncPresentationState(phase: 'failed', failureReason: 'Band out of range'), 'Band out of range'),
  ]) {
    testWidgets('Sync now says how it ended: $name', (t) async {
      final app = _SyncApp(ends);
      late BuildContext ctx;
      await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
          value: app,
          child: _app(Builder(builder: (c) {
            ctx = c;
            return const SizedBox();
          }))));
      await syncNowAndSay(ctx);
      await t.pump();
      expect(app.syncs, 1);
      expect(t.takeAnnouncements().map((a) => a.message), [says]);
    });
  }

  test('the coach announcement is the reply\'s first sentence, without markdown', () {
    expect(coachSpokenFirstSentence('**Your sleep** was short. Try bed at 22:30.'),
        'Your sleep was short.');
    expect(coachSpokenFirstSentence('# Heading\nBody'), 'Heading');
    expect(coachSpokenFirstSentence('No full stop'), 'No full stop');
    expect(coachSpokenFirstSentence('x' * 300).length, 241);
  });
}
