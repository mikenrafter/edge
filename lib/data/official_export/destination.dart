// Scoped destinations for OSBK bytes. Automatic BackupStorage gzips its input
// and cannot be reused for an already encrypted official import file.
import 'dart:io';
import 'package:path/path.dart' as p;
import '../backup_storage.dart';

abstract class OfficialDestination {
  String get label;
  Future<String> write(File encrypted, String name);
  Future<File> readBack(String handle, File privateFile);
  Future<String> publish(String handle, String name);
  Future<void> delete(String handle);
}

class LocalOfficialDestination implements OfficialDestination {
  LocalOfficialDestination(this.directory);
  final Directory directory;
  @override
  String get label => directory.path;
  File _child(String handle) {
    if (!p.isWithin(directory.absolute.path, File(handle).absolute.path)) {
      throw const FileSystemException('File is outside selected folder');
    }
    return File(handle);
  }

  @override
  Future<String> write(File encrypted, String name) async {
    if (p.basename(name) != name) {
      throw const FormatException('Unsafe export filename');
    }
    final dest = _child(p.join(directory.path, name));
    await dest.create(exclusive: true);
    try {
      await encrypted.openRead().pipe(dest.openWrite());
      return dest.path;
    } catch (_) {
      await dest.delete();
      rethrow;
    }
  }

  @override
  Future<File> readBack(String handle, File privateFile) =>
      _child(handle).copy(privateFile.path);
  @override
  Future<String> publish(String handle, String name) async {
    if (p.basename(name) != name) {
      throw const FormatException('Unsafe export filename');
    }
    final dest = _child(p.join(directory.path, name));
    if (await dest.exists()) {
      throw const FileSystemException('Export filename is already in use');
    }
    return (await _child(handle).rename(dest.path)).path;
  }

  @override
  Future<void> delete(String handle) => _child(handle).delete();
}

class AndroidOfficialDestination implements OfficialDestination {
  AndroidOfficialDestination(this.folder);
  final BackupFolder folder;
  @override
  String get label => folder.name;
  @override
  Future<String> write(File encrypted, String name) async {
    final result = await AndroidBackupStorage.channel
        .invokeMapMethod<String, dynamic>('write', {
          'tree': folder.uri,
          'source': encrypted.path,
          'name': name,
        });
    if (result == null) {
      throw const FileSystemException('Export was not written');
    }
    return result['uri'] as String;
  }

  @override
  Future<File> readBack(String handle, File privateFile) async {
    await AndroidBackupStorage.channel.invokeMethod<void>('read', {
      'tree': folder.uri,
      'uri': handle,
      'destination': privateFile.path,
    });
    return privateFile;
  }

  @override
  Future<String> publish(String handle, String name) async {
    final result = await AndroidBackupStorage.channel
        .invokeMapMethod<String, dynamic>('rename', {
          'tree': folder.uri,
          'uri': handle,
          'name': name,
        });
    if (result == null) {
      throw const FileSystemException('Export was not published');
    }
    return result['uri'] as String;
  }

  @override
  Future<void> delete(String handle) => AndroidBackupStorage.channel
      .invokeMethod<void>('delete', {'tree': folder.uri, 'uri': handle});
}
