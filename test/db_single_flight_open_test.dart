// LocalDb.instance is single-flight, and close() waits for an open in flight.
// Before, a close during the first open returned at once and the open then
// published a live handle; with a second racing open, one handle leaked with
// its transaction. In the sync tests a leaked handle from one test held a lock
// into the next, which then hung.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';

import 'support/app_state_derive_harness.dart';

const _db = 'db_single_flight_open.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => deriveDbSetUp(_db));
  tearDown(() => deriveDbTearDown(_db));

  test('a close during the first open waits for it and closes that handle',
      () async {
    final opening = LocalDb.instance;
    await LocalDb.close();
    final h = await opening;
    expect(h.isOpen, isFalse);
    expect(LocalDb.isStoreOpen, isFalse);
  });
}
