// P2 RED golden stubs only. Parent must review and generate images in GREEN,
// then remove these explicit skips. No baseline images are invented here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'wake_widgets_test.dart' show pumpWakePage, dayFixture, sleepFixture;

void main() {
  testWidgets(
    'wake journal day timeline golden',
    (t) async {
      await pumpWakePage(t, dayFixture());
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/wake_journal_day.png'),
      );
    },
    skip: true, // P2 RED: parent generates and reviews baseline in GREEN
  );

  testWidgets(
    'wake journal sleep detail golden',
    (t) async {
      await pumpWakePage(t, SleepDetail(data: sleepFixture()));
      await expectLater(
        find.byType(SleepDetail),
        matchesGoldenFile('goldens/wake_journal_sleep.png'),
      );
    },
    skip: true, // P2 RED: parent generates and reviews baseline in GREEN
  );
}
