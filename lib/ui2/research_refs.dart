// The studies the app names on screen, in one place, and the one widget that
// turns a citation line into links.
//
// A DOI is only ever written here after it has been seen in the repo's own
// sources (test/ui2_research_refs_test.dart fails on one that has not). A
// reference without a DOI is kept with `doi: null` and renders as plain text,
// never as a guessed link; filling in its DOI is all it takes to light it up.

import 'package:flutter/widgets.dart';

import 'community_links.dart';
import 'grammar.dart';
import 'theme.dart';

class ResearchRef {
  const ResearchRef(this.id, this.label, {this.venue, this.doi});

  /// Stable key, not shown.
  final String id;

  /// The short form exactly as it appears in a citation line.
  final String label;

  /// Journal as the repo's own comments name it. Null where none does.
  final String? venue;

  /// Bare DOI, `10.xxxx/...` — no `doi:` and no URL prefix. Null = no link.
  final String? doi;

  String? get url => doi == null ? null : 'https://doi.org/$doi';
}

const kResearchRefs = <ResearchRef>[
  // DOIs below are quoted in lib/compute/derivation_engine.dart.
  ResearchRef('straczkiewicz2023', 'Straczkiewicz 2023',
      venue: 'npj Digit Med', doi: '10.1038/s41746-022-00745-z'),
  ResearchRef('oconnell2017', 'O\'Connell 2017',
      venue: 'PLoS ONE', doi: '10.1371/journal.pone.0169616'),
  // Shown on screen, no DOI in the repo yet — plain text until one is added.
  ResearchRef('taskforce1996', 'Task Force 1996'),
  ResearchRef('lipponen2019', 'Lipponen & Tarvainen 2019'),
  ResearchRef('plews2013', 'Plews 2013'),
  ResearchRef('pimentel2017', 'Pimentel 2017'),
  ResearchRef('vanhees2015', 'van Hees 2015'),
  ResearchRef('keytel2005', 'Keytel 2005'),
  ResearchRef('banister1975', 'Banister 1975'),
  ResearchRef('edwards1993', 'Edwards 1993'),
  ResearchRef('baevsky2008', 'Baevsky 2008'),
  ResearchRef('cole1999', 'Cole 1999'),
  ResearchRef('laguna1998', 'Laguna 1998'),
  ResearchRef('bigger1992', 'Bigger 1992'),
];

/// The linkable reference named inside one citation segment, if any.
ResearchRef? linkedRefIn(String segment) {
  for (final r in kResearchRefs) {
    if (r.doi != null && segment.contains(r.label)) return r;
  }
  return null;
}

const _sep = ' · ';

/// A citation line. Each `·`-separated part that names a reference with a
/// DOI is a tappable link to https://doi.org/DOI in the external browser;
/// everything else stays plain text. A line with nothing to link is the same
/// single [Text] it always was.
Widget researchCitation(
  BuildContext c,
  String citation, {
  TextStyle? style,
  Future<bool> Function(String url) open = open3rdPartyLink,
}) {
  final parts = citation.split(_sep);
  if (!parts.any((s) => linkedRefIn(s) != null)) {
    return Text(citation, style: style);
  }
  final linkStyle = (style ?? F.over).copyWith(
    color: P.of(c).on(C.blue),
    decoration: TextDecoration.underline,
  );
  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0) Text(_sep, style: style),
        if (linkedRefIn(parts[i]) case final ref?)
          Pressable(
            link: true,
            semanticLabel: ref.label,
            onTap: () => open(ref.url!),
            child: ExcludeSemantics(child: Text(parts[i], style: linkStyle)),
          )
        else
          Text(parts[i], style: style),
      ],
    ],
  );
}
