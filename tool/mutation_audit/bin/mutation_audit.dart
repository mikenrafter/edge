import 'dart:io';

import 'package:mutation_audit/mutation_audit.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
