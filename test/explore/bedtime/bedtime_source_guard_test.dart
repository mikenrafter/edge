// Source guards for Bedtime breathing cues: one causal-stager call path (AGENTS
// 3.8), pure policy, a controller with no AppState reference, no treatment
// wording on the screen. Evidence: Tsai et al. 2015, doi:10.1111/psyp.12333.
//
// These read the files in lib/explore/bedtime, so they hold from the first
// commit (they pass against the phase 1 stubs too).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The file's code with `//` comments removed (a comment may say "no AppState").
String _src(String name) => File('lib/explore/bedtime/$name')
    .readAsLinesSync()
    .map((l) => l.replaceFirst(RegExp(r'//.*$'), ''))
    .join('\n');

void main() {
  final files = {
    'policy': _src('bedtime_pacing_policy.dart'),
    'controller': _src('bedtime_session_controller.dart'),
    'screen': _src('bedtime_screen.dart'),
  };

  test('no second stager: nothing here runs or reaches the analytics stager', () {
    for (final e in files.entries) {
      for (final needle in [
        'CausalStager',
        'observeNaturalSync',
        'IsolateNaturalStageObserver(',
        'package:openstrap_analytics',
        'Isolate.run',
        'dart:isolate',
      ]) {
        expect(e.value.contains(needle), isFalse, reason: '${e.key}: $needle');
      }
    }
  });

  test('the policy is pure: no clock, no I/O, no timers, no UI', () {
    final p = files['policy']!;
    for (final needle in [
      'DateTime.now',
      'dart:io',
      'dart:async',
      'Timer',
      'package:flutter/material',
      'package:flutter/widgets',
      'app_state',
      'Prefs',
    ]) {
      expect(p.contains(needle), isFalse, reason: needle);
    }
  });

  test('the controller and screen hold no AppState reference', () {
    for (final n in ['controller', 'screen']) {
      expect(files[n]!.contains('app_state'), isFalse, reason: n);
      expect(files[n]!.contains('AppState'), isFalse, reason: n);
    }
  });

  test('the screen carries no treatment or guarantee wording', () {
    final banned = RegExp(
        r'\b(insomnia\w*|treat\w*|cure\w*|guarantee\w*)\b|fell asleep in',
        caseSensitive: false);
    expect(banned.hasMatch(files['screen']!), isFalse);
  });
}
