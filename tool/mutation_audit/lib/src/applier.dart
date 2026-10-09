import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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

  /// Files that carry a mutation not yet restored.
  final Set<String> _mutated = {};

  /// Replaces the bytes at the mutant's offset. Checks first that they are
  /// [Mutant.original] ([StaleMutantError] otherwise, file untouched) and
  /// that the file is not already mutated.
  Future<AppliedMutation> apply(Mutant mutant) async {
    final path = _resolve(mutant.file);
    if (_mutated.contains(path)) {
      throw StaleMutantError('${mutant.file} still carries an unrestored mutation');
    }
    final bytes = await File(path).readAsBytes();
    final original = utf8.encode(mutant.original);
    final end = mutant.byteOffset + mutant.byteLength;
    var fits = mutant.byteOffset >= 0 &&
        end <= bytes.length &&
        mutant.byteLength == original.length;
    for (var i = 0; fits && i < original.length; i++) {
      fits = bytes[mutant.byteOffset + i] == original[i];
    }
    if (!fits) {
      throw StaleMutantError(
          '${mutant.file}: "${mutant.original}" is not at byte ${mutant.byteOffset}');
    }
    final mutated = [
      ...bytes.sublist(0, mutant.byteOffset),
      ...utf8.encode(mutant.mutated),
      ...bytes.sublist(end),
    ];
    await File(path).writeAsBytes(mutated, flush: true);
    _mutated.add(path);
    return AppliedMutation(mutant, path, bytes);
  }

  /// Writes the original bytes back and re-reads the file to prove it
  /// ([RestoreFailedError] when it differs). Safe to call twice.
  Future<void> restore(AppliedMutation applied) async {
    final file = File(applied.path);
    await file.writeAsBytes(applied.originalBytes, flush: true);
    final back = await file.readAsBytes();
    var same = back.length == applied.originalBytes.length;
    for (var i = 0; same && i < back.length; i++) {
      same = back[i] == applied.originalBytes[i];
    }
    if (!same) {
      throw RestoreFailedError('${applied.mutant.file} is not byte-identical after restore');
    }
    _mutated.remove(applied.path);
  }

  String _resolve(String relative) {
    final full = p.normalize(p.join(root, relative));
    if (p.isAbsolute(relative) || !p.isWithin(p.normalize(root), full)) {
      throw ArgumentError.value(relative, 'file', 'must be a path inside the export');
    }
    return full;
  }
}
