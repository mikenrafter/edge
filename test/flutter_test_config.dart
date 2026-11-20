import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// The derive's second half reads `TypicalMealTimes` from SharedPreferences
/// (lib/data/typical_day_model.dart, added 2026-10-27). With no plugin and no
/// mock the read throws MissingPluginException, the day is stored partial, and
/// the checkpoint and metric_series writes never happen. Every test file starts
/// with an empty store; a test that needs values still calls
/// `SharedPreferences.setMockInitialValues` itself.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  SharedPreferences.setMockInitialValues({});
  await testMain();
}
