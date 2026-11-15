import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/state/sleep_edit_runner.dart';

class TestSleepEditEffects implements SleepEditEffects {
  TestSleepEditEffects({
    required Future<void> Function(SleepEditJob) run,
    required Future<void> Function() publish,
    required void Function(bool) hold,
    this.onError,
  }) : _run = run,
       _publish = publish,
       _hold = hold;
  final Future<void> Function(SleepEditJob) _run;
  final Future<void> Function() _publish;
  final void Function(bool) _hold;
  @override
  Future<void> run(SleepEditJob job) => _run(job);
  @override
  Future<void> publish() => _publish();
  @override
  void hold(bool held) => _hold(held);
  final void Function(Object)? onError;
  @override
  void report(Object error) => onError?.call(error);
}

class TestSleepEditPublication implements SleepEditPublication {
  TestSleepEditPublication(this.action);
  final Future<bool> Function() action;
  @override
  Future<bool> publish() => action();
}
