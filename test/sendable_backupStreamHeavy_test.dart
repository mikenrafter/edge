// WHY: registered streaming crypto messages and actual results must cross the
// isolate boundary. CLAIM(official-export-saved-bytes).
import 'package:flutter_test/flutter_test.dart';
import 'guards/support/entry_samples.dart';
void main(){test('backupStreamHeavy actual request/result round trip',()async{await kEntrySamples['backupStreamHeavy']!.roundTrip();});}
