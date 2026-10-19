// Pins the PROCESS timezone for one test file, then restores it.
//
// Why: a few goldens are recorded under TZ=UTC (sleepClockOffsetSec is
// tz-corrected from the real system zone, and local day windows follow it).
// They used to markTestSkipped in any other zone, so a local full run skipped
// them silently and they went stale unnoticed. Pinning makes them run, and
// pass or fail, in every zone.
//
// How: libc setenv("TZ") + tzset(), the technique in
// test/day_window_dst_test.dart. Dart's DateTime reads the C library's local
// time on every call, so this re-homes the local calendar, isolates included.
// `flutter test` runs each file in its own process, so the pin cannot leak to
// another file; tearDownAll restores it anyway. POSIX only: on Windows this is
// a no-op and the zone stays whatever the machine has.
//
// Call it first thing in main(), before any test body or group reads the zone.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _SetenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _UnsetenvNative = Int32 Function(Pointer<Utf8>);
typedef _UnsetenvDart = int Function(Pointer<Utf8>);
typedef _TzsetNative = Void Function();
typedef _TzsetDart = void Function();

void _setProcessTz(String? tz) {
  final lib = DynamicLibrary.process();
  final key = 'TZ'.toNativeUtf8();
  try {
    if (tz == null) {
      lib.lookupFunction<_UnsetenvNative, _UnsetenvDart>('unsetenv')(key);
    } else {
      final value = tz.toNativeUtf8();
      lib.lookupFunction<_SetenvNative, _SetenvDart>('setenv')(key, value, 1);
      calloc.free(value);
    }
    lib.lookupFunction<_TzsetNative, _TzsetDart>('tzset')();
  } finally {
    calloc.free(key);
  }
}

/// Sets the process zone to [tz] now and restores the previous one after the
/// file's last test.
void pinProcessTimeZone([String tz = 'UTC']) {
  if (Platform.isWindows) return;
  final previous = Platform.environment['TZ'];
  _setProcessTz(tz);
  tearDownAll(() => _setProcessTz(previous));
}
