"""送信訓練（FR-H）の測定と採点が成立するかを確かめるための試作。

  実装ではなく、仕様を書く前の検証に用いたもの。付録 A の数値はこのコードで得た。
  不完全さを制御できる CW を合成し、包絡線検波で要素長を取り出して、送出値を
  復元できるかを見る。python3 fist_measure_prototype.py で表が出る。

  Throwaway prototype used to check that the FR-H measurements are possible
  before writing them into the specification -- not the implementation. The
  figures in appendix A come from this code. It synthesises CW with
  controllable imperfection, recovers element lengths with an envelope
  detector, and reports how well the sent values come back."""
import numpy as np, math

MORSE={'A':'.-','B':'-...','C':'-.-.','D':'-..','E':'.','F':'..-.','G':'--.','H':'....',
'I':'..','J':'.---','K':'-.-','L':'.-..','M':'--','N':'-.','O':'---','P':'.--.','Q':'--.-',
'R':'.-.','S':'...','T':'-','U':'..-','V':'...-','W':'.--','X':'-..-','Y':'-.--','Z':'--..',
'0':'-----','1':'.----','2':'..---','3':'...--','4':'....-','5':'.....','6':'-....',
'7':'--...','8':'---..','9':'----.','/':'-..-.','?':'..--..','.':'.-.-.-',',':'--..--'}

def synth(text, wpm=20, dah=3.0, intra=1.0, inter=3.0, word=7.0,
          jitter=0.03, drift=0.0, tone=700, fs=8000, noise=0.01, seed=0):
    """不完全さを制御できる CW 合成。jitter は各要素長の相対 SD。
    CW synthesis with controllable imperfection; jitter is the relative SD per element."""
    rng = np.random.RandomState(seed)
    dit0 = 1.2 / wpm
    segs = [(False, 0.5)]
    n_elem = 0
    total_elems = sum(len(MORSE[c]) for c in text if c != ' ')
    for wi, w in enumerate(text.split(' ')):
        if wi: segs.append((False, word))
        for ci, ch in enumerate(w):
            if ci: segs.append((False, inter))
            for ei, e in enumerate(MORSE[ch]):
                if ei: segs.append((False, intra))
                segs.append((True, 1.0 if e == '.' else dah))
    segs.append((False, 0.5))

    out_segs = []
    for i, (on, units) in enumerate(segs):
        if isinstance(units, float) and units in (0.5,) and (i == 0 or i == len(segs)-1):
            out_segs.append((on, units)); continue
        # 速度ドリフト: セッション中に dit 長が drift 割合だけ変化する
        prog = n_elem / max(1, total_elems)
        dit = dit0 * (1.0 + drift * (prog - 0.5))
        d = units * dit * (1.0 + rng.randn() * jitter)
        out_segs.append((on, max(d, 0.005)))
        if on: n_elem += 1

    n = int(sum(d for _, d in out_segs) * fs)
    env = np.zeros(n); pos = 0
    for on, d in out_segs:
        c = int(round(d * fs))
        if on: env[pos:pos+c] = 1.0
        pos = min(pos + c, n)
    r = int(0.004 * fs)
    env = np.convolve(env, np.ones(r)/r, mode='same')
    t = np.arange(n) / fs
    sig = 0.5 * env * np.sin(2*math.pi*tone*t)
    if noise: sig += rng.normal(0, noise, n)
    return np.clip(sig, -1, 1).astype(np.float32), fs

def envelope(audio, fs, tone, bw=200.0, smooth_ms=3.0):
    """帯域通過 → 整流 → 平滑。モデルの STFT(15ms) ではなく専用検波を使う。
    Bandpass, rectify, smooth -- a dedicated detector, not the model's 15 ms STFT."""
    q = tone / bw
    w0 = 2*math.pi*tone/fs; alpha = math.sin(w0)/(2*q)
    b0, b1, b2 = alpha, 0.0, -alpha
    a0, a1, a2 = 1+alpha, -2*math.cos(w0), 1-alpha
    b = np.array([b0,b1,b2])/a0; a = np.array([a1,a2])/a0
    x = audio.astype(np.float64)
    for _ in range(2):
        y = np.zeros_like(x); x1=x2=y1=y2=0.0
        for i in range(len(x)):
            y0 = b[0]*x[i] + b[1]*x1 + b[2]*x2 - a[0]*y1 - a[1]*y2
            y[i] = y0; x2, x1 = x1, x[i]; y2, y1 = y1, y0
        x = y
    e = np.abs(x)
    k = max(1, int(smooth_ms/1000*fs))
    return np.convolve(e, np.ones(k)/k, mode='same')

