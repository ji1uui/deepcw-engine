#!/bin/sh
# 差し込みが 2 つ以上ある文言に、番号（`%0:s` の形）が付いているかを確かめます
# （要件 NFR-7.6）。
#
# **英語は日本語と語順が違います。**`総合 %.0f 点（%s の基準）` を
# `%s scored %.0f` と訳したくても、番号が無ければ**引数の順序を変えられません。**
# Pascal の `Format` は `%0:.0f` `%1:s` の形なら順序を選べます。
#
# **これは訳す前に済ませておく仕事です。**訳してから番号を足すと、訳文も書き直し
# になります（同じ行を 2 度触ることになる）。
#
# 差し込みが 1 つだけの文言は見ません。**1 つなら並べ替える余地がありません。**
#
# Checks that any string with two or more placeholders carries indices
# (the `%0:s` form) -- requirement NFR-7.6.
#
# **English does not keep Japanese word order.** To translate
# `総合 %.0f 点（%s の基準）` as `%s scored %.0f`, the arguments have to be
# reorderable, and without indices they are not. Pascal's `Format` allows
# `%0:.0f` and `%1:s`.
#
# **This belongs before translating**: indices added afterwards mean rewriting
# the translations too -- touching the same lines twice.
#
# A string with a single placeholder is not looked at: **with one, there is
# nothing to reorder.**
set -e
cd "$(dirname "$0")/.."

python3 - "$@" <<'PY'
import io, re, sys, glob

# 註釈のなかの文字列は見ません。**註釈は画面に出ません。**
# Strings inside comments are not looked at: **comments never reach the screen.**
def literals(path):
    s = io.open(path, encoding='utf-8').read()
    out = []
    i = 0; n = len(s); line = 1
    while i < n:
        c = s[i]
        if c == '\n': line += 1; i += 1; continue
        if c == '{':
            while i < n and s[i] != '}':
                if s[i] == '\n': line += 1
                i += 1
            i += 1; continue
        if c == '(' and i + 1 < n and s[i+1] == '*':
            i += 2
            while i + 1 < n and not (s[i] == '*' and s[i+1] == ')'):
                if s[i] == '\n': line += 1
                i += 1
            i += 2; continue
        if c == '/' and i + 1 < n and s[i+1] == '/':
            while i < n and s[i] != '\n': i += 1
            continue
        if c == "'":
            start = line; i += 1; buf = ''
            while i < n:
                if s[i] == "'":
                    if i + 1 < n and s[i+1] == "'": buf += "'"; i += 2; continue
                    i += 1; break
                if s[i] == '\n': line += 1
                buf += s[i]; i += 1
            out.append((start, buf)); continue
        i += 1
    return out

def without_comments(path):
    """註釈を空白に置き換えます。**行番号は変えません。**
    Comments blanked out, **keeping the line numbering.**"""
    s = io.open(path, encoding='utf-8').read()
    out = []
    i = 0; n = len(s)
    while i < n:
        c = s[i]
        if c == '{':
            while i < n and s[i] != '}':
                out.append('\n' if s[i] == '\n' else ' '); i += 1
            if i < n: out.append(' '); i += 1
            continue
        if c == '(' and i + 1 < n and s[i+1] == '*':
            out.append('  '); i += 2
            while i + 1 < n and not (s[i] == '*' and s[i+1] == ')'):
                out.append('\n' if s[i] == '\n' else ' '); i += 1
            out.append('  '); i += 2
            continue
        if c == '/' and i + 1 < n and s[i+1] == '/':
            while i < n and s[i] != '\n':
                out.append(' '); i += 1
            continue
        out.append(c); i += 1
    return ''.join(out)

SPEC = re.compile(r'%(?P<idx>\d+:)?-?(?:\*|\d*)(?:\.(?:\*|\d+))?[sdufgxeMmnp]')

def placeholders(t):
    """`%%` は差し込みではありません。/ `%%` is not a placeholder."""
    out = []; i = 0
    while i < len(t):
        if t[i] == '%':
            if i + 1 < len(t) and t[i+1] == '%':
                i += 2; continue
            m = SPEC.match(t, i)
            if m:
                out.append(m); i = m.end(); continue
        i += 1
    return out

japanese = re.compile(r'[ぁ-んァ-ヶ一-龠]')

# 訳さないもの——試験の出力、検査の報告、言語の名前。
# Not translated: test output, the checks' own reports, the language names.
SKIP = {
    'app/gui_probe.lpr', 'app/layoutcheck.pas', 'app/textcheck.pas',
    'app/deepcw_station.lpr', 'app/uilang.pas',
}

bad = []
looked = 0
for path in sorted(set(glob.glob('app/*.pas') + glob.glob('app/*.lpr') +
                       glob.glob('src/*.pas'))):
    if path in SKIP:
        continue
    for line, text in literals(path):
        if not japanese.search(text):
            continue
        ms = placeholders(text)
        if len(ms) < 2:
            continue
        looked += 1
        if not any(m.group('idx') for m in ms):
            bad.append((path, line, text))

# `resourcestring` の宣言に `LineEnding` が混じっていないか。
#
# **`LineEnding` は OS で中身が変わります**（Linux は `#10`、Windows は
# `#13#10`）。訳の一覧に載る綴りが OS ごとに変わるので、**Windows では訳が
# 当たりません**（付録 BH.1）。改行は `#10` と書き、画面に出す直前に
# `AsLines` が直します。
#
# Is `LineEnding` mixed into a `resourcestring` declaration?
#
# **Its contents differ by platform** (`#10` on Linux, `#13#10` on Windows), so
# the spelling in the translation list would differ and **the translations
# would not match on Windows** (appendix BH.1). Line breaks are written `#10`
# and turned into the real one by `AsLines` just before they are shown.
platform_breaks = []
for path in sorted(set(glob.glob('app/*.pas') + glob.glob('app/*.lpr') +
                       glob.glob('src/*.pas'))):
    if path in SKIP:
        continue
    text = without_comments(path)
    inside = False
    for n, line in enumerate(text.split('\n'), 1):
        stripped = line.strip()
        if stripped == 'resourcestring':
            inside = True; continue
        if inside and stripped in ('implementation', 'begin', 'var', 'type',
                                   'const'):
            inside = False; continue
        if inside and 'LineEnding' in line:
            platform_breaks.append((path, n, stripped))

if platform_breaks:
    print('訳せる文言に `LineEnding` が混じっています（%d 件）。' %
          len(platform_breaks))
    print('OS で中身が変わるため、Windows では訳が当たりません。`#10` と書いてください。')
    for path, line, text in platform_breaks:
        print('  %s:%d  %s' % (path, line, text))
    sys.exit(1)

if bad:
    print('番号の付いていない文言が %d 件あります。' % len(bad))
    print('訳す人が引数を並べ替えられません。番号付き（0 から順）にしてください。')
    for path, line, text in bad:
        print('  %s:%d  %s' % (path, line, text))
    sys.exit(1)

print('差し込みが 2 つ以上の文言 %d 件、すべて番号付き。改行も OS に依らない形です' % looked)
PY
