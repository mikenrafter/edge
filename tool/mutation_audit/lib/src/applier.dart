import 'mutant.dart';

/// A mutant is not applicable to the file as it is now (the original text is
/// not at the recorded offset).
class StaleMutantError extends StateError {
  StaleMutantError(super.message);
}

/// The file after restoring is not byte-identical to before applying.
class RestoreFailedError extends StateError {
  RestoreFailedError(super.message);
}

/// A mutant that has been written to disk and not yet restored.
class AppliedMutation {
  AppliedMutation(this.mutant, this.path, this.originalBytes);
  final Mutant mutant;
  final String path;
  final List<int> originalBytes;
}

/// Writes a mutant into a file under [root] and puts it back byte for byte.
class MutationApplier {
  MutationApplier(this.root);

  /// The disposable export (never the developer checkout).
  final String root;

  /// Replaces the bytes at the mutant's offset. Checks first that they are
  /// [Mutant.original] ([StaleMutantError] otherwise, file untouched) and
  /// that the file is not already mutated.
  Future<AppliedMutation> apply(Mutant mutant) =>
      throw UnimplementedError('MutationApplier.apply');

  /// Writes the original bytes back and re-reads the file to prove it
  /// ([RestoreFailedError] when it differs). Safe to call twice.
  Future<void> restore(AppliedMutation applied) =>
      throw UnimplementedError('MutationApplier.restore');
}
