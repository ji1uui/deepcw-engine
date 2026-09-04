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
  end;
  TStations = array of TStation;

{ 広帯域スペクトログラムから局を見つけます。音程の昇順で返します。

  昇順で返すのは、隣との距離を求めるのがこの順でしか成り立たないからです。
  強い順が要る場合（要件 FR-I.7）は、受け取った側で並べ替えてください。

  Finds the stations in a wide spectrogram, returned in ascending pitch order,
  because the distance to a neighbour is only defined in that order. Sort a copy
  where descending level is wanted (requirement FR-I.7). }
function DetectStations(const Wide: TSpectrogram; WideRate: Integer): TStations;

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

function DetectStations(const Wide: TSpectrogram; WideRate: Integer): TStations;
var
  BinHz: Double;
  FirstBin, LastBin, Radius, FloorBins: Integer;
  Bin, Frame, Window, WindowFirst, WindowLast, I, Count: Integer;
  Column, Neighbourhood: TDoubleArray;
  Level, Floor_, Statistic: TDoubleArray;
  Peak: Boolean;
begin
  Result := nil;
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
    Inc(Count);
  end;
  SetLength(Result, Count);
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

end.
