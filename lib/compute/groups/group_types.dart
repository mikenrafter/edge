// group_types.dart — the calculation-group registry vocabulary (design 06).
//
// The types live in openstrap_analytics (lib/src/onehz/registry/
// group_registry.dart) since phase 1b, because analytics declares its own
// groups; edge re-exports them so its imports keep working.
export 'package:openstrap_analytics/onehz.dart'
    show GroupKind, InputScope, InputDecl, GroupDecl, GroupRegistry;
