#!/usr/bin/env python3
"""Prove that the lib/data/db.dart split is mechanical.

Usage: tool/check_move_only.py [BASE_REF]   (default: a9b765a7, the split's base)

A one-time proof for the split commit: once db.dart or a part changes after
merge, it is expected to report differences.

Compares lib/data/db.dart at BASE_REF with the working tree (db.dart plus
lib/data/db/*.dart). Stdlib only; run from anywhere inside the repo.

The split keeps every moved LocalDb static's declaration in db.dart as a
one-line forward to a top-level `_ldb<Name>` function in a part file. Checks:

  1. BODY      each `_ldb<Name>` function equals its base member byte for byte
               (comments, whitespace, strings), except for inserted `LocalDb.`
               qualifiers on LocalDb statics (`$x` in a string becomes
               `${LocalDb.x}`), found with a tokenizer, not a regex on text.
  2. FORWARD   the db.dart member is the base member up to the end of its
               parameter list, then ` => _ldb<Name><type args>(<every parameter
               by name, named ones as name: name>);` and nothing else.
  3. DECL      everything before ` =>` (doc comment, annotations, signature,
               defaults) is unchanged from the base.
  4. REST      every other line of base db.dart is unchanged or moved verbatim:
               the multiset of remaining non-blank lines is equal across base and
               (db.dart + parts), db.dart keeps their order, and each remaining
               top-level item of a part is one contiguous run of base lines.
               Only blank lines and `part` / `part of` lines are ignored.

Prints a readable diff for every violation and exits 1; exits 0 when clean.
"""
import difflib
import glob
import os
import re
import subprocess
import sys
from collections import Counter

DB = 'lib/data/db.dart'
PARTS = 'lib/data/db/*.dart'
CLASS = 'LocalDb'

# ---------------------------------------------------------------- tokenizer

PUNCT = ['>>>=', '<<=', '>>=', '...?', '...', '??=', '~/=', '>>>', '..?', '?..',
         '=>', '==', '!=', '>=', '<=', '+=', '-=', '*=', '/=', '%=', '&=', '|=',
         '^=', '&&', '||', '??', '..', '?.', '++', '--', '<<', '>>', '~/']
IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
NUM = re.compile(r'0[xX][0-9a-fA-F]+|\d+')


class Tok:
    __slots__ = ('kind', 'text', 'pos')

    def __init__(self, kind, text, pos):
        self.kind, self.text, self.pos = kind, text, pos

    def __repr__(self):
        return f'{self.kind}:{self.text!r}'


