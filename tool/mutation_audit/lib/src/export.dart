import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'process_runner.dart';

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
  /// when given. Throws [UnsafeExportTarget] when the final export path -- on
  /// every creation path, whatever TMPDIR or parentDir say -- is, contains or
  /// lies inside the repo or any other worktree of it (after resolving
  /// symlinks), [ExportFailed] when git cannot export it. The repo is not
  /// modified.
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
    final resolved = await _git(repoPath, ['rev-parse', '--verify', '--quiet', '$sha^{commit}']);
    if (resolved.exitCode != 0) {
      throw ExportFailed('cannot resolve "$sha" in $repoPath: ${_text(resolved.stderr)}');
    }
    final full = _text(resolved.stdout);

    // Developer checkouts: the repository and every other worktree of it. The
    // final export path is validated on every creation path (explicit
    // exportDir, parentDir, the system temp dir -- TMPDIR may point anywhere).
    final protected = await _developerCheckouts(repoPath);
    void check(String target, {required bool whole}) {
      for (final dev in protected) {
        final inside = p.equals(target, dev) || p.isWithin(dev, target);
        // The export itself must also not contain a checkout. A parent
        // directory (checked before anything is created in it) may.
        final contains = whole && p.isWithin(target, dev);
        if (inside || contains) {
          throw UnsafeExportTarget('$target is, contains or lies inside the developer checkout $dev');
        }
      }
    }

    Directory? created;
    final String path;
    if (exportDir != null) {
      path = _resolveLoosely(exportDir);
      check(path, whole: true);
    } else {
      final parent = parentDir == null ? Directory.systemTemp : Directory(parentDir);
      check(_resolveLoosely(parent.path), whole: false);
      created = parent.createTempSync('mutation_audit_');
      path = created.resolveSymbolicLinksSync();
      try {
        check(path, whole: true);
      } on UnsafeExportTarget {
        created.deleteSync(recursive: true);
        rethrow;
      }
    }
    final added = await _git(repoPath, ['worktree', 'add', '--detach', path, full]);
    if (added.exitCode != 0) {
      if (created != null && created.existsSync()) created.deleteSync(recursive: true);
      await _git(repoPath, ['worktree', 'prune']);
      throw ExportFailed('git worktree add failed: ${_text(added.stderr)}');
    }
    return DisposableExport._(repoPath, full, path);
  }

  /// [repoPath] and every worktree git lists for it (the main one included),
  /// as resolved paths.
  static Future<List<String>> _developerCheckouts(String repoPath) async {
    final out = <String>{repoPath};
    final listed = await _git(repoPath, ['worktree', 'list', '--porcelain']);
    if (listed.exitCode == 0) {
      for (final line in '${listed.stdout}'.split('\n')) {
        if (line.startsWith('worktree ')) out.add(_resolveLoosely(line.substring('worktree '.length).trim()));
      }
    }
    return out.toList();
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
/// when [body] returns, when it throws, and when [interrupts] emits (Ctrl-C,
/// SIGTERM).
///
/// An interrupt does NOT abandon [body]: it cancels the [CancelToken] handed
/// to the body, and the export stays until the body has stopped what it
/// started (reaped the child processes, restored the mutated file) and
/// returned or thrown. Only then is the export removed, and
/// [InterruptedError] is thrown (also when the body had just finished, and
/// when the signal came while the export was being removed: the handler stays
/// installed until the removal is done).
///
/// [disposer] replaces `export.dispose()` (a seam for tests).
///
/// The interrupt subscription is made first, before anything is created, so a
/// signal during the (slow) creation of the export is not lost: the body is
/// not run and the half-made export is removed.
Future<T> withDisposableExport<T>({
  required String repo,
  required String sha,
  required Future<T> Function(DisposableExport export, CancelToken cancel) body,
  String? parentDir,
  String? exportDir,
  Stream<ProcessSignal>? interrupts,
  Future<void> Function(DisposableExport export)? disposer,
}) async {
  final cancel = CancelToken();
  final subscription = interrupts?.listen((_) => cancel.cancel());
  DisposableExport? export;
  late final T value;
  try {
    export = await DisposableExport.create(
        repo: repo, sha: sha, parentDir: parentDir, exportDir: exportDir);
    if (cancel.isCancelled) throw InterruptedError();
    value = await body(export, cancel);
  } finally {
    // The handler outlives the removal: with it gone, a Ctrl-C during
    // `git worktree remove` would take the default action and orphan the export.
    try {
      if (export != null) await (disposer ?? (e) => e.dispose())(export);
    } finally {
      await subscription?.cancel();
    }
  }
  // A signal at any point, cleanup included, is an interrupt (exit 130).
  if (cancel.isCancelled) throw InterruptedError();
  return value;
}

/// The run was interrupted by a signal.
class InterruptedError implements Exception {
  @override
  String toString() => 'InterruptedError';
}

/// One path dependency that redirects a package to a directory.
class PathOverride {
  const PathOverride(this.package, this.path, this.source,
      {this.resolvedPath, this.gitHead, this.dirty});
  final String package, path;

  /// `pubspec_overrides.yaml`, `pubspec.yaml` or `pubspec.lock`.
  final String source;

  /// Where Pub resolves [path]: against the export, canonical.
  final String? resolvedPath;

  /// The sibling's git HEAD and whether its working tree has uncommitted
  /// changes (untracked files included). Null when [resolvedPath] is not the
  /// top level of a git repository: unknown, never guessed.
  final String? gitHead;
  final bool? dirty;

  Map<String, Object?> toJson() => {
        'package': package,
        'path': path,
        'source': source,
        'resolvedPath': resolvedPath,
        'gitHead': gitHead,
        'dirty': dirty,
      };
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
    this.packageConfigSha256,
  });

  /// SHA-256 of pubspec.lock / pubspec_overrides.yaml, null when absent.
  final String? lockSha256, overridesFileSha256;

  /// SHA-256 of `.dart_tool/package_config.json`: what Pub actually resolved
  /// (it exists only once setup has run), null when absent.
  final String? packageConfigSha256;
  final List<PathOverride> pathOverrides;
  final List<GitDependency> gitDependencies;

  Map<String, Object?> toJson() => {
        'pubspecLockSha256': lockSha256,
        'pubspecOverridesSha256': overridesFileSha256,
        'packageConfigSha256': packageConfigSha256,
        'pathOverrides': [for (final o in pathOverrides) o.toJson()],
        'gitDependencies': [for (final g in gitDependencies) g.toJson()],
      };
}

