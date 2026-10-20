// The staged-sleep key must see the UTC offset AT THE NIGHT'S OWN instants,
// not only today's zone abbreviation and offset: Denver and Phoenix read the
// same in winter and differ on a summer night, so a device-zone change between
// them must not reuse a staging made under the other (AGENTS §3.7, §3.3).
// Pinned to Denver for the whole file (one zone per process); the "other"
// zone is a fixed-offset function handed to the key.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/compute/sleep_staging_worker.dart';
import 'package:openstrap_edge/compute/staged_sleep_cache.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/util/worker_init.dart';

import 'support/pin_tz.dart';

class _Phoenix extends ZoneOffsets {
  const _Phoenix();
  @override
  int minutesAt(int epochSec) => -420;
}

const _phoenix = _Phoenix();

final _inputs = WorkerInputs(
  nowEpochMs: 0,
  zoneId: 'UTC',
  localeTag: 'en',
);

SleepStagingInput _input() => const SleepStagingInput(
      dayId: '2026-07-10',
      searchSub: Substrate.empty,
      override: null,
      priorSleep: [],
      confirmedWakeSec: null,
      profileJson: null,
      mayFold: false,
      rowChunks: [],
      rowsLoSec: 0,
      rowsHiSec: 0,
      nowSec: 0,
    );

StagingProvenance _prov(int from, int to,
        {Map<int, int> revs = const {1: 1},
        Map<InputSignal, List<({int start, int end, String? deviceId})>>
            ownership = const {},
        int wipeEpoch = 0}) =>
    StagingProvenance(
      fromSec: from,
      toSec: to,
      revs: revs,
      ownership: ownership,
      wipeEpoch: wipeEpoch,
      openCount: 1,
    );

int _sec(int y, int m, int d, int h) =>
    DateTime.utc(y, m, d, h).millisecondsSinceEpoch ~/ 1000;

(int, int) _digest(StagingProvenance p, {ZoneOffsets zone = const ZoneOffsets()}) =>
    stagingInputDigest(_inputs, _input(),
        zoneKey: 'MST|-420', provenance: p, zone: zone);

void main() {
  pinProcessTimeZone('America/Denver');

  test('a summer night differs between Denver and Phoenix', () {
    final p = _prov(_sec(2026, 7, 10, 3), _sec(2026, 7, 10, 15));
    expect(_digest(p), isNot(_digest(p, zone: _phoenix)),
        reason: 'MDT is -6 h, Phoenix -7 h: same key today, not on the night');
  });

  test('a winter night is the same in both (no spurious miss)', () {
    final p = _prov(_sec(2026, 1, 10, 3), _sec(2026, 1, 10, 15));
    expect(_digest(p), _digest(p, zone: _phoenix));
  });

  test('nightZoneOffsets sees a DST transition inside the window', () {
    // 2026-03-08 02:00 MST -> MDT in Denver.
    final across = _prov(_sec(2026, 3, 8, 3), _sec(2026, 3, 8, 15));
    final before = _prov(_sec(2026, 3, 7, 3), _sec(2026, 3, 7, 15));
    expect(nightZoneOffsets(across.fromSec - 86400, across.toSec + 86400)
        .map((e) => e[1])
        .toSet(), {-420, -360});
    expect(nightZoneOffsets(before.fromSec - 86400 * 3, before.toSec)
        .map((e) => e[1])
        .toSet(), {-420});
  });

  test('substrate provenance moves the key; unchanged provenance does not',
      () {
    final from = _sec(2026, 7, 10, 3), to = _sec(2026, 7, 10, 15);
    final base = _digest(_prov(from, to));
    expect(_digest(_prov(from, to)), base);
    expect(_digest(_prov(from, to, revs: const {1: 2})), isNot(base),
        reason: 'an input_rev bucket bump (in-place row change)');
    expect(_digest(_prov(from, to, revs: const {1: 1, 2: 1})), isNot(base));
    expect(_digest(_prov(from, to, wipeEpoch: 1)), isNot(base),
        reason: 'a wiped or rebuilt store resets input_rev');
    expect(_digest(_prov(from, to + 900)), isNot(base));
    expect(
        _digest(_prov(from, to, ownership: {
          InputSignal.hr1Hz: [(start: from, end: to, deviceId: 'ring')],
        })),
        isNot(base),
        reason: 'ownership picks which device\'s row each second uses');
  });
}
