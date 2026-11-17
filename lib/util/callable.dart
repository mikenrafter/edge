// Concrete dispatch protocols for stored hooks. A named method keeps runtime
// collaborators visible to the heavy-work analysis; Function.call cannot name
// its possible targets. Production adapters own concrete services. Test adapters
// live in test/support so instrumentation cannot add an opaque production path.
abstract interface class Call0<R> {
  R call();
}

abstract interface class Call1<A, R> {
  R call(A value);
}

abstract interface class Call2<A, B, R> {
  R call(A first, B second);
}

abstract interface class Call3<A, B, C, R> {
  R call(A first, B second, C third);
}
