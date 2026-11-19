import 'dart:ffi';
import 'package:ffi/ffi.dart';
typedef _SetenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _UnsetenvNative = Int32 Function(Pointer<Utf8>);
typedef _UnsetenvDart = int Function(Pointer<Utf8>);
typedef _TzsetNative = Void Function();
typedef _TzsetDart = void Function();

void setProcessTz(String? tz) {
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

