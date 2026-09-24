#!/bin/sh
# 画面に出る日本語が、`resourcestring` の外に書かれていないことを確かめます
# （要件 NFR-7.6）。
#
# **版 2.68 で、画面に出る文言はすべて `resourcestring` に分け終えました。**
# ここから先の劣化は「新しく書いた日本語の literal」です。言語の往復検査
# （`lang_roundtrip_test.sh`）は、試験のときに中身の入っている札しか見ないので、
# 採点の結果や知らせのような**その場で組み立てる文言は見逃します。**ソースを
# 直接見て、`resourcestring` の外にある日本語を名指しで落とします。
#
# **訳さないと決めたものだけを、理由付きで通します**（下の ALLOWED）。
# 足すときは理由を書いてください。理由を書けないものは、訳すべきものです。
#
# Checks that no Japanese meant for the screen is written outside a
# `resourcestring` (requirement NFR-7.6).
#
# **As of version 2.68 every word shown on screen has been separated.** From
# here on, the regression is a newly written Japanese literal. The language
# round trip (`lang_roundtrip_test.sh`) only sees labels that hold something
# during the test, so **words built on the spot -- a score, a message -- slip
# past it.** This reads the source and names any Japanese outside a
# `resourcestring`.
#
# **Only what was decided not to translate passes, each with its reason**
# (ALLOWED below). Adding to it needs a reason; what has none should be
# translated.
set -u
cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob, re, sys

# (ファイル, 手続きまたは定数の名前) -> 理由 / (file, routine or constant) -> reason
ALLOWED = {
    ('app/frmmain.pas', 'TMainForm.ReportLanguage'): '試験の報告（回帰試験が読む） / test report',
    ('app/frmmain.pas', 'TMainForm.CheckTranscriptHeight'): '試験の報告（組み方の検査が出す） / test report (layout check)',
    ('app/layoutcheck.pas', '*'): '試験の報告 / test report',
    ('app/textcheck.pas', '*'): '試験の報告 / test report',
    ('app/uilang.pas', 'UiLangCaption'): '言語名はその言語で書く / a language is named in itself',
    ('src/deepcw.audio.pas', 'CheckStructureLayout'): '命令行の道具だけが出す / CLI only (cw_devices --abi-only)',
    ('src/deepcw.platform.pas', 'MemoryUseCaption'): '命令行の道具だけが出す / CLI only (cw_tune)',
    ('src/deepcw.fist.pas', 'FIST_STANDARD_LEGACY_NAMES'): '古い記録を読む凍結した綴り / frozen spelling of old records',
    ('src/deepcw.fist.pas', 'FIST_KEY_LEGACY_NAMES'): '古い記録を読む凍結した綴り / frozen spelling of old records',
    ('src/deepcw.fist.pas', 'FIST_SCORE_NAMES'): '使われていない（画面に出ない） / unused, never shown',
    ('src/deepcw.practice.pas', 'EXERCISE_LEGACY_NAMES'): '古い記録を読む凍結した綴り / frozen spelling of old records',
}

JAPANESE = re.compile(r'[぀-ヿ一-鿿＀-￯]')

def strip_comments(line, state):
    """{ } と (* *) と // を除きます。複数行の { } は state で持ち越します。
    Removes { }, (* *) and //; a { } spanning lines is carried in state."""
    out = []; i = 0; n = len(line)
    while i < n:
        if state['brace']:
            j = line.find('}', i)
            if j < 0: return ''.join(out)
            state['brace'] = False; i = j + 1; continue
        if state['paren']:
            j = line.find('*)', i)
            if j < 0: return ''.join(out)
            state['paren'] = False; i = j + 2; continue
        c = line[i]
        if c == "'":
            j = i + 1
            while j < n:
                if line[j] == "'" and j + 1 < n and line[j+1] == "'": j += 2; continue
                if line[j] == "'": break
                j += 1
            out.append(line[i:j+1]); i = j + 1; continue
        if c == '{': state['brace'] = True; i += 1; continue
        if line.startswith('(*', i): state['paren'] = True; i += 2; continue
        if line.startswith('//', i): break
        out.append(c); i += 1
    return ''.join(out)

bad = []
looked = 0
for path in sorted(glob.glob('app/*.pas') + glob.glob('src/*.pas')):
    state = {'brace': False, 'paren': False}
    section = None      # 'resourcestring' / 'const' / other
    routine = None
    constant = None
    for n, raw in enumerate(open(path, encoding='utf-8'), 1):
        code = strip_comments(raw.rstrip('\n'), state)
        s = code.strip()
        # 入れ子の手続きは外側の名前で数えます（行頭から始まる見出しだけを取る）。
        # A nested routine counts under the outer one (only headers at column 0).
        m = re.match(r'(procedure|function|constructor|destructor)\s+([\w.]+)', code, re.I)
        if m:
            routine = m.group(2); section = None; constant = None
        low = s.lower()
        if low in ('resourcestring', 'const', 'type', 'var', 'implementation',
                   'interface', 'begin') or low.startswith('uses'):
            section = low if low in ('resourcestring', 'const') else None
            if low == 'implementation': routine = None
            continue
        if section == 'const':
            cm = re.match(r'(\w+)\s*[:=]', s)
            if cm: constant = cm.group(1)
        for lit in re.findall(r"'((?:[^']|'')*)'", code):
            if not JAPANESE.search(lit):
                continue
            looked += 1
            if section == 'resourcestring':
                continue
            name = constant if section == 'const' else routine
            if (path, '*') in ALLOWED or (path, name) in ALLOWED:
                continue
            bad.append((path, n, name, lit))

for path, n, name, lit in bad:
    print('  %s:%d (%s) 「%s」' % (path, n, name, lit[:60]))
print('日本語の literal %d 件を見ました。resourcestring の外で、訳さない理由の無いもの %d 件'
      % (looked, len(bad)))
sys.exit(1 if bad else 0)
PY
