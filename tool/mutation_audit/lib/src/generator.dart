import 'mutant.dart';

/// All mutants of [source] (the text of [file]), in deterministic order:
/// ascending byte offset, then operator id, then replacement text.
///
/// One mutant per executable site and replacement; never inside comments,
/// string literals (interpolations included), import / export / part
/// directives or annotations. Source that does not parse yields no mutants.
List<Mutant> generateMutants(String source, {required String file}) =>
    throw UnimplementedError('generateMutants');

/// The stable id of a mutant: `<file>:<byteOffset>:<operator id>:<hash>` where
/// hash is 8 lowercase hex digits of the FNV-1a 32-bit hash of the UTF-8
/// bytes of [mutated].
String mutantId({
  required String file,
  required int byteOffset,
  required MutationOperator operator,
  required String mutated,
}) =>
    throw UnimplementedError('mutantId');

/// [source] with [mutant] applied (replaces the bytes at its byte offset).
String mutatedSource(String source, Mutant mutant) =>
    throw UnimplementedError('mutatedSource');
