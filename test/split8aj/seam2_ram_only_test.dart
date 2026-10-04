// 8AJ seam 2 characterization of AGENTS §3.14: live frames, the developer feed
// and the live-HR viewers are RAM only. Measured with SQLite's total_changes()
// on the app's own connection (any INSERT / UPDATE / DELETE moves it) and with
// the preference keys. Must pass before and after the LiveStreamController move.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show BandProfile;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/derive_harness.dart' show deriveDbSetUp, deriveDbTearDown, settleMs;
import 'support/live_harness.dart';

const _db = 'openstrap_split8aj_seam2_ram_only.db';

Future<int> _changes() async {
  final db = await LocalDb.instance;
  final r = await db.rawQuery('SELECT total_changes() AS n');
  return (r.single['n'] as num).toInt();
}

Future<Set<String>> _prefKeys() async =>
    (await SharedPreferences.getInstance()).getKeys();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  Future<void> flood(AppState app, {required bool gen5}) async {
    for (var i = 0; i < 5; i++) {
      app.debugAppendLiveHr(kBandId, 60 + i, 1790000000000 + i * 1000);
      app.debugOnLiveFrame(0x28, hexOf(hr28Inner(hr: 60 + i, rr: [800 + i])), null);
      if (gen5) {
        app.debugOnLiveFrame(0x2B, hexOf(r21LiveInner()), 1790000000);
        app.debugOnLiveFrame(0x2B, hexOf(r17LiveInnerWith(liveHr: 70)), null);
      } else {
        app.debugOnLiveFrame(0x33, hexOf(imu33Inner()), 1790000000);
        app.debugOnLiveFrame(0x2B, hexOf(r10LiveInner()), 1790000000);
        app.debugOnLiveFrame(0x2B, hexOf(r11LiveInner()), null);
      }
    }
  }

  for (final gen5 in [true, false]) {
    final name = gen5 ? 'gen5' : 'gen4';
    test('start, a flood of frames, a live-HR viewer and stop write no row '
        'and no preference ($name)', () async {
      final rig = G6Rig(band: gen5 ? BandProfile.gen5 : BandProfile.gen4);
      addTearDown(rig.dispose);
      await LocalDb.instance;
      // The once-only alert-prefs migration writes its blob on the first read,
      // whoever makes it; take that out of the baseline.
      await NotificationPrefs.load();
      await settleMs(300);
      final rows = await _changes();
      final prefs = await _prefKeys();
      await rig.app.startLiveFeed(kBandId);
      rig.app.retainLiveHrView();
      await rig.settle();
      await flood(rig.app, gen5: gen5);
      rig.app.releaseLiveHrView();
      await rig.app.stopLiveFeed(kBandId);
      await rig.settle();
      expect(rig.app.liveStreams.streamKeys(kBandId), isNotEmpty,
          reason: 'the frames did land in RAM');
      expect(await _changes(), rows);
      expect(await _prefKeys(), prefs);
    });
  }

  test('a flood into a bare forTesting app (no engine frames) writes nothing',
      () async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await LocalDb.instance;
    await settleMs(100);
    final rows = await _changes();
    await flood(app, gen5: true);
    await flood(app, gen5: false);
    await settleMs(100);
    expect(await _changes(), rows);
  });

  test('the buffer holds a sliding 30 s window and is not a store: a restart '
      '(new AppState) starts empty', () async {
    final first = AppState.forTesting();
    await flood(first, gen5: true);
    expect(first.liveStreams.streamKeys(kBandId), isNotEmpty);
    first.dispose();
    final second = AppState.forTesting();
    addTearDown(second.dispose);
    expect(second.liveStreams.streamKeys(kBandId), isEmpty);
    expect(identical(first.liveStreams, second.liveStreams), isFalse);
  });
}
