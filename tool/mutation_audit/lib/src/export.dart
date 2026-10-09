import 'dart:io' show ProcessSignal;

/// The export target is, contains or lies inside the developer checkout.
class UnsafeExportTarget implements Exception {
  UnsafeExportTarget(this.message);
  final String message;
  @override
  String toString() => 'UnsafeExportTarget: $message';
}

/// A path override (pubspec_overrides.yaml, `dependency_overrides` with a
/// path, or a `source: path` lock entry) is active and not allowed.
class PathOverrideRefused implements Exception {
  PathOverrideRefused(this.message);
  final String message;
  @override
  String toString() => 'PathOverrideRefused: $message';
}

/// The commit could not be exported (unknown sha, not a git repository).
class ExportFailed implements Exception {
  ExportFailed(this.message);
  final String message;
  @override
  String toString() => 'ExportFailed: $message';
}

/// A disposable copy of one commit: `git worktree add --detach <path> <sha>`
/// under a fresh temporary directory. The developer checkout is never touched
/// (no commit, stash, checkout or reset in it).
class DisposableExport {
  DisposableExport._(this.repo, this.sha, this.path);

  /// The developer repository the export came from (absolute, resolved).
  final String repo;

  /// The full 40-hex commit that was exported.
  final String sha;

  /// The export directory.
  final String path;

  /// Exports [sha] (any rev git resolves) of [repo]. The directory is created
  /// under [parentDir] (default: the system temp dir), or is [exportDir]
  /// when given. Throws [UnsafeExportTarget] when the target is the repo, a
  /// parent of it or inside it (after resolving symlinks), [ExportFailed]
  /// when git cannot export it. The repo is not modified.
  static Future<DisposableExport> create({
    required String repo,
    required String sha,
    String? parentDir,
    String? exportDir,
  }) =>
      throw UnimplementedError('DisposableExport.create');

  /// Removes the worktree registration (`git worktree remove --force` and
  /// prune) and the directory. Idempotent; never throws for an export that is
  /// already gone.
  Future<void> dispose() => throw UnimplementedError('DisposableExport.dispose');
}

/// Creates the export, runs [body] with it, and disposes of it afterwards:
/// when [body] returns, when it throws, and when [interrupts] emits (Ctrl-C):
/// then the export is disposed of, [body] is abandoned, and an
/// [InterruptedError] is thrown. The export is removed before the future
/// completes.
Future<T> withDisposableExport<T>({
  required String repo,
  required String sha,
  required Future<T> Function(DisposableExport export) body,
  String? parentDir,
  String? exportDir,
  Stream<ProcessSignal>? interrupts,
}) =>
    throw UnimplementedError('withDisposableExport');

/// The run was interrupted by a signal.
class InterruptedError implements Exception {
  @override
  String toString() => 'InterruptedError';
}

/// One path dependency that redirects a package to a directory.
class PathOverride {
  const PathOverride(this.package, this.path, this.source);
  final String package, path;

  /// `pubspec_overrides.yaml`, `pubspec.yaml` or `pubspec.lock`.
  final String source;
  Map<String, Object?> toJson() =>
      {'package': package, 'path': path, 'source': source};
}

/// A dependency resolved from git, as the lock file pins it.
class GitDependency {
  const GitDependency(this.package, this.url, this.resolvedRef);
  final String package, url, resolvedRef;
  Map<String, Object?> toJson() =>
      {'package': package, 'url': url, 'resolvedRef': resolvedRef};
}

/// What the export resolves its dependencies from.
class DependencyConfig {
  const DependencyConfig({
    required this.lockSha256,
    required this.overridesFileSha256,
    required this.pathOverrides,
    required this.gitDependencies,
  });

  /// SHA-256 of pubspec.lock / pubspec_overrides.yaml, null when absent.
  final String? lockSha256, overridesFileSha256;
  final List<PathOverride> pathOverrides;
  final List<GitDependency> gitDependencies;

  Map<String, Object?> toJson() => {
        'pubspecLockSha256': lockSha256,
        'pubspecOverridesSha256': overridesFileSha256,
        'pathOverrides': [for (final o in pathOverrides) o.toJson()],
        'gitDependencies': [for (final g in gitDependencies) g.toJson()],
      };
}

/// Reads the dependency configuration of the export at [exportPath] and
/// refuses ([PathOverrideRefused]) when a path override is active, unless its
/// target, resolved against [repo] (where it was written), is one of
/// [allowedOverrides] (absolute or relative to [repo], resolved the same way).
/// Path overrides are: entries of pubspec_overrides.yaml, `dependency_overrides`
/// entries of pubspec.yaml with a `path:`, and `source: path` packages in
/// pubspec.lock. Git pins are only recorded.
Future<DependencyConfig> resolveDependencyConfig(
  String exportPath, {
  required String repo,
  List<String> allowedOverrides = const [],
}) =>
    throw UnimplementedError('resolveDependencyConfig');
