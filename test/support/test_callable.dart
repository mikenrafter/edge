// Test-only adapters for production's named dispatch protocols. The hooks are
// scripted here; no opaque Function.call is added to the application graph.
import 'package:openstrap_edge/util/callable.dart';

final class TestCall0<R> implements Call0<R> {
  TestCall0(this.body);
  final R Function() body;
  @override
  R call() => body();
  // Relaunch listener tests preserve tear-off identity when registering/stopping.
  @override
  bool operator ==(Object other) => other is TestCall0<R> && other.body == body;
  @override
  int get hashCode => body.hashCode;
}

final class TestCall1<A, R> implements Call1<A, R> {
  TestCall1(this.body);
  final R Function(A) body;
  @override
  R call(A value) => body(value);
}

final class TestCall2<A, B, R> implements Call2<A, B, R> {
  TestCall2(this.body);
  final R Function(A, B) body;
  @override
  R call(A first, B second) => body(first, second);
}

final class TestCall3<A, B, C, R> implements Call3<A, B, C, R> {
  TestCall3(this.body);
  final R Function(A, B, C) body;
  @override
  R call(A first, B second, C third) => body(first, second, third);
}
