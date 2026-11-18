// The PRODUCTION calendar (`DayLabelCalendar`, the canonical day_label.dart API
// in the process zone) in the three zones the persistence checklist names.
//
// WHY: prune_cursor_test.dart proves the rule with a zone-database calendar; the
// exporter will run with the device's process zone, so the real wrapper must agree
// with the same independent literals when the process zone is moved. The host
// cannot move its zone on Boat (day_window_dst_test has the same limit): run this
// file on the shared host (edge-test) or CI. CLAIM(official-export-prune-edge).
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/prune_cursor.dart';

typedef _SetenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _UnsetenvNative = Int32 Function(Pointer<Utf8>);
typedef _UnsetenvDart = int Function(Pointer<Utf8>);
typedef _TzsetNative = Void Function();
typedef _TzsetDart = void Function();

void _setProcessZone(String? zone) {
  final lib = DynamicLibrary.process();
  final key = 'TZ'.toNativeUtf8();
  try {
    if (zone == null) {
      lib.lookupFunction<_UnsetenvNative, _UnsetenvDart>('unsetenv')(key);
    } else {
      final value = zone.toNativeUtf8();
      lib.lookupFunction<_SetenvNative, _SetenvDart>('setenv')(key, value, 1);
      calloc.free(value);
    }
    lib.lookupFunction<_TzsetNative, _TzsetDart>('tzset')();
  } finally {
    calloc.free(key);
  }
}

// zone -> (input instant, next local midnight at or after it), literals from an
// independent zone database.
const _cases = <String, List<(int, int)>>{
  'UTC': [(1792454400, 1792454400), (1792454401, 1792540800), (1792497600, 1792540800)],
  'America/Denver': [
    (1792476000, 1792476000), // exactly local midnight
    (1792476001, 1792562400),
    (1792519200, 1792562400), // noon
    (1793514600, 1793602800), // fall-back day, 25 h
    (1772962200, 1773036000), // spring-forward day, 23 h
  ],
  'Asia/Kolkata': [(1792434600, 1792434600), (1792434601, 1792521000), (1792477800, 1792521000)],
};

void main() {
  tearDown(() => _setProcessZone('UTC'));
  for (final e in _cases.entries) {
    test('${e.key}: DayLabelCalendar matches the independent literals', () {
      _setProcessZone(e.key);
      // Fails loudly on a host that cannot move its zone, rather than skipping.
      expect(
        DateTime.fromMillisecondsSinceEpoch(1792497600 * 1000).timeZoneName,
        isNotEmpty,
      );
      if (e.key == 'Asia/Kolkata') {
        expect(DateTime.utc(2026, 7, 1).toLocal().timeZoneOffset, const Duration(hours: 5, minutes: 30));
      }
      for (final (input, want) in e.value) {
        expect(const DayLabelCalendar().midnightAtOrAfter(input), want, reason: '${e.key} $input');
      }
    });
  }
}
