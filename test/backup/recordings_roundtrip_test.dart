// Device-lab IMU recordings (JSON Lines under <docs>/device_lab/imu/) travel in
// a full export and come back byte-exact; a file already on the device is not
// overwritten.
//
// RED: the export has no backup_files table and the import restores no file.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/data/db.dart';

import 'backup_support.dart';

// Includes bytes that are not valid UTF-8, to catch a text round trip.
List<int> _bytes(int seed, int n) =>
    [for (var i = 0; i < n; i++) (i * 31 + seed) & 0xff];

void main() {
  late BackupEnv env;
  setUpAll(() async => env = await BackupEnv.create('bkx_files_test.db'));
  tearDownAll(() async => env.dispose());

  test('export carries every recording under a relative path', () async {
    await env.wipe();
    await env.writeImu('rec_a.jsonl', _bytes(1, 5000));
    await env.writeImu('rec_b.jsonl', _bytes(2, 70000));
    await env.seedData();
    final path = await LocalDb.exportCopy();

    final files = await exportedFiles(path);
    expect(files, isNotNull, reason: 'export has a backup_files table');
    expect(files!.keys.toSet(),
        {'device_lab/imu/rec_a.jsonl', 'device_lab/imu/rec_b.jsonl'});
    expect(files['device_lab/imu/rec_b.jsonl'], _bytes(2, 70000));
  });

  test('import writes the recordings back byte-exact', () async {
    await env.wipe();
    await env.writeImu('rec_a.jsonl', _bytes(1, 5000));
    await env.writeImu('rec_b.jsonl', _bytes(2, 70000));
    await env.seedData();
    final path = await LocalDb.exportCopy();

    await env.wipe();
    expect(env.imuDir.existsSync(), isFalse);
    await LocalDb.importFromDbFile(path);

    expect(env.imuFile('rec_a.jsonl').existsSync(), isTrue);
    expect(env.imuFile('rec_a.jsonl').readAsBytesSync(), _bytes(1, 5000));
    expect(env.imuFile('rec_b.jsonl').readAsBytesSync(), _bytes(2, 70000));
  });

  test('a file already on the device is not overwritten', () async {
    await env.wipe();
    await env.writeImu('rec_a.jsonl', _bytes(1, 100));
    await env.writeImu('rec_b.jsonl', _bytes(2, 100));
    await env.seedData();
    final path = await LocalDb.exportCopy();

    await env.wipe();
    await env.writeImu('rec_a.jsonl', _bytes(9, 40)); // same name, other bytes
    await LocalDb.importFromDbFile(path);

    expect(env.imuFile('rec_a.jsonl').readAsBytesSync(), _bytes(9, 40));
    expect(env.imuFile('rec_b.jsonl').existsSync(), isTrue,
        reason: 'the absent one is restored');
    expect(env.imuFile('rec_b.jsonl').readAsBytesSync(), _bytes(2, 100));
  });

  test('a path that escapes the recordings folder is refused', () async {
    await env.wipe();
    await env.writeImu('rec_a.jsonl', _bytes(1, 10));
    await env.seedData();
    final path = await LocalDb.exportCopy();
    final files = await exportedFiles(path);
    expect(files, isNotNull, reason: 'export has a backup_files table');
    // Plant a hostile row in the backup, as a tampered file would.
    final db = await LocalDb.instance;
    await db.execute('ATTACH DATABASE ? AS evil', [path]);
    await db.execute(
        "INSERT OR REPLACE INTO evil.backup_files(rel_path, bytes) "
        "VALUES ('../../escaped.txt', x'41')");
    await db.execute('DETACH DATABASE evil');

    await env.wipe();
    await LocalDb.importFromDbFile(path);
    final escaped = File('${env.docs.parent.path}/escaped.txt');
    expect(escaped.existsSync(), isFalse);
    expect(env.imuFile('rec_a.jsonl').existsSync(), isTrue,
        reason: 'the honest file still restores');
  });
}
