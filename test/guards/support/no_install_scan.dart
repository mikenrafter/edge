// no_install_scan.dart — pure scanners behind the no-install guard.
//
// Each scanner reports USE of a banned install capability, not prose about it:
// comments are stripped first, so an explanation ("we do not use
// REQUEST_INSTALL_PACKAGES") never fails the guard, while a restored permission,
// dependency, provider or binary-URL read does. The guard's own literals live in
// this support file and its test, which the whole-tree walk never scans.

/// One banned capability found in one file.
class InstallViolation {
  const InstallViolation(this.file, this.ban, this.line);
  final String file;
  final String ban;
  final int line;
  @override
  String toString() => '$file:$line  $ban';
}

/// The four bans of spec §5.7, as stable ids.
const kBanPermission = 'REQUEST_INSTALL_PACKAGES';
const kBanDependency = 'ota_update';
const kBanProvider = 'OtaUpdateFileProvider';
const kBanBinaryUrl = 'browser_download_url';

String _stripXmlComments(String xml) => xml.replaceAllMapped(
      RegExp(r'<!--.*?-->', dotAll: true),
      // Keep newlines so line numbers still point at the original file.
      (m) => '\n' * '\n'.allMatches(m.group(0)!).length,
    );

String _stripLineComments(String text, {bool hash = false, bool slashes = true}) {
  final out = <String>[];
  for (final line in text.split('\n')) {
    var cut = line;
    if (slashes) {
      final i = _commentStart(line, '//');
      if (i >= 0) cut = line.substring(0, i);
    }
    if (hash) {
      final i = _commentStart(line, '#');
      if (i >= 0) cut = line.substring(0, i);
    }
    out.add(cut);
  }
  return out.join('\n');
}

/// Index of a comment marker that is not inside a quoted string, or -1.
int _commentStart(String line, String marker) {
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }
    if (line.startsWith(marker, i)) {
      // `https://` is a URL, not a comment.
      if (marker == '//' && i > 0 && line[i - 1] == ':') continue;
      return i;
    }
  }
  return -1;
}

String _stripBlockComments(String text) => text.replaceAllMapped(
      RegExp(r'/\*.*?\*/', dotAll: true),
      (m) => '\n' * '\n'.allMatches(m.group(0)!).length,
    );

List<InstallViolation> _find(String file, String code, Map<String, Pattern> bans) {
  final found = <InstallViolation>[];
  final lines = code.split('\n');
  for (var i = 0; i < lines.length; i++) {
    for (final ban in bans.entries) {
      if (lines[i].contains(ban.value)) {
        found.add(InstallViolation(file, ban.key, i + 1));
      }
    }
  }
  return found;
}

/// An AndroidManifest (source or merged): the install permission, the OTA
/// provider/receiver and the plugin's package.
List<InstallViolation> scanManifest(String file, String xml) => _find(
      file,
      _stripXmlComments(xml),
      {
        kBanPermission: kBanPermission,
        kBanProvider: kBanProvider,
        // The plugin's other installer component. Its package names the dependency.
        kBanDependency: 'sk.fourq.otaupdate',
      },
    );

/// An Android resource XML (file_paths for the provider).
List<InstallViolation> scanResourceXml(String file, String xml) => _find(
      file,
      _stripXmlComments(xml),
      {kBanDependency: RegExp(r'\bota_update\b')},
    );

/// pubspec.yaml / pubspec.lock: the dependency as a key, not a comment.
List<InstallViolation> scanPubspec(String file, String text) => _find(
      file,
      _stripLineComments(text, hash: true, slashes: false),
      {kBanDependency: RegExp(r'^\s*ota_update\s*:', multiLine: false)},
    );

/// Dart source: the binary-download URL field and the plugin's import/types.
List<InstallViolation> scanDart(String file, String text) => _find(
      file,
      _stripBlockComments(_stripLineComments(text)),
      {
        kBanBinaryUrl: kBanBinaryUrl,
        kBanDependency: RegExp(r'package:ota_update/'),
        kBanPermission: kBanPermission,
        kBanProvider: kBanProvider,
      },
    );

/// Kotlin / Java / Gradle: the install permission, provider and plugin package.
List<InstallViolation> scanNative(String file, String text) => _find(
      file,
      _stripBlockComments(_stripLineComments(text)),
      {
        kBanPermission: kBanPermission,
        kBanProvider: kBanProvider,
        kBanDependency: RegExp(r'ota_update|sk\.fourq\.otaupdate'),
        kBanBinaryUrl: kBanBinaryUrl,
      },
    );