def lex(src):
    """Tokens that concatenate back to `src`. Kinds: ws, comment, id, num,
    sym, str (string text), interp ($ before shorthand id), ibeg ($ { ), iend
    (the closing brace of ${...}); code inside ${...} is lexed as code."""
    toks = []
    i, n = 0, len(src)
    stack = []  # entries: ('str', quote, raw) or ('code', brace_depth)
    code_depths = []  # brace depth stack for ${ } code
    brace = 0

    def string_body(i, quote, raw):
        """Lex string text from i until closing quote or an interpolation."""
        start = i
        triple = len(quote) == 3
        while i < n:
            c = src[i]
            if not raw and c == '\\':
                i += 2
                continue
            if src.startswith(quote, i):
                if i > start:
                    toks.append(Tok('str', src[start:i], start))
                toks.append(Tok('str', quote, i))
                return i + len(quote), 'closed'
            if c == '\n' and not triple:
                break
            if not raw and c == '$':
                if i > start:
                    toks.append(Tok('str', src[start:i], start))
                if i + 1 < n and src[i + 1] == '{':
                    toks.append(Tok('ibeg', '${', i))
                    return i + 2, 'interp'
                m = IDENT.match(src, i + 1)
                if m:
                    toks.append(Tok('interp', '$', i))
                    toks.append(Tok('id', m.group(), i + 1))
                    i = m.end()
                    start = i
                    continue
            i += 1
        if i > start:
            toks.append(Tok('str', src[start:i], start))
        return i, 'eof'

    def begin_string(i):
        """If a string literal starts at i, lex it; return new i or None."""
        raw = False
        j = i
        if src[j] == 'r' and j + 1 < n and src[j + 1] in '\'"':
            raw = True
            j += 1
        if src[j] not in '\'"':
            return None
        q = src[j]
        quote = q * 3 if src.startswith(q * 3, j) else q
        toks.append(Tok('str', src[i:j + len(quote)], i))
        return j + len(quote), quote, raw

    while i < n:
        if stack and stack[-1][0] == 'str':
            _, quote, raw = stack[-1]
            i, state = string_body(i, quote, raw)
            if state == 'closed':
                stack.pop()
            elif state == 'interp':
                code_depths.append(brace)
                brace = 0
                stack.append(('code',))
            else:
                stack.pop()
            continue
        c = src[i]
        if c.isspace():
            j = i
            while j < n and src[j].isspace():
                j += 1
            toks.append(Tok('ws', src[i:j], i))
            i = j
            continue
        if src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            toks.append(Tok('comment', src[i:j], i))
            i = j
            continue
        if src.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith('/*', j):
                    depth += 1
                    j += 2
                elif src.startswith('*/', j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            toks.append(Tok('comment', src[i:j], i))
            i = j
            continue
        s = begin_string(i) if (c in '\'"' or (c == 'r' and i + 1 < n and src[i + 1] in '\'"')) else None
        if s:
            i, quote, raw = s
            stack.append(('str', quote, raw))
            continue
        m = IDENT.match(src, i)
        if m:
            toks.append(Tok('id', m.group(), i))
            i = m.end()
            continue
        m = NUM.match(src, i)
        if m:
            toks.append(Tok('num', m.group(), i))
            i = m.end()
            continue
        if c == '{':
            brace += 1
        elif c == '}':
            if stack and stack[-1][0] == 'code' and brace == 0:
                toks.append(Tok('iend', '}', i))
                stack.pop()
                brace = code_depths.pop()
                i += 1
                continue
            brace -= 1
        for p in PUNCT:
            if src.startswith(p, i):
                toks.append(Tok('sym', p, i))
                i += len(p)
                break
        else:
            toks.append(Tok('sym', c, i))
            i += 1
    assert ''.join(t.text for t in toks) == src, 'lexer lost text'
    return toks


def code(toks):
    return [t for t in toks if t.kind not in ('ws', 'comment')]


# ---------------------------------------------------------- member splitting

OPEN, CLOSE = '([{', ')]}'


def split_items(src, toks, lo, hi):
    """Split code between token indexes lo..hi (a class body or a whole file)
    into top-level items. Returns dicts with: tstart (first token incl. leading
    trivia), sig (first code token after metadata), end (exclusive offset),
    ctoks (code tokens of the item)."""
    items = []
    i = lo
    while i < hi:
        # skip trivia
        k = i
        while k < hi and toks[k].kind in ('ws', 'comment'):
            k += 1
        if k >= hi:
            break
        first = k
        depth = 0
        seen_assign = False
        j = k
        end = None
        while j < hi:
            t = toks[j]
            if t.kind in ('str', 'ibeg', 'iend', 'interp'):
                j += 1
                continue
            if t.kind == 'sym':
                if t.text in OPEN:
                    if t.text == '{' and depth == 0 and not seen_assign:
                        # block body: ends at the matching brace
                        d = 0
                        m = j
                        while m < hi:
                            tm = toks[m]
                            if tm.kind == 'sym':
                                if tm.text in OPEN:
                                    d += 1
                                elif tm.text in CLOSE:
                                    d -= 1
                                    if d == 0:
                                        break
                            m += 1
                        end = m
                        break
                    depth += 1
                elif t.text in CLOSE:
                    depth -= 1
                elif depth == 0 and t.text in ('=', '=>'):
                    seen_assign = True
                elif depth == 0 and t.text == ';':
                    end = j
                    break
            j += 1
        if end is None:
            end = hi - 1
        items.append({'tstart': i, 'first': first, 'tend': end + 1})
        i = end + 1
    for it in items:
        it['start'] = toks[it['tstart']].pos
        last = toks[it['tend'] - 1]
        it['end'] = last.pos + len(last.text)
        it['ctoks'] = [t for t in toks[it['first']:it['tend']] if t.kind not in ('ws', 'comment')]
        # signature start: skip metadata annotations
        c = it['ctoks']
        s = 0
        while s < len(c) and c[s].text == '@':
            s += 1
            if s < len(c) and c[s].kind == 'id':
                s += 1
            while s + 1 < len(c) and c[s].text == '.' and c[s + 1].kind == 'id':
                s += 2
            if s < len(c) and c[s].text == '(':
                d = 0
                while s < len(c):
                    if c[s].kind == 'sym' and c[s].text in OPEN:
                        d += 1
                    elif c[s].kind == 'sym' and c[s].text in CLOSE:
                        d -= 1
                        if d == 0:
                            s += 1
                            break
                    s += 1
        it['sig'] = c[s].pos if s < len(c) else it['end']
        it['sigi'] = s
    return items


def describe(it):
    """name, kind, params (open/close token positions or None), name token."""
    c = it['ctoks']
    s = it['sigi']
    depth = 0
    kind, name_t, popen = 'field', None, None
    for k in range(s, len(c)):
        t = c[k]
        if t.kind != 'sym' and t.kind != 'id':
            continue
        if t.kind == 'sym':
            if t.text == '(' and depth == 0:
                prev = c[k - 1] if k > s else None
                if (prev is None or prev.text in ('Function', 'static', 'final',
                        'const', 'late', 'external', 'get', 'set')
                        or (prev.kind == 'sym' and prev.text != '>')):
                    depth += 1
                    continue
                popen = k
                p = k - 1
                if c[p].text == '>':
                    d = 0
                    while p >= 0:
                        if c[p].text == '>':
                            d += 1
                        elif c[p].text == '<':
                            d -= 1
                            if d == 0:
                                p -= 1
                                break
                        p -= 1
                name_t = c[p]
                kind = 'method'
                break
            if t.text in OPEN:
                depth += 1
            elif t.text in CLOSE:
                depth -= 1
            elif depth == 0 and t.text in ('{', '=>', '=', ';'):
                break
    if kind == 'field':
        # getter/setter or field
        ids = []
        for k in range(s, len(c)):
            t = c[k]
            if t.kind == 'sym' and t.text in ('{', '=>', '=', ';') and not ids == []:
                break
            if t.kind == 'id':
                ids.append((k, t))
        for pos, (k, t) in enumerate(ids):
            if t.text in ('get', 'set') and pos + 1 < len(ids) and pos > 0:
                kind = t.text
                name_t = ids[pos + 1][1]
                break
        if name_t is None and ids:
            name_t = ids[-1][1]
    return kind, name_t, popen


def param_info(c, popen):
    """(params_end_pos, args) for a method whose parameter list opens at c[popen]."""
    entries, tokens = [], []
    in_named = False
    depth = 0      # nesting inside ( [ { of the current parameter
    angle = 0
    end = None
    for k in range(popen + 1, len(c)):
        t = c[k]
        if t.kind == 'sym':
            if t.text in OPEN:
                if depth == 0 and not tokens and t.text in '[{':
                    in_named = t.text == '{'
                    continue
                depth += 1
            elif t.text in CLOSE:
                if depth == 0:
                    if t.text == ')':
                        if tokens:
                            entries.append((tokens, in_named))
                        end = t.pos + 1
                        break
                    continue            # closes the optional/named group
                depth -= 1
            elif t.text == '<':
                angle += 1
            elif t.text == '>':
                angle -= 1
            elif t.text == '>>':
                angle -= 2
            elif t.text == ',' and depth == 0 and angle <= 0:
                if tokens:
                    entries.append((tokens, in_named))
                tokens = []
                continue
        tokens.append(t)
    args = []
    for toks, nm in entries:
        dd = 0
        cut = len(toks)
        for q, t in enumerate(toks):
            if t.kind == 'sym' and t.text in OPEN:
                dd += 1
            elif t.kind == 'sym' and t.text in CLOSE:
                dd -= 1
            elif dd == 0 and t.kind == 'sym' and t.text == '=':
                cut = q
                break
        toks = toks[:cut]
        if toks[-1].text == ')':       # old-style function-typed parameter
            dd, q = 0, len(toks) - 1
            while q >= 0:
                dd += (toks[q].text == ')') - (toks[q].text == '(')
                if dd == 0:
                    break
                q -= 1
            name = toks[q - 1].text
        else:
            name = toks[-1].text
        args.append(f'{name}: {name}' if nm else name)
    return end, args


def type_param_names(c, name_k, popen):
    if c[popen - 1].text != '>':
        return ''
    names, depth, expect = [], 0, True
    for t in c[name_k + 1:popen]:
        if t.text == '<':
            depth += 1
            if depth == 1:
                continue
        elif t.text == '>':
            depth -= 1
            continue
        if depth == 1 and t.kind == 'id' and expect:
            names.append(t.text)
            expect = False
        elif depth == 1 and t.text == ',':
            expect = True
    return '<' + ', '.join(names) + '>'


# ------------------------------------------------------------------ aligning


def align(expected, moved, statics):
    """Compare token streams; `moved` may add `LocalDb.` before statics and turn
    `$x` into `${LocalDb.x}`. Returns (problem or None, qualifier_count)."""
    a = [t for t in lex(expected)]
    b = [t for t in lex(moved)]
    i = j = quals = 0
    while i < len(a) and j < len(b):
        if a[i].text == b[j].text and a[i].kind == b[j].kind:
            i += 1
            j += 1
        elif (b[j].kind == 'id' and b[j].text == CLASS and j + 2 < len(b)
              and b[j + 1].text == '.' and b[j + 2].kind == 'id'
              and b[j + 2].text in statics):
            j += 2
            quals += 1
        elif (a[i].kind == 'interp' and b[j].kind == 'ibeg' and j + 4 < len(b)
              and b[j + 1].text == CLASS and b[j + 2].text == '.'
              and b[j + 3].kind == 'id' and b[j + 4].kind == 'iend'
              and a[i + 1].text == b[j + 3].text and b[j + 3].text in statics):
            i += 2
            j += 5
            quals += 1
        else:
            break
    if i == len(a) and j == len(b):
        return None, quals
    pos_a = a[i].pos if i < len(a) else len(expected)
    pos_b = b[j].pos if j < len(b) else len(moved)
    return (expected[max(0, pos_a - 60):pos_a + 60],
            moved[max(0, pos_b - 60):pos_b + 60]), quals


# --------------------------------------------------------------------- main


def git(*args, root):
    return subprocess.run(['git', *args], cwd=root, check=True,
                          capture_output=True, text=True).stdout


def lines_of(text, spans):
    """Non-blank, non-directive lines of `text` outside the char spans."""
    out = []
    pos = 0
    for line in text.split('\n'):
        a, b = pos, pos + len(line)
        pos = b + 1
        if not line.strip():
            continue
        if any(s <= a and b <= e for s, e in spans) or any(
                s < b and a < e and s <= a for s, e in spans):
            # line lies (at least starting) inside a span
            if any(s <= a < e for s, e in spans):
                continue
        if re.match(r'\s*part( of)? ', line):
            continue
        out.append(line)
    return out


def class_members(src, toks):
    code_idx = [k for k, t in enumerate(toks) if t.kind not in ('ws', 'comment')]
    for n, k in enumerate(code_idx):
        if (toks[k].text == 'class' and n + 2 < len(code_idx)
                and toks[code_idx[n + 1]].text == CLASS
                and toks[code_idx[n + 2]].text == '{'):
            open_k = code_idx[n + 2]
            d, m = 0, open_k
            while m < len(toks):
                if toks[m].kind == 'sym':
                    if toks[m].text in OPEN:
                        d += 1
                    elif toks[m].text in CLOSE:
                        d -= 1
                        if d == 0:
                            break
                m += 1
            return split_items(src, toks, open_k + 1, m), open_k, m
    raise SystemExit(f'class {CLASS} not found')


def fn_name(member):
    base = member[1:] if member.startswith('_') else member
    return '_ldb' + base[0].upper() + base[1:]


def main():
    base_ref = sys.argv[1] if len(sys.argv) > 1 else 'a9b765a7'
    root = git('rev-parse', '--show-toplevel', root='.').strip()
    old = git('show', f'{base_ref}:{DB}', root=root)
    with open(os.path.join(root, DB)) as f:
        new = f.read()
    parts = {}
    for path in sorted(glob.glob(os.path.join(root, PARTS))):
        with open(path) as f:
            parts[os.path.relpath(path, root)] = f.read()

    problems = []

    def bad(msg, *detail):
        problems.append(msg)
        print('FAIL', msg)
        for d in detail:
            print('    ' + d.replace('\n', '\n    '))

    otoks, ntoks = lex(old), lex(new)
    omem, _, _ = class_members(old, otoks)
    nmem, _, _ = class_members(new, ntoks)

    def key(src, it):
        kind, nt, popen = describe(it)
        return (kind, nt.text if nt else None), (kind, nt, popen)

    ostat = {}
    statics = set()
    for it in omem:
        k, (kind, nt, popen) = key(old, it)
        ostat[k] = (it, kind, nt, popen)
        # every name a member declares (fields may declare several)
        if nt:
            statics.add(nt.text)
        if kind == 'field':
            c = it['ctoks']
            depth = 0
            for q, t in enumerate(c):
                if t.kind == 'sym' and t.text in OPEN:
                    depth += 1
                elif t.kind == 'sym' and t.text in CLOSE:
                    depth -= 1
                elif depth == 0 and t.text == ',' and q + 1 < len(c) and c[q + 1].kind == 'id':
                    statics.add(c[q + 1].text)
    nstat = {}
    for it in nmem:
        k, (kind, nt, popen) = key(new, it)
        if k in nstat:
            bad(f'duplicate member {k} in new {DB}')
        nstat[k] = (it, kind, nt, popen)
    if set(nstat) - set(ostat):
        for k in sorted(set(nstat) - set(ostat), key=str):
            bad(f'member {k} exists in new {DB} but not in the base')
    if set(ostat) - set(nstat):
        for k in sorted(set(ostat) - set(nstat), key=str):
            bad(f'member {k} of the base is missing from new {DB}')

    # Part files: top-level items.
    funcs = {}      # name -> (file, text)
    part_items = []  # (file, normalized lines list) for non-_ldb items
    part_resid = Counter()
    func_spans = {}
    for fname, src in parts.items():
        ptoks = lex(src)
        items = split_items(src, ptoks, 0, len(ptoks))
        spans = []
        for it in items:
            c = it['ctoks']
            if c and c[0].text == 'part' and len(c) > 1 and c[1].text == 'of':
                spans.append((it['start'], it['end']))
                continue
            kind, nt, popen = describe(it)
            if kind == 'method' and nt and nt.text.startswith('_ldb'):
                if nt.text in funcs:
                    bad(f'{nt.text} defined twice ({funcs[nt.text][0]} and {fname})')
                funcs[nt.text] = (fname, src[it['sig']:it['end']])
                spans.append((it['sig'], it['end']))
            # other items are "rest" blocks, checked below
        func_spans[fname] = (src, items, spans)

    moved_members = []
    used = set()
    for k, (oit, okind, ont, opopen) in ostat.items():
        if k not in nstat:
            continue
        nit = nstat[k][0]
        otext = old[oit['start']:oit['end']]
        ntext = new[nit['start']:nit['end']]
        if otext == ntext:
            continue
        name = k[1]
        if okind not in ('method', 'get'):
            bad(f'{name}: a {okind} changed but only methods/getters may move',
                *_udiff(otext, ntext))
            continue
        c = oit['ctoks']
        name_k = c.index(ont)
        if okind == 'method':
            pend, args = param_info(c, opopen)
            tp = type_param_names(c, name_k, opopen)
        else:
            pend, args, tp = ont.pos + len(ont.text), [], ''
        fn = fn_name(name)
        moved_members.append((oit['start'], oit['end']))
        # (3)+(2): declaration unchanged, then exactly the forwarder
        head = otext[:pend - oit['start']]
        want = f'{head} => {fn}{tp}({", ".join(args)});'
        if ntext != want:
            if ntext.startswith(head):
                bad(f'{name}: forwarder differs (or extra code)',
                    f'expected: {want[len(head):]}', f'found:    {ntext[len(head):]}')
            else:
                bad(f'{name}: declaration (doc comment, annotations or signature) changed',
                    *_udiff(head, ntext[:len(head) + 40]))
            continue
        # (1): body
        if fn not in funcs:
            bad(f'{name}: forwarder targets {fn}, which no part file defines')
            continue
        used.add(fn)
        ftext = funcs[fn][1]
        sig0 = oit['sig'] - oit['start']
        sig_text = otext[sig0:]
        if not sig_text.startswith('static '):
            bad(f'{name}: base member is not static')
            continue
        sig_text = sig_text[len('static '):]
        rel = lambda p: p - oit['sig'] - len('static ')
        if okind == 'method':
            expected = sig_text[:rel(ont.pos)] + fn + sig_text[rel(ont.pos) + len(ont.text):]
        else:
            kw = next(t for t in c[:name_k] if t.text == 'get' and t.pos > oit['sig'])
            body = otext[ont.pos + len(ont.text) - oit['start']:]
            expected = sig_text[:rel(kw.pos)] + fn + '()' + body
        diff, quals = align(expected, ftext, statics)
        if diff is not None:
            bad(f'{name}: moved body differs from the base beyond `{CLASS}.` qualifiers',
                f'base : ...{diff[0]}...', f'moved: ...{diff[1]}...')
    for fn in sorted(set(funcs) - used):
        bad(f'{fn} in {funcs[fn][0]} is not the target of any changed db.dart member')

    # (4) everything else
    base_rest = lines_of(old, moved_members)
    new_spans = [(it['start'], it['end']) for k, (it, *_r) in nstat.items()
                 if old[ostat[k][0]['start']:ostat[k][0]['end']] != new[it['start']:it['end']]]
    new_rest = lines_of(new, new_spans)
    parts_rest = []
    block_runs = []
    for fname, (src, items, spans) in func_spans.items():
        parts_rest += lines_of(src, spans)
        for it in items:
            c = it['ctoks']
            if (c and c[0].text == 'part') or (
                    describe(it)[1] and describe(it)[1].text.startswith('_ldb')
                    and describe(it)[0] == 'method'):
                continue
            blk = [l for l in src[it['start']:it['end']].split('\n') if l.strip()]
            block_runs.append((fname, blk))
    if Counter(base_rest) != Counter(new_rest) + Counter(parts_rest):
        d1 = Counter(base_rest) - Counter(new_rest) - Counter(parts_rest)
        d2 = Counter(new_rest) + Counter(parts_rest) - Counter(base_rest)
        for l, n in d1.items():
            bad(f'line lost x{n}: {l.strip()[:100]}')
        for l, n in d2.items():
            bad(f'line added x{n}: {l.strip()[:100]}')
    # order: db.dart rest is a subsequence of the base rest
    it_ = iter(base_rest)
    if not all(l in it_ for l in new_rest):
        bad(f'{DB}: remaining lines are not in base order')
    for fname, blk in block_runs:
        if not any(base_rest[k:k + len(blk)] == blk
                   for k in range(len(base_rest) - len(blk) + 1)):
            bad(f'{fname}: block starting {blk[0].strip()[:70]!r} ({len(blk)} lines) '
                'is not one contiguous run of base lines')

    nm = len(moved_members)
    kept = len(omem) - nm
    print(f'base {base_ref}: {len(omem)} {CLASS} members; {nm} moved to '
          f'{len(funcs)} _ldb functions in {len(parts)} part files, {kept} kept; '
          f'{DB}: {old.count(chr(10))} -> {new.count(chr(10))} lines')
    print('FAIL' if problems else 'OK: mechanical split verified')
    return 1 if problems else 0


def _udiff(a, b):
    return [l for l in difflib.unified_diff(a.split('\n'), b.split('\n'),
                                            'base', 'new', lineterm='', n=1)][:30]


if __name__ == '__main__':
    sys.exit(main())
