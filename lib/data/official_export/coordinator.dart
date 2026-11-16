// Owns one export session, its cancellation and all private intermediates.
// CLAIM(export-verified-save): success follows authentication of bytes read
// from the selected destination [coordinator_test, provider corruption case].
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'destination.dart';
import 'mapper.dart';
import 'profile.dart';
import 'worker.dart';

sealed class OfficialExportResult {
  const OfficialExportResult();
}

class OfficialExportSaved extends OfficialExportResult {
  const OfficialExportSaved(
    this.report,
    this.files, {
    this.recoveryKept = false,
    this.recoveryError,
    this.names = const [],
  });
  final OfficialExportReport report;
  final List<String> files;
  final List<String> names;
  final bool recoveryKept;
  final String? recoveryError;
}

class OfficialExportCancelled extends OfficialExportResult {
  const OfficialExportCancelled(this.savedFiles);
  final List<String> savedFiles;
}

class OfficialExportFailed extends OfficialExportResult {
  const OfficialExportFailed(this.stage, this.reason, this.savedFiles);
  final String stage, reason;
  final List<String> savedFiles;
}

class _SessionProgress implements OfficialExportProgress {
  _SessionProgress(this.cancellation, this.sink);
  final OfficialExportCancellation cancellation;
  final OfficialExportProgress? sink;
  String stage = 'Preparing private snapshot';
  @override
  void update(String label, int? count) {
    stage = label;
    sink?.update(label, count);
    cancellation.check();
  }
}

class OfficialExportCoordinator {
  static bool _active = false;
  static Future<void> _cleanupTail = Future<void>.value();
  final _cancellation = OfficialExportCancellation();
  void cancel() => _cancellation.cancel();
  void _check() => _cancellation.check();

