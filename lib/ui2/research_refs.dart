// The studies the app names on screen, in one place, and the one widget that
// turns a citation line into links.
//
// A DOI is only ever written here after it has been fetched from Crossref and
// doi.org and matched on first author, title and year, and is recorded with
// its evidence in docs/research-references.md (test/ui2_research_refs_test.dart
// fails on a DOI that is not in the repo's sources outside this table). A
// reference without a DOI is kept with `doi: null` and renders as plain text,
// never as a guessed link; filling in its DOI is all it takes to light it up.
// A book or chapter with no DOI carries a `link` to a library or book record.

import 'package:flutter/widgets.dart';

import 'community_links.dart';
import 'grammar.dart';
import 'theme.dart';

class ResearchRef {
  const ResearchRef(this.id, this.label, {this.venue, this.doi, this.link});

  /// Stable key, not shown.
  final String id;

  /// The short form exactly as it appears in a citation line.
  final String label;

  /// Journal as the repo's own comments name it. Null where none does.
  final String? venue;

  /// Bare DOI, `10.xxxx/...` — no `doi:` and no URL prefix. Null = no link.
  final String? doi;

  /// Page to open when the work has no DOI (a book or a chapter): a library
  /// or publisher record, https only. Never set together with [doi].
  final String? link;

  String? get url => doi != null ? 'https://doi.org/$doi' : link;
}

const kResearchRefs = <ResearchRef>[
  // Straczkiewicz and O'Connell: DOIs quoted in lib/compute/derivation_engine.dart.
  // The rest: each DOI fetched from Crossref and doi.org on 2026-10-03 and matched
  // on first author, title and year — see docs/research-references.md.
  ResearchRef('straczkiewicz2023', 'Straczkiewicz 2023',
      venue: 'npj Digit Med', doi: '10.1038/s41746-022-00745-z'),
  ResearchRef('oconnell2017', 'O\'Connell 2017',
      venue: 'PLoS ONE', doi: '10.1371/journal.pone.0169616'),
  ResearchRef('taskforce1996', 'Task Force 1996',
      venue: 'Circulation', doi: '10.1161/01.CIR.93.5.1043'),
  ResearchRef('lipponen2019', 'Lipponen & Tarvainen 2019',
      venue: 'J Med Eng Technol', doi: '10.1080/03091902.2019.1640306'),
  ResearchRef('plews2013', 'Plews 2013',
      venue: 'Sports Med', doi: '10.1007/s40279-013-0071-8'),
  ResearchRef('pimentel2017', 'Pimentel 2017',
      venue: 'IEEE Trans Biomed Eng', doi: '10.1109/TBME.2016.2613124'),
  ResearchRef('vanhees2015', 'van Hees 2015',
      venue: 'PLoS ONE', doi: '10.1371/journal.pone.0142533'),
  ResearchRef('keytel2005', 'Keytel 2005',
      venue: 'J Sports Sci', doi: '10.1080/02640410470001730089'),
  // No DOI exists for these. Banister 1991 is a Human Kinetics book chapter and
  // Edwards 1993 a trade book, so each links to a library or book record
  // instead; Baevsky 2008 is a booklet whose source is still unconfirmed, so it
  // stays plain text. See docs/research-references.md.
  ResearchRef('banister1991', 'Banister 1991',
      link: 'https://archive.org/details/physiologicaltes0000unse'),
  ResearchRef('morton1990', 'Morton 1990',
      venue: 'J Appl Physiol', doi: '10.1152/jappl.1990.69.3.1171'),
  ResearchRef('edwards1993', 'Edwards 1993',
      link: 'https://books.google.com/books?vid=ISBN0963463306'),
  ResearchRef('baevsky2008', 'Baevsky 2008'),
  ResearchRef('cole1999', 'Cole 1999',
      venue: 'N Engl J Med', doi: '10.1056/NEJM199910283411804'),
  ResearchRef('laguna1998', 'Laguna 1998',
      venue: 'IEEE Trans Biomed Eng', doi: '10.1109/10.678605'),
  ResearchRef('bigger1992', 'Bigger 1992',
      venue: 'Circulation', doi: '10.1161/01.CIR.85.1.164'),
];

/// The linkable reference named inside one citation segment, if any.
ResearchRef? linkedRefIn(String segment) {
  for (final r in kResearchRefs) {
    if (r.url != null && segment.contains(r.label)) return r;
  }
  return null;
}

const _sep = ' · ';

/// A citation line. Each `·`-separated part that names a reference with a
/// DOI (https://doi.org/DOI) or a book `link` is a tappable link in the
/// external browser;
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