/// Reads the dependency configuration of the export at [exportPath] and
/// refuses ([PathOverrideRefused]) when a path override is active, unless it
/// points at one of [allowedOverrides] (absolute, or relative to [repo], the
/// developer checkout). A relative override is resolved against the EXPORT --
/// where Pub reads it -- not against [repo]; both sides are canonicalised
/// (`..`, `.`, trailing slashes, symlinks) before they are compared. Path
/// overrides are: entries of pubspec_overrides.yaml, `dependency_overrides`
/// entries of pubspec.yaml with a `path:`, and `source: path` packages in
/// pubspec.lock. Git pins are only recorded. For each allowed override the
/// sibling's git HEAD and dirty flag are recorded.
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

  final allowed = {for (final a in allowedOverrides) _resolveLoosely(p.join(repo, a))};
  final recorded = <PathOverride>[];
  for (final o in overrides) {
    // Pub resolves a relative path against the project it reads it in: the export.
    final where = _resolveLoosely(p.join(exportPath, o.path));
    if (!allowed.contains(where)) {
      throw PathOverrideRefused(
          '${o.source} redirects ${o.package} to ${o.path}, which Pub resolves (relative to the '
          'export $exportPath) to $where; that is not an allowed sibling'
          '${allowed.isEmpty ? '' : ' (allowed: ${allowed.join(', ')})'}; '
          'pass --allow-override with the absolute path of the audited sibling');
    }
    final state = await _gitState(where);
    recorded.add(PathOverride(o.package, o.path, o.source,
        resolvedPath: where, gitHead: state?.$1, dirty: state?.$2));
  }
  return DependencyConfig(
    lockSha256: hashOf('pubspec.lock'),
    overridesFileSha256: hashOf('pubspec_overrides.yaml'),
    packageConfigSha256: hashOf(p.join('.dart_tool', 'package_config.json')),
    pathOverrides: recorded,
    gitDependencies: git,
  );
}

/// HEAD and dirtiness of the git repository whose top level is [dir]; null
/// when [dir] is not such a top level (not a repository, missing, or only a
/// subdirectory of one).
Future<(String, bool)?> _gitState(String dir) async {
  if (!Directory(dir).existsSync()) return null;
  try {
    final top = await _git(dir, ['rev-parse', '--show-toplevel']);
    if (top.exitCode != 0 || !p.equals(_resolveLoosely(_text(top.stdout)), dir)) return null;
    final head = await _git(dir, ['rev-parse', 'HEAD']);
    final status = await _git(dir, ['status', '--porcelain']);
    if (head.exitCode != 0 || status.exitCode != 0) return null;
    return (_text(head.stdout), _text(status.stdout).isNotEmpty);
  } on ProcessException {
    return null;
  }
}
