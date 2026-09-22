#!/bin/sh
# `Format` に渡す引数の数が、文言の求める数と合っているかを確かめます
# （要件 NFR-7.6）。
#
# **これは画面が崩れる話ではなく、落ちる話です。**`Format` は、文字列が求める
# 引数より渡された引数が少なければ例外を投げます。しかも**その行が画面に出よう
# とした瞬間まで、何も起きません。**困ったときの案内のように滅多に出ない行ほど、
# 見つかりません。
#
# 文言を `resourcestring` に移すときは、**綴りと呼び出しが別々の場所に離れます。**
# 離れたものは、片方だけ直せます。
#
#   RsErrStatusLine = '%0:s: %1:s';        ← 2 つ求める
#   Format(RsErrStatusLine, [Context])     ← 1 つしか渡していない
#
# 番号付きなら**いちばん大きい番号＋1**、番号が無ければ**個数**が求める数です。
# `%%` は差し込みではありません。
#
# Checks that the number of arguments handed to `Format` matches what the string
# asks for (requirement NFR-7.6).
#
# **This is not about the screen breaking but about the program stopping.**
# `Format` raises when fewer arguments arrive than the string asks for, and
# **nothing happens until the moment that line is due on screen** -- so the
# lines least likely to be seen, such as what is said when something goes wrong,
# are the ones least likely to be found.
#
# Moving words into a `resourcestring` **puts the spelling and the call in
# different places**, and things in different places can be changed one at a
# time.
#
# What is asked for is the **highest index plus one** where indices are used,
# and the **count** where they are not. `%%` is not a placeholder.
set -e
cd "$(dirname "$0")/.."

python3 - "$@" <<'PY'
import io, re, glob, sys

# 註釈のなかは見ません。**註釈は画面に出ません。**
# Comments are not looked at: **they never reach the screen.**
def strip_comments(s):
    out = []; i = 0; n = len(s)
    while i < n:
        c = s[i]
        if c == '{':
            d = 1; i += 1
            while i < n and d > 0:
                if s[i] == '{': d += 1
                elif s[i] == '}': d -= 1
                out.append('\n' if s[i] == '\n' else ' '); i += 1
            continue
        if c == '/' and i + 1 < n and s[i+1] == '/':
            while i < n and s[i] != '\n': out.append(' '); i += 1
            continue
        if c == "'":
            out.append(c); i += 1
            while i < n:
                out.append(s[i])
                if s[i] == "'":
                    if i + 1 < n and s[i+1] == "'": out.append(s[i+1]); i += 2; continue
                    i += 1; break
                i += 1
            continue
        out.append(c); i += 1
    return ''.join(out)

SPEC = re.compile(r'%(?:(\d+):)?-?(?:\*|\d*)(?:\.(?:\*|\d+))?[sdufgxeMmnpSDUFGXEP]')

def needed(text):
    """その文言が求める引数の数。/ How many arguments the string asks for."""
    i = 0; count = 0; highest = -1
    while i < len(text):
        if text[i] == '%':
            if i + 1 < len(text) and text[i+1] == '%':
                i += 2; continue
            m = SPEC.match(text, i)
            if m:
                count += 1
                if m.group(1) is not None:
                    highest = max(highest, int(m.group(1)))
                i = m.end(); continue
        i += 1
    return (highest + 1) if highest >= 0 else count

FILES = sorted(set(glob.glob('app/*.pas') + glob.glob('app/*.lpr') +
                   glob.glob('src/*.pas')))

# `resourcestring` の綴りを集めます。**複数行に分けて書かれたものも畳みます。**
# The spellings, **folded back together when written across lines.**
values = {}
for path in FILES:
    s = strip_comments(io.open(path, encoding='utf-8').read())
    inside = False; buf = ''; name = None
    for line in s.split('\n'):
        t = line.strip()
        if t == 'resourcestring':
            inside = True; continue
        if inside and t in ('implementation', 'begin', 'var', 'type', 'const'):
            inside = False; continue
        if not inside:
            continue
        if not buf:
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$', t)
            if not m: continue
            name = m.group(1); buf = m.group(2)
        else:
            buf += ' ' + t
        if buf.rstrip().endswith(';'):
            lit = ''.join(re.findall(r"'((?:[^']|'')*)'", buf)).replace("''", "'")
            values[name] = lit; buf = ''; name = None

def args_count(src, start):
    """`[` から始まる配列の、最上位のカンマの数＋1。
    入れ子の括弧と、文字列のなかのカンマは数えません。
    Top-level commas plus one: nested brackets and commas inside strings do not
    count."""
    depth = 0; i = start; n = len(src); count = 1; instring = False
    while i < n:
        c = src[i]
        if instring:
            if c == "'":
                if i + 1 < n and src[i+1] == "'": i += 2; continue
                instring = False
            i += 1; continue
        if c == "'": instring = True; i += 1; continue
        if c in '([': depth += 1
        elif c in ')]':
            depth -= 1
            if depth == 0: return count
        elif c == ',' and depth == 1: count += 1
        i += 1
    return None

bad = []; looked = 0
call = re.compile(r'\bFormat\s*\(\s*(Rs[A-Za-z0-9_]*)\s*,\s*\[')
for path in FILES:
    s = strip_comments(io.open(path, encoding='utf-8').read())
    for m in call.finditer(s):
        name = m.group(1)
        if name not in values:
            continue
        want = needed(values[name])
        got = args_count(s, m.end() - 1)
        if got is None:
            continue
        looked += 1
        if got != want:
            bad.append((path, s[:m.start()].count('\n') + 1, name, want, got,
                        values[name][:50]))

if bad:
    print('文言が求める引数の数と、渡している数が違います（%d 件）。' % len(bad))
    print('その行が画面に出ようとした瞬間に Format が例外を投げます。')
    for path, line, name, want, got, text in bad:
        print('  %s:%d  %s  求める %d / 渡す %d  「%s」'
              % (path, line, name, want, got, text))
    sys.exit(1)

print('Format に渡す引数の数 %d 件、すべて文言と合っています' % looked)
PY
