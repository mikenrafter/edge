import 'package:flutter_test/flutter_test.dart';

/// Allows the red phase to compile before the new production seams exist.
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
