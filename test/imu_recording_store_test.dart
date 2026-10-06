// Saved IMU lab recordings: nothing is written until Save, the file lands at
// device_lab/imu/<id>.jsonl under the documents directory, a list reads only
// headers, delete removes the file, and a share failure is not a save failure.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/imu_recording.dart';
import 'package:openstrap_edge/gestures/imu_recording_store.dart';
import 'package:openstrap_edge/util/log_file.dart';

import 'support/imu_recording_fixtures.dart';

ImuRecording _rec(String id, {DateTime? at, int packets = 2}) => ImuRecording(
      meta: ImuRecordingMeta(
        id: id,
        kind: ImuRecordingKind.ambient,
        label: 'walking',
        bandModel: 'WHOOP 4.0',
        deviceId: 'band-a',
        createdAt: at ?? DateTime.utc(2026, 10, 5, 12),
        requestedDuration: const Duration(seconds: 30),
        maxPackets: 600,
      ),
      status: ImuRecordingStatus.stopped,
      packets: [for (var i = 0; i < packets; i++) labPacket(1000 * (i + 1))],
      markers: [labMarker(ImuMarkerKind.tapReceived, 10)],
    );

void main() {
  late Directory docs;
  late ImuRecordingStore store;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('imu_store_');
    store = ImuRecordingStore(documentsDir: () async => docs);
  });
  tearDown(() async {
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  test('constructing and listing write nothing but the empty folder', () async {
    expect(await store.list(), isEmpty);
    final files = docs.listSync(recursive: true).whereType<File>();
    expect(files, isEmpty);
  });

  test('save writes <documents>/device_lab/imu/<id>.jsonl, readable back',
      () async {
    final r = _rec('imu-1');
    final saved = await store.save(r);
    final sep = Platform.pathSeparator;
    expect(saved.path, '${docs.path}${sep}device_lab${sep}imu${sep}imu-1.jsonl');
    expect(File(saved.path).readAsStringSync(), r.toJsonLines());
    expect(saved.sizeBytes, File(saved.path).lengthSync());
    final back = await store.load('imu-1');
    expect(back.toJsonLines(), r.toJsonLines());
    expect(docs.listSync(recursive: true).whereType<File>().map((f) => f.path),
        [saved.path],
        reason: 'no .part file is left behind');
  });

  test('saving the same id again replaces the file', () async {
    await store.save(_rec('imu-1', packets: 1));
    await store.save(_rec('imu-1', packets: 3));
    final list = await store.list();
    expect(list, hasLength(1));
    expect(list.single.packetCount, 3);
  });

  test('list gives summaries newest first without loading packets', () async {
    await store.save(_rec('old', at: DateTime.utc(2026, 10, 1)));
    await store.save(_rec('new', at: DateTime.utc(2026, 10, 5)));
    final list = await store.list();
    expect(list.map((s) => s.id), ['new', 'old']);
    final s = list.first;
    expect(s.kind, ImuRecordingKind.ambient);
    expect(s.label, 'walking');
    expect(s.status, ImuRecordingStatus.stopped);
    expect(s.packetCount, 2);
    expect(s.bandModel, 'WHOOP 4.0');
    expect(s.createdAt, DateTime.utc(2026, 10, 5));
    expect(s.readable, isTrue);
  });

  test('an unreadable file is listed (last) so it can be deleted', () async {
    await store.save(_rec('good'));
    final dir = await store.directory();
    File('${dir.path}/broken.jsonl').writeAsStringSync('not a recording');
    File('${dir.path}/notes.txt').writeAsStringSync('ignored');
    final list = await store.list();
    expect(list.map((s) => s.id), ['good', 'broken']);
    expect(list.last.readable, isFalse);
    expect(list.last.label, isNull);
    await store.delete('broken');
    expect((await store.list()).map((s) => s.id), ['good']);
  });

  test('delete removes the file; deleting what is gone is fine', () async {
    final saved = await store.save(_rec('imu-1'));
    await store.delete('imu-1');
    expect(File(saved.path).existsSync(), isFalse);
    await store.delete('imu-1');
  });

  test('an id that could escape the folder is refused', () async {
    for (final bad in ['../x', 'a/b', '', 'a.b', r'a\b']) {
      expect(() => store.delete(bad), throwsArgumentError, reason: bad);
      expect(() => store.load(bad), throwsArgumentError, reason: bad);
    }
    expect(() => store.save(_rec('../evil')), throwsArgumentError);
    expect(docs.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('a write that fails leaves no half file and is thrown to the caller',
      () async {
    final dir = await store.directory();
    // A directory where the .part file must go makes the write fail.
    Directory('${dir.path}/imu-1.jsonl.part').createSync();
    await expectLater(store.save(_rec('imu-1')), throwsA(anything));
    expect(File('${dir.path}/imu-1.jsonl').existsSync(), isFalse);
  });

  group('shareFileCopy', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('imu_share_'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('shares a copy in the temp directory; the saved file stays', () async {
      final saved = await store.save(_rec('imu-1'));
      String? shared;
      final ok = await shareFileCopy(saved.path,
          tempDir: tmp, share: (p) async => shared = p);
      expect(ok, isTrue);
      expect(shared, '${tmp.path}/imu-1.jsonl');
      expect(File(shared!).readAsStringSync(),
          File(saved.path).readAsStringSync());
      expect(File(saved.path).existsSync(), isTrue);
    });

    test('a share that throws is false, and the saved file is untouched',
        () async {
      final saved = await store.save(_rec('imu-1'));
      final ok = await shareFileCopy(saved.path,
          tempDir: tmp, share: (p) async => throw StateError('no sheet'));
      expect(ok, isFalse);
      expect(File(saved.path).existsSync(), isTrue);
    });

    test('a file already in the temp directory keeps its bytes', () async {
      // The motion export writes its ZIP to the temp directory; copying it
      // onto itself used to share a 0-byte file.
      final zip = File('${tmp.path}/export.zip')
        ..writeAsBytesSync(List.generate(64, (i) => i));
      String? shared;
      final ok = await shareFileCopy(zip.path,
          tempDir: tmp, share: (p) async => shared = p);
      expect(ok, isTrue);
      expect(shared, zip.path);
      expect(File(shared!).lengthSync(), 64);
    });

    test('a missing file is false, not a throw', () async {
      expect(
          await shareFileCopy('${docs.path}/nope.jsonl',
              tempDir: tmp, share: (p) async {}),
          isFalse);
    });

    test('the JSON MIME type', () {
      expect(kJsonFileMime, 'application/json');
    });
  });
}
