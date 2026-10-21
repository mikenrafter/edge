// file_size.dart — the file-size guard's engine (owner rule A).
//
// Rule: no .dart file under lib/ or test/ may exceed [kMaxCodeLines] CODE lines
// (countCodeLines in code_lines.dart). Generated files are excluded entirely:
// lib/l10n/app_localizations*.dart, *.g.dart, *.freezed.dart (at any depth).
// Files outside lib/ and test/, and non-.dart files, are never scanned.
//
// test/guards/file_size_exceptions.json is a FLAT JSON object, repo-relative
// path -> recorded code-line count, for every file over the limit today.
//   * excepted file: fails when count > recorded + [kExceptionSlack];
//   * file over the limit and not listed: fails;
//   * listed file whose count is now strictly under the limit: fails, message
//     contains "remove it from the list" (shrink-only hygiene);
//   * listed path that no longer exists: fails.

import 'dart:convert';
import 'dart:io';

import 'code_lines.dart';

const int kMaxCodeLines = 6000;
const int kExceptionSlack = 200;

/// True for files the guard skips entirely. [relPath] is repo-relative with
/// forward slashes.
bool isGeneratedDart(String relPath) {
  if (relPath.endsWith('.g.dart') || relPath.endsWith('.freezed.dart')) {
    return true;
  }
  return RegExp(r'^lib/l10n/app_localizations[^/]*\.dart$').hasMatch(relPath);
}

/// Reads the exceptions file: a flat `{ "path": int }` object. Throws
/// [PathNotFoundException]/[FormatException] when it is missing or malformed.
Map<String, int> readFileSizeExceptions(String path) {
  final raw = jsonDecode(File(path).readAsStringSync());
  if (raw is! Map) {
    throw FormatException('$path: expected a flat {path: int} object');
  }
  final out = <String, int>{};
  for (final e in raw.entries) {
    final v = e.value;
    if (e.key is! String || v is! int) {
      throw FormatException('$path: ${e.key} must map to an int');
    }
    out[e.key as String] = v;
  }
  return out;
}

/// Code-line counts of every scanned (non-generated) .dart file under
/// `<root>/lib` and `<root>/test`, keyed by repo-relative path.
Map<String, int> scanCodeLines(String root) {
  final out = <String, int>{};
  for (final top in const ['lib', 'test']) {
    final dir = Directory('$root/$top');
    if (!dir.existsSync()) continue;
    final prefix = '$root/$top';
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final rel = '$top${e.path.substring(prefix.length)}'.replaceAll(r'\', '/');
      if (isGeneratedDart(rel)) continue;
      out[rel] = countCodeLines(e.readAsStringSync());
    }
  }
  return out;
}

/// Scans `<root>/lib` and `<root>/test` and returns one human-readable problem
/// per violation (empty = pass). Each message names the repo-relative path; the
/// listed-but-now-small case contains "remove it from the list". [limit] and
/// [slack] are injectable so fixtures stay tiny.
List<String> fileSizeProblems({
  required String root,
  required Map<String, int> exceptions,
  int limit = kMaxCodeLines,
  int slack = kExceptionSlack,
}) {
  final counts = scanCodeLines(root);
  final problems = <String>[];
  for (final e in counts.entries) {
    final recorded = exceptions[e.key];
    if (recorded == null) {
      if (e.value > limit) {
        problems.add('${e.key}: ${e.value} code lines, over the limit of '
            '$limit. Split the file; do not add it to the exceptions.');
      }
    } else if (e.value > recorded + slack) {
      problems.add('${e.key}: ${e.value} code lines, over its recorded '
          '$recorded + $slack allowed growth. Split the file.');
    }
  }
  for (final e in exceptions.entries) {
    final n = counts[e.key];
    if (n == null) {
      problems.add('${e.key}: listed in the file-size exceptions but does '
          'not exist; remove it from the list.');
    } else if (n < limit) {
      problems.add('${e.key}: now $n code lines, under the limit of $limit; '
          'remove it from the list.');
    }
  }
  return problems;
}