def extract_runs(env, fs):
    """ヒステリシス付きのしきい値で mark/space の連続長を取り出す。
    Extract mark/space run lengths with a hysteresis threshold."""
    hi = np.percentile(env, 95); lo = np.percentile(env, 20)
    t_hi = lo + 0.55*(hi-lo); t_lo = lo + 0.35*(hi-lo)
    state = env[0] > t_hi
    runs = []; start = 0
    for i in range(1, len(env)):
        if state and env[i] < t_lo:
            runs.append((True, (i-start)/fs)); state=False; start=i
        elif (not state) and env[i] > t_hi:
            runs.append((False, (i-start)/fs)); state=True; start=i
    runs.append((state, (len(env)-start)/fs))
    return runs[1:-1]   # 先頭・末尾の無音を捨てる

def analyse(runs):
    marks = np.array([d for on,d in runs if on])
    gaps  = np.array([d for on,d in runs if not on])
    if len(marks) < 8: return None
    # dit 長 = 短い側のマークの中央値（2 クラスタの素朴な分離）
    thr = (marks.min()*marks.max())**0.5
    dits = marks[marks < thr]; dahs = marks[marks >= thr]
    if len(dits) < 3 or len(dahs) < 3: return None
    dit = float(np.median(dits))
    intra = gaps[gaps < 2*dit]
    inter = gaps[(gaps >= 2*dit) & (gaps < 5*dit)]
    wordg = gaps[gaps >= 5*dit]
    def cv(a): return float(np.std(a)/np.mean(a)) if len(a) > 1 else float('nan')
    def sep(a, b):
        if len(a)<2 or len(b)<2: return float('nan')
        return float((np.mean(b)-np.mean(a))/(np.std(a)+np.std(b)+1e-9))
    return dict(
        wpm = 1.2/dit,
        dit_cv = cv(dits), dah_cv = cv(dahs),
        dah_ratio = float(np.mean(dahs)/dit),
        intra_ratio = float(np.mean(intra)/dit) if len(intra) else float('nan'),
        inter_ratio = float(np.mean(inter)/dit) if len(inter) else float('nan'),
        word_ratio  = float(np.mean(wordg)/dit) if len(wordg) else float('nan'),
        inter_cv = cv(inter),
        mark_sep = sep(dits, dahs),
        gap_sep  = sep(intra, inter),
        n_marks = len(marks),
    )

TEXT = "CQ CQ DE JA1ABC JA1ABC K TNX FER CALL UR RST 599 NAME TARO QTH TOKYO"
cases = [
 ("熟練 (jitter 3%)",        dict(jitter=0.03)),
 ("中級 (jitter 12%)",       dict(jitter=0.12)),
 ("初級 (jitter 25%, 比 2.4, 文字間 2.2)", dict(jitter=0.25, dah=2.4, inter=2.2)),
 ("バグキー風 (比 2.6, 長点ばらつき)", dict(jitter=0.05, dah=2.6, dah_jitter=True)),
 ("速度ドリフト 25%",        dict(jitter=0.05, drift=0.25)),
 ("ファンズワース (文字間 6)", dict(jitter=0.04, inter=6.0, word=12.0)),
]
print(f"{'ケース':<38} {'WPM':>5} {'dit CV':>7} {'dah比':>6} {'符号内':>6} {'文字間':>6} {'語間':>6} {'短長分離':>8} {'区切分離':>8}")
print("-"*104)
for name, kw in cases:
    kw = dict(kw); kw.pop('dah_jitter', None)
    a, fs = synth(TEXT, wpm=20, tone=700, seed=1, **kw)
    r = analyse(extract_runs(envelope(a, fs, 700), fs))
    if not r: print(f"{name:<38} 解析できず"); continue
    print(f"{name:<38} {r['wpm']:5.1f} {r['dit_cv']:7.3f} {r['dah_ratio']:6.2f} "
          f"{r['intra_ratio']:6.2f} {r['inter_ratio']:6.2f} {r['word_ratio']:6.2f} "
          f"{r['mark_sep']:8.2f} {r['gap_sep']:8.2f}")

