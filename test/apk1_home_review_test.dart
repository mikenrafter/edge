import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/day_review.dart' show DayReviewEntry;
import 'package:openstrap_edge/ui2/screens/detected_activities.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'backup/backup_support.dart';
import 'support/apk1_harness.dart';
import 'support/pin_tz.dart';

final _review = find.byKey(const ValueKey<String>('card:detected'));
final _daynav = find.byKey(const ValueKey<String>('card:daynav'));

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
      apk1Test('${bare ? 'Bare' : 'Loaded'} Home keeps one Review activities card, '
          'reachable with ${failed ? 'a failed count' : 'pending activities'} at $scale', (t) async {
        final routes = Apk1Routes();
        await apk1Mount(t, routes: routes, scale: scale,
          source: HomeScreen(data: apk1Home(bare: bare, observation: null,
              reviewFailed: failed), now: apk1Now),
        );
        await apk1Reveal(t, _daynav);
        expect(_daynav, findsOneWidget);
        await apk1Reveal(t, _review);
        expect(_review, findsOneWidget);
        // One card, wherever the day is bare or loaded: no second copy above
        // the date and no old marked-moment prompt.
        expect(find.byType(DetectedActivitiesCard), findsOneWidget);
        expect(find.descendant(of: _review, matching: find.text('Review activities')), findsOneWidget);
        expect(find.descendant(of: _review, matching: find.text(failed
            ? 'Could not load activities. Try again.' : '2 to review')), findsOneWidget);
        expect(t.getSize(_review).height, greaterThanOrEqualTo(44));
        expect(t.getRect(_review).right, lessThanOrEqualTo(360));
        expect(t.takeException(), isNull);
        await t.tap(_review);
        await apk1Settle(t);
        expect(find.byType(DayReviewEntry), findsOneWidget);
        expect(routes.routes, hasLength(2));
        expect(apk1Selected(t), ShellDomain.today.index);
        expect(t.takeException(), isNull);
        await t.binding.handlePopRoute();
        // Let the default route's reverse transition finish.
        await t.pump(const Duration(milliseconds: 500));
        await apk1Settle(t);
        expect(routes.routes, hasLength(1));
        expect(find.byType(DayReviewEntry), findsNothing);
      });
    }
  }
}
