// WHY: the official file is already encrypted. Gzipping it through the ordinary
// backup writer breaks the target routing. CLAIM(export-real-target).
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/backup_storage.dart';
import 'package:openstrap_edge/data/official_export/destination.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Android scoped destination sends OSBK bytes unchanged and reads actual saved URI',
    () async {
      final root = await Directory.systemTemp.createTemp('official_dest_');
      final calls = <String>[];
      const folder = BackupFolder(
        uri: 'content://documents/tree/chosen',
        name: 'Chosen folder',
      );
      const handle = 'content://documents/tree/chosen/document/official';
      final bytes = [79, 83, 66, 75, 1, 2, 3, 4];
      final source = File('${root.path}/sealed.osbk');
      await source.writeAsBytes(bytes);
      final destination = AndroidOfficialDestination(folder);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidBackupStorage.channel, (call) async {
            calls.add(call.method);
            final args = call.arguments as Map;
            expect(args['tree'], folder.uri);
            switch (call.method) {
              case 'write':
                expect(
                  await File(args['source'] as String).readAsBytes(),
                  bytes,
                );
                expect(args['name'], 'official.db.osbk.incomplete');
                return {'uri': handle, 'name': args['name']};
              case 'read':
                expect(args['uri'], handle);
                await File(args['destination'] as String).writeAsBytes(bytes);
                return null;
              case 'rename':
                expect(args['uri'], handle);
                return {'uri': handle, 'name': args['name']};
              case 'delete':
                expect(args['uri'], handle);
                return null;
              default:
                throw PlatformException(code: 'unexpected_method');
            }
          });
      try {
        final written = await destination.write(
          source,
          'official.db.osbk.incomplete',
        );
        expect(written, handle);
        final read = await destination.readBack(
          written,
          File('${root.path}/readback.osbk'),
        );
        expect(await read.readAsBytes(), bytes);
        expect(await destination.publish(written, 'official.db.osbk'), handle);
        await destination.delete(written);
        expect(calls, ['write', 'read', 'rename', 'delete']);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AndroidBackupStorage.channel, null);
        await root.delete(recursive: true);
      }
    },
  );
}
