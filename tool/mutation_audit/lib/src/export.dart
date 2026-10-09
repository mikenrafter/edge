import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

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
  }) async {
    final String repoPath;
    try {
      repoPath = Directory(repo).resolveSymbolicLinksSync();
    } on FileSystemException catch (e) {
      throw ExportFailed('cannot read repository $repo: ${e.message}');
    }
    if (exportDir != null) {
      final target = _resolveLoosely(exportDir);
      if (p.equals(target, repoPath) || p.isWithin(repoPath, target) || p.isWithin(target, repoPath)) {
        throw UnsafeExportTarget('$exportDir is, contains or lies inside the developer checkout $repoPath');
      }
    }
    final resolved = await _git(repoPath, ['rev-parse', '--verify', '--quiet', '$sha^{commit}']);
    if (resolved.exitCode != 0) {
      throw ExportFailed('cannot resolve "$sha" in $repoPath: ${_text(resolved.stderr)}');
    }
    final full = _text(resolved.stdout);

    Directory? created;
    final String path;
    if (exportDir != null) {
      path = _resolveLoosely(exportDir);
    } else {
      final parent = parentDir == null ? Directory.systemTemp : Directory(parentDir);
      created = parent.createTempSync('mutation_audit_');
      path = created.resolveSymbolicLinksSync();
    }
    final added = await _git(repoPath, ['worktree', 'add', '--detach', path, full]);
    if (added.exitCode != 0) {
      if (created != null && created.existsSync()) created.deleteSync(recursive: true);
      await _git(repoPath, ['worktree', 'prune']);
      throw ExportFailed('git worktree add failed: ${_text(added.stderr)}');
    }
    return DisposableExport._(repoPath, full, path);
  }

  /// Removes the worktree registration (`git worktree remove --force` and
  /// prune) and the directory. Idempotent; never throws for an export that is
  /// already gone.
  Future<void> dispose() async {
    await _git(repo, ['worktree', 'remove', '--force', path]);
    final dir = Directory(path);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    await _git(repo, ['worktree', 'prune']);
  }
}

Future<ProcessResult> _git(String repo, List<String> args) =>
    Process.run('git', ['-C', repo, ...args]);

String _text(Object? out) => '$out'.trim();

/// An absolute, symlink-resolved spelling of [path] even when the last parts
/// do not exist yet: the deepest existing ancestor is resolved, the rest
/// appended.
String _resolveLoosely(String path) {
  final absolute = p.normalize(p.absolute(path));
  var existing = absolute;
  final rest = <String>[];
  while (!FileSystemEntity.isDirectorySync(existing) && !FileSystemEntity.isLinkSync(existing)) {
    final parent = p.dirname(existing);
    if (parent == existing) break;
    rest.insert(0, p.basename(existing));
    existing = parent;
  }
  var base = existing;
  try {
    base = Directory(existing).resolveSymbolicLinksSync();
  } on FileSystemException {
    // keep the normalised spelling
  }
  return p.joinAll([base, ...rest]);
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
}) async {
  final export = await DisposableExport.create(
      repo: repo, sha: sha, parentDir: parentDir, exportDir: exportDir);
  final interrupted = Completer<void>();
  final subscription = interrupts?.listen((_) {
    if (!interrupted.isCompleted) interrupted.complete();
  });
  try {
    final work = body(export)..ignore();
    final first = await Future.any<Object?>([
      work.then<Object?>((value) => _Finished<T>(value)),
      interrupted.future.then<Object?>((_) => null),
    ]);
    if (first is _Finished<T>) return first.value;
    throw InterruptedError();
  } finally {
    await subscription?.cancel();
    await export.dispose();
  }
}

class _Finished<T> {
  _Finished(this.value);
  final T value;
}

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
}) async {
  String? hashOf(String name) {
    final file = File(p.join(exportPath, name));
    return file.existsSync() ? sha256.convert(file.readAsBytesSync()).toString() : null;
  }

  YamlMap? load(String name) {
    final file = File(p.join(exportPath, name));
    if (!file.existsSync()) return null;
    final doc = loadYaml(file.readAsStringSync());
    return doc is YamlMap ? doc : null;
  }

  final overrides = <PathOverride>[];
  void overridesFrom(String name) {
    final entries = load(name)?['dependency_overrides'];
    if (entries is! YamlMap) return;
    for (final e in entries.entries) {
      final value = e.value;
      if (value is YamlMap && value['path'] != null) {
        overrides.add(PathOverride('${e.key}', '${value['path']}', name));
      }
    }
  }

  overridesFrom('pubspec_overrides.yaml');
  overridesFrom('pubspec.yaml');

  final git = <GitDependency>[];
  final packages = load('pubspec.lock')?['packages'];
  if (packages is YamlMap) {
    for (final e in packages.entries) {
      final pkg = e.value;
      if (pkg is! YamlMap) continue;
      final description = pkg['description'];
      if (description is! YamlMap) continue;
      if (pkg['source'] == 'git') {
        git.add(GitDependency('${e.key}', '${description['url']}', '${description['resolved-ref']}'));
      } else if (pkg['source'] == 'path') {
        // Only a `source: path` package is an override. A git package's
        // `description.path` is the folder inside that git repository.
        overrides.add(PathOverride('${e.key}', '${description['path']}', 'pubspec.lock'));
      }
    }
  }

  String target(String path) => p.normalize(p.absolute(p.join(repo, path)));
  final allowed = {for (final a in allowedOverrides) target(a)};
  for (final o in overrides) {
    if (!allowed.contains(target(o.path))) {
      throw PathOverrideRefused(
          '${o.source} redirects ${o.package} to ${o.path}; pass --allow-override for the audited sibling');
    }
  }
  return DependencyConfig(
    lockSha256: hashOf('pubspec.lock'),
    overridesFileSha256: hashOf('pubspec_overrides.yaml'),
    pathOverrides: overrides,
    gitDependencies: git,
  );
}
