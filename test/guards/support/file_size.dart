// file_size.dart — the file-size guard's engine (owner rule A).
//
// STUBS (red phase): every function throws until the green phase implements it.
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

const int kMaxCodeLines = 6000;
const int kExceptionSlack = 200;

/// True for files the guard skips entirely. [relPath] is repo-relative with
/// forward slashes.
bool isGeneratedDart(String relPath) =>
    throw UnimplementedError('isGeneratedDart');

/// Reads the exceptions file: a flat `{ "path": int }` object. Throws
/// [PathNotFoundException]/[FormatException] when it is missing or malformed.
Map<String, int> readFileSizeExceptions(String path) =>
    throw UnimplementedError('readFileSizeExceptions');

/// Scans `<root>/lib` and `<root>/test` and returns one human-readable problem
/// per violation (empty = pass). Each message names the repo-relative path; the
/// listed-but-now-small case contains "remove it from the list". [limit] and
/// [slack] are injectable so fixtures stay tiny.
List<String> fileSizeProblems({
  required String root,
  required Map<String, int> exceptions,
  int limit = kMaxCodeLines,
  int slack = kExceptionSlack,
}) =>
    throw UnimplementedError('fileSizeProblems');
