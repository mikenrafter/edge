import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'backup/backup_support.dart';
import 'support/apk1_harness.dart';
import 'support/apk1_keys.dart';
import 'support/pin_tz.dart';

final _review = find.byKey(const ValueKey<String>(apk1ReviewActivities));
final _daynav = find.byKey(const ValueKey<String>('card:daynav'));

Future<void> _noPromptAnywhere(WidgetTester t) async {
  final p = t.state<ScrollableState>(apk1VerticalScroll.first).position;
  p.jumpTo(0);
  for (var i = 0; i < 100; i++) {
    await t.pump();
    expect(find.byType(DetectedActivitiesCard), findsNothing,
        reason: 'the removed prompt must not survive in another lazy-list item');
    expect(t.takeException(), isNull);
    if (p.pixels >= p.maxScrollExtent) break;
    p.jumpTo((p.pixels + 180).clamp(p.minScrollExtent, p.maxScrollExtent));
  }
  expect(p.pixels, p.maxScrollExtent, reason: 'checked the whole Home list');
  p.jumpTo(0);
  await t.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  pinProcessTimeZone();
  late BackupEnv env;
  setUpAll(() async => env = await apk1Environment('apk1_review.db'));
  tearDownAll(() => env.dispose());
  setUp(apk1ClearPrefs);

  for (final scale in [1.0, 3.1]) {
    for (final (failed, bare) in [
      (false, false), (true, false), (false, true), (true, true),
    ]) {
      apk1Test('${bare ? 'Bare' : 'Loaded'} Home removes the prompt card but keeps review reachable '
          'with ${failed ? 'a failed count' : 'pending activities'} at $scale', (t) async {
        final routes = Apk1Routes();
        // A bare day is the branch that currently puts card:detected ABOVE
        // card:daynav; a loaded day already puts it below the rings.
        await apk1Mount(t, routes: routes, scale: scale,
          source: HomeScreen(data: apk1Home(bare: bare, observation: null,
              reviewFailed: failed), now: apk1Now),
        );
        await _noPromptAnywhere(t);
        await apk1Reveal(t, _daynav);
        expect(_daynav, findsOneWidget);
        expect(find.byType(DetectedActivitiesCard), findsNothing,
            reason: 'remove the prompt card, including the bare-day copy above the date');
        expect(t.takeException(), isNull);
        await apk1Reveal(t, _review);
        expect(_review, findsOneWidget);
        expect(find.byType(DetectedActivitiesCard), findsNothing,
            reason: 'moving the old card below the fold does not remove it');
        expect(find.descendant(of: _review, matching: find.text('Review activities')), findsOneWidget);
        expect(t.getSize(_review).height, greaterThanOrEqualTo(44));
        expect(t.getRect(_review).right, lessThanOrEqualTo(360));
        expect(t.takeException(), isNull);
        await t.tap(_review);
        await apk1Settle(t);
        expect(find.byType(DetectedActivitiesScreen), findsOneWidget);
        expect(routes.routes, hasLength(2));
        expect(apk1Selected(t), ShellDomain.today.index);
        expect(t.takeException(), isNull);
        await t.binding.handlePopRoute();
        await apk1Settle(t);
        expect(routes.routes, hasLength(1));
        expect(find.byType(DetectedActivitiesScreen), findsNothing);
      });
    }
  }
}
