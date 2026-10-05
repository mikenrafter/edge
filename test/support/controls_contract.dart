import 'package:flutter_test/flutter_test.dart';

/// Lets a test reach a production seam that may not exist, failing with a clear message.
/// This does not emulate policy: every decision comes from the production object.
T contract<T>(String behavior, T Function() invoke) {
  try {
    return invoke();
  } on NoSuchMethodError {
    fail('Missing production behavior: $behavior. See controls_contract.md.');
  }
}

Future<T> asyncContract<T>(String behavior, Future<T> Function() invoke) async {
  try {
    return await invoke();
  } on NoSuchMethodError {
    fail('Missing production behavior: $behavior. See controls_contract.md.');
  }
}

Future<void> flushOperations() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
