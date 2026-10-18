// imu_recording_store.dart — the saved IMU lab recordings on disk.
//
// A recording reaches disk only when the wearer taps Save: one JSON Lines file
// per recording at `<ApplicationDocumentsDirectory>/device_lab/imu/<id>.jsonl`
// (the directory is injectable for tests). It is the single exception to
// "live high-rate data is RAM-only" (invariant 14), authorised by the owner for
// explicit lab-file export; the file never touches raw_records, decoded_*,
// raw_archive or any backup path of the app's database.
//
// Listing reads only each file's header line, so a list of recordings does not
// load their packets.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import 'imu_recording.dart';

/// One saved file, as the list shows it. When the header cannot be read the
/// summary fields are null and [readable] is false: the file is still listed so
/// it can be deleted.
class SavedImuRecording {
  const SavedImuRecording({
    required this.id,
    required this.path,
    required this.sizeBytes,
    this.kind,
    this.label,
    this.status,
    this.createdAt,
    this.packetCount,
    this.bandModel,
  });

  final String id;
  final String path;
  final int sizeBytes;
  final ImuRecordingKind? kind;
  final String? label;
  final ImuRecordingStatus? status;
  final DateTime? createdAt;
  final int? packetCount;
  final String? bandModel;

  bool get readable => createdAt != null;
}

class ImuRecordingStore {
  ImuRecordingStore({Future<Directory> Function()? documentsDir})
      : _documentsDir = documentsDir ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDir;

  /// File-name safe ids only: no path separators, no dots.
  static final RegExp _safeId = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  /// `<documents>/device_lab/imu`, created when missing.
  Future<Directory> directory() async {
    final docs = await _documentsDir();
    final dir = Directory(
        '${docs.path}${Platform.pathSeparator}device_lab${Platform.pathSeparator}imu');
    return dir.create(recursive: true);
  }

  Future<File> _file(String id) async {
    if (!_safeId.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'not a safe recording id');
    }
    final dir = await directory();
    return File('${dir.path}${Platform.pathSeparator}$id.jsonl');
  }

  /// Write [recording] and return where it is. The file appears whole or not at
  /// all: it is written beside its name and renamed into place. Throws when the
  /// disk refuses; the caller says so.
  Future<SavedImuRecording> save(ImuRecording recording) async {
    final target = await _file(recording.meta.id);
    final part = File('${target.path}.part');
    try {
      await part.writeAsString(recording.toJsonLines(), flush: true);
      await part.rename(target.path);
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
    return SavedImuRecording(
      id: recording.meta.id,
      path: target.path,
      sizeBytes: await target.length(),
      kind: recording.meta.kind,
      label: recording.meta.label,
      status: recording.status,
      createdAt: recording.meta.createdAt,
      packetCount: recording.packetCount,
      bandModel: recording.meta.bandModel,
    );
  }

  /// Saved recordings, newest first; unreadable ones last.
  Future<List<SavedImuRecording>> list() async {
    final dir = await directory();
    final out = <SavedImuRecording>[];
    await for (final f in dir.list()) {
      if (f is! File || !f.path.endsWith('.jsonl')) continue;
      final name = f.path.split(Platform.pathSeparator).last;
      out.add(await _summary(f, name.substring(0, name.length - '.jsonl'.length)));
    }
    out.sort((a, b) {
      final x = a.createdAt, y = b.createdAt;
      if (x == null || y == null) {
        return x == null && y == null ? a.id.compareTo(b.id) : (x == null ? 1 : -1);
      }
      return y.compareTo(x);
    });
    return out;
  }

  /// Read one saved recording back. Throws [FormatException] for a file that is
  /// not a recording this app reads, and [FileSystemException] when missing.
  Future<ImuRecording> load(String id) async =>
      ImuRecording.parse(await (await _file(id)).readAsString());

  /// Delete one saved recording. Deleting what is not there is not an error.
  Future<void> delete(String id) async {
    final f = await _file(id);
    if (await f.exists()) await f.delete();
  }

  /// Copy every saved JSONL recording into one ZIP for explicit export.
  /// Unreadable files are included byte-for-byte so export does not discard
  /// anything the wearer saved.
  Future<File> exportAll() async {
    final dir = await directory();
    final files = <File>[];
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.jsonl')) files.add(entry);
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) throw StateError('No saved IMU recordings to export.');

    final archive = Archive();
    for (final file in files) {
      final bytes = await file.readAsBytes();
      archive.addFile(
        ArchiveFile(file.uri.pathSegments.last, bytes.length, bytes),
      );
    }
    final encoded = ZipEncoder().encode(archive);
    final temp = await getTemporaryDirectory();
    final name =
        'openstrap-motion-${DateTime.now().toUtc().microsecondsSinceEpoch}.zip';
    final output = File(
      '${temp.path}${Platform.pathSeparator}$name',
    );
    await output.writeAsBytes(encoded, flush: true);
    return output;
  }

  Future<SavedImuRecording> _summary(File f, String id) async {
    final size = await f.length();
    try {
      final first = await f
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      final h = jsonDecode(first) as Map<String, Object?>;
      if (h['format'] != kImuRecordingFormat) throw const FormatException();
      final kindId = h['recordingKind'];
      return SavedImuRecording(
        id: id,
        path: f.path,
        sizeBytes: size,
        kind: ImuRecordingKind.values.where((k) => k.id == kindId).firstOrNull,
        label: h['label'] as String?,
        status: ImuRecordingStatus.values
            .where((s) => s.name == h['status'])
            .firstOrNull,
        createdAt: DateTime.parse(h['createdUtc'] as String).toUtc(),
        packetCount: h['packetCount'] as int?,
        bandModel: (h['band'] as Map?)?['model'] as String?,
      );
    } catch (_) {
      return SavedImuRecording(id: id, path: f.path, sizeBytes: size);
    }
  }
}
