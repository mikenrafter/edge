// Streaming facade for the shared OSBK crypto owner. No verification plaintext.
import 'dart:io';

Future<String> encryptBackupStream(File source, String passphrase,
    Future<void> Function(List<int>) write, {
    void Function(int)? onBytes, void Function()? checkCancelled,
    int iterations = 210000,
}) async => 'stub';
Future<String> verifyBackupStream(Stream<List<int>> source, String passphrase, {
    void Function(int)? onBytes, void Function()? checkCancelled,
}) async => 'stub';
