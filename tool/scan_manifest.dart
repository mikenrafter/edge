// Scans manifests for the install capabilities the app must never carry
// (test/guards/support/no_install_scan.dart is the one scanner). Takes aapt or
// aapt2 `dump xmltree` text and merged AndroidManifest.xml files alike.
//
// Usage: dart run tool/scan_manifest.dart FILE...
// Exit: 0 clean, 1 violations, 2 unusable input (missing, empty, not a manifest).
import 'dart:io';

import '../test/guards/support/no_install_scan.dart';

int _run(List<String> files) {
  if (files.isEmpty) {
    stderr.writeln('Usage: dart run tool/scan_manifest.dart FILE...');
    return 2;
  }
  final found = <InstallViolation>[];
  for (final path in files) {
    final f = File(path);
    final String text;
    try {
      text = f.readAsStringSync();
    } on FileSystemException catch (e) {
      stderr.writeln('cannot read $path: ${e.message}');
      return 2;
    }
    // An empty or unrelated file scans clean; that must never read as a pass.
    if (!RegExp(r'<manifest\b|^\s*E: manifest(\s|$)', multiLine: true).hasMatch(text)) {
      stderr.writeln('$path is not a manifest');
      return 2;
    }
    found.addAll(scanManifest(path, text));
  }
  if (found.isEmpty) {
    stdout.writeln('manifest scan: ${files.length} file(s) clean');
    return 0;
  }
  for (final v in found) {
    stderr.writeln('BANNED install capability: $v');
  }
  return 1;
}

void main(List<String> args) => exit(_run(args));
