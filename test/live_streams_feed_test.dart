// 8B — the Live devices buffer is fed from the live callbacks and from nothing
// else, in RAM only. The buffer's own rules are pinned in
// test/phase8/live_devices_test.dart; this pins the AppState taps.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A 20-byte 0x28 compact-HR frame carrying two beat intervals.
String _hr28(List<int> rr) {
  final b = List<int>.filled(20, 0);
  b[0] = 0x28;
  final ts = 1790000000;
  for (var i = 0; i < 4; i++) {
    b[2 + i] = (ts >> (8 * i)) & 0xff;
  }
  b[9] = rr.length;
  for (var i = 0; i < rr.length; i++) {
    b[10 + 2 * i] = rr[i] & 0xff;
    b[11 + 2 * i] = (rr[i] >> 8) & 0xff;
  }
  return b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a heart-rate reading lands in the buffer under its own device', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    final at = DateTime.now().millisecondsSinceEpoch;
    expect(app.debugAppendLiveHr('', 61, at), isTrue);
    expect(app.debugAppendLiveHr('polar-1', 120, at), isTrue);
    expect(app.liveStreams.retained('', 'hr').map((s) => s.value), [61]);
    expect(app.liveStreams.retained('polar-1', 'hr').map((s) => s.value), [120]);
  });

  test('a reading with no value is not a sample', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    expect(app.debugAppendLiveHr('', null, 1), isFalse);
    expect(app.debugAppendLiveHr('', 0, 2), isFalse);
    expect(app.liveStreams.streamKeys(''), isEmpty);
  });

  test('beat intervals from a live frame become an rr stream, oldest first',
      () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.debugOnLiveFrame(0x28, _hr28([800, 810]), 1790000000);
    final rr = app.liveStreams.retained('', 'rr');
    expect(rr.map((s) => s.value), [800, 810]);
    expect(rr.first.at.isBefore(rr.last.at), isTrue);
  });

  test('a frame with no beats adds nothing (no fabricated zero)', () {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    app.debugOnLiveFrame(0x28, _hr28([]), 1790000000);
    expect(app.liveStreams.streamKeys(''), isEmpty);
  });
}
