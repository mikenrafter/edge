// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'pulse_respiratory_pair_test.dart' as f;
import 'pulse_residual_cases.dart';

List<ana.PulseBeatInput> mixedTrace(bool physical, double bpm, double amplitude, int seed, {bool mixture=true}) {
 final random=Random(seed);
 return f.trace(f.target,20,(i,t) {
  final mean=60000/bpm, noise=120*(2*random.nextDouble()-1);
  final phase=2*pi*.25*(physical ? t/1000 : (i+1)*mean/1000);
  return t>=300000 && t<900000 ? (mean+noise+(mixture?amplitude*sin(phase):0)).round() : mean.round();
 });
void main() {
 // WHY/CLAIM(pulse-respiratory-residual): respiration can coexist with independent irregularity.
 // # catches: spectral matching alone, resampled-domain floors, and personal thresholds suppressing a residual.
 test('997 frozen counterfactual pairs survive both baseline states', () {
  final lost=<String>[];var cases=0;
  for(final cell in protectedRespiratoryCases) {
   for(final seed in cell.seeds) {
    final key='${cell.physical}:${cell.bpm}:${cell.amplitude}:$seed';
    final beats=mixedTrace(cell.physical,cell.bpm,cell.amplitude,seed);
    // Frozen membership is never selected by this implementation's decisions.
    expect(f.run(beats,sleeping:false).episodes,hasLength(1),reason:'mixture control $key');
    expect(f.run(mixedTrace(cell.physical,cell.bpm,cell.amplitude,seed,mixture:false)).episodes,hasLength(1),reason:'sinusoid-free control $key');
    for(final ready in [false,true]) {
     final result=f.run(beats,ready:ready);
     expect(result.windows.first.toJson()['baseline'],containsPair('status',ready?'ready':'calibrating'));
     if(result.episodes.isEmpty)lost.add('$key:ready=$ready');
    }
    cases++;
   }
   print('RESIDUAL_PROGRESS cases=$cases lost=${lost.length}');
  }
  print('PROTECTED_RESIDUAL ${jsonEncode({'cases':cases,'lost':lost})}');
  expect(lost,isEmpty);
 },timeout:const Timeout(Duration(minutes:12)),tags:'sweep');
 // WHY: keep the concrete counterexample cheap enough for every pulse gate.
 // # catches: failing to connect the residual decision to production detection.
 test('52 bpm random RR with 50 ms respiratory modulation remains eligible', () {
  for(final ready in [false,true]) {
   final result=f.run(mixedTrace(true,52,50,0),ready:ready);
   expect(result.episodes,hasLength(1));
   expect(result.windows.every((w)=>w.qualified),isTrue);
  }
 });
}
