// WHY: CLAIM(official-export-saved-bytes) on the platform-cipher path. The
// Android destination encrypts and verifies natively (OsbkGcm.kt, byte-checked
// against the JDK's AES/GCM in OsbkGcmTest). Here a stand-in does the same GCM
// with pointycastle from the handed-over OsbkKey, so the test pins the Dart
// side: the header and key it hands over open with the passphrase in the
// ordinary reader, one full authenticated pass runs before publishing, and a
// second one reads the PUBLISHED document back, whatever the provider's rename
// did. [review r1 F1, F2, F4]
// catches: wrong key/nonce/header plumbing; skipped read-back; trusting a
// rename that changed bytes; a stream-only provider; an older bridge.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show PlatformException;
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/backup_storage.dart';
import 'package:openstrap_edge/data/official_export/coordinator.dart';
import 'package:openstrap_edge/data/official_export/session.dart';
import 'package:openstrap_edge/data/official_export/space_budget.dart';
import 'package:openstrap_edge/import/backup_crypto.dart';
import 'package:pointycastle/export.dart';
import 'rich_fixture.dart';
import 'session_fixture.dart';

GCMBlockCipher _gcm(bool encrypt,OsbkKey key)=>GCMBlockCipher(AESEngine())
  ..init(encrypt,AEADParameters(KeyParameter(key.key),128,key.nonce,key.header));

