// capabilities_scope.dart — how a screen gets its Capabilities.
//
// main.dart provides one Capabilities above the app, fed by AppState (see
// AppState.capabilities) and rebuilt only when an input actually moved. A
// screen reads it with `context.caps` (rebuilds on change) or
// `context.capsRead` (callbacks, initState).
//
// Outside that provider the answer is built from what is at hand, never from a
// guess: an AppState above the screen supplies the band inputs; with neither
// (a golden), the detached inputs say there is no band. That mirrors how the
// ui2 screens already treat a missing AppState.

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'capabilities.dart';
import 'prefs.dart';

extension CapabilitiesContext on BuildContext {
  /// Capabilities for this subtree; rebuilds the caller when they change.
  Capabilities get caps => _resolve(this, listen: true);

  /// Capabilities now, without subscribing.
  Capabilities get capsRead => _resolve(this, listen: false);
}

Capabilities _resolve(BuildContext c, {required bool listen}) {
  try {
    return Provider.of<Capabilities>(c, listen: listen);
  } on ProviderNotFoundException {
    // Fall through to the next source.
  }
  try {
    return Provider.of<AppState>(c, listen: listen).capabilities;
  } on ProviderNotFoundException {
    // Fall through to the detached answer.
  }
  return Capabilities(
    CapabilityInputs.detached(devMode: Prefs.getBool(Prefs.devMode, false)),
  );
}
