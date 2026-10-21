// The one place a callback handed in by a caller is invoked by value.
//
// The UI worker guard (test/guards/heavy_calc_guard_test.dart) cannot resolve
// an invocation of a function-typed variable and counts each one as new work
// on the UI isolate. These callbacks are cheap seams (a clock, a stop flag, a
// vibration), so they are applied here, once, behind a resolvable name.

/// Calls [callback] with [args] and returns its result as [T].
T applyCallback<T>(Function callback, [List<Object?> args = const []]) =>
    Function.apply(callback, args) as T;
