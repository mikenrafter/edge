import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Routes framework errors into the returned list for the rest of the test,
/// and puts the previous handler back in a teardown so a failing or throwing
/// test cannot leave its collector installed. Nothing is dropped: a test that
/// uses this decides which of the collected messages are acceptable.
List<String> captureFlutterErrors() {
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (d) {
    // The binding reports a test body's own failure through this handler and
    // then asserts that it recorded it. Swallowing it here hangs the run
    // instead of reporting the failed expectation.
    if (d.context?.toDescription() == 'running a test') {
      previous?.call(d);
    } else {
      errors.add(d.exceptionAsString());
    }
  };
  addTearDown(() => FlutterError.onError = previous);
  return errors;
}
