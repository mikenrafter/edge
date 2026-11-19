import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A document-tree grant, not a filesystem path. Kept on this device only.
class BackupFolder {
  const BackupFolder({required this.uri, required this.name, this.acquiredForSession=false});

  final String uri;
  final String name;
  final bool acquiredForSession;

  Map<String, String> toJson() => {'uri': uri, 'name': name};

  factory BackupFolder.fromJson(Map<String, dynamic> json) =>
      BackupFolder(uri: json['uri'] as String, name: json['name'] as String,acquiredForSession:json['newGrant']==true);
}

class BackupFile {
  const BackupFile({required this.path, required this.name});

  final String path;
  final String name;
}

/// Retention and publication use the same policy for paths and document URIs.
abstract class BackupStorage {
  Future<List<BackupFile>> list();
  Future<BackupFile> write(File snapshot, String name);
  Future<BackupFile> rename(BackupFile file, String name);
  Future<void> delete(BackupFile file);
}

class LocalBackupStorage implements BackupStorage {
  const LocalBackupStorage(this.directory);

  final Directory directory;

  @override
  Future<List<BackupFile>> list() async => [
    await for (final entry in directory.list())
      if (entry is File)
        BackupFile(path: entry.path, name: p.basename(entry.path)),
  ];

  @override
  Future<BackupFile> write(File snapshot, String name) async {
    final file = File(p.join(directory.path, name));
    try {
      await snapshot.openRead().transform(gzip.encoder).pipe(file.openWrite());
      return BackupFile(path: file.path, name: name);
    } catch (_) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<BackupFile> rename(BackupFile file, String name) async {
    final destination = File(p.join(directory.path, name));
    if (await destination.exists()) {
      throw const FileSystemException('Backup filename is already in use');
    }
    final renamed = await File(file.path).rename(destination.path);
    return BackupFile(path: renamed.path, name: name);
  }

  @override
  Future<void> delete(BackupFile file) async {
    await File(file.path).delete();
  }
}

/// The native bridge handles document-provider I/O on a worker thread. Dart
/// still owns compression, naming, retention, and backup scheduling.
class AndroidBackupStorage implements BackupStorage {
  const AndroidBackupStorage(this.folder);

  static const channel = MethodChannel('openstrap/backup_folder');
  final BackupFolder folder;

  static Future<BackupFolder?> pick() async {
    final result = await channel.invokeMapMethod<String, dynamic>('pick');
    return result == null ? null : BackupFolder.fromJson(result);
  }

  static Future<void> release(BackupFolder folder) =>
      channel.invokeMethod<void>('release', {'tree': folder.uri});

  Map<String, String> _arguments() => {'tree': folder.uri};

  BackupFile _file(Map<dynamic, dynamic> value) =>
      BackupFile(path: value['uri'] as String, name: value['name'] as String);

  @override
  Future<List<BackupFile>> list() async {
    final result = await channel.invokeListMethod<dynamic>(
      'list',
      _arguments(),
    );
    if (result == null) {
      throw const FileSystemException('Cannot read backup folder');
    }
    return [for (final file in result) _file(file as Map)];
  }

