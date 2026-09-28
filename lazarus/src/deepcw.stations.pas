unit DeepCW.Stations;

{ 帯域の中にいる局を見つけ、局ごとに「隣を絵から追い出す幅」を決めます。

  多局同時受信（要件 FR-I）の土台です。上に載る処理――局ごとの切り出し、復号、
  局数の制限、画面――は、すべてここが出す音程と幅を前提にします。**ここが
  間違っていると、上のどの層で症状が出ても原因はここに戻ってきます。**そのため
  この層だけで完結して測れるように、純粋な関数と、時間をまたぐ状態を持つ追跡器を
  分けてあります。

  見つけ方の要点は 3 つです。

  1. **時間方向は平均ではなく上位分位で見ます。**符号は断続するので、平均を取ると
     鍵を押している間の大きさが休みで薄まります。上位分位なら、休みが長い局でも
     鍵を押している間の大きさがそのまま出ます。
  2. **雑音面は帯域全体ではなく近傍で測ります。**受信機の濾波器は帯域に傾斜を
     持つので、1 つのしきい値では山の側で採り過ぎ、裾の側で採り逃します。
  3. **近すぎる 2 つの山は 1 局と見なします。**付録 G.2 で分離を確かめてあるのは
     100 Hz 間隔までです。測っていない間隔の局を「2 局」と称しません。

  Finds the stations present in the passband and decides, for each, the width
  that keeps its neighbours out of the picture.

  This is the foundation of multi-station reception (requirement FR-I).
  Everything above it — slicing per station, decoding, limiting how many are
  analysed, the display — takes the pitches and widths from here. **A fault here
  surfaces in whichever layer above happens to show it, and the search leads
  back to this one.** So it is built to be measurable on its own: pure functions
  apart from the tracker that carries state across rounds.

  Three things matter in how a station is found.

  1. **Along time, an upper quantile rather than a mean.** Keying is
     intermittent, so a mean dilutes the key-down level with the gaps. An upper
     quantile reports the key-down level even for a station with long gaps.
  2. **The noise floor is measured locally, not across the whole band.** A
     receiver's filter slopes, so a single threshold over-detects at the top of
     the slope and under-detects at its skirts.
  3. **Two peaks too close together count as one station.** Appendix G.2
     establishes separation down to 100 Hz spacing and no closer; stations
     nearer than that are not claimed to be two. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, DeepCW.Types;

const
  { 探す範囲。運用者に見えているウォーターフォール（0〜3000 Hz）とおおむね揃え、
    低い側は電源ハム、高い側は実運用でまず使われない範囲を外しています。
    能力の限界ではなく、探す範囲です。

    The range searched, roughly matching the waterfall the operator sees
    (0-3000 Hz), with mains hum excluded at the bottom and, at the top, a range
    CW is not sent in. It is where the search looks, not a limit of what could
    be read. }
  DETECT_LOW_HZ = 200.0;
  DETECT_HIGH_HZ = 2900.0;

  { これより近い 2 つの山は 1 局と見なします。付録 G.2 が分離を確かめたのは
    100 Hz 間隔までで、それより近い間隔は測っていません。**測っていないものを
    「2 局です」と称しないための線です。**

    Two peaks closer than this count as one station. Appendix G.2 establishes
    separation at 100 Hz spacing and no closer. **This is the line that keeps
    the detector from claiming two stations where nothing was measured.** }
  DETECT_MIN_SEPARATION_HZ = 100.0;

  { 局と認めるための、近傍の雑音面からの高さ。

    測って決めました。同じ音声で、検出の高さと復号の誤り率を並べると:
    12.7 dB で誤り率 0.00、9.6 dB で 0.04、6.6 dB で 0.25、それ以下はモデルが
    読めません。**すなわち 6 dB は、モデルが文字を出せなくなるところと一致します。**
    これより上げると読める局を取り逃し、下げても読めない局に解析を割くだけです。
    弱い局の扱いは、検出ではなく局数の制限（要件 FR-I.7）の仕事です。

    How far above the local noise floor a peak must be to count as a station.

    Fixed by measurement. On the same audio, the detected level against the
    decode error rate runs: 0.00 at 12.7 dB, 0.04 at 9.6 dB, 0.25 at 6.6 dB, and
    nothing readable below. **Six decibels is therefore where the model stops
    producing text.** Raising it would lose stations that still read; lowering it
    would only spend analysis on stations that cannot. What to do about weak
    stations belongs to the limit on how many are analysed (requirement FR-I.7),
    not to detection. }
  DETECT_MIN_LEVEL_DB = 6.0;

  { 時間方向にどの分位を取るか。1.0 に近いほど、休みの長い局にも反応しますが、
    雑音の突発にも反応します（付録 N.1）。
    Which quantile to take along time. Closer to 1.0 responds to stations with
    longer gaps, and also to bursts of noise (appendix N.1). }
  DETECT_TIME_QUANTILE = 0.90;

  { 雑音面をどの分位で測るか、どれだけの幅で測るか。帯域の半分が局で埋まっても
    雑音のままでいられるよう、中央値より下を取ります。
    Which quantile estimates the noise floor and over what width. It sits below
    the median so that it still reads noise when half the band is occupied. }
  DETECT_FLOOR_QUANTILE = 0.25;
  DETECT_FLOOR_WINDOW_HZ = 200.0;

  { **キークリックを局と見なさない**ための決めごと（付録 BZ）。

    強い局の打鍵の切り替え（立ち上がり・立ち下がり）は、窓（80 ms）が切り替えを
    またぐコマで、±175・±375 Hz などに側波を作ります。局が強い（近傍の雑音面から
    37 dB 前後）と、この側波がしきい値を超えて**実在しない局**として見つかり、
    「E5I SIE5…」のような点ばかりの文字を読みました（実画面で確かめた）。

    側波は**切り替えのコマにしか無い**ので、強い局が落ち着いているコマ（前後
    `DETECT_CLICK_STEADY_FRAMES` コマのあいだ、ずっと押しているか、ずっと離して
    いる）だけで測り直すと消えます（実測で 7〜37 dB 下がる）。本物の別の局は
    打鍵が独立しているので、そのコマでも鳴っています（実測で 0.0 dB）。

    - `DETECT_CLICK_GAP_DB`: 測り直すのは、これ以上強い局があるときだけ。
      同じ強さの局どうしには何もしない（側波は元の局より 10 dB 近く以上弱い。
      強い局が 2 つあると 9.9 dB の側波があったので 6 dB とした）
    - `DETECT_CLICK_STEADY_FRAMES`: 前後何コマ落ち着いていれば「落ち着いた」か。
      3 コマ（±45 ms）で窓の半分（40 ms）を覆う
    - `DETECT_CLICK_ON_RATIO`・`DETECT_CLICK_OFF_RATIO`: 押している・離している
      と見なす大きさ（強い局の上位分位に対する比）
    - `DETECT_CLICK_MIN_FRAMES`: 落ち着いたコマがこれより少なければ判じない
      （知らないことを根拠に局を消さない）

    **Key clicks are not stations** (appendix BZ). A strong station's keying
    edges put sidebands at +/-175, +/-375 Hz and so on in every frame whose
    window (80 ms) straddles an edge. With a strong station (about 37 dB over
    the local floor) they cleared the threshold and were found as **stations
    that did not exist**, reading dots-only text such as "E5I SIE5..." (seen on
    screen). The sidebands exist **only in frames holding an edge**, so
    re-measured over the frames where the strong station is steady (key held
    down, or held up, for `DETECT_CLICK_STEADY_FRAMES` frames either side) they
    vanish (7 to 37 dB lower, measured), while a real station, keyed
    independently, is still there (0.0 dB). Re-measuring happens only below a
    station at least `DETECT_CLICK_GAP_DB` stronger (the sidebands were 16 dB
    or more below their source, 9.9 dB with two strong stations, hence 6 dB),
    so stations of equal strength are left alone; three frames (+/-45 ms) cover half the window (40 ms); the on and
    off ratios are against the strong station's upper quantile; and with fewer
    than `DETECT_CLICK_MIN_FRAMES` steady frames nothing is judged (not knowing
    is no reason to remove a station). }
  DETECT_CLICK_GAP_DB = 6.0;
  { 落ち着いたコマで測り直すときの分位。**本物の局は、落ち着いたコマの一部で
    鳴っていれば足り、キークリックは一度も鳴らない**ので、上のほうを取ります。
    0.90 では、短い文の弱い局（強い局が送り続けるあいだに送り終える）が消えた
    （実測、付録 BZ.3）。
    The quantile for re-measuring on the steady frames. **A real station need
    only sound in some of them, and a key click never does**, so it sits high:
    at 0.90 a weak station with a short message (finished while the strong ones
    kept sending) was removed (measured, appendix BZ.3). }
  DETECT_CLICK_QUANTILE = 0.98;
  DETECT_CLICK_STEADY_FRAMES = 3;
  DETECT_CLICK_ON_RATIO = 0.5;
  DETECT_CLICK_OFF_RATIO = 0.05;
  DETECT_CLICK_MIN_FRAMES = 20;

  { 局ごとの絵から隣の強い局のキークリックを除く決めごと（付録 CB、
    `SuppressNeighbourClicks`）。どれも実測で決めた。
    The settings for removing a strong neighbour's clicks from one station's
    picture (appendix CB, `SuppressNeighbourClicks`), all set by measurement. }
  NEIGHBOUR_STRONGER_RATIO = 2.0;
  NEIGHBOUR_PRESENT_LEVEL = 0.25;
  NEIGHBOUR_PEAK_RATIO = 2.0;
  NEIGHBOUR_GUARD_FRAMES = 6;
  NEIGHBOUR_VISIBLE_RATIO = 6.0;
  { `NEIGHBOUR_VISIBLE_RATIO` は、ビンの 25% 分位に対する倍率。25% 分位を基準に
    するのは、**キークリックが半分以上のコマに出るビンでは中央値がクリックの
    高さに持ち上がる**ため（中央値を基準にすると、直せていた場面を取りこぼした）。
    6 倍は、雑音だけなら中央値（25% 分位の約 1.55 倍）の約 4 倍に当たり、雑音が
    超える見込みは 1 ビンあたり 10 万分の 1.5 程度。4 倍では 1% を超え、残す幅の
    21 ビンのどれかが超えるコマが 2 割あり、**雑音だけのコマまで置き換えて**読みを
    崩した（実測、付録 CB.3）。置き換える値も 25% 分位。
    `NEIGHBOUR_VISIBLE_RATIO` is against each bin's 25% quantile. The 25% quantile
    because **in a bin where clicks fill more than half the frames the median is
    raised to click level** (against the median, cases that had been fixed were
    missed). Six times is about four times the noise median (some 1.55 times
    the 25% quantile), exceeded by noise in about 1.5 bins in a hundred thousand;
    at four times it was over 1%, a fifth of frames had some bin of the 21 kept
    above it, and **frames of noise alone were replaced**, spoiling the reading
    (measured, appendix CB.3). The value replaced in is the 25% quantile too. }

  { 残す幅の上限と下限。上限は 1 局のみを聴くときの帯域（TUNER_BANDWIDTH の
    自動）と同じ値で、局が 1 つだけのときに単局受信と同じ挙動になります。
    下限は付録 G.2 の測定下限で、これより狭めると速い符号の鍵操作側波帯
    （40 WPM で約 ±33 Hz）を削り始めます。

    The bounds on the width kept. The upper bound equals the bandwidth used when
    listening to one station, so a lone station behaves exactly as single-station
    reception does. The lower bound is appendix G.2's measured limit; narrower
    starts cutting the keying sidebands of fast sending (about +/-33 Hz at
    40 WPM). }
  DETECT_MAX_HALF_WIDTH_HZ = 250.0;
  DETECT_MIN_HALF_WIDTH_HZ = 50.0;

  { 前の回に見つけた局と同じものと見なす範囲。ビン幅 12.5 Hz の 2 つ分です。
    How far a peak may move and still be the same station: two bins of 12.5 Hz. }
  DETECT_MATCH_TOLERANCE_HZ = 25.0;

  { 何回続けて見えたら局と認め、何回続けて消えたら忘れるか。認めるのを 1 回に
    すると雑音の突発が局になり、忘れるのを 1 回にすると語間の休みで局が消えます。

    How many consecutive rounds confirm a station and how many drop it.
    Confirming on one round would make a burst of noise a station; dropping on
    one would lose a station across the gap between words. }
  DETECT_CONFIRM_ROUNDS = 2;
  DETECT_DROP_ROUNDS = 3;

type
  { 見つかった 1 局。/ One station that was found. }
  TStation = record
    { 音程（Hz）。広帯域スペクトログラムのビンの中心なので、12.5 Hz 刻みです。
      The pitch in hertz. It is a bin centre of the wide spectrogram, so it falls
      on the same 12.5 Hz grid the tuner uses. }
    Hz: Double;
    { 近傍の雑音面からの高さ（dB）。局数を絞るとき（要件 FR-I.7）の順序になります。
      Height above the local noise floor in decibels, which is the order in which
      stations are kept when their number must be cut (requirement FR-I.7). }
    LevelDb: Double;
    { 絵に残す片側の幅（Hz）。いちばん近い隣までの距離のおよそ半分です。
      The half width kept in the picture, about half the distance to the nearest
      neighbour. }
    HalfWidthHz: Double;
    { この山の近傍に畳み込まれた、別の峰の数。0 なら 1 局だけです。

      検出は 100 Hz より近い山を 1 つに畳みます（付録 G.2 の測定下限）。畳んだ
      という事実をここで残さないと、**上の層からは「1 局」と見分けが付きません。**
      パイルアップのように密集した範囲を「密集している」と示すには（要件 FR-J.6）、
      畳んだことを知っている必要があります。読めていない文字列を並べるより、
      「ここに大勢いる」と正しく伝えるほうが役に立ちます。

      How many other peaks were folded into this one; zero means a single
      station.

      Detection folds peaks closer than 100 Hz — the limit measured in appendix
      G.2 — into one. Unless the fact is recorded here, **the layers above cannot
      tell that from a single station.** Showing a crowded stretch as crowded
      (requirement FR-J.6) requires knowing that folding happened. Saying "there
      are many here" is more use than listing strings that were not read. }
    Crowded: Integer;
  end;
  TStations = array of TStation;

{ 広帯域スペクトログラムから局を見つけます。音程の昇順で返します。

  昇順で返すのは、隣との距離を求めるのがこの順でしか成り立たないからです。
  強い順が要る場合（要件 FR-I.7）は、受け取った側で並べ替えてください。

  Finds the stations in a wide spectrogram, returned in ascending pitch order,
  because the distance to a neighbour is only defined in that order. Sort a copy
  where descending level is wanted (requirement FR-I.7). }
function DetectStations(const Wide: TSpectrogram; WideRate: Integer): TStations;

{ 局ごとに切り出した絵から、**隣の強い局のキークリックだけのコマ**を、その局の
  ふだんの雑音の高さに置き換えます（付録 CB）。置き換えたコマの数を返します。

  弱い局が送り終えたあと（や長い休みのあいだ）、その局の帯に入った強い局の
  キークリックを、モデルは点（E・I・S・H）として読みました（実測、「CQ DE K1ABC
  K1ABC KS S HE SSEISIEHISE」）。**弱い局が送っている間は、クリックがあっても
  正しく読めた**ので、次のすべてに当たるコマだけを置き換えます。

  - **その局の音が近くに無い**: 中心のビンがその局の上位分位の 1/4 以上で、かつ
    両脇（±4〜8 ビン）の平均の `NEIGHBOUR_PEAK_RATIO` 倍以上なら「音がある」
    （トーンは中心に尖り、クリックは平ら）。音があるコマの前後
    `NEIGHBOUR_GUARD_FRAMES` コマは触らない
  - **より強い隣の局が切り替えの最中**: 上位分位が `NEIGHBOUR_STRONGER_RATIO` 倍
    以上の局が、前後 3 コマのあいだ押しっぱなしでも離しっぱなしでもない
  - **何かが見えている**: 残す幅（`HalfWidthHz`）のどこかのビンが、そのビンの
    ふだんの雑音（25% 分位）の `NEIGHBOUR_VISIBLE_RATIO` 倍以上。雑音に埋もれた
    クリックは害が無いので触らない

  **変えるのは復号器へ渡す写し**（`Slice`）だけで、`Wide`（ウォーターフォール・
  聴き直しの元）は変えません（Raw Observation を残す）。隣に強い局がいなければ
  何もしません。

  `Stations` は、いま見えているすべての局の音程（Hz）、`Own` はそのうちこの絵の
  局の番号です。

  Replaces, in the picture sliced for one station, **the frames holding nothing
  but a strong neighbour's key clicks** with that station's usual noise level
  (appendix CB); returns how many frames were replaced.

  After a weak station stopped (or in its long pauses), the model read the key
  clicks of a strong station that reached its band as dots (E, I, S, H) --
  "CQ DE K1ABC K1ABC KS S HE SSEISIEHISE", measured. **While the weak station
  was sending it read correctly despite the clicks**, so only frames meeting
  all of the following are replaced: **no tone of its own nearby** (the centre
  bin at least a quarter of the station's upper quantile and at least
  `NEIGHBOUR_PEAK_RATIO` times the mean of the bins 4-8 away -- a tone is
  peaked, a click is flat -- with `NEIGHBOUR_GUARD_FRAMES` frames either side
  of such a frame left alone); **a stronger neighbour in mid-edge** (a station
  at least `NEIGHBOUR_STRONGER_RATIO` times stronger in upper quantile, neither
  held down nor held up over the three frames either side); and **something
  visible** (some bin within `HalfWidthHz` at least `NEIGHBOUR_VISIBLE_RATIO`
  times its usual noise, the 25% quantile -- clicks buried in noise do no
  harm). **Only the copy for the decoder** (`Slice`) changes; `Wide`, the
  source of the waterfall and replay, does not (the raw observation stays).
  With no strong neighbour nothing is done. `Stations` holds the pitch (Hz) of
  every station now present and `Own` the index of this picture's station. }
function SuppressNeighbourClicks(var Slice: TSpectrogram;
  const Wide: TSpectrogram; WideRate: Integer; const Stations: array of Double;
  Own: Integer; HalfWidthHz: Double): Integer;

type
  { `SuppressNeighbourClicks` が見る列（コマごとの振幅、窓 80 ms・15 ms おき）。
    `Own` はその局の音程、`Side` はその両脇 ±4〜8 ビン（±50〜100 Hz）の平均、
    `Neighbours` は隣の局それぞれの音程。どれも同じコマ数で、絵（`Slice`）の
    コマと時刻が揃っていること。
    The columns `SuppressNeighbourClicks` looks at (magnitude per frame, 80 ms
    window every 15 ms): `Own` at the station's pitch, `Side` the mean of the
    bins 4-8 either side (+/-50-100 Hz), `Neighbours` one per neighbour. All
    have the same number of frames, lined up in time with the picture
    (`Slice`). }
  TClickColumns = record
    Own: TDoubleArray;
    Side: TDoubleArray;
    Neighbours: array of TDoubleArray;
  end;

{ `SuppressNeighbourClicks` の中身を、列で受け取る形です。交信モード（1 局を
  聴く）は広い絵を作らないので、列を音から直に求めて渡します（付録 CI）。
  `BinHz` は `Slice` の 1 ビンの幅。
  The body of `SuppressNeighbourClicks`, taking the columns: contact mode
  (listening to one station) builds no wide picture, so it works the columns
  out from the audio directly and passes them (appendix CI). `BinHz` is the
  width of one bin of `Slice`. }
function SuppressClicksFromColumns(var Slice: TSpectrogram;
  const Columns: TClickColumns; HalfWidthHz, BinHz: Double): Integer;

const
  { 交信モードで「その局の音」のビンを探す幅（同調点の両側のビン数、1 ビン
    12.5 Hz。±50 Hz は信号追跡の探す幅 `TUNER_TRACK_WINDOW_HZ` と同じ）。
    利用者が合わせた点は局の音程からずれうるので、窓ごとに、この中で最も
    尖り続けるビンを選びます（同調点を優先。付録 CI.2）。
    How many bins either side of the tuned pitch contact mode searches for the
    station's tone (12.5 Hz a bin; +/-50 Hz, the tracking search
    `TUNER_TRACK_WINDOW_HZ`). The pitch the operator set can be off the
    station's, so per window the bin that stays most peaked in this range is
    chosen (the tuned one preferred; appendix CI.2). }
  CLICK_OWN_SPAN_BINS = 4;
  { これより近い隣の局は、クリックの置き換えに使いません。強い局の定常の漏れ
    （窓の側波）が両脇のビン（±50〜100 Hz）に届き、その局の音があっても
    「音が無い」と判じて、その局の符号を消したため（150 Hz 横で 0.00 → 0.11、
    付録 CI.2）。
    Neighbours nearer than this are not used for click replacement: a strong
    station's steady leakage (window sidelobes) reaches the side bins
    (+/-50-100 Hz), so the station's own tone was judged absent and its code
    was erased (0.00 -> 0.11 at 150 Hz, appendix CI.2). }
  CLICK_MIN_NEIGHBOUR_HZ = 200.0;

type
  { 交信モードの `TClickColumns` を、音から直に、1 コマ 1 度だけ求めて控える
    ものです（付録 CI）。

    多局受信は帯域全体の絵を作るので列はそこから取れますが、交信モードの解析は
    同調した音だけを整形するので、その絵がありません。解析のたびに未確定の音
    （2〜24 秒）全体の列を求め直すと 1 回 100 ms を超えるため、**コマを受信の
    始めからの時刻で控え、新しく届いた音のコマだけを求めます**。窓（80 ms）が
    音の端に近いコマは、あとで音が届くと値が変わるので控えません。

    列は、窓 80 ms（ハン窓）・15 ms おきの、同調点・両脇・隣の局の音程それぞれ
    1 本ずつの DFT です（モデルの絵と同じ窓と刻み。周波数は任意）。交信モードは
    帯域制限の前の、モデルの周波数の音（`PrepareForModelWidth` の
    `Unfiltered`）を渡します（録音周波数によらず安い）。**解析のスレッドだけ
    から使います**（排他を持ちません）。

    Works out contact mode's `TClickColumns` from the audio directly, each frame
    once, and keeps them (appendix CI). Multi-station reception builds a
    picture of the whole band to take the columns from; contact mode prepares
    only the tuned audio and has none. Working the columns out again over all
    the pending audio (2-24 s) at every analysis costs over 100 ms, so **frames
    are kept by their time since reception began and only frames of newly
    arrived audio are computed**. A frame whose window (80 ms) comes near either
    end of the audio is not kept, its value changing once more audio arrives.
    Each column is a single-frequency DFT (Hann window of 80 ms every 15 ms --
    the model picture's window and step -- at any frequency) at the tuned
    pitch, its sides and each neighbour. Contact mode passes the audio before
    the band limit, at the model's rate (`Unfiltered` of
    `PrepareForModelWidth`), which is cheap whatever the capture rate. **Used
    from the analysis thread only** (no lock). }
  TClickColumnCache = class
  private
    FRate: Integer;
    FTuneHz: Double;
    FNeighbourHz: TDoubleArray;
    FWindow: Integer;
    { 確かめる周波数ごとの、窓を掛けた余弦・正弦。並びは、同調点から
      ±(CLICK_OWN_SPAN_BINS + 8) ビンの連続した並び（`FBandProbes` 本）の
      あとに隣の局。
      The windowed cosine and sine per probed frequency: a run of bins
      +/-(CLICK_OWN_SPAN_BINS + 8) around the tuned pitch (`FBandProbes` of
      them), then the neighbours. }
    FCos, FSin: array of TDoubleArray;
    FBandProbes: Integer;
    { 控えたコマ。`FFirst` が先頭のコマの番号（受信の始めから 15 ms おき）、
      `FCount` が数。`FBand` はコマごとに `FBandProbes` 個の値を並べたもの。
      The frames kept: `FFirst` is the number of the first (15 ms steps from
      the start of reception), `FCount` how many. `FBand` holds
      `FBandProbes` values per frame. }
    FFirst: Int64;
    FCount: Integer;
    FBand: TDoubleArray;
    FNeighbours: array of TDoubleArray;
    FNeighboursStale: Boolean;
    FComputed: Int64;
    FOwnBin: Integer;
    procedure BuildProbes(First, Last: Integer);
    function LeftOf(Frame: Int64; AudioStart: Double): Int64;
    procedure Probe(const Audio: TSingleArray; AudioStart: Double; Frame: Int64;
      First, Last: Integer; var Values: TDoubleArray);
    function FrameInside(Frame: Int64; AudioStart: Double;
      Length_: Integer): Boolean;
    procedure Store(Frame: Int64; const Values: TDoubleArray);
    procedure Trim(AudioStart: Double);
  public
    { 条件を合わせます。周波数か同調点が変われば控えを捨て、隣の局だけが
      変われば、隣の局の列だけを次に求め直します。同調点から
      `CLICK_MIN_NEIGHBOUR_HZ` より近い隣の局は使いません。
      Sets the conditions. A new rate or tuned pitch drops everything kept; new
      neighbours alone have only their columns worked out again at the next
      request. Neighbours nearer the tuned pitch than
      `CLICK_MIN_NEIGHBOUR_HZ` are not used. }
    procedure Configure(Rate: Integer; TuneHz: Double;
      const Neighbours: array of Double);
    procedure Clear;
    { `Audio` は、受信を始めてから `AudioStart` 秒目から始まる音（`Configure`
      で渡した周波数）。その `StartSeconds` 秒目から始まる `Frames` コマの列を
      返します。隣の局が無ければ `Neighbours` は空です。
      `Audio` starts `AudioStart` seconds after reception began (at the rate
      given to `Configure`). Returns the columns of `Frames` frames from
      `StartSeconds` into it; with no neighbours, `Neighbours` is empty. }
    function Columns(const Audio: TSingleArray; AudioStart: Double;
      StartSeconds: Double; Frames: Integer): TClickColumns;
    function HasNeighbours: Boolean;
    { 求めたコマの延べ数（試験と測りのため）。/ Frames computed so far, for
      tests and measurement. }
    property Computed: Int64 read FComputed;
    property Kept: Integer read FCount;
    { 直近の `Columns` が局の音としたビン（同調点からのビン数）。
      The bin the last `Columns` took as the station's tone (bins from the
      tuned pitch). }
    property OwnBin: Integer read FOwnBin;
  end;

{ 局ごとに、いちばん近い隣までの距離から残す幅を決めます（要件 FR-I.3）。

  **渡す一覧には、解析する局だけでなく、そこにいる局をすべて入れてください。**
  解析しないと決めた局も電波は出しており、絵には写り込みます。解析する局だけで
  幅を決めると、切り捨てた局が隣にいる局の幅が広すぎることになります。

  Sets each station's width from the distance to its nearest neighbour
  (requirement FR-I.3).

  **Pass every station that is present, not only the ones being analysed.** A
  station left out of the analysis is still transmitting and still in the
  picture; widths computed from the analysed subset alone would be too wide for
  any station whose neighbour was dropped. }
procedure AssignHalfWidths(var Stations: TStations);

type
  { 追跡している 1 局。見つかった回数と消えた回数を持ちます。
    A station being tracked, with how many rounds it has been seen and missed. }
  TTrackedStation = record
    { 局を一意に指す番号。現れたときに振り、消えるまで変わりません。

      音程で指すことはできません。局はわずかに動き、動いた先が別の局の番号と
      重なることもあります。**上の層は局ごとに受信文を貯めるので、指し違えれば
      別の局の文が混ざります。**番号で指せば、動いても混ざりません。

      A number that identifies the station, assigned when it appears and
      unchanged until it goes.

      Pitch cannot serve as the identifier: stations drift, and a drifted pitch
      can land where another's was. **The layer above accumulates a transcript
      per station, so confusing two of them mixes their text.** A number cannot
      be confused by drift. }
    Id: Int64;
    Station: TStation;
    { 続けて見つかった回数と、続けて消えた回数。片方が進めば他方は 0 に戻ります。
      Consecutive rounds seen and missed; advancing one resets the other. }
    Hits: Integer;
    Misses: Integer;
    { 局として認めたか。認めるまでは幅の計算にだけ使い、外へは出しません。
      Whether it is confirmed. Until then it counts towards the widths but is not
      reported. }
    Confirmed: Boolean;
    { 受信開始からの秒。いつ現れ、いつ最後に聞こえたか。
      Seconds since reception began: when it appeared and when it was last
      heard. }
    FirstSeconds: Double;
    LastSeconds: Double;
  end;
  TTrackedStations = array of TTrackedStation;

  { 回をまたいで局を追いかけます。

    1 回の検出だけでは、局は現れたり消えたりします。符号には語間の休みがあり、
    雑音には突発があるためです。**回ごとに一覧を作り直すと、局ごとの受信文が
    そのたびに途切れます。**続けて見えたものだけを局と認め、続けて消えたものだけを
    忘れることで、一覧が落ち着きます。

    解析スレッドからのみ呼んでください。排他は持ちません。持たせるより、
    触るスレッドを 1 つに決めるほうが、後から読んで確かめられます。

    Follows stations across rounds.

    Call it from the analysis thread only; it holds no lock. Fixing which thread
    touches it is easier to verify by reading than a lock would be.

    A single detection has stations appearing and vanishing: code has gaps
    between words and noise has bursts. **Rebuilding the list each round would
    break each station's transcript every time.** Only what is seen repeatedly
    becomes a station, and only what is missing repeatedly is forgotten, which
    settles the list. }
  TStationTracker = class
  private
    FStations: TTrackedStations;
    FNextId: Int64;
    FConfirmRounds: Integer;
    FDropRounds: Integer;
    function IndexOfNearest(const Used: array of Boolean;
      const Found: TStations; Hz: Double): Integer;
  public
    constructor Create;

    { 1 回ぶんの検出を取り込みます。NowSeconds は受信開始からの秒です。
      Takes in one round of detections; NowSeconds is seconds since reception
      began. }
    procedure Update(const Found: TStations; NowSeconds: Double);
    procedure Clear;

    { 局と認めたものだけを、音程の昇順で返します。
      The confirmed stations only, in ascending pitch order. }
    function Confirmed: TStations;
    { 今この回に聞こえている局を、強い順に返します。解析する局を選ぶための
      順序です（要件 FR-I.7）。

      **認めたかどうかで絞りません。**認めるまで待つと、受信を始めてから最初の
      1 窓ぶん、どの局も解析されません。呼ばれるのを待つ運用（要件 FR-I.4）では、
      呼んできた局を読み始めるのがまるごと 1 窓ぶん遅れることになります。
      1 回だけ現れた雑音を解析してしまう費用は 1 窓ぶんで、そちらのほうが安い。

      認める・忘れるの決まりは、**一覧の落ち着きのため**にあります。解析の可否では
      なく、画面に出すかどうかに効かせます。

      The stations heard in this round, strongest first: the order in which
      stations are chosen for analysis (requirement FR-I.7).

      **This is not filtered by whether a station is confirmed.** Waiting for
      confirmation would leave the first window of a reception with nothing
      analysed at all, and would delay reading a station that has just started
      calling by a whole window — which is precisely what the waiting mode
      (requirement FR-I.4) must not do. Analysing a one-round burst of noise
      costs one window, which is the cheaper mistake.

      The confirm and drop rules exist **to settle the list**, so they govern what
      is shown rather than what is analysed. }
    function Loudest: TTrackedStations;
    { 追跡中のすべて。認める前のものも含みます。診断と試験のためです。
      Everything being tracked, unconfirmed included, for diagnostics and
      tests. }
    function All: TTrackedStations;
    function Count: Integer;

    property ConfirmRounds: Integer read FConfirmRounds write FConfirmRounds;
    property DropRounds: Integer read FDropRounds write FDropRounds;
  end;

{ 配列の中から、0..1 の位置にある値を返します（0.5 なら中央値）。配列は
  並べ替えられます。全体を整列させず、必要な 1 つだけを選び出します。

  Returns the value at a position from 0 to 1 in the array (0.5 being the
  median), reordering it. It selects the one value wanted rather than sorting
  the whole. }
function QuantileOf(var Values: TDoubleArray; Position: Double): Double;

implementation

function QuantileOf(var Values: TDoubleArray; Position: Double): Double;
var
  Wanted: Integer;

  { クイックセレクト。求める順位の要素だけが正しい位置に来れば足ります。
    Quickselect: only the element of the rank wanted needs to reach its place. }
  procedure Select(Low_, High_, Rank: Integer);
  var
    Pivot: Double;
    I, J, Middle: Integer;
    Swap: Double;
  begin
    while Low_ < High_ do
    begin
      { 3 つの中央を軸にします。既に整列した入力で最悪になるのを避けるためです。
        The median of three is the pivot, which avoids the worst case on input
        that is already ordered. }
      Middle := Low_ + (High_ - Low_) div 2;
      if Values[Middle] < Values[Low_] then
      begin
        Swap := Values[Middle]; Values[Middle] := Values[Low_]; Values[Low_] := Swap;
      end;
      if Values[High_] < Values[Low_] then
      begin
        Swap := Values[High_]; Values[High_] := Values[Low_]; Values[Low_] := Swap;
      end;
      if Values[High_] < Values[Middle] then
      begin
        Swap := Values[High_]; Values[High_] := Values[Middle]; Values[Middle] := Swap;
      end;
      Pivot := Values[Middle];

      I := Low_;
      J := High_;
      while I <= J do
      begin
        while Values[I] < Pivot do Inc(I);
        while Values[J] > Pivot do Dec(J);
        if I <= J then
        begin
          Swap := Values[I]; Values[I] := Values[J]; Values[J] := Swap;
          Inc(I);
          Dec(J);
        end;
      end;
      { 求める順位がある側だけを追います。
        Only the side holding the rank wanted is followed. }
      if Rank <= J then
        High_ := J
      else if Rank >= I then
        Low_ := I
      else
        Exit;
    end;
  end;

begin
  if Length(Values) = 0 then
    Exit(0);
  Wanted := ClampInt(Round(Position * (Length(Values) - 1)), 0, High(Values));
  Select(0, High(Values), Wanted);
  Result := Values[Wanted];
end;

{ log1p された値を振幅へ戻します。dB を出すには比が要り、log1p の値の差は比に
  なりません。
  Turns a log1p value back into a magnitude. A ratio is needed for decibels, and
  differences of log1p values are not ratios. }
function MagnitudeOf(Value: Double): Double;
begin
  Result := Exp(Value) - 1;
  if Result < 0 then
    Result := 0;
end;

type
  TSteadyMask = array of Boolean;

{ 強い局（`RefBin`、上位分位 `RefStatistic`）が落ち着いているコマ（付録 BZ）。
  戻り値はその数。/ The frames where the strong station (`RefBin`, upper
  quantile `RefStatistic`) is steady (appendix BZ); returns how many. }
function SteadyFrames(const Wide: TSpectrogram; RefBin: Integer;
  RefStatistic: Double; out Mask: TSteadyMask): Integer;
var
  Frame, J: Integer;
  Magnitude: Double;
  AllOn, AllOff: Boolean;
begin
  Result := 0;
  Mask := nil;
  SetLength(Mask, Wide.Frames);
  for Frame := 0 to Wide.Frames - 1 do
    Mask[Frame] := False;
  if RefStatistic <= 0 then
    Exit;
  for Frame := DETECT_CLICK_STEADY_FRAMES to
    Wide.Frames - 1 - DETECT_CLICK_STEADY_FRAMES do
  begin
    AllOn := True;
    AllOff := True;
    for J := Frame - DETECT_CLICK_STEADY_FRAMES to
      Frame + DETECT_CLICK_STEADY_FRAMES do
    begin
      Magnitude := MagnitudeOf(Wide.Data[J * Wide.Bins + RefBin]);
      if Magnitude < DETECT_CLICK_ON_RATIO * RefStatistic then
        AllOn := False;
      if Magnitude > DETECT_CLICK_OFF_RATIO * RefStatistic then
        AllOff := False;
      if not (AllOn or AllOff) then
        Break;
    end;
    if AllOn or AllOff then
    begin
      Mask[Frame] := True;
      Inc(Result);
    end;
  end;
end;

{ 落ち着いたコマだけで測り直した、雑音面からの高さ（dB）。測れなければ
  とても低い値。/ The height over the floor re-measured on the steady frames
  alone (dB); a very low value when it cannot be measured. }
function SteadyLevelDb(const Wide: TSpectrogram; Bin: Integer;
  const Mask: TSteadyMask; Floor_: Double): Double;
var
  Values: TDoubleArray;
  Frame, Count: Integer;
  Magnitude: Double;
begin
  Result := -1000;
  if Floor_ <= 0 then
    Exit;
  Values := nil;
  SetLength(Values, Wide.Frames);
  Count := 0;
  for Frame := 0 to Wide.Frames - 1 do
    if Mask[Frame] then
    begin
      Values[Count] := Wide.Data[Frame * Wide.Bins + Bin];
      Inc(Count);
    end;
  if Count = 0 then
    Exit;
  SetLength(Values, Count);
  Magnitude := MagnitudeOf(QuantileOf(Values, DETECT_CLICK_QUANTILE));
  if Magnitude <= 0 then
    Exit;
  Result := 20 * Log10(Magnitude / Floor_);
end;

function DetectStations(const Wide: TSpectrogram; WideRate: Integer): TStations;
var
  BinHz: Double;
  FirstBin, LastBin, Radius, FloorBins: Integer;
  Bin, Frame, Window, WindowFirst, WindowLast, I, Count, Folded: Integer;
  Column, Neighbourhood: TDoubleArray;
  Level, Floor_, Statistic: TDoubleArray;
  Peak: Boolean;
  J, Kept, OwnBin, Rank, Above, RefCount, Candidate: Integer;
  Masks: array of TSteadyMask;
  Steady: array of Integer;
  Keep: array of Boolean;
  Order, Refs: array of Integer;
  { 畳む候補の山（自分のビンを除く）。局が決まってから数えます。
    The candidate peaks to fold (own bin excluded), counted once the stations
    are settled. }
  FoldBins: array of array of Integer;
  { 見つけた局のビン（`Result` と同じ番号）。/ The bin of each station found
    (numbered as `Result`). }
  StationBin: array of Integer;
  { 本物と判じた、畳んだ山（局ごと、ビン）。隣の局のキークリックを判じる参照に
    加えます（付録 BZ.6）。/ The folded peaks judged real (per station, bins),
    added as references when judging neighbours' clicks (appendix BZ.6). }
  Companions: array of array of Integer;
  WithCompanion: Boolean;

  { その山（`OwnBin`）が、参照する山（`Refs` の先頭 `RefCount` 個、**ビンの
    番号**）のキークリックか（付録 BZ）。参照それぞれが落ち着いているコマで、
    また 2 局以上なら全員が同時に落ち着き 1 局以上が押しているコマで測り直し、
    しきい値を割ればキークリックとします。**本物の局はどの測り直しでも割らない。**
    Whether the peak at `OwnBin` is a key click of the reference peaks (the
    first `RefCount` of `Refs`, **bin numbers**) (appendix BZ): it is
    re-measured over each reference's steady frames and, with two or more,
    over the frames where all are steady and one holds the key down; falling
    below the threshold makes it a click. **A real station never does.** }
  function ClickOf(OwnBin: Integer; const Refs: array of Integer;
    RefCount: Integer): Boolean;
  var
    R, J, RefBin, TogetherCount, Frame: Integer;
    Together, AnyOn: TSteadyMask;
  begin
    Result := False;
    Together := nil;
    AnyOn := nil;
    for R := 0 to RefCount - 1 do
    begin
      RefBin := Refs[R];
      J := RefBin;
      if Steady[J] < 0 then
        Steady[J] := SteadyFrames(Wide, RefBin, Statistic[RefBin], Masks[J]);
      if (Steady[J] >= DETECT_CLICK_MIN_FRAMES) and
         (SteadyLevelDb(Wide, OwnBin, Masks[J], Floor_[OwnBin]) <
          DETECT_MIN_LEVEL_DB) then
        Exit(True);
      { 強い局どうしの落ち着いたコマの重なり。**強い局が 2 つあると、片方が
        落ち着いていても、もう片方の切り替えで鳴る**峰がありました（実測、
        付録 BZ.3）。すべてが同時に落ち着き、**少なくとも 1 局が押している**
        コマで測ります（全員が黙っているコマでは、本物の局も黙っている）。
        The overlap of the strong stations' steady frames. **With two strong
        stations, a peak kept ringing on one's edges while the other was
        steady** (measured, appendix BZ.3). It is measured where all are steady
        at once **and at least one holds the key down** (where everyone is
        silent, a real station is silent too). }
      if R = 0 then
      begin
        SetLength(Together, Wide.Frames);
        SetLength(AnyOn, Wide.Frames);
        for Frame := 0 to Wide.Frames - 1 do
        begin
          Together[Frame] := Masks[J][Frame];
          AnyOn[Frame] := False;
        end;
      end
      else
        for Frame := 0 to Wide.Frames - 1 do
          Together[Frame] := Together[Frame] and Masks[J][Frame];
      for Frame := 0 to Wide.Frames - 1 do
        if MagnitudeOf(Wide.Data[Frame * Wide.Bins + RefBin]) >=
           DETECT_CLICK_ON_RATIO * Statistic[RefBin] then
          AnyOn[Frame] := True;
    end;
    if RefCount < 2 then
      Exit;
    TogetherCount := 0;
    for Frame := 0 to Wide.Frames - 1 do
    begin
      Together[Frame] := Together[Frame] and AnyOn[Frame];
      if Together[Frame] then
        Inc(TogetherCount);
    end;
    Result := (TogetherCount >= DETECT_CLICK_MIN_FRAMES) and
      (SteadyLevelDb(Wide, OwnBin, Together, Floor_[OwnBin]) <
       DETECT_MIN_LEVEL_DB);
  end;

begin
  Result := nil;
  FoldBins := nil;
  if (Wide.Frames <= 0) or (Wide.Bins <= 0) or (WideRate <= 0) then
    Exit;

  { ビン幅は、渡されたスペクトログラム自身から求めます。メタデータから計算すると、
    渡された絵と食い違ったときに黙って別の周波数を指します。
    The bin spacing is derived from the spectrogram handed in. Computing it from
    the metadata instead would silently point at the wrong frequency whenever the
    two disagreed. }
  if Wide.Bins < 2 then
    Exit;
  BinHz := WideRate / ((Wide.Bins - 1) * 2);
  if BinHz <= 0 then
    Exit;

  FirstBin := Max(1, Ceil(DETECT_LOW_HZ / BinHz));
  LastBin := Min(Wide.Bins - 2, Trunc(DETECT_HIGH_HZ / BinHz));
  if LastBin <= FirstBin then
    Exit;

  { [1] ビンごとに、時間方向の上位分位を取ります。断続する符号の、鍵を押して
        いる間の大きさが出ます。
        [1] Per bin, the upper quantile along time, which gives the key-down
        level of intermittent code. }
  SetLength(Statistic, Wide.Bins);
  SetLength(Column, Wide.Frames);
  for Bin := 0 to Wide.Bins - 1 do
  begin
    for Frame := 0 to Wide.Frames - 1 do
      Column[Frame] := Wide.Data[Frame * Wide.Bins + Bin];
    Statistic[Bin] := MagnitudeOf(QuantileOf(Column, DETECT_TIME_QUANTILE));
  end;

  { [2] ビンごとに、近傍の雑音面を測ります。受信機の濾波器の傾斜に追従します。
        [2] Per bin, the local noise floor, which follows the slope of the
        receiver's filter. }
  FloorBins := Max(4, Round(DETECT_FLOOR_WINDOW_HZ / BinHz));
  SetLength(Floor_, Wide.Bins);
  SetLength(Neighbourhood, 2 * FloorBins + 1);
  for Bin := 0 to Wide.Bins - 1 do
  begin
    WindowFirst := Max(0, Bin - FloorBins);
    WindowLast := Min(Wide.Bins - 1, Bin + FloorBins);
    Window := WindowLast - WindowFirst + 1;
    SetLength(Neighbourhood, Window);
    for I := 0 to Window - 1 do
      Neighbourhood[I] := Statistic[WindowFirst + I];
    Floor_[Bin] := QuantileOf(Neighbourhood, DETECT_FLOOR_QUANTILE);
  end;

  { [3] 雑音面からの高さ（dB）。
        [3] Height above that floor, in decibels. }
  SetLength(Level, Wide.Bins);
  for Bin := 0 to Wide.Bins - 1 do
    if (Floor_[Bin] <= 0) or (Statistic[Bin] <= 0) then
      Level[Bin] := 0
    else
      Level[Bin] := 20 * Log10(Statistic[Bin] / Floor_[Bin]);

  { [4] しきい値を超え、かつ近傍でいちばん高いビンを局とします。近傍の広さを
        分離の下限に合わせることで、近すぎる 2 つの山は 1 つに畳まれます。

        [4] A bin is a station when it clears the threshold and is the highest
        in its neighbourhood. Making that neighbourhood the separation limit is
        what folds two peaks that are too close into one. }
  { 近傍の半径は、分離の下限より **1 ビン狭く** します。半径を下限そのものに
    すると、ちょうど下限の間隔で並ぶ 2 局が互いの近傍に入り、弱いほうが必ず
    消えます。**測って「分離できる」と言った 100 Hz 間隔が、検出できない。**
    1 ビン狭めることで、下限以上の間隔は 2 局、下限未満は 1 局、と境目が要件の
    とおりになります。

    The neighbourhood radius is **one bin narrower** than the separation limit.
    At the limit itself, two stations exactly that far apart fall inside each
    other's neighbourhood and the weaker always disappears — **the very 100 Hz
    spacing that was measured as separable would not be detected.** One bin
    narrower puts the boundary where the requirement puts it: at or beyond the
    limit is two stations, closer is one. }
  Radius := Max(1, Round(DETECT_MIN_SEPARATION_HZ / BinHz) - 1);
  Count := 0;
  SetLength(Result, (LastBin - FirstBin) div Radius + 2);
  for Bin := FirstBin to LastBin do
  begin
    if Level[Bin] < DETECT_MIN_LEVEL_DB then
      Continue;
    Peak := True;
    for I := Max(0, Bin - Radius) to Min(Wide.Bins - 1, Bin + Radius) do
    begin
      if I = Bin then
        Continue;
      { 平らな頂の場合は左端の 1 つだけを採ります。左は真に小さく、右は同じでも
        よい、とすることで、同じ高さが並んでも 1 つに決まります。
        On a plateau only the leftmost is taken: strictly greater to the left and
        greater or equal to the right settles on one bin when several share a
        height. }
      if I < Bin then
      begin
        if Level[I] >= Level[Bin] then
        begin
          Peak := False;
          Break;
        end;
      end
      else if Level[I] > Level[Bin] then
      begin
        Peak := False;
        Break;
      end;
    end;
    if not Peak then
      Continue;
    if Count = Length(Result) then
      SetLength(Result, Count * 2 + 4);
    Result[Count].Hz := Bin * BinHz;
    Result[Count].LevelDb := Level[Bin];
    Result[Count].HalfWidthHz := DETECT_MAX_HALF_WIDTH_HZ;
    { 近傍に畳み込んだ峰を数えます。峰は「両隣より高く、しきい値を超えるビン」
      とします。自分自身も数に入るので、1 を引いた残りが畳んだ数です。
      Counts the peaks folded in. A peak is a bin above the threshold and higher
      than both its neighbours; this bin counts itself, so one less is the number
      folded in. }
    { 畳む候補を控えます。数えるのは、残す局が決まってから（[6]）。
      The candidates to fold are noted; they are counted once the stations to
      keep are settled ([6]). }
    if Count >= Length(FoldBins) then
      SetLength(FoldBins, Length(Result));
    FoldBins[Count] := nil;
    for I := Max(1, Bin - Radius) to Min(Wide.Bins - 2, Bin + Radius) do
      if (I <> Bin) and (Level[I] >= DETECT_MIN_LEVEL_DB) and
         (Level[I] > Level[I - 1]) and (Level[I] >= Level[I + 1]) then
      begin
        SetLength(FoldBins[Count], Length(FoldBins[Count]) + 1);
        FoldBins[Count][High(FoldBins[Count])] := I;
      end;
    Result[Count].Crowded := 0;
    Inc(Count);
  end;
  SetLength(Result, Count);

  { [5] 強い局のキークリックを、局の一覧から除きます（付録 BZ）。6 dB 以上
        強い局それぞれについて、その局が落ち着いているコマで測り直し、
        しきい値を割ったものを除きます。**本物の局は、どの強い局に対しても
        割りません**（打鍵が独立しているため）。幅は、除いたあとで決めます。
        [5] Key clicks of strong stations are removed from the list
        (appendix BZ): for each station 6 dB or more stronger, a peak is
        re-measured over the frames where that station is steady and removed if
        it falls below the threshold. **A real station never does**, against
        any strong station, being keyed independently. Widths are settled after
        the removal. }
  SetLength(StationBin, Count);
  for I := 0 to Count - 1 do
    StationBin[I] := Round(Result[I].Hz / BinHz);
  { 落ち着いたコマは、ビンごとに要るときだけ求めて控えます。
    Steady frames are worked out per bin, only when needed, and kept. }
  SetLength(Masks, Wide.Bins);
  SetLength(Steady, Wide.Bins);
  for I := 0 to Wide.Bins - 1 do
    Steady[I] := -1;
  SetLength(Keep, Count);
  SetLength(Order, Count);
  for I := 0 to Count - 1 do
  begin
    Keep[I] := True;
    Order[I] := I;
  end;
  { 強い順に決めます。**参照にするのは、残すと決めた局だけ**です。幻の峰を
    参照にすると、その「落ち着いたコマ」が本物の局を消しました（実測、
    付録 BZ.3）。
    Decided strongest first; **only stations already kept serve as
    references**. Using a phantom peak as one let its "steady frames" remove a
    real station (measured, appendix BZ.3). }
  for I := 1 to Count - 1 do
  begin
    J := Order[I];
    Kept := I - 1;
    while (Kept >= 0) and (Result[Order[Kept]].LevelDb < Result[J].LevelDb) do
    begin
      Order[Kept + 1] := Order[Kept];
      Dec(Kept);
    end;
    Order[Kept + 1] := J;
  end;
  SetLength(Refs, Wide.Bins);
  for Rank := 0 to Count - 1 do
  begin
    I := Order[Rank];
    OwnBin := StationBin[I];
    RefCount := 0;
    for Above := 0 to Rank - 1 do
    begin
      J := Order[Above];
      if Keep[J] and
         (Result[J].LevelDb >= Result[I].LevelDb + DETECT_CLICK_GAP_DB) then
      begin
        Refs[RefCount] := StationBin[J];
        Inc(RefCount);
      end;
    end;
    if ClickOf(OwnBin, Refs, RefCount) then
      Keep[I] := False;
  end;

  { [6] 「密集」の数（要件 FR-J.6）。畳む候補の山のうち、**残す局のどれかの
        キークリックであるものは数えません**（付録 BZ.6）。その局自身の
        クリックだけでなく、**隣の強い局のクリックが 100 Hz 以内に落ちる**と、
        1 局しかいない本物の弱い局が「密集 3」と出て、符号が隠れていました。
        [6] The crowded count (requirement FR-J.6). Candidate peaks that are
        **a key click of any station kept are not counted** (appendix BZ.6):
        not only a station's own clicks but **a strong neighbour's clicks
        landing within 100 Hz** made a real, lone weak station read "crowded 3",
        hiding its call sign. }
  SetLength(Companions, Count);
  for I := 0 to Count - 1 do
  begin
    Companions[I] := nil;
    if not Keep[I] then
      Continue;
    Folded := 1;
    for Candidate := 0 to High(FoldBins[I]) do
    begin
      Bin := FoldBins[I][Candidate];
      RefCount := 0;
      for Rank := 0 to Count - 1 do
      begin
        J := Order[Rank];
        if Keep[J] and (Result[J].LevelDb >= Level[Bin] + DETECT_CLICK_GAP_DB) then
        begin
          Refs[RefCount] := StationBin[J];
          Inc(RefCount);
        end;
      end;
      if not ClickOf(Bin, Refs, RefCount) then
      begin
        Inc(Folded);
        SetLength(Companions[I], Length(Companions[I]) + 1);
        Companions[I][High(Companions[I])] := Bin;
      end;
    end;
    Result[I].Crowded := Folded - 1;
  end;

  { [7] 畳んだ本物の山も参照に加えて、もう一度判じます（付録 BZ.6）。強い局の
        100 Hz 以内に本物の局がいると 1 局に畳まれ、**その局のキークリックの幻**
        （825・1238 Hz など）が、参照に入らないために残っていました。
        [7] Judged once more with the real folded peaks among the references
        (appendix BZ.6). A real station within 100 Hz of a strong one is folded
        into it, and **its key-click phantoms** (825, 1238 Hz...) survived because
        it was never a reference. }
  for Rank := 0 to Count - 1 do
  begin
    I := Order[Rank];
    if not Keep[I] then
      Continue;
    RefCount := 0;
    WithCompanion := False;
    for Above := 0 to Rank - 1 do
    begin
      J := Order[Above];
      if not Keep[J] then
        Continue;
      if Result[J].LevelDb < Result[I].LevelDb + DETECT_CLICK_GAP_DB then
        Continue;
      Refs[RefCount] := StationBin[J];
      Inc(RefCount);
      { 畳んだ本物の山は、強さの差を問わず参照に加えます。幻の峰は強い局と
        畳んだ局の**両方の**クリックの和で、畳んだ局と同じくらいの高さに
        なっていました（実測、付録 BZ.6）。本物の局はどの参照に対しても
        測り直しで下がらないので、参照を増やしても消えません。
        A real folded peak joins the references whatever its strength: the
        phantom was the sum of **both** stations' clicks and stood as high as
        the folded station itself (measured, appendix BZ.6). A real station
        does not fall against any reference, so more references cannot remove
        it. }
      for Candidate := 0 to High(Companions[J]) do
      begin
        Refs[RefCount] := Companions[J][Candidate];
        Inc(RefCount);
        WithCompanion := True;
      end;
    end;
    if WithCompanion and ClickOf(StationBin[I], Refs, RefCount) then
      Keep[I] := False;
  end;
  Kept := 0;
  for I := 0 to Count - 1 do
    if Keep[I] then
    begin
      Result[Kept] := Result[I];
      Inc(Kept);
    end;
  SetLength(Result, Kept);
  AssignHalfWidths(Result);
end;

procedure AssignHalfWidths(var Stations: TStations);
var
  I: Integer;
  Nearest, Distance: Double;
begin
  for I := 0 to High(Stations) do
  begin
    { 音程の昇順で渡される前提です。隣は前後の 2 つだけを見れば足ります。
      The list is in ascending pitch order, so only the two adjacent entries can
      be the nearest neighbour. }
    Nearest := Infinity;
    if I > 0 then
      Nearest := Stations[I].Hz - Stations[I - 1].Hz;
    if I < High(Stations) then
    begin
      Distance := Stations[I + 1].Hz - Stations[I].Hz;
      if Distance < Nearest then
        Nearest := Distance;
    end;
    if IsInfinite(Nearest) then
      { 隣がいなければ、1 局だけを聴くときと同じ幅にします。
        With no neighbour, the width is the one used for a single station. }
      Stations[I].HalfWidthHz := DETECT_MAX_HALF_WIDTH_HZ
    else
      Stations[I].HalfWidthHz := EnsureRange(Nearest / 2,
        DETECT_MIN_HALF_WIDTH_HZ, DETECT_MAX_HALF_WIDTH_HZ);
  end;
end;

constructor TStationTracker.Create;
begin
  inherited Create;
  FNextId := 1;
  FConfirmRounds := DETECT_CONFIRM_ROUNDS;
  FDropRounds := DETECT_DROP_ROUNDS;
end;

procedure TStationTracker.Clear;
begin
  FStations := nil;
end;

{ まだ使われていない候補のうち、いちばん近いものを返します。許容の外なら -1。
  同じ候補を 2 つの局に割り当てないよう、使用済みを見ます。

  The nearest candidate not yet taken, or -1 when none is within tolerance. The
  taken flags stop one candidate being assigned to two stations. }
function TStationTracker.IndexOfNearest(const Used: array of Boolean;
  const Found: TStations; Hz: Double): Integer;
var
  I: Integer;
  Distance, Best: Double;
begin
  Result := -1;
  Best := DETECT_MATCH_TOLERANCE_HZ;
  for I := 0 to High(Found) do
  begin
    if Used[I] then
      Continue;
    Distance := Abs(Found[I].Hz - Hz);
    if Distance <= Best then
    begin
      Best := Distance;
      Result := I;
    end;
  end;
end;

procedure TStationTracker.Update(const Found: TStations; NowSeconds: Double);
var
  Used: array of Boolean;
  Kept: TTrackedStations;
  Present: TStations;
  Moving: TTrackedStation;
  I, Match, Total, PresentCount: Integer;
begin
  SetLength(Used, Length(Found));
  for I := 0 to High(Used) do
    Used[I] := False;

  { [1] 追跡中のものを、今回の検出に突き合わせます。
        [1] Match what is being tracked against this round's detections. }
  Total := 0;
  SetLength(Kept, Length(FStations) + Length(Found));
  for I := 0 to High(FStations) do
  begin
    Match := IndexOfNearest(Used, Found, FStations[I].Station.Hz);
    if Match >= 0 then
    begin
      Used[Match] := True;
      Kept[Total] := FStations[I];
      Kept[Total].Station.Hz := Found[Match].Hz;
      Kept[Total].Station.LevelDb := Found[Match].LevelDb;
      Kept[Total].Hits := FStations[I].Hits + 1;
      Kept[Total].Misses := 0;
      Kept[Total].LastSeconds := NowSeconds;
      if Kept[Total].Hits >= FConfirmRounds then
        Kept[Total].Confirmed := True;
      Inc(Total);
    end
    else
    begin
      { 消えていた回数を数え、続けて消えたものだけを忘れます。1 回で忘れると、
        語間の休みで局が消えます。
        Missing rounds are counted and only a run of them forgets a station;
        forgetting on one would lose a station across the gap between words. }
      if FStations[I].Misses + 1 >= FDropRounds then
        Continue;
      Kept[Total] := FStations[I];
      Kept[Total].Hits := 0;
      Kept[Total].Misses := FStations[I].Misses + 1;
      Inc(Total);
    end;
  end;

  { [2] どれにも当たらなかった候補を、新しい局として加えます。
        [2] Candidates that matched nothing become new stations. }
  for I := 0 to High(Found) do
  begin
    if Used[I] then
      Continue;
    Kept[Total].Id := FNextId;
    Inc(FNextId);
    Kept[Total].Station := Found[I];
    Kept[Total].Hits := 1;
    Kept[Total].Misses := 0;
    Kept[Total].Confirmed := FConfirmRounds <= 1;
    Kept[Total].FirstSeconds := NowSeconds;
    Kept[Total].LastSeconds := NowSeconds;
    Inc(Total);
  end;
  SetLength(Kept, Total);

  { [3] 音程の昇順に並べ替えます。幅の計算はこの順でしか成り立ちません。
        [3] Sort into ascending pitch order, which is the only order the widths
        can be computed in. }
  for I := 1 to High(Kept) do
  begin
    Moving := Kept[I];
    Match := I;
    while (Match > 0) and (Kept[Match - 1].Station.Hz > Moving.Station.Hz) do
    begin
      Kept[Match] := Kept[Match - 1];
      Dec(Match);
    end;
    Kept[Match] := Moving;
  end;

  { [4] 幅は「今この回に出ている局」から決めます。消えている局は電波を出して
        いないので、絵にも写り込みません。
        [4] Widths come from the stations heard this round: one that has gone
        quiet is not transmitting and so is not in the picture either. }
  PresentCount := 0;
  SetLength(Present, Length(Kept));
  for I := 0 to High(Kept) do
    if Kept[I].Misses = 0 then
    begin
      Present[PresentCount] := Kept[I].Station;
      Inc(PresentCount);
    end;
  SetLength(Present, PresentCount);
  AssignHalfWidths(Present);

  PresentCount := 0;
  for I := 0 to High(Kept) do
    if Kept[I].Misses = 0 then
    begin
      Kept[I].Station.HalfWidthHz := Present[PresentCount].HalfWidthHz;
      Inc(PresentCount);
    end;

  FStations := Kept;
end;

function TStationTracker.Confirmed: TStations;
var
  I, Total: Integer;
begin
  Total := 0;
  SetLength(Result, Length(FStations));
  for I := 0 to High(FStations) do
    if FStations[I].Confirmed then
    begin
      Result[Total] := FStations[I].Station;
      Inc(Total);
    end;
  SetLength(Result, Total);
end;

function TStationTracker.Loudest: TTrackedStations;
var
  I, Total, Position: Integer;
  Moving: TTrackedStation;
begin
  Total := 0;
  SetLength(Result, Length(FStations));
  for I := 0 to High(FStations) do
    if FStations[I].Misses = 0 then
    begin
      Result[Total] := FStations[I];
      Inc(Total);
    end;
  SetLength(Result, Total);
  { 強い順。数が少ないので単純な挿入で足ります。
    Strongest first; the numbers are small enough for a plain insertion. }
  for I := 1 to High(Result) do
  begin
    Moving := Result[I];
    Position := I;
    while (Position > 0) and
          (Result[Position - 1].Station.LevelDb < Moving.Station.LevelDb) do
    begin
      Result[Position] := Result[Position - 1];
      Dec(Position);
    end;
    Result[Position] := Moving;
  end;
end;

function TStationTracker.All: TTrackedStations;
begin
  Result := Copy(FStations, 0, Length(FStations));
end;

function TStationTracker.Count: Integer;
begin
  Result := Length(FStations);
end;

{ 元の並びを崩さずに分位を求めます（`QuantileOf` は並べ替える）。
  A quantile without disturbing the original order (`QuantileOf` reorders). }
function QuantileOfCopy(const Values: TDoubleArray; Position: Double): Double;
var
  Work: TDoubleArray;
begin
  Work := Copy(Values);
  Result := QuantileOf(Work, Position);
end;

function SuppressNeighbourClicks(var Slice: TSpectrogram;
  const Wide: TSpectrogram; WideRate: Integer; const Stations: array of Double;
  Own: Integer; HalfWidthHz: Double): Integer;
var
  BinHz: Double;
  OwnBin, RefBin, Frame, J, K, Count: Integer;
  Columns: TClickColumns;
begin
  Result := 0;
  if (Own < 0) or (Own > High(Stations)) or (Wide.Frames <= 0) or
     (Wide.Bins < 2) or (WideRate <= 0) or (Slice.Bins <= 0) then
    Exit;
  BinHz := WideRate / ((Wide.Bins - 1) * 2);
  if BinHz <= 0 then
    Exit;
  OwnBin := Round(Stations[Own] / BinHz);
  if (OwnBin < 8) or (OwnBin > Wide.Bins - 9) then
    Exit;

  { 絵から、その局・両脇・隣の局の列を取り出します（付録 CB と同じ見方）。
    The station's, its sides' and the neighbours' columns, taken from the
    picture (as in appendix CB). }
  SetLength(Columns.Own, Wide.Frames);
  SetLength(Columns.Side, Wide.Frames);
  for Frame := 0 to Wide.Frames - 1 do
  begin
    Columns.Own[Frame] := MagnitudeOf(Wide.Data[Frame * Wide.Bins + OwnBin]);
    Columns.Side[Frame] := 0;
    for K := 4 to 8 do
      Columns.Side[Frame] := Columns.Side[Frame] +
        MagnitudeOf(Wide.Data[Frame * Wide.Bins + OwnBin - K]) +
        MagnitudeOf(Wide.Data[Frame * Wide.Bins + OwnBin + K]);
    Columns.Side[Frame] := Columns.Side[Frame] / 10;
  end;
  Count := 0;
  SetLength(Columns.Neighbours, Length(Stations));
  for J := 0 to High(Stations) do
  begin
    if J = Own then
      Continue;
    RefBin := Round(Stations[J] / BinHz);
    if (RefBin < 0) or (RefBin >= Wide.Bins) then
      Continue;
    SetLength(Columns.Neighbours[Count], Wide.Frames);
    for Frame := 0 to Wide.Frames - 1 do
      Columns.Neighbours[Count][Frame] :=
        MagnitudeOf(Wide.Data[Frame * Wide.Bins + RefBin]);
    Inc(Count);
  end;
  SetLength(Columns.Neighbours, Count);
  Result := SuppressClicksFromColumns(Slice, Columns, HalfWidthHz, BinHz);
end;

function SuppressClicksFromColumns(var Slice: TSpectrogram;
  const Columns: TClickColumns; HalfWidthHz, BinHz: Double): Integer;
var
  OwnUpper, RefUpper: Double;
  ColumnFrames, Frames, Frame, J, K, Bin, Centre, HalfBins: Integer;
  Column, Floors, LogFloors: TDoubleArray;
  Present, Edge, Near, Visible: array of Boolean;
  AnyEdge, AllOn, AllOff: Boolean;
begin
  Result := 0;
  ColumnFrames := Length(Columns.Own);
  if (ColumnFrames <= 0) or (Length(Columns.Side) <> ColumnFrames) or
     (Slice.Bins <= 0) or (Slice.Frames <= 0) or (BinHz <= 0) then
    Exit;
  Frames := Min(Slice.Frames, ColumnFrames);
  OwnUpper := QuantileOfCopy(Columns.Own, DETECT_TIME_QUANTILE);
  if OwnUpper <= 0 then
    Exit;

  { より強い隣の局の、切り替えの最中のコマ。/ Frames where a stronger
    neighbour is in mid-edge. }
  SetLength(Edge, ColumnFrames);
  for Frame := 0 to ColumnFrames - 1 do
    Edge[Frame] := False;
  AnyEdge := False;
  for J := 0 to High(Columns.Neighbours) do
  begin
    if Length(Columns.Neighbours[J]) <> ColumnFrames then
      Continue;
    RefUpper := QuantileOfCopy(Columns.Neighbours[J], DETECT_TIME_QUANTILE);
    if RefUpper < NEIGHBOUR_STRONGER_RATIO * OwnUpper then
      Continue;
    for Frame := 0 to ColumnFrames - 1 do
    begin
      AllOn := True;
      AllOff := True;
      for K := Max(0, Frame - DETECT_CLICK_STEADY_FRAMES) to
        Min(ColumnFrames - 1, Frame + DETECT_CLICK_STEADY_FRAMES) do
      begin
        if Columns.Neighbours[J][K] < DETECT_CLICK_ON_RATIO * RefUpper then
          AllOn := False;
        if Columns.Neighbours[J][K] > DETECT_CLICK_OFF_RATIO * RefUpper then
          AllOff := False;
      end;
      if not (AllOn or AllOff) then
      begin
        Edge[Frame] := True;
        AnyEdge := True;
      end;
    end;
  end;
  if not AnyEdge then
    Exit;

  { その局の音があるコマと、その前後。/ Frames with the station's own tone,
    and those near them. }
  SetLength(Present, ColumnFrames);
  for Frame := 0 to ColumnFrames - 1 do
    Present[Frame] :=
      (Columns.Own[Frame] >= NEIGHBOUR_PRESENT_LEVEL * OwnUpper) and
      (Columns.Own[Frame] >= NEIGHBOUR_PEAK_RATIO * Columns.Side[Frame]);
  SetLength(Near, ColumnFrames);
  for Frame := 0 to ColumnFrames - 1 do
  begin
    Near[Frame] := False;
    for K := Max(0, Frame - NEIGHBOUR_GUARD_FRAMES) to
      Min(ColumnFrames - 1, Frame + NEIGHBOUR_GUARD_FRAMES) do
      if Present[K] then
      begin
        Near[Frame] := True;
        Break;
      end;
  end;

  { 置き換えうるコマが無ければ、ビンごとの分位は求めません（結果は同じ）。
    With no frame that could be replaced, the per-bin quantiles are skipped
    (the result is the same). }
  AnyEdge := False;
  for Frame := 0 to Frames - 1 do
    if Edge[Frame] and not Near[Frame] then
    begin
      AnyEdge := True;
      Break;
    end;
  if not AnyEdge then
    Exit;

  { 残す幅の中で何かが見えているコマ。ビンごとの 25% 分位を基準にし、置き換える
    値にも使います。/ Frames with something visible inside the width kept,
    against each bin's 25% quantile, which is also the value replaced in. }
  Column := nil;
  SetLength(Floors, Slice.Bins);
  SetLength(LogFloors, Slice.Bins);
  SetLength(Column, Slice.Frames);
  for Bin := 0 to Slice.Bins - 1 do
  begin
    for Frame := 0 to Slice.Frames - 1 do
      Column[Frame] := Slice.Data[Frame * Slice.Bins + Bin];
    LogFloors[Bin] := QuantileOfCopy(Column, DETECT_FLOOR_QUANTILE);
    Floors[Bin] := MagnitudeOf(LogFloors[Bin]);
  end;
  Centre := Slice.Bins div 2;
  HalfBins := Max(1, Round(HalfWidthHz / BinHz));
  SetLength(Visible, Frames);
  for Frame := 0 to Frames - 1 do
  begin
    Visible[Frame] := False;
    for Bin := Max(0, Centre - HalfBins) to Min(Slice.Bins - 1, Centre + HalfBins) do
      if MagnitudeOf(Slice.Data[Frame * Slice.Bins + Bin]) >=
         NEIGHBOUR_VISIBLE_RATIO * Max(Floors[Bin], 1e-12) then
      begin
        Visible[Frame] := True;
        Break;
      end;
  end;

  for Frame := 0 to Frames - 1 do
    if Edge[Frame] and Visible[Frame] and not Near[Frame] then
    begin
      for Bin := 0 to Slice.Bins - 1 do
        Slice.Data[Frame * Slice.Bins + Bin] := LogFloors[Bin];
      Inc(Result);
    end;
end;


{ TClickColumnCache }

const
  { 両脇として見るビン（同調点から 4〜8 ビン、付録 CB と同じ）。
    The bins taken as the sides (4 to 8 from the tuned pitch, as in
    appendix CB). }
  CLICK_SIDE_NEAR_BINS = 4;
  CLICK_SIDE_FAR_BINS = 8;
  CLICK_SIDE_PROBES = CLICK_SIDE_FAR_BINS - CLICK_SIDE_NEAR_BINS + 1;
  { モデルの絵と同じ窓と刻み（3200 Hz で 256 点・48 点）。
    The model picture's window and step (256 and 48 points at 3200 Hz). }
  CLICK_WINDOW_SECONDS = 0.08;
  CLICK_HOP_SECONDS = 0.015;
  CLICK_BIN_HZ = 12.5;
  { 音の端からこれだけ内側のコマだけを控えます。整形（周波数の変換・標本化の
    変換）は音の端で値が揺れ、あとで音が届くと変わるためです。
    Only frames at least this far inside the audio are kept: the preparation
    (frequency translation, rate conversion) wobbles at the ends of the audio
    and changes once more audio arrives. }
  CLICK_EDGE_SECONDS = 0.1;
  { 同調点以外のビンを局の音とするのは、尖り具合（上位分位）が同調点の
    これ倍を超えるときだけ（付録 CI.2）。
    Another bin than the tuned one is taken as the station's tone only when
    its peakedness (upper quantile) is more than this times the tuned bin's
    (appendix CI.2). }
  CLICK_OWN_SWITCH_RATIO = 1.5;

procedure TClickColumnCache.Clear;
begin
  FFirst := 0;
  FCount := 0;
  FBand := nil;
  FNeighbours := nil;
  FNeighboursStale := False;
end;

function TClickColumnCache.HasNeighbours: Boolean;
begin
  Result := Length(FNeighbourHz) > 0;
end;

procedure TClickColumnCache.BuildProbes(First, Last: Integer);
var
  P, I: Integer;
  Hz, W, Phase: Double;
begin
  for P := First to Last do
  begin
    if P < FBandProbes then
      Hz := FTuneHz + (P - CLICK_OWN_SPAN_BINS - CLICK_SIDE_FAR_BINS) *
        CLICK_BIN_HZ
    else
      Hz := FNeighbourHz[P - FBandProbes];
    SetLength(FCos[P], FWindow);
    SetLength(FSin[P], FWindow);
    for I := 0 to FWindow - 1 do
    begin
      { 周期型のハン窓（`HannWindow` と同じ）。/ Periodic Hann, as `HannWindow`. }
      W := 0.5 - 0.5 * Cos(2 * Pi * I / FWindow);
      Phase := 2 * Pi * Hz * I / FRate;
      if (Hz <= 0) or (Hz >= FRate / 2) then
        W := 0;
      FCos[P][I] := W * Cos(Phase);
      FSin[P][I] := W * Sin(Phase);
    end;
  end;
end;

procedure TClickColumnCache.Configure(Rate: Integer; TuneHz: Double;
  const Neighbours: array of Double);
var
  I, Count: Integer;
  Same: Boolean;
  Chosen: TDoubleArray;
begin
  if (Rate <> FRate) or (TuneHz <> FTuneHz) then
  begin
    FRate := Rate;
    FTuneHz := TuneHz;
    FNeighbourHz := nil;
    FWindow := Max(1, Round(Rate * CLICK_WINDOW_SECONDS));
    FBandProbes := 2 * (CLICK_OWN_SPAN_BINS + CLICK_SIDE_FAR_BINS) + 1;
    SetLength(FCos, FBandProbes);
    SetLength(FSin, FBandProbes);
    if Rate > 0 then
      BuildProbes(0, FBandProbes - 1);
    Clear;
  end;
  Chosen := nil;
  SetLength(Chosen, Length(Neighbours));
  Count := 0;
  for I := 0 to High(Neighbours) do
    if Abs(Neighbours[I] - TuneHz) >= CLICK_MIN_NEIGHBOUR_HZ then
    begin
      Chosen[Count] := Neighbours[I];
      Inc(Count);
    end;
  SetLength(Chosen, Count);
  Same := Count = Length(FNeighbourHz);
  if Same then
    for I := 0 to Count - 1 do
      if Chosen[I] <> FNeighbourHz[I] then
        Same := False;
  if Same then
    Exit;
  FNeighbourHz := Chosen;
  SetLength(FCos, FBandProbes + Count);
  SetLength(FSin, FBandProbes + Count);
  if FRate > 0 then
    BuildProbes(FBandProbes, High(FCos));
  SetLength(FNeighbours, Count);
  for I := 0 to High(FNeighbours) do
    SetLength(FNeighbours[I], Length(FBand) div Max(1, FBandProbes));
  FNeighboursStale := FCount > 0;
end;

function TClickColumnCache.LeftOf(Frame: Int64; AudioStart: Double): Int64;
begin
  Result := Round((Frame * CLICK_HOP_SECONDS - AudioStart) * FRate) -
    FWindow div 2;
end;

function TClickColumnCache.FrameInside(Frame: Int64; AudioStart: Double;
  Length_: Integer): Boolean;
var
  Left, Edge: Int64;
begin
  Left := LeftOf(Frame, AudioStart);
  Edge := Round(CLICK_EDGE_SECONDS * FRate);
  Result := (Left >= Edge) and (Left + FWindow <= Length_ - Edge);
end;

procedure TClickColumnCache.Probe(const Audio: TSingleArray; AudioStart: Double;
  Frame: Int64; First, Last: Integer; var Values: TDoubleArray);
var
  Left, Index, Top: Int64;
  I, P: Integer;
  Re, Im, X: Double;
  Segment: TDoubleArray;
begin
  Segment := nil;
  SetLength(Segment, FWindow);
  Left := LeftOf(Frame, AudioStart);
  Top := High(Audio);
  for I := 0 to FWindow - 1 do
  begin
    { 音の端の外は折り返します（モデルの絵の `ReflectPad` と同じ）。
      Beyond either end the audio is reflected (as the model picture's
      `ReflectPad`). }
    Index := Left + I;
    if Index < 0 then
      Index := -Index;
    if Index > Top then
      Index := 2 * Top - Index;
    if (Index < 0) or (Index > Top) then
      Segment[I] := 0
    else
      Segment[I] := Audio[Index];
  end;
  for P := First to Last do
  begin
    Re := 0;
    Im := 0;
    for I := 0 to FWindow - 1 do
    begin
      X := Segment[I];
      Re := Re + X * FCos[P][I];
      Im := Im + X * FSin[P][I];
    end;
    Values[P] := Sqrt(Re * Re + Im * Im);
  end;
  Inc(FComputed);
end;

procedure TClickColumnCache.Store(Frame: Int64; const Values: TDoubleArray);
var
  J, P, Capacity: Integer;
begin
  if (FCount > 0) and (Frame <> FFirst + FCount) then
    Clear;
  if FCount = 0 then
  begin
    FFirst := Frame;
    SetLength(FNeighbours, Length(FNeighbourHz));
  end;
  Capacity := Length(FBand) div Max(1, FBandProbes);
  if FCount >= Capacity then
  begin
    Capacity := Max(256, Capacity * 2);
    SetLength(FBand, Capacity * FBandProbes);
    for J := 0 to High(FNeighbours) do
      SetLength(FNeighbours[J], Capacity);
  end;
  for P := 0 to FBandProbes - 1 do
    FBand[FCount * FBandProbes + P] := Values[P];
  for J := 0 to High(FNeighbours) do
    FNeighbours[J][FCount] := Values[FBandProbes + J];
  Inc(FCount);
end;

procedure TClickColumnCache.Trim(AudioStart: Double);
var
  Drop, J: Integer;
begin
  { 音の先頭より前のコマは、もう求められません。/ Frames before the start
    of the audio will not be asked for again. }
  Drop := 0;
  while (Drop < FCount) and (LeftOf(FFirst + Drop, AudioStart) < 0) do
    Inc(Drop);
  if Drop = 0 then
    Exit;
  if Drop >= FCount then
  begin
    Clear;
    Exit;
  end;
  FBand := Copy(FBand, Drop * FBandProbes, (FCount - Drop) * FBandProbes);
  for J := 0 to High(FNeighbours) do
    FNeighbours[J] := Copy(FNeighbours[J], Drop, FCount - Drop);
  Inc(FFirst, Drop);
  Dec(FCount, Drop);
end;

function TClickColumnCache.Columns(const Audio: TSingleArray; AudioStart: Double;
  StartSeconds: Double; Frames: Integer): TClickColumns;
var
  Values, Band, Ratios, Prefix: TDoubleArray;
  First, Frame: Int64;
  K, J, P, Probes, Centre, Candidate, Best: Integer;
  Score, BestScore, CentreScore: Double;

  { 両脇（±4〜8 ビン）の平均。/ The mean of the sides (bins 4-8 away). }
  function SideMean(Row, Bin: Integer): Double;
  var
    Base: Integer;
  begin
    Base := Row * (FBandProbes + 1);
    Result := (Prefix[Base + Bin - CLICK_SIDE_NEAR_BINS + 1] -
      Prefix[Base + Bin - CLICK_SIDE_FAR_BINS] +
      Prefix[Base + Bin + CLICK_SIDE_FAR_BINS + 1] -
      Prefix[Base + Bin + CLICK_SIDE_NEAR_BINS]) / (2 * CLICK_SIDE_PROBES);
  end;

begin
  Result.Own := nil;
  Result.Side := nil;
  Result.Neighbours := nil;
  if (FRate <= 0) or (Frames <= 0) or (Length(Audio) = 0) then
    Exit;
  Probes := Length(FCos);
  Values := nil;
  SetLength(Values, Probes);
  Trim(AudioStart);

  { 隣の局が変わったなら、控えたコマの隣の局の列だけを求め直します。
    With new neighbours, only their columns of the kept frames are redone. }
  if FNeighboursStale then
  begin
    FNeighboursStale := False;
    for K := 0 to FCount - 1 do
      if FrameInside(FFirst + K, AudioStart, Length(Audio)) then
      begin
        Probe(Audio, AudioStart, FFirst + K, FBandProbes, Probes - 1, Values);
        for J := 0 to High(FNeighbours) do
          FNeighbours[J][K] := Values[FBandProbes + J];
      end
      else
      begin
        Clear;
        Break;
      end;
  end;

  Band := nil;
  SetLength(Band, Frames * FBandProbes);
  SetLength(Result.Neighbours, Length(FNeighbourHz));
  for J := 0 to High(Result.Neighbours) do
    SetLength(Result.Neighbours[J], Frames);
  First := Round((AudioStart + StartSeconds) / CLICK_HOP_SECONDS);
  for K := 0 to Frames - 1 do
  begin
    Frame := First + K;
    if (FCount > 0) and (Frame >= FFirst) and (Frame < FFirst + FCount) then
    begin
      for P := 0 to FBandProbes - 1 do
        Band[K * FBandProbes + P] := FBand[(Frame - FFirst) * FBandProbes + P];
      for J := 0 to High(Result.Neighbours) do
        Result.Neighbours[J][K] := FNeighbours[J][Frame - FFirst];
      Continue;
    end;
    { 窓がまるごと音の外（復号器が短い音に足す無音）なら 0 です。
      A window wholly outside the audio (the silence the decoder pads a short
      clip with) reads 0. }
    if (LeftOf(Frame, AudioStart) >= Length(Audio)) or
       (LeftOf(Frame, AudioStart) + FWindow <= 0) then
    begin
      for P := 0 to FBandProbes - 1 do
        Band[K * FBandProbes + P] := 0;
      for J := 0 to High(Result.Neighbours) do
        Result.Neighbours[J][K] := 0;
      Continue;
    end;
    Probe(Audio, AudioStart, Frame, 0, Probes - 1, Values);
    for P := 0 to FBandProbes - 1 do
      Band[K * FBandProbes + P] := Values[P];
    for J := 0 to High(Result.Neighbours) do
      Result.Neighbours[J][K] := Values[FBandProbes + J];
    if FrameInside(Frame, AudioStart, Length(Audio)) then
      Store(Frame, Values);
  end;

  { 局の音のビンを、この窓で 1 つ選びます。同調点の周り（±
    `CLICK_OWN_SPAN_BINS`）で、両脇（±4〜8 ビンの平均。付録 CB と同じ）に
    比べて尖っている度合いの上位分位がいちばん高いビン。トーンは同じビンで
    尖り続け、クリックは平らです。**コマごとに選ぶと、雑音だけのときにどこかの
    ビンが偶然尖り、ほとんどのコマを「局の音がある」としてしまった**
    （付録 CI.2）。
    One bin is chosen as the station's tone for this window: around the tuned
    pitch (+/-`CLICK_OWN_SPAN_BINS`), the bin whose upper quantile of
    peakedness against its sides (the mean of the bins 4-8 either side, as in
    appendix CB) is highest. A tone stays peaked in the same bin; a click is
    flat. **Chosen frame by frame, some bin was peaked by chance in noise
    alone, and nearly every frame counted as "the station's tone present"**
    (appendix CI.2). }
  Centre := CLICK_OWN_SPAN_BINS + CLICK_SIDE_FAR_BINS;
  { 両脇の和は、コマごとの累積和から 4 回の引き算で求めます（候補ごとに
    10 回足すより安い）。/ The side sums come from per-frame running sums,
    four subtractions each (cheaper than ten additions per candidate). }
  Prefix := nil;
  SetLength(Prefix, Frames * (FBandProbes + 1));
  for K := 0 to Frames - 1 do
  begin
    Prefix[K * (FBandProbes + 1)] := 0;
    for P := 0 to FBandProbes - 1 do
      Prefix[K * (FBandProbes + 1) + P + 1] :=
        Prefix[K * (FBandProbes + 1) + P] + Band[K * FBandProbes + P];
  end;
  Ratios := nil;
  SetLength(Ratios, Frames);
  Best := Centre;
  BestScore := -1;
  CentreScore := -1;
  for Candidate := Centre - CLICK_OWN_SPAN_BINS to Centre + CLICK_OWN_SPAN_BINS do
  begin
    for K := 0 to Frames - 1 do
      Ratios[K] := Band[K * FBandProbes + Candidate] /
        Max(SideMean(K, Candidate), 1e-12);
    Score := QuantileOf(Ratios, DETECT_TIME_QUANTILE);
    if Candidate = Centre then
      CentreScore := Score;
    { 同じなら同調点に近いほう。/ On a tie, the one nearer the tuned pitch. }
    if (Score > BestScore) or
       ((Score = BestScore) and
        (Abs(Candidate - Centre) < Abs(Best - Centre))) then
    begin
      BestScore := Score;
      Best := Candidate;
    end;
  end;
  { 同調点のビンを優先します。ほかのビンは、はっきり尖っているときだけ選び
    ます。**局が窓の一部でしか鳴っていないと（送り終える前後）、どのビンの
    上位分位も雑音と変わらず、選び方が偶然に左右されて、その局の最後の字を
    消した**（付録 CI.2）。
    The tuned bin is preferred; another is chosen only when clearly more
    peaked. **When the station sounds in only part of the window (around when
    it stops), every bin's upper quantile looks like noise and the choice fell
    to chance, erasing the station's last character** (appendix CI.2). }
  if BestScore < CLICK_OWN_SWITCH_RATIO * CentreScore then
    Best := Centre;
  FOwnBin := Best - Centre;
  SetLength(Result.Own, Frames);
  SetLength(Result.Side, Frames);
  for K := 0 to Frames - 1 do
  begin
    Result.Own[K] := Band[K * FBandProbes + Best];
    Result.Side[K] := SideMean(K, Best);
  end;
end;

end.
