// WHY: the coach's spoken outcome is what a TalkBack user hears instead of
// watching the reply land. The first pilot kept the FIRST assistant message of
// a turn, but the engine emits assistant text beside tool calls ("I will check
// your sleep") before the final answer, so the user heard the preamble, never
// the answer. If a later request failed, the preamble even masked the failure.
// Review round 1, finding S1.
//
// CLAIM(A11Y-COACH-OUTCOME): a turn that succeeds announces its LAST assistant
// message; a turn that fails announces the failure, whatever was said before.
// Both run through the real CoachScreen and CoachEngine, with only the HTTP
// boundary faked. (coachSpokenFirstSentence alone cannot see this: the bug is
// which message it is handed.)
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/screens/coach.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'backup/backup_support.dart';
import 'support/apk1_harness.dart';

/// A provider that answers the first request with a preamble and a tool call
/// (the tool is unknown, so the engine reports it to the model and goes on),
/// then either the final answer or a transport failure.
class _Provider extends http.BaseClient {
  _Provider({required this.secondFails, this.preamble = 'I will check your sleep.'});
  final bool secondFails;
  final String preamble;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    if (calls == 2 && secondFails) throw http.ClientException('Provider went away');
    final message = calls == 1
        ? {
            'role': 'assistant',
            'content': preamble,
            'tool_calls': [
              {'id': 'p1', 'function': {'name': 'no_such_tool', 'arguments': '{}'}}
            ],
          }
        : {'role': 'assistant', 'content': 'You slept seven hours.'};
    return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'choices': [{'message': message}]}))), 200,
        headers: {'content-type': 'application/json'});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUpAll(() async => env = await apk1Environment('a11y_coach_outcome.db'));
  tearDownAll(() => env.dispose());
  setUp(apk1ClearPrefs);

  /// Runs one turn ("How was my sleep?") and returns what the screen spoke.
  Future<({List<String> said, int calls})> turn(WidgetTester t, _Provider provider) async {
    final config = CoachConfig();
    await config.save(
        baseUrl: 'http://localhost:11434/v1', model: 'test-model', api: CoachApi.chatCompletions);
    final app = AppState.forTesting()..repo = Apk1Repo();
    await http.runWithClient(() async {
      await t.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<AppState>.value(value: app),
            ChangeNotifierProvider<CoachConfig>.value(value: config),
          ],
          child: MaterialApp(
              theme: buildTheme(Brightness.light),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const CoachScreen(initialMessage: 'How was my sleep?', startNewSession: true))));
      // File and HTTP work need real time; the frames need fake time.
      for (var i = 0; i < 30; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pump(const Duration(milliseconds: 100));
      }
    }, () => provider);
    final said = t.takeAnnouncements().map((a) => a.message).toList();
    await t.pumpWidget(const SizedBox());
    app.dispose();
    config.dispose();
    return (said: said, calls: provider.calls);
  }

  testWidgets('a preamble before the final answer: the answer is announced', (t) async {
    final r = await turn(t, _Provider(secondFails: false));
    expect(r.calls, 2, reason: 'the preamble turn and the answer turn both ran');
    expect(r.said, ['Coach replied: You slept seven hours.'],
        reason: 'the user must hear the answer, once, not the preamble');
  });

  testWidgets('a preamble, then a failed request: the failure is announced, not the preamble', (t) async {
    final r = await turn(t, _Provider(secondFails: true));
    expect(r.calls, 2);
    expect(r.said, hasLength(1));
    expect(r.said.single, contains('Provider went away'));
    expect(r.said.single, isNot(contains('I will check your sleep')),
        reason: 'a failed turn has no reply to announce');
  });
}
