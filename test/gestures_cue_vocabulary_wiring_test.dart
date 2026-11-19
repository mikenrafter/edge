import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source_lexical.dart';

void main() {

  group('AppState wiring (source guards)', () {
    // The cue methods live in the gesture controller; the ack in
    // _onLiveEvent stays in AppState.
    final appSrc = File('lib/state/app_state.dart').readAsStringSync();

    test('the action-done ack goes through ackTap with the confirm cue', () {
      final body = codeOnly(bodyOf(appSrc, 'void _onLiveEvent('));
      expect(body, contains('ackTap('));
      expect(body, contains('gestureCues.confirm'));
    });
  });
}
