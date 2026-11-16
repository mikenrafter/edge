import 'package:openstrap_edge/data/official_export/profile.dart';

class TestSnapshot implements OfficialSnapshot {
  TestSnapshot(this.run);
  final Future<String> Function(String) run;
  @override
  Future<String> capture(String path) => run(path);
}

class TestRecoveryChoice implements OfficialRecoveryChoice {
  TestRecoveryChoice(this.run);
  final Future<bool?> Function() run;
  @override
  Future<bool?> choose() => run();
}

class TestProgress implements OfficialExportProgress {
  TestProgress(this.run);
  final void Function(String, int?) run;
  @override
  void update(String stage, int? count) => run(stage, count);
}