# ---------------------------------------------------------------
# 課題文が既知なら、各要素を種別に確実に対応づけられるはず。
# With the prescribed text known, every element should be attributable.
def expected_sequence(text):
    """(種別) の列を返す。dit/dah/intra/inter/word。"""
    seq=[]
    for wi,w in enumerate(text.split(' ')):
        if wi: seq.append('word')
        for ci,ch in enumerate(w):
            if ci: seq.append('inter')
            for ei,e in enumerate(MORSE[ch]):
                if ei: seq.append('intra')
                seq.append('dit' if e=='.' else 'dah')
    return seq

def analyse_known(runs, text):
    """課題文の既知列と測定列を突き合わせて種別を決める。
    Attribute each measured element using the known prescribed text."""
    seq = expected_sequence(text)
    meas = [(on,d) for on,d in runs]
    exp_on = [t in ('dit','dah') for t in seq]
    if len(meas) != len(seq):
        return None, f"要素数が一致しません 測定{len(meas)} / 期待{len(seq)}"
    if [on for on,_ in meas] != exp_on:
        return None, "マーク/スペースの並びが一致しません"
    by = {}
    for (on,d),t in zip(meas, seq):
        by.setdefault(t, []).append(d)
    dit = float(np.median(by['dit']))
    def cv(k):
        a=np.array(by.get(k,[]));
        return float(np.std(a)/np.mean(a)) if len(a)>1 else float('nan')
    def ratio(k):
        a=np.array(by.get(k,[]));
        return float(np.mean(a)/dit) if len(a) else float('nan')
    def sep(k1,k2):
        a=np.array(by.get(k1,[])); b=np.array(by.get(k2,[]))
        if len(a)<2 or len(b)<2: return float('nan')
        return float((np.mean(b)-np.mean(a))/(np.std(a)+np.std(b)+1e-9))
    return dict(wpm=1.2/dit, dit_cv=cv('dit'), dah_cv=cv('dah'),
                dah_ratio=ratio('dah'), intra_ratio=ratio('intra'),
                inter_ratio=ratio('inter'), word_ratio=ratio('word'),
                inter_cv=cv('inter'),
                mark_sep=sep('dit','dah'), gap_sep=sep('intra','inter')), None

print()
print("=== 課題文が既知の場合（種別を確実に対応づけ） ===")
print(f"{'ケース':<38} {'WPM':>5} {'dit CV':>7} {'dah比':>6} {'符号内':>6} {'文字間':>6} {'語間':>6} {'短長分離':>8} {'区切分離':>8}")
print("-"*104)
for name, kw in cases:
    kw=dict(kw); kw.pop('dah_jitter',None)
    a,fs = synth(TEXT, wpm=20, tone=700, seed=1, **kw)
    r,err = analyse_known(extract_runs(envelope(a,fs,700),fs), TEXT)
    if err: print(f"{name:<38} {err}"); continue
    print(f"{name:<38} {r['wpm']:5.1f} {r['dit_cv']:7.3f} {r['dah_ratio']:6.2f} "
          f"{r['intra_ratio']:6.2f} {r['inter_ratio']:6.2f} {r['word_ratio']:6.2f} "
          f"{r['mark_sep']:8.2f} {r['gap_sep']:8.2f}")
print()
print("送出した値: 初級 = dah 2.4 / 文字間 2.2、ファンズワース = 文字間 6.0 / 語間 12.0")
