// why: owner rule (m385): a reload never blanks what is on screen. Placeholders
// belong to the first read and to a day switch; an update changes only the
// values that changed. CLAIM(home-reload-keeps-values).
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';
import 'support/as_of_recalc_fakes.dart';

class _Reads extends HomeRepo {
  _Reads() : super(homeBundle(withDaily: false));
  var next = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> getTodayStored() => next.future;
}

/// PendingContent regions inside the ring card that currently draw a placeholder.
int _pendingRings(WidgetTester t) => find
    .descendant(
        of: find.byType(RingTrio),
        matching: find.byWidgetPredicate((w) => w is PendingContent && w.pending))
    .evaluate()
    .length;

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('first read shows placeholders; a reload with data never does',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    final repo = _Reads();
    final app = AppState.forTesting()..repo = repo;
    addTearDown(app.dispose);
    await t.pumpWidget(perfApp(app, const HomeScreen()));
    await t.pump(const Duration(milliseconds: 400));
    expect(_pendingRings(t), greaterThan(0), reason: 'first load keeps placeholders');
    repo.next.complete(homeBundle(readiness: 22));
    await _settle(t);
    expect(find.text('Recovery 22 of 100'), findsOneWidget);
    expect(_pendingRings(t), 0);

    // A reload that takes longer than the 200 ms rule: values stay, no frame
    // of the placeholder, at any point of the wait.
    repo.next = Completer<Map<String, dynamic>>();
    app.insightsRevision.value++;
    for (var ms = 0; ms < 1200; ms += 50) {
      await t.pump(const Duration(milliseconds: 50));
      expect(_pendingRings(t), 0, reason: 'placeholder frame at ${ms + 50} ms');
      expect(find.text('Recovery 22 of 100'), findsOneWidget);
    }
    // The update lands: only the changed value changes, still no placeholder.
    repo.next.complete(homeBundle(readiness: 30));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
      expect(_pendingRings(t), 0);
    }
    expect(find.text('Recovery 30 of 100'), findsOneWidget);
    expect(find.text('Recovery 22 of 100'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
