// RULES B.2 on the evening notification: the older-calculation note in its
// body is in the language the app shows (the same lookup every composed-without
// a BuildContext notification uses), not a silent English default.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations_de.dart';
import 'package:openstrap_edge/l10n/app_localizations_en.dart';
import 'package:openstrap_edge/l10n/app_localizations_es.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/older_version_fixtures.dart';

Future<String?> _headline(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final app = AppState.forTesting();
  addTearDown(app.dispose);
  app.repo = OlderRepo(charts: {
    'strain': [
      for (var back = 30; back >= 1; back--) cp(back, 6 + back % 3),
      cp(0, 20, older: 104),
    ],
  });
  final n = DateTime.now();
  return app.debugSweepHeadlineNow(now: DateTime(n.year, n.month, n.day, 15));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('German app: the note is German', () async {
    final h = (await _headline({'locale_override': 'de'}))!;
    expect(h, contains('20.0*'));
    expect(h, contains(AppLocalizationsDe().olderVersionSweepFinding(104)));
    expect(h, isNot(contains('Older calculation')));
  });

  test('Spanish app: the note is Spanish', () async {
    final h = (await _headline({'locale_override': 'es'}))!;
    expect(h, contains(AppLocalizationsEs().olderVersionSweepFinding(104)));
  });

  test('English app: the English key text', () async {
    final h = (await _headline({'locale_override': 'en'}))!;
    expect(h, contains(AppLocalizationsEn().olderVersionSweepFinding(104)));
  });
}
