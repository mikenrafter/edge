import 'export_hooks.dart';
// WHY: cancellation, provider corruption and failure must not leave readable
// health files behind. Proves CLAIM(export-no-source-write/export-verified-save).
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/official_export/coordinator.dart';
import 'package:openstrap_edge/data/official_export/destination.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/import/backup_crypto.dart';
import 'package:openstrap_edge/data/official_export/mapper.dart';
import '../backup/backup_support.dart';

class CorruptDestination extends LocalOfficialDestination {
  CorruptDestination(super.directory);
  @override
  Future<File> readBack(String handle, File privateFile) async {
    final f = await super.readBack(handle, privateFile);
    final bytes = await f.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await f.writeAsBytes(bytes);
    return f;
  }
}

class RecoveryFailureDestination extends LocalOfficialDestination {
  RecoveryFailureDestination(super.directory);
  @override
  Future<String> write(File source, String name) {
    if (name.contains('fork-recovery')) {
      throw const FileSystemException('No space left on device');
    }
    return super.write(source, name);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackupEnv env;
  setUp(() async {
    env = await BackupEnv.create('official_coordinator.db');
  });
  tearDown(() async {
    await env.dispose();
  });

  // catches: recovery demanded before official save or plaintext temp leaked.
  test(
    'official saved first; recovery defaults offered afterward; verified exact snapshot',
    () async {
      await env.seedData();
      final source = await LocalDb.exportCopy();
      final live = await LocalDb.instance;
      final inventoryBefore = await inventoryDatabase(live);
      final out = await Directory('${env.root.path}/out').create();
      final temp = await Directory('${env.root.path}/sessions').create();
      final coordinator = OfficialExportCoordinator();
      final result = await coordinator.export(
        snapshot: TestSnapshot((_) async => source),
        privateRoot: temp,
        destination: LocalOfficialDestination(out),
        passphrase: 'correct horse sample phrase',
        profileText: await File(
          'assets/official_export/v0.11.3.json',
        ).readAsString(),
        recoveryChoice: TestRecoveryChoice(() async {
          expect(
            out.listSync().whereType<File>().map((f) => f.path),
            hasLength(1),
          );
          expect(out.listSync().single.path, contains('official-v0.11.3'));
          return true;
        }),
      );
      expect(result, isA<OfficialExportSaved>());
      final saved = result as OfficialExportSaved;
      expect(saved.files, hasLength(2));
      expect(temp.listSync(), isEmpty);
      final recovery = File('${env.root.path}/recovery.db');
      await decryptBackupFile(
        File(saved.files.last),
        recovery,
        'correct horse sample phrase',
      );
      // Recovery gains only the transition manifest; exact logical source rows
      // are verified separately by the coverage inventory.
      await verifyDatabaseInventory(
        recovery.path,
        saved.report.sourceInventory,
      );
      expect(await inventoryDatabase(live), inventoryBefore);
    },
  );

  // catches: success published before actual destination authentication.
  test('provider corruption fails and removes output and plaintext', () async {
    await env.seedData();
    final before = await inventoryDatabase(await LocalDb.instance);
    final source = await LocalDb.exportCopy();
    final out = await Directory('${env.root.path}/out').create();
    final temp = await Directory('${env.root.path}/sessions').create();
    final result = await OfficialExportCoordinator().export(
      snapshot: TestSnapshot((_) async => source),
      privateRoot: temp,
      destination: CorruptDestination(out),
      passphrase: 'correct horse sample phrase',
      profileText: await File(
        'assets/official_export/v0.11.3.json',
      ).readAsString(),
      recoveryChoice: TestRecoveryChoice(() async => true),
    );
    expect(result, isA<OfficialExportFailed>());
    expect(temp.listSync(), isEmpty);
    expect(out.listSync(), isEmpty);
    expect(await inventoryDatabase(await LocalDb.instance), before);
  });

  // catches: cancellation observed only after publication.
  test(
    'cancellation after snapshot cleans everything without publishing',
    () async {
      await env.seedData();
      final before = await inventoryDatabase(await LocalDb.instance);
      final source = await LocalDb.exportCopy();
      final out = await Directory('${env.root.path}/out').create();
      final temp = await Directory('${env.root.path}/sessions').create();
      final coordinator = OfficialExportCoordinator();
      final result = await coordinator.export(
        snapshot: TestSnapshot((_) async {
          coordinator.cancel();
          return source;
        }),
        privateRoot: temp,
        destination: LocalOfficialDestination(out),
        passphrase: 'correct horse sample phrase',
        profileText: await File(
          'assets/official_export/v0.11.3.json',
        ).readAsString(),
        recoveryChoice: TestRecoveryChoice(() async => true),
      );
      expect(result, isA<OfficialExportCancelled>());
      expect(temp.listSync(), isEmpty);
      expect(out.listSync(), isEmpty);
      expect(await inventoryDatabase(await LocalDb.instance), before);
      expect(await File(source).exists(), isFalse);
    },
  );
  // WHY: losing the optional second write must retain a verified official file.
  // CLAIM(export-verified-save). catches: deleting all outputs on recovery error.
  test(
    'recovery disk-full preserves verified official and reports partial outcome',
    () async {
      await env.seedData();
      final before = await inventoryDatabase(await LocalDb.instance);
      final source = await LocalDb.exportCopy();
      final out = await Directory('${env.root.path}/out').create();
      final temp = await Directory('${env.root.path}/sessions').create();
      final result = await OfficialExportCoordinator().export(
        snapshot: TestSnapshot((_) async => source),
        privateRoot: temp,
        destination: RecoveryFailureDestination(out),
        passphrase: 'correct horse sample phrase',
        profileText: await File(
          'assets/official_export/v0.11.3.json',
        ).readAsString(),
        recoveryChoice: TestRecoveryChoice(() async => true),
      );
      expect(result, isA<OfficialExportSaved>());
      final saved = result as OfficialExportSaved;
      expect(saved.files, hasLength(1));
      expect(saved.recoveryKept, isFalse);
      expect(saved.recoveryError, contains('No space left on device'));
      expect(out.listSync(), hasLength(1));
      expect(temp.listSync(), isEmpty);
      expect(await inventoryDatabase(await LocalDb.instance), before);
    },
  );

  // WHY: a killed process must not leave unencrypted sessions until next export.
  // CLAIM(export-no-source-write). catches: deleting foreign files or no cleanup.
  test('abandoned private session cleanup preserves unrelated files', () async {
    final root = await Directory('${env.root.path}/sessions').create();
    final abandoned = await Directory('${root.path}/session-dead').create();
    await File(
      '${abandoned.path}/fork.db',
    ).writeAsString('sensitive placeholder');
    final unrelated = File('${root.path}/keep.txt');
    await unrelated.writeAsString('keep');
    await OfficialExportCoordinator.cleanupAbandoned(root);
    expect(await abandoned.exists(), isFalse);
    expect(await unrelated.readAsString(), 'keep');
  });

  // WHY: failure before snapshot returns still owns its plaintext intermediate.
  // CLAIM(export-no-source-write). catches: cleanup only after snapshot success.
  test(
    'snapshot failure deletes intermediate and keeps source unchanged',
    () async {
      await env.seedData();
      final before = await inventoryDatabase(await LocalDb.instance);
      final out = await Directory('${env.root.path}/out').create();
      final temp = await Directory('${env.root.path}/sessions').create();
      final result = await OfficialExportCoordinator().export(
        snapshot: TestSnapshot((path) async {
          await File(path).writeAsString('plaintext partial snapshot');
          throw const FileSystemException('Snapshot interrupted');
        }),
        privateRoot: temp,
        destination: LocalOfficialDestination(out),
        passphrase: 'correct horse sample phrase',
        profileText: await File(
          'assets/official_export/v0.11.3.json',
        ).readAsString(),
        recoveryChoice: TestRecoveryChoice(() async => false),
      );
      expect(result, isA<OfficialExportFailed>());
      expect(temp.listSync(), isEmpty);
      expect(out.listSync(), isEmpty);
      expect(await inventoryDatabase(await LocalDb.instance), before);
    },
  );
}
