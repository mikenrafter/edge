// A sub-tab index remembered from the five-tab Health (Overview,
// Explore, Trends, Vitals, Labs) has to land on the right one of the four-tab
// Health (Last night, Today, Trends, Labs).
//
// This asks for one pure function, HealthScreen.tabFromLegacy(int), so the
// mapping is written once and a stored index, a deep link or a golden can all
// go through it. Kept in its own file: a symbol that does not exist yet fails
// the compile of whatever file names it.
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ui2/screens/screens.dart';

void main() {
  const lastNight = 0, today = 1, trends = 2, labs = 3;

  test('old Overview (0) is Last night', () {
    expect(HealthScreen.tabFromLegacy(0), lastNight);
  });
  test('old Explore (1) is Trends', () {
    expect(HealthScreen.tabFromLegacy(1), trends);
  });
  test('old Trends (2) is Trends', () {
    expect(HealthScreen.tabFromLegacy(2), trends);
  });
  test('old Vitals (3) is Today', () {
    expect(HealthScreen.tabFromLegacy(3), today);
  });
  test('old Labs (4) is Labs', () {
    expect(HealthScreen.tabFromLegacy(4), labs);
  });
  test('an index that was never valid is Last night, never a crash', () {
    expect(HealthScreen.tabFromLegacy(-1), lastNight);
    expect(HealthScreen.tabFromLegacy(9), lastNight);
  });
}
