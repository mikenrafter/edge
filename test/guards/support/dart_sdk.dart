// dart_sdk.dart — finds the Dart SDK package:analyzer needs, under
// `flutter test` (where Platform.resolvedExecutable is flutter_tester, not dart).

import 'dart:io';

/// The Dart SDK root (contains `lib/_internal`). Throws a StateError listing
/// what was tried, so a CI failure says where to look.
String dartSdkPath() {
  final tried = <String>[];
  String? hit(String? candidate) {
    if (candidate == null || candidate.isEmpty) return null;
    tried.add(candidate);
    return Directory('$candidate/lib/_internal').existsSync() ? candidate : null;
  }

  final env = Platform.environment;
  final flutterRoot = env['FLUTTER_ROOT'];
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final found = hit(env['DART_SDK']) ??
      hit(flutterRoot == null ? null : '$flutterRoot/bin/cache/dart-sdk') ??
      hit(Directory(exeDir).parent.path) ??
      hit('$exeDir/dart-sdk') ??
      hit('${Directory(exeDir).parent.parent.path}/dart-sdk');
  if (found == null) {
    throw StateError('no Dart SDK found; tried: ${tried.join(', ')}');
  }
  return found;
}
