// Owns cross-day artifact construction and encoding inside the worker. The
// coordinator supplies the immutable read snapshot and publication metadata.
import 'dart:convert';
import '../util/heavy.dart';
import '../util/worker_init.dart';
import '../util/worker_audit.dart';
import 'crossday_pipeline.dart';

@SendableShape('SQL scalar/profile maps; sendable_buildCrossDayArtifactHeavy_test round-trips populated inputs')
class CrossDayArtifactInput {
  const CrossDayArtifactInput(this.worker, this.days, this.profile,
      this.cycleStarts, this.sessionTypes, this.methodFamilies, this.algorithm,
      this.builtForDay, this.builtAtEpoch, this.zone, this.inputSignature);
  final WorkerInputs worker;
  final List<Map<String, dynamic>> days;
  final Map<String, dynamic> profile;
  final List<String> cycleStarts;
  final Map<String, List<String>> sessionTypes;
  final Map<String, String> methodFamilies;
  final int algorithm, builtAtEpoch;
  final String builtForDay, zone;
  final String? inputSignature;
}

@sendable
class CrossDayArtifactResult {
  const CrossDayArtifactResult(this.json, this.dropped, this.needMin);
  final String json;
  final List<String> dropped;
  final double? needMin;
}

/// Bounded projection, shared by the worker and the existing public read seam.
/// A refused need remains absent; no population default is introduced.
double? crossDayNeedMinutes(Map<String, dynamic> bundle) =>
    switch (bundle['sleep_coach']) {
      {'need': {'value': {'need_sec': final num s}}} =>
        (s / 60).roundToDouble(),
      _ => null,
    };

@heavy
CrossDayArtifactResult buildCrossDayArtifactHeavy(CrossDayArtifactInput input) {
  WorkerInit.ensure(input.worker);
  assertWorker();
  WorkerAudit.entered('buildCrossDayArtifactHeavy');
  final bundle = buildCrossDayBundle(input.days, input.profile,
      cycleStartDates: input.cycleStarts,
      sessionTypesByDate: input.sessionTypes,
      methodFamilies: input.methodFamilies)
    ..['algo_version'] = input.algorithm
    ..['built_for_day'] = input.builtForDay
    ..['built_at_epoch'] = input.builtAtEpoch
    ..['zone'] = input.zone;
  if (input.inputSignature != null) bundle['input_sig'] = input.inputSignature;
  final paths = <String>[];
  final safe = sanitizeForJson(bundle, paths) as Map<String, dynamic>;
  if (paths.isNotEmpty) safe['encode_dropped_fields'] = paths;
  return CrossDayArtifactResult(jsonEncode(safe), paths, crossDayNeedMinutes(safe));
}
