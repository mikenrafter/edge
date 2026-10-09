import 'mutant.dart';

/// Chooses which of [mutants] (already in generator order) to run.
///
/// - [sample] (needs [seed], else [ArgumentError]): that many mutants drawn
///   uniformly without replacement by a seeded PRNG implemented in this
///   package (so a seed means the same draw on every Dart version), returned in
///   the original order. Asking for more than exist returns all of them.
/// - [maxMutants]: afterwards, at most that many, the first ones in order.
/// - Neither: all of them. Negative numbers are an [ArgumentError].
List<Mutant> selectMutants(
  List<Mutant> mutants, {
  int? maxMutants,
  int? sample,
  int? seed,
}) =>
    throw UnimplementedError('selectMutants');