  @override
  Future<BackupFile> write(File snapshot, String name) async {
    // A private compressed staging copy avoids moving a whole database through
    // the method channel. Neither this file nor the snapshot is buffered in RAM.
    final temp = await (await getTemporaryDirectory()).createTemp('backup_');
    try {
      final compressed = File(p.join(temp.path, 'snapshot.db.gz'));
      await snapshot
          .openRead()
          .transform(gzip.encoder)
          .pipe(compressed.openWrite());
      final result = await channel.invokeMapMethod<String, dynamic>('write', {
        ..._arguments(),
        'source': compressed.path,
        'name': name,
      });
      if (result == null) {
        throw const FileSystemException('Backup was not written');
      }
      return _file(result);
    } finally {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<BackupFile> rename(BackupFile file, String name) async {
    final result = await channel.invokeMapMethod<String, dynamic>('rename', {
      ..._arguments(),
      'uri': file.path,
      'name': name,
    });
    if (result == null) {
      throw const FileSystemException('Backup was not published');
    }
    return _file(result);
  }

  @override
  Future<void> delete(BackupFile file) =>
      channel.invokeMethod<void>('delete', {..._arguments(), 'uri': file.path});
}

/// Uncompressed OSBK streaming at the existing folder owner. A handle remains
/// incomplete until authenticated read-back and publication both succeed.
abstract interface class CipherBackupStorage {
  String get label;
  Future<BackupFile> createCiphertext(String name);
  Future<void> appendCiphertext(BackupFile file, List<int> bytes);
  Future<void> closeCiphertext(BackupFile file);
  Stream<List<int>> readCiphertext(BackupFile file);
  Future<BackupFile> publishCiphertext(BackupFile file, String name);
  Future<void> deleteCiphertext(BackupFile file);
}

class LocalCipherBackupStorage implements CipherBackupStorage {
  const LocalCipherBackupStorage(this.directory);
  final Directory directory;
  @override String get label=>directory.path;
  Future<File> _file(BackupFile file) async {
    final root=await directory.resolveSymbolicLinks();
    final resolved=await File(file.path).resolveSymbolicLinks();
    if(p.dirname(resolved)!=root) throw const FileSystemException('File is outside selected folder');
    return File(resolved);
  }
  @override Future<BackupFile> createCiphertext(String name) async {
    if(p.basename(name)!=name || name=='.' || name=='..') throw const FormatException('Unsafe filename');
    await directory.create(recursive:true);
    final file=File(p.join(directory.path,name));
    await file.create(exclusive:true);
    return BackupFile(path:file.path,name:name);
  }
  @override Future<void> appendCiphertext(BackupFile file,List<int> bytes) async {
    await (await _file(file)).writeAsBytes(bytes,mode:FileMode.append);
  }
  @override Future<void> closeCiphertext(BackupFile file) async {
    final out=await (await _file(file)).open(mode:FileMode.append);
    try {await out.flush();} finally {await out.close();}
  }
  @override Stream<List<int>> readCiphertext(BackupFile file) async* {yield* (await _file(file)).openRead();}
  @override Future<BackupFile> publishCiphertext(BackupFile file,String name) async {
    if(p.basename(name)!=name) throw const FormatException('Unsafe filename');
    final target=File(p.join(directory.path,name));
    if(await target.exists())throw const FileSystemException('Filename is already in use');
    final published=await (await _file(file)).rename(target.path);
    return BackupFile(path:published.path,name:name);
  }
  @override Future<void> deleteCiphertext(BackupFile file) async {await (await _file(file)).delete();}
}

class AndroidCipherBackupStorage implements CipherBackupStorage {
  const AndroidCipherBackupStorage(this.folder);
  final BackupFolder folder;
  @override String get label=>folder.name;
  Map<String,Object?> _args([BackupFile? file])=>{'tree':folder.uri,if(file!=null)'uri':file.path};
  BackupFile _file(Map<dynamic,dynamic> value)=>BackupFile(path:value['uri'] as String,name:value['name'] as String);
  @override Future<BackupFile> createCiphertext(String name) async {
    final file=await AndroidBackupStorage.channel.invokeMapMethod<String,dynamic>('openCiphertext',{..._args(),'name':name});
    if(file==null)throw const FileSystemException('Could not create export');
    return _file(file);
  }
  @override Future<void> appendCiphertext(BackupFile file,List<int> bytes)=>
    AndroidBackupStorage.channel.invokeMethod<void>('appendCiphertext',{..._args(file),'bytes':Uint8List.fromList(bytes)});
  @override Future<void> closeCiphertext(BackupFile file)=>AndroidBackupStorage.channel.invokeMethod<void>('closeCiphertext',_args(file));
  @override Stream<List<int>> readCiphertext(BackupFile file) async* {
    try {
      while(true) {
        final chunk=await AndroidBackupStorage.channel.invokeMethod<Uint8List>('readCiphertext',_args(file));
        if(chunk==null)throw const FileSystemException('Could not read saved file');
        if(chunk.isEmpty)break;
        yield chunk;
      }
    } finally {await AndroidBackupStorage.channel.invokeMethod<void>('closeCiphertextRead',_args(file));}
  }
  @override Future<BackupFile> publishCiphertext(BackupFile file,String name)=>AndroidBackupStorage(folder).rename(file,name);
  @override Future<void> deleteCiphertext(BackupFile file)=>AndroidBackupStorage(folder).delete(file);
}
