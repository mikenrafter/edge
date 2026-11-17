// WHY: a native read started by a widget needs its FakeAsync microtasks
// pumped before that context is discarded. The production close waits for
// CLAIM(widget-db-close): real read leases; teardown must prove their completion, never close under them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';

Future<void> closeWidgetDatabase(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  // A screen load can span several separately leased statements. Drain its
  // post-unmount continuations before installing close's new-reader barrier.
  for (var i = 0; i < 60; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  var completed = false;
  final closing = LocalDb.close().whenComplete(() => completed = true);
  for (var i = 0; i < 120 && !completed; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(completed, isTrue, reason: 'all native read leases must settle before teardown');
  await closing;
}