class NativeDestination extends Destination implements NativeOsbkCipher {
  NativeDestination(super.root,super.space);
  int encrypts=0,verifies=0,appends=0;
  final floors=<int>[];
  // A bridge built before the platform cipher answers false here.
  bool nativeSupported=true;
  // A rename that keeps the length and both ends but changes one byte in the middle.
  bool flipMiddleOnRename=false;
  @override Future<void> appendCiphertext(BackupFile file,List<int> bytes){appends++;return super.appendCiphertext(file,bytes);}
  @override Future<String> encryptFileInto(BackupFile file,String plainPath,OsbkKey key,{int floorBytes=0,void Function(int)? onBytes,void Function()? checkCancelled}) async {
    encrypts++;floors.add(floorBytes);
    final plain=await File(plainPath).readAsBytes();
    final sealed=_gcm(true,key).process(plain);
    await File(file.path).writeAsBytes([...key.header,...sealed],mode:FileMode.append);
    onBytes?.call(plain.length);
    return hashes.sha256.convert(plain).toString();
  }
  @override Future<String> verifyFile(BackupFile file,OsbkKey key,{void Function(int)? onBytes,void Function()? checkCancelled}) async {
    verifies++;
    final bytes=await File(file.path).readAsBytes();
    expect(bytes.sublist(0,BackupHeader.byteLength),key.header);
    return hashes.sha256.convert(_gcm(false,key).process(Uint8List.sublistView(bytes,BackupHeader.byteLength))).toString();
  }
  @override Future<bool> nativeAvailable()async=>nativeSupported;
  @override Future<BackupFile> publishCiphertext(BackupFile file,String name) async {
    final published=await super.publishCiphertext(file,name);
    if(flipMiddleOnRename) {
      final bytes=await File(published.path).readAsBytes();
      bytes[bytes.length~/2]^=0x01;
      await File(published.path).writeAsBytes(bytes);
    }
    return published;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('platform cipher output opens with the passphrase; a full read-back before publishing and another of the published file',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('native_cipher_');
    try {
      final free=Space();final destination=NativeDestination(root,free);
      final outcome=await OfficialExportCoordinator().export(snapshot:Snapshot(fx.forkPath),privateRoot:Directory('${root.path}/private'),
        destination:destination,space:ExportSpaceBudget(source:free),prompts:Prompts(()async=>'pw',(_)async=>false));
      expect(outcome,isA<OfficialExportSaved>());
      final saved=(outcome as OfficialExportSaved).receipt;
      expect((destination.encrypts,destination.verifies,destination.appends),(1,2,0));
      expect(File(saved.file.path).path.endsWith('.db.osbk'),isTrue);
      // The ordinary passphrase reader (what v0.12.2 runs) authenticates it.
      expect(await verifyBackupStream(File(saved.file.path).openRead(),'pw'),saved.plainSha256);
      expect(await File(saved.file.path).length(),saved.bytes);
    } finally {await root.delete(recursive:true);await fx.dispose();}
  });
  test('a rename that changes the bytes fails the read-back and publishes nothing trusted',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('native_cipher_bad_');
    try {
      final free=Space();final destination=NativeDestination(root,free)..corruptRename=true;
      final outcome=await OfficialExportCoordinator().export(snapshot:Snapshot(fx.forkPath),privateRoot:Directory('${root.path}/private'),
        destination:destination,space:ExportSpaceBudget(source:free),prompts:Prompts(()async=>'pw',(_)async=>false));
      expect(outcome,isA<OfficialExportFailed>());
      expect((outcome as OfficialExportFailed).stage,ExportStage.verifying);
    } finally {await root.delete(recursive:true);await fx.dispose();}
  });
  test('a rename that flips one middle byte is caught by authenticating the published file',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('native_cipher_flip_');
    try {
      final free=Space();final destination=NativeDestination(root,free)..flipMiddleOnRename=true;
      final outcome=await OfficialExportCoordinator().export(snapshot:Snapshot(fx.forkPath),privateRoot:Directory('${root.path}/private'),
        destination:destination,space:ExportSpaceBudget(source:free),prompts:Prompts(()async=>'pw',(_)async=>false));
      expect(outcome,isA<OfficialExportFailed>());
      expect((outcome as OfficialExportFailed).stage,ExportStage.verifying);
    } finally {await root.delete(recursive:true);await fx.dispose();}
  });
  test('the published file is read back as a stream, never seeked, so a pipe-backed provider still publishes',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('native_cipher_pipe_');
    try {
      final free=Space();final destination=NativeDestination(root,free);
      final outcome=await OfficialExportCoordinator().export(snapshot:Snapshot(fx.forkPath),privateRoot:Directory('${root.path}/private'),
        destination:destination,space:ExportSpaceBudget(source:free),prompts:Prompts(()async=>'pw',(_)async=>false));
      expect(outcome,isA<OfficialExportSaved>());
      expect(destination.verifies,2);
    } finally {await root.delete(recursive:true);await fx.dispose();}
  });
  test('an older bridge without the cipher methods exports through the Dart stream',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('native_cipher_old_');
    try {
      final free=Space();final destination=NativeDestination(root,free)..nativeSupported=false;
      final outcome=await OfficialExportCoordinator().export(snapshot:Snapshot(fx.forkPath),privateRoot:Directory('${root.path}/private'),
        destination:destination,space:ExportSpaceBudget(source:free),prompts:Prompts(()async=>'pw',(_)async=>false));
      expect(outcome,isA<OfficialExportSaved>());
      expect((destination.encrypts,destination.verifies),(0,0));
      expect(destination.appends,greaterThan(0));
      final saved=(outcome as OfficialExportSaved).receipt;
      expect(await verifyBackupStream(File(saved.file.path).openRead(),'pw'),saved.plainSha256);
    } finally {await root.delete(recursive:true);await fx.dispose();}
  });
  test('the Android destination reads the cipher capability off the bridge: an older bridge answers false',()async {
    final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final storage=const AndroidCipherBackupStorage(BackupFolder(uri:'content://tree',name:'Documents'));
    // No handler: every call is a MissingPluginException, as on a bridge built before the cipher.
    expect(await storage.nativeAvailable(),isFalse);
    messenger.setMockMethodCallHandler(AndroidBackupStorage.channel,(call)async=>call.method=='cipherProgress'?0:null);
    try {expect(await storage.nativeAvailable(),isTrue);}
    finally {messenger.setMockMethodCallHandler(AndroidBackupStorage.channel,null);}
  });
  // [review r1 F6] One free-space sample before a ~1 GB native write lets a band
  // drain or another writer spend the ingestion reserve mid-write, so the
  // writer is handed the reserve and rechecks it itself.
  test('the native writer is handed the live-data reserve to recheck while it writes',()async {
    final fx=await RichFixture.build();final root=await Directory.systemTemp.createTemp('native_cipher_floor_');
    try {
      final free=Space();final destination=NativeDestination(root,free);
      final budget=ExportSpaceBudget(source:free,liveFloorBytes:123456789);
      final outcome=await OfficialExportCoordinator().export(snapshot:Snapshot(fx.forkPath),privateRoot:Directory('${root.path}/private'),
        destination:destination,space:budget,prompts:Prompts(()async=>'pw',(_)async=>false));
      expect(outcome,isA<OfficialExportSaved>());
      expect(destination.floors,[123456789]);
    } finally {await root.delete(recursive:true);await fx.dispose();}
  });
  test('the bridge passes the reserve down and a refusal from its writer is the ordinary space refusal',()async {
    final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final storage=const AndroidCipherBackupStorage(BackupFolder(uri:'content://tree',name:'Documents'));
    final key=OsbkKey(Uint8List(38),Uint8List(32));
    Map<Object?,Object?>? sent;
    messenger.setMockMethodCallHandler(AndroidBackupStorage.channel,(call)async {
      if(call.method=='cipherProgress')return 0;
      if(call.method=='encryptCiphertext'){
        sent=call.arguments as Map<Object?,Object?>;
        throw PlatformException(code:'space',message:'no room',details:[1000,2000,3000]);
      }
      return null;
    });
    try {
      await expectLater(storage.encryptFileInto(const BackupFile(path:'x',name:'x'),'/plain',key,floorBytes:777),
        throwsA(isA<ExportSpaceExhausted>().having((e)=>(e.freeBytes,e.nextWriteBytes,e.floorBytes),'numbers',(1000,2000,3000))));
      expect(sent!['floorBytes'],777);
    } finally {messenger.setMockMethodCallHandler(AndroidBackupStorage.channel,null);}
  });
}