  /// [snapshot] writes directly inside the leased private session. It must
  /// return a consistent full snapshot with strict prefs and approved files.
  Future<OfficialExportResult> export({
    required OfficialSnapshot snapshot,
    required Directory privateRoot,
    required OfficialDestination destination,
    required String passphrase,
    required String profileText,
    required OfficialRecoveryChoice recoveryChoice,
    OfficialExportProgress? onProgress,
  }) async {
    if (_active) {
      return const OfficialExportFailed(
        'Starting',
        'Another export is running',
        [],
      );
    }
    _active = true;
    final files = <String>[];
    final names = <String>[];
    final progressState = _SessionProgress(_cancellation, onProgress);
    Directory? session;
    RandomAccessFile? lease;
    String? unfinished;
    try {
      await privateRoot.create(recursive: true);
      await cleanupAbandoned(privateRoot);
      final exportId =
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
      session = await Directory(
        '${privateRoot.path}/session-$exportId',
      ).create();
      lease = await File('${session.path}/lease').open(mode: FileMode.write);
      await lease.lock(FileLock.exclusive);
      void progress(String label, [int? n]) {
        progressState.update(label, n);
      }

      progress(progressState.stage);
      final sourcePath = await snapshot.capture('${session.path}/fork.db');
      if (!sourcePath.startsWith('${session.path}/')) {
        // Test/custom snapshot seams remain owned from the moment they return.
        await File(sourcePath).rename('${session.path}/fork.db');
      }
      final source = '${session.path}/fork.db';
      _check();
      final official = '${session.path}/official.db';
      final report = await mapOfficialSnapshot(
        source,
        official,
        profileText,
        cancellation: _cancellation,
        progress: progressState,
      );
      progress('Verifying official database');
      final sourceDb = await openDatabase(source, singleInstance: false);
      try {
        await writeTransitionManifest(sourceDb, report);
      } finally {
        await sourceDb.close();
      }
      final recoveryInventory = report.sourceInventory;
      await verifyDatabaseInventory(source, recoveryInventory);
      final officialName =
          'openstrap-official-$officialTargetTag-$exportId.db.osbk';
      Future<String> save(
        String plain,
        String name,
        Map<String, Object?> inventory,
      ) async {
        progress('Encrypting $name');
        final encrypted = '${session!.path}/sealed.osbk';
        await Isolate.run(
          () => sealOfficialFileHeavy(
            exportWorkerInputs,
            plain,
            encrypted,
            passphrase,
          ),
        );
        _check();
        unfinished = await destination.write(
          File(encrypted),
          '$name.incomplete',
        );
        progress('Reading saved file back');
        final read = await destination.readBack(
          unfinished!,
          File('${session.path}/readback.osbk'),
        );
        final checked = '${session.path}/verified.db';
        final readPath = read.path;
        await Isolate.run(
          () => openOfficialFileHeavy(
            exportWorkerInputs,
            readPath,
            checked,
            passphrase,
          ),
        );
        if (await exportFileHash(checked) != await exportFileHash(plain)) {
          throw const FormatException('Saved file checksum differs');
        }
        await verifyDatabaseInventory(checked, inventory);
        _check();
        final finalHandle = await destination.publish(unfinished!, name);
        unfinished = finalHandle;
        // Some document providers implement rename as a second copy. Read
        // the final URI again before recording completion.
        final published = await destination.readBack(
          finalHandle,
          File('${session.path}/published.osbk'),
        );
        final publishedPath = published.path;
        await Isolate.run(
          () => openOfficialFileHeavy(
            exportWorkerInputs,
            publishedPath,
            checked,
            passphrase,
          ),
        );
        if (await exportFileHash(checked) != await exportFileHash(plain)) {
          throw const FormatException('Published file checksum differs');
        }
        files.add(finalHandle);
        names.add(name);
        unfinished = null;
        for (final path in [encrypted, read.path, checked, published.path]) {
          final f = File(path);
          if (await f.exists()) await f.delete();
        }
        return finalHandle;
      }

      await save(official, officialName, report.outputInventory);
      progress('Official file saved and verified');
      final recovery = await recoveryChoice.choose();
      _check();
      if (recovery == true) {
        try {
          await save(
            source,
            'openstrap-fork-recovery-pilot-$exportId.db.osbk',
            recoveryInventory,
          );
        } on ExportCancellation {
          rethrow;
        } catch (error) {
          return OfficialExportSaved(
            report,
            List.unmodifiable(files),
            recoveryError: 'Official file saved; recovery failed: $error',
            names: List.unmodifiable(names),
          );
        }
      }
      return OfficialExportSaved(
        report,
        List.unmodifiable(files),
        recoveryKept: recovery == true,
        names: List.unmodifiable(names),
      );
    } on ExportCancellation {
      return OfficialExportCancelled(List.unmodifiable(files));
    } catch (error) {
      return OfficialExportFailed(
        progressState.stage,
        error.toString(),
        List.unmodifiable(files),
      );
    } finally {
      if (unfinished != null) {
        try {
          await destination.delete(unfinished!);
        } catch (_) {
          /* remains explicitly .incomplete if provider access was lost */
        }
      }
      try {
        await lease?.unlock();
        await lease?.close();
      } finally {
        try {
          if (session != null && await session.exists()) {
            await session.delete(recursive: true);
          }
        } finally {
          _active = false;
        }
      }
    }
  }

  /// A process crash releases the OS lease. A different active session keeps
  /// its files; cleanup only touches this exporter's own directory prefix.
  static Future<void> cleanupPrivateSessions() async {
    if (_active) return;
    final temp = await getTemporaryDirectory();
    await cleanupAbandoned(Directory('${temp.path}/official-export'));
  }

  static Future<void> cleanupAbandoned(Directory root) {
    final next = _cleanupTail.then((_) => _cleanupFiles(root));
    _cleanupTail = next.catchError((Object _) {});
    return next;
  }

  static Future<void> _cleanupFiles(Directory root) async {
    if (!await root.exists()) return;
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory ||
          !entry.path.split('/').last.startsWith('session-')) {
        continue;
      }
      RandomAccessFile? lease;
      try {
        lease = await File('${entry.path}/lease').open(mode: FileMode.append);
        await lease.lock(FileLock.exclusive);
        await entry.delete(recursive: true);
      } on FileSystemException {
        // An active owner holds the non-blocking lock, or access is unavailable.
      } finally {
        await lease?.close();
      }
    }
  }
}
