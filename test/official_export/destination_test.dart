// WHY: the Dart folder adapter must send uncompressed bytes and close both I/O
// directions. CLAIM(official-export-saved-bytes). Native provider is the boundary.
// catches: gzip OSBK; create a private cipher copy; skip final-handle reads.
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/backup_storage.dart';
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 test('Android adapter streams bounded bytes through the scoped folder owner',()async{
  final calls=<String>[];final bytes=<int>[];var read=false;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(AndroidBackupStorage.channel,(call)async{
    calls.add(call.method);
    expect((call.arguments as Map)['tree'],'content://provider/tree/chosen');
    switch(call.method){
     case 'openCiphertext':return {'uri':'content://provider/staging','name':'export.incomplete'};
     case 'appendCiphertext':bytes.addAll((call.arguments as Map)['bytes'] as Uint8List);return null;
     case 'readCiphertext':if(read)return Uint8List(0);read=true;return Uint8List.fromList(bytes);
     case 'rename':return {'uri':'content://provider/published','name':'export.osbk'};
     default:return null;
    }
  });
  addTearDown(()=>TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(AndroidBackupStorage.channel,null));
  const storage=AndroidCipherBackupStorage(BackupFolder(uri:'content://provider/tree/chosen',name:'Chosen'));
  final file=await storage.createCiphertext('export.incomplete');
  await storage.appendCiphertext(file,[79,83,66,75,1]);await storage.closeCiphertext(file);
  expect(await storage.readCiphertext(file).expand((b)=>b).toList(),[79,83,66,75,1]);
  final published=await storage.publishCiphertext(file,'export.osbk');expect(published.path,'content://provider/published');
  await storage.deleteCiphertext(published);
  expect(calls,['openCiphertext','appendCiphertext','closeCiphertext','readCiphertext','readCiphertext','closeCiphertextRead','rename','delete']);
 });
}
