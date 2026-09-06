unit WaterfallView;

{ 受信中の音を、時間と周波数の面として見せる部品です。

  ここは「読みたい信号を選ぶ場所」です。信号をクリックすると、その音程が
  モデルの読める音程へ寄せられ、以後その信号が復号されます。運用者に見える
  のは、クリックした信号が読めるようになることだけです（要件 FR-D.1）。
  ホイールと上下キーで 12.5 Hz ずつ微調整でき（FR-D.2）、いま何を狙って
  いるかは縦線と帯で示します（FR-D.5）。

  描画は、環状に使う 1 枚の画像へ新しい行だけを書き込み、表示のときに 2 回に
  分けて写す方式です。1 行ごとに画像全体を書き直すより軽く済みます。新しい行は
  下に現れ、古い行が上へ流れていきます。

  Shows the received audio as a time-frequency surface.

  This is where the operator picks the signal they want. Clicking a signal
  translates its pitch to one the model can read, and from then on that signal
  is what gets decoded; all the operator sees is that the signal they clicked
  becomes readable (requirement FR-D.1). The wheel and the arrow keys trim it
  in 12.5 Hz steps (FR-D.2), and a line and a band show what is currently
  being aimed at (FR-D.5).

  Only the new row is written into a single image used as a ring, and the
  image is drawn in two pieces, which is cheaper than rewriting the whole
  image for every row. New rows appear at the bottom and older ones flow
  upwards. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Controls, Graphics, Forms, LCLType, IntfGraphics,
  GraphType, FPimage,
  DeepCW.Types, DeepCW.Dsp, DeepCW.Tuner, DeepCW.Decoder;

const
  { ウォーターフォールの高さ（行数）。8000 Hz の録音で約 10 秒ぶんです。
    Waterfall depth in rows; about ten seconds at an 8000 Hz capture. }
  WATERFALL_ROWS = 256;
  { 1 秒あたりの行数。速すぎると目が追えず、遅いと符号の形が見えません。
    Rows per second; faster than this is hard to follow, slower hides the
    shape of the code. }
  WATERFALL_ROWS_PER_SECOND = 25;
  { 表示する周波数の上限。無線機の低周波出力はここまでに収まります。
    Highest frequency shown; receiver audio output stays below this. }
  WATERFALL_TOP_HZ = 3000.0;
  { 周波数の分解能の目安。これに近い FFT 長を 2 の冪から選びます。
    Target frequency resolution; the FFT length is the power of two nearest
    to it. }
  WATERFALL_RESOLUTION_HZ = 8.0;
  { 表示する強さの幅（dB）。雑音の高さを下端に置き、そこから上へこの幅を
    割り当てます。上端を最大値に追従させると、強い局が現れるたびに画面全体の
    明るさが変わってしまい、目が慣れません。

    Displayed dynamic range in decibels, laid out upwards from the noise
    level. Tracking the peak instead would change the brightness of the whole
    display whenever a strong station appears, which the eye never settles
    into. }
  WATERFALL_RANGE_DB = 60.0;

type
  { 帯域にいる 1 局の見出し。**この部品は「どう決めたか」を知りません。**
    名前を決めるのは DeepCW.BandMap、渡すのは画面側です（要件 FR-J.5）。
    強さを持つのは、見出しが重なるときに強い局を優先するためです。

    One station's label. **This control knows nothing of how it was decided**:
    the name comes from DeepCW.BandMap by way of the form (requirement FR-J.5).
    The level is carried so that the stronger station wins when labels collide. }
  TStationLabel = record
    Hz: Double;
    Text: string;
    LevelDb: Double;
  end;
  TStationLabels = array of TStationLabel;

  TWaterfallView = class(TCustomControl)
  private
    FSampleRate: Integer;
    FFFT: TRealFFT;
    FFFTSize: Integer;
    FHop: Integer;
    FWindow: TDoubleArray;
    FColumns: Integer;
    FTopHz: Double;

    { 未処理の入力。FFT 1 回に足りるまで溜めます。
      Input not yet transformed, held until one FFT's worth has arrived. }
    FCarry: TSingleArray;
    FCarryCount: Integer;

    { 画像を環状に使います。FRow が次に書き込む行です。
      The image is used as a ring; FRow is the row written next. }
    FRow: Integer;
    FFilled: Integer;

    { 表示の下端（雑音の高さ、dB）。行ごとの統計から少しずつ動かします。
      Display floor in decibels, the noise level, eased towards the per-row
      statistic. }
    FFloor: Double;
    FHasScale: Boolean;

    FImage: TLazIntfImage;
    FBitmap: TBitmap;
    FImageStale: Boolean;

    FTuneHz: Double;
    { 直近の平均スペクトル。信号追跡はこれを見ます。表示のために毎行 FFT を
      掛けているので、追跡のために新たに変換する必要はありません
      （要件 FR-D.7）。

      A smoothed recent spectrum, which is what signal tracking reads. An FFT
      is already run for every row of the display, so tracking needs no
      transform of its own (requirement FR-D.7). }
    FAverage: TDoubleArray;
    FRowsSinceTrack: Integer;
    { 行の時刻を決めるための帳簿。**独自の時計ではありません。**FBaseSeconds は
      呼び出し側から受け取った基準で、FConsumed は基準からいくつ標本を行に
      変えたかです。
      The books that give a row its time. **Not a clock of its own**:
      FBaseSeconds is the origin handed in by the caller and FConsumed counts the
      samples turned into rows since it. }
    FBaseSeconds: Double;
    FNextSeconds: Double;
    FConsumed: Int64;
    FNewestRowSeconds: Double;
    FChars: TDecodedChars;
    FStations: TStationLabels;
    FShowChars: Boolean;
    FTracking: Boolean;
    { 直前の同調点の変化が、利用者の操作ではなく追跡によるものか。画面側が
      案内文を出すかどうかを決めるのに使います。
      Whether the last change of pitch came from tracking rather than from the
      operator, which is how the form decides whether to say anything. }
    FAutoTuned: Boolean;
    { 直前にクリックされた音程。丸めも範囲の制限も掛けていない値です。
      画面側が「その音程には合わせられない」と案内するために使います
      （要件 FR-D.4）。

      The pitch of the last click, before rounding or clamping. The form uses
      it to explain that a pitch could not be tuned (requirement FR-D.4). }
    FRequestedHz: Double;
    FHalfWidthHz: Double;
    FOnTuneChanged: TNotifyEvent;
    FMessage: string;

    procedure SetShowChars(Value: Boolean);
    procedure DrawCharacters(ScaleTop: Integer);
    procedure DrawStations;
    function SurfaceHeight: Integer;
    procedure Configure(ASampleRate: Integer);
    procedure PushRow(const Magnitudes: TDoubleArray);
    procedure RefreshImage;
    procedure NudgeTune(Steps: Integer);
    { 1 秒に 1 度、信号のいる位置へ同調点を寄せます。
      Once a second, eases the tuned pitch towards where the signal is. }
    procedure FollowSignal;
    { Value を同調先とし、Requested には丸めや範囲の制限を掛ける前の値を残し
      ます。両者が離れているかどうかで、画面側は「寄せた」ことを案内できます。

      Tunes to Value while recording in Requested what was asked for, before
      rounding or clamping. The gap between the two is how the form knows to
      explain that the pitch was moved. }
    procedure ApplyTune(Value, Requested: Double);
    procedure SetTuneHz(Value: Double);
    procedure SetHalfWidthHz(Value: Double);
  protected
    { 周波数と桁の対応。派生クラス（試験の覆い）からも要ります。公開まで広げず、
      protected に留めています。
      The mapping between frequency and column, needed by a descendant (the
      test's shim) as well. Kept protected rather than widened to public. }
    function XToFrequency(X: Integer): Double;
    function FrequencyToX(Hz: Double): Integer;
    { 次の描画で画像を作り直させます。検証用の測定から呼びます。
      Forces the image to be rebuilt on the next paint; called from the
      verification harness. }
    procedure MarkImageStale;
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { 受信した音声を足します。表示できるだけの行が溜まるたびに 1 行進みます。
      Adds received audio; one row is produced whenever enough has arrived. }
    { 音を渡します。StartSeconds は**その先頭の標本が受信開始から何秒目か**です。

      **この部品に時計を持たせません。**渡された時刻が前回の続きでなければ、
      呼び出し側が数え直した（受信のやり直し・ファイルの復号）と見て、こちらも
      数え直します。保管庫（`DeepCW.Review`）と同じ規則です。独自に数えると、
      文字の時刻と行の時刻がいつの間にか食い違い、**重ねた文字が別の場所を指し
      ます**（要件 FR-D.6）。

      Hands over audio. StartSeconds is **how many seconds into the reception
      its first sample falls.**

      **This control keeps no clock of its own.** A time that does not continue
      the last one means the caller restarted its count — a fresh reception, a
      file decode — so counting restarts here too, by the same rule the audio
      store uses (`DeepCW.Review`). Counting independently would let the
      characters' times and the rows' times drift apart, and **the characters
      laid over the display would point at the wrong place**
      (requirement FR-D.6). }
    procedure PushSamples(const Samples: TSingleArray; ASampleRate: Integer;
      StartSeconds: Double);
    procedure Clear;

    { 帯域にいる局の見出しを重ねます（要件 FR-J.5）。渡さなければ何も重なりません。

      **一覧と同じ文字を渡してください。**同じ局を一覧と波形で違う名前で出すと、
      どちらを信じるべきか分かりません。決めるのは DeepCW.BandMap の
      `EntryCaption` 1 か所です。

      Lays labels for the stations in the band over the display
      (requirement FR-J.5); handing over nothing overlays nothing.

      **Hand it the same text the list shows.** The same station named
      differently in the list and on the waterfall leaves no telling which to
      believe; `EntryCaption` in DeepCW.BandMap decides it, once. }
    procedure SetStations(const Value: TStationLabels);

    { 復号した文字を重ねます（要件 FR-D.6）。時刻を持つ文字だけを、その時刻の
      行へ描きます。渡さなければ何も重なりません。
      Lays the decoded characters over the display (requirement FR-D.6): each
      character is drawn on the row for its own time. Handing over nothing
      overlays nothing. }
    procedure SetCharacters(const Value: TDecodedChars);

    { いちばん新しい行の時刻。受信開始からの秒です。
      The newest row's time, in seconds since reception began. }
    function NewestSeconds: Double;
    { その時刻の行が画面のどこに来るか。見えていなければ負を返します。
      Where the row for that time falls on screen, or negative when off it. }
    function SecondsToY(Seconds: Double): Integer;
    { 画面のその高さが、どの時刻の行か。
      Which row's time falls at that height on screen. }
    function SecondsAtY(Y: Integer): Double;

    { 同調している音程。0 で同調なし。設定すると OnTuneChanged を呼びます。
      The tuned pitch, or 0 for none. Setting it raises OnTuneChanged. }
    property TuneHz: Double read FTuneHz write SetTuneHz;
    { 同調時に残す帯域の片側の広さ。帯として重ねて描きます。
      Half-width of the band kept while tuned; drawn as an overlay. }
    property HalfWidthHz: Double read FHalfWidthHz write SetHalfWidthHz;
    { 信号がまだ届いていないときなどに、面の上へ出す案内です。
      Guidance drawn over the surface, e.g. before any audio arrives. }
    property Message_: string read FMessage write FMessage;
    property SampleRate: Integer read FSampleRate;
    { 直前にクリックされた、丸める前の音程。/ The last click, unrounded. }
    property RequestedHz: Double read FRequestedHz;
    { 動いていく信号を自動で追いかけるか。既定で有効です（要件 FR-D.7）。
      Whether to follow a signal that moves; on by default (FR-D.7). }
    property Tracking: Boolean read FTracking write FTracking;
    { 文字を重ねるか。重ねた文字は信号を隠すので、切れるようにしてあります。
      Whether to overlay the characters. They cover the signals, so they can be
      turned off. }
    property ShowCharacters: Boolean read FShowChars write SetShowChars;
    { 直前の変化が追跡によるものか。/ Whether the last change came from
      tracking rather than the operator. }
    property AutoTuned: Boolean read FAutoTuned;
    { 同調できる音程の範囲。案内の文言に使います。
      The range of tunable pitches, for the guidance message. }
    function LowestHz: Double;
    function HighestHz: Double;

    property OnTuneChanged: TNotifyEvent read FOnTuneChanged write FOnTuneChanged;

    property Align;
    property Anchors;
    property BorderSpacing;
    property Font;
    property TabStop;
    property OnMouseMove;
  end;

implementation

{ 振幅 0..255 を色に写します。暗いところから、青、緑、黄、白へ移ります。
  数値の大小が明るさの順に並ぶため、色覚特性によらず読み取れます。

  Maps a magnitude of 0..255 to a colour running from dark through blue,
  green and yellow to white. Because magnitude tracks lightness, the reading
  does not depend on colour vision. }
function WaterfallColour(Level: Byte): TFPColor;
var
  T: Double;
  R, G, B: Integer;
begin
  T := Level / 255;
  if T < 0.35 then
  begin
    R := 0;
    G := Round(40 * T / 0.35);
    B := Round(20 + 150 * T / 0.35);
  end
  else if T < 0.6 then
  begin
    R := 0;
    G := Round(40 + 170 * (T - 0.35) / 0.25);
    B := Round(170 - 90 * (T - 0.35) / 0.25);
  end
  else if T < 0.85 then
  begin
    R := Round(255 * (T - 0.6) / 0.25);
    G := Round(210 + 45 * (T - 0.6) / 0.25);
    B := Round(80 - 80 * (T - 0.6) / 0.25);
  end
  else
  begin
    R := 255;
    G := 255;
    B := Round(255 * (T - 0.85) / 0.15);
  end;
  Result.Red := ClampInt(R, 0, 255) * 257;
  Result.Green := ClampInt(G, 0, 255) * 257;
  Result.Blue := ClampInt(B, 0, 255) * 257;
  Result.Alpha := alphaOpaque;
end;

constructor TWaterfallView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := True;
  FTopHz := WATERFALL_TOP_HZ;
  FHalfWidthHz := 0;
  FTuneHz := 0;
  FTracking := True;
  FAutoTuned := False;
  FMessage := '受信を開始すると、ここに信号が流れます。読みたい信号をクリックしてください。';
  FBitmap := TBitmap.Create;
  Configure(8000);
end;

destructor TWaterfallView.Destroy;
begin
  FreeAndNil(FFFT);
  FreeAndNil(FImage);
  FreeAndNil(FBitmap);
  inherited Destroy;
end;

procedure TWaterfallView.Configure(ASampleRate: Integer);
var
  Size, I, Column: Integer;
  Blank: TFPColor;
begin
  if ASampleRate <= 0 then
    Exit;
  FSampleRate := ASampleRate;
  { 分解能の目安に最も近い 2 の冪を選びます。
    Pick the power of two closest to the wanted resolution. }
  Size := 256;
  while (Size < 8192) and (FSampleRate / Size > WATERFALL_RESOLUTION_HZ) do
    Size := Size * 2;
  FFFTSize := Size;
  FHop := Max(1, Round(FSampleRate / WATERFALL_ROWS_PER_SECOND));
  FreeAndNil(FFFT);
  FFFT := TRealFFT.Create(FFFTSize);
  FWindow := HannWindow(FFFTSize);
  FTopHz := Min(WATERFALL_TOP_HZ, FSampleRate / 2);
  FColumns := Max(2, Trunc(FTopHz * FFFTSize / FSampleRate) + 1);

  SetLength(FCarry, FFFTSize * 2);
  FCarryCount := 0;
  FAverage := nil;
  FRowsSinceTrack := 0;
  FRow := 0;
  FFilled := 0;
  FHasScale := False;

  FreeAndNil(FImage);
  FImage := TLazIntfImage.Create(FColumns, WATERFALL_ROWS, [riqfRGB]);
  Blank := WaterfallColour(0);
  for I := 0 to WATERFALL_ROWS - 1 do
    for Column := 0 to FColumns - 1 do
      FImage.Colors[Column, I] := Blank;
  FImageStale := True;
end;

procedure TWaterfallView.Clear;
var
  I, Column: Integer;
  Blank: TFPColor;
begin
  if FImage <> nil then
  begin
    Blank := WaterfallColour(0);
    for I := 0 to WATERFALL_ROWS - 1 do
      for Column := 0 to FColumns - 1 do
        FImage.Colors[Column, I] := Blank;
  end;
  FRow := 0;
  FFilled := 0;
  FCarryCount := 0;
  FAverage := nil;
  FRowsSinceTrack := 0;
  FHasScale := False;
  FImageStale := True;
  Invalidate;
end;

procedure TWaterfallView.PushRow(const Magnitudes: TDoubleArray);
var
  I: Integer;
  Value, Level, Total, Noise: Double;
begin
  if Length(Magnitudes) = 0 then
    Exit;
  { 強さは dB で扱います。振幅そのままでは、弱い信号がすべて黒に沈みます。
    Work in decibels; on a linear amplitude scale every weak signal is black. }
  Total := 0;
  for I := 0 to High(Magnitudes) do
    Total := Total + 20 * Log10(Magnitudes[I] + 1E-9);
  Noise := Total / Length(Magnitudes);

  { 信号が占めるビンはごく一部なので、平均はほぼ雑音の高さになります。これを
    下端に取ることで、表示の調整を運用者にさせずに済みます（要件 FR-G.1）。

    A signal occupies only a few bins, so the mean sits at the noise level.
    Taking that as the floor means the operator never has to adjust the
    display (requirement FR-G.1). }
  if not FHasScale then
  begin
    FFloor := Noise;
    FHasScale := True;
  end
  else
    { 急に変えると画面が明滅します。ゆっくり追わせます。
      Changing this abruptly makes the display flicker, so it eases across. }
    FFloor := FFloor + (Noise - FFloor) * 0.1;

  for I := 0 to FColumns - 1 do
  begin
    if I <= High(Magnitudes) then
    begin
      Level := 20 * Log10(Magnitudes[I] + 1E-9);
      Value := (Level - FFloor) / WATERFALL_RANGE_DB;
    end
    else
      Value := 0;
    FImage.Colors[I, FRow] := WaterfallColour(ClampInt(Round(255 * Value), 0, 255));
  end;

  { 追跡のために、生の振幅を穏やかに平均します。1 行ごとの絵は符号の断続で
    大きく揺れますが、平均すれば信号のいる位置は安定して見えます。

    For tracking, the raw magnitudes are eased into an average. A single row
    swings wildly as the code keys on and off, but the average shows where the
    signal sits steadily. }
  if Length(FAverage) <> FColumns then
  begin
    SetLength(FAverage, FColumns);
    for I := 0 to FColumns - 1 do
      if I <= High(Magnitudes) then
        FAverage[I] := Magnitudes[I]
      else
        FAverage[I] := 0;
  end
  else
    for I := 0 to FColumns - 1 do
      if I <= High(Magnitudes) then
        FAverage[I] := FAverage[I] + (Magnitudes[I] - FAverage[I]) * 0.08;

  FRow := (FRow + 1) mod WATERFALL_ROWS;
  if FFilled < WATERFALL_ROWS then
    Inc(FFilled);
  FImageStale := True;

  Inc(FRowsSinceTrack);
  if FRowsSinceTrack >= WATERFALL_ROWS_PER_SECOND then
  begin
    FRowsSinceTrack := 0;
    FollowSignal;
  end;
end;

procedure TWaterfallView.FollowSignal;
var
  Wanted: Double;
begin
  if (not FTracking) or (FTuneHz <= 0) or (FFFTSize <= 0) then
    Exit;
  if not TrackTone(FAverage, FSampleRate / FFFTSize, FTuneHz, Wanted) then
    Exit;
  { 追跡による変化であることを控えてから知らせます。画面側は、これを見て
    案内文を出すかどうかを決めます。
    Note that the change came from tracking before announcing it; the form
    reads this to decide whether to say anything. }
  FAutoTuned := True;
  try
    ApplyTune(Wanted, Wanted);
  finally
    FAutoTuned := False;
  end;
end;

procedure TWaterfallView.PushSamples(const Samples: TSingleArray;
  ASampleRate: Integer; StartSeconds: Double);
var
  Frame: TDoubleArray;
  Magnitudes: TDoubleArray;
  I, Taken, Offset, Room, Skip: Integer;
begin
  if Length(Samples) = 0 then
    Exit;
  if (ASampleRate > 0) and (ASampleRate <> FSampleRate) then
    Configure(ASampleRate);
  if FFFT = nil then
    Exit;

  { 渡された時刻が前回の続きか。半標本より離れていれば数え直します。**黙って
    繋げると、以後ずっと文字が別の行を指します。**途中まで溜めた標本も、前の
    時間軸のものなので手放します。
    Whether the time handed in continues the last. More than half a sample apart
    means counting restarts. **Joining them silently would point every character
    at the wrong row from then on.** The partly filled carry belongs to the old
    timeline, so it goes too. }
  if (FFilled = 0) or (Abs(StartSeconds - FNextSeconds) > 0.5 / FSampleRate) then
  begin
    FBaseSeconds := StartSeconds;
    FConsumed := 0;
    FCarryCount := 0;
    FNewestRowSeconds := StartSeconds;
  end;
  FNextSeconds := StartSeconds + Length(Samples) / FSampleRate;

  { 画面に残るのは末尾のぶんだけです。**それを超える量が一度に来たら、超えた分は
    初めから読みません。**書いてすぐ上書きするために FFT を掛けるのは、そのまま
    画面が止まる時間になります（10 分の録音で 1.9 秒）。保管庫が
    「一度に容量を超える量が来たら、その末尾だけを残す」のと同じ考えです。

    Only the tail ever survives on screen. **When more than that arrives at
    once, the excess is never read.** Running an FFT over audio that is
    overwritten immediately turns straight into time the display is frozen --
    1.9 seconds for a ten-minute recording. It is the same reasoning by which
    the audio store keeps only the tail of an oversized block.

    飛ばした分だけ基準を進めるので、行の時刻はずれません。
    The origin moves forward by what was skipped, so the rows keep their
    times. }
  Room := WATERFALL_ROWS * FHop + FFFTSize;
  Skip := 0;
  if Length(Samples) > Room then
  begin
    Skip := Length(Samples) - Room;
    FBaseSeconds := StartSeconds + Skip / FSampleRate;
    FConsumed := 0;
    FCarryCount := 0;
    FNewestRowSeconds := FBaseSeconds;
  end;

  SetLength(Frame, FFFTSize);
  Offset := Skip;
  while Offset < Length(Samples) do
  begin
    Taken := Min(Length(Samples) - Offset, Length(FCarry) - FCarryCount);
    for I := 0 to Taken - 1 do
      FCarry[FCarryCount + I] := Samples[Offset + I];
    Inc(FCarryCount, Taken);
    Inc(Offset, Taken);

    while FCarryCount >= FFFTSize do
    begin
      for I := 0 to FFFTSize - 1 do
        Frame[I] := FCarry[I] * FWindow[I];
      FFFT.MagnitudeSpectrum(Frame, 0, FColumns, Magnitudes);
      { この行が表すのは、いま使った窓の**真ん中**の時刻です。端を採ると、
        窓の長さ（8000 Hz で 128 ms）の半分だけ系統的にずれます。
        The row stands for the time at the **middle** of the window just used.
        Taking an edge would bias every row by half the window — 128 ms at
        8000 Hz. }
      FNewestRowSeconds := FBaseSeconds +
        (FConsumed + FFFTSize / 2) / FSampleRate;
      Inc(FConsumed, FHop);
      PushRow(Magnitudes);
      { ホップぶんだけ捨てます。/ Discard one hop. }
      for I := 0 to FCarryCount - FHop - 1 do
        FCarry[I] := FCarry[I + FHop];
      Dec(FCarryCount, FHop);
      if FCarryCount < 0 then
        FCarryCount := 0;
    end;
  end;
  Invalidate;
end;

function TWaterfallView.XToFrequency(X: Integer): Double;
begin
  if Width <= 1 then
    Exit(0);
  Result := FTopHz * X / (Width - 1);
end;

function TWaterfallView.FrequencyToX(Hz: Double): Integer;
begin
  if FTopHz <= 0 then
    Exit(0);
  Result := Round(Hz / FTopHz * (Width - 1));
end;

{ 画像から描画用のビットマップへ写します。新しい行が来たときだけ行います。
  Copies the image into the bitmap used for drawing, only when a new row has
  arrived. }
procedure TWaterfallView.RefreshImage;
begin
  if FImage = nil then
    Exit;
  FBitmap.LoadFromIntfImage(FImage);
  FImageStale := False;
end;

procedure TWaterfallView.MarkImageStale;
begin
  FImageStale := True;
end;

procedure TWaterfallView.SetShowChars(Value: Boolean);
begin
  if FShowChars = Value then
    Exit;
  FShowChars := Value;
  Invalidate;
end;

procedure TWaterfallView.SetStations(const Value: TStationLabels);
begin
  FStations := Value;
  if FShowChars then
    Invalidate;
end;

procedure TWaterfallView.SetCharacters(const Value: TDecodedChars);
begin
  FChars := Value;
  if FShowChars then
    Invalidate;
end;

function TWaterfallView.NewestSeconds: Double;
begin
  Result := FNewestRowSeconds;
end;

{ 目盛りを除いた、滝の高さ。行から画面への割り付けはここを使います。
  The waterfall's height without the scale; the rows are laid out over it. }
function TWaterfallView.SurfaceHeight: Integer;
begin
  Result := Height - Canvas.TextHeight('0') - 4;
  if Result < 10 then
    Result := Height;
end;

function TWaterfallView.SecondsToY(Seconds: Double): Integer;
var
  RowsBack, Surface: Integer;
begin
  Result := -1;
  Surface := SurfaceHeight;
  if (FFilled = 0) or (Surface <= 0) then
    Exit;
  RowsBack := Round((FNewestRowSeconds - Seconds) * WATERFALL_ROWS_PER_SECOND);
  if (RowsBack < 0) or (RowsBack >= Min(FFilled, WATERFALL_ROWS)) then
    Exit;
  Result := Surface - 1 - Round(RowsBack * Surface / WATERFALL_ROWS);
  if (Result < 0) or (Result >= Surface) then
    Result := -1;
end;

function TWaterfallView.SecondsAtY(Y: Integer): Double;
var
  Surface: Integer;
begin
  Surface := SurfaceHeight;
  if Surface <= 1 then
    Exit(FNewestRowSeconds);
  Result := FNewestRowSeconds -
    ((Surface - 1 - Y) * WATERFALL_ROWS / Surface) / WATERFALL_ROWS_PER_SECOND;
end;

{ 復号した文字を、その時刻の行へ重ねます（要件 FR-D.6）。

  横の位置は同調線の右です。**同調していないときは重ねません。**そのときの
  受信文は受信機の音程のまま読んだもので、どの周波数に属するとも言えないため、
  どこに置いても嘘になります。

  Lays the characters over the rows for their own times (requirement FR-D.6).

  They sit just right of the tuning line. **Nothing is drawn while untuned**:
  the text then comes from whatever pitch the receiver produces and belongs to
  no frequency in particular, so any position would be a lie. }
procedure TWaterfallView.DrawCharacters(ScaleTop: Integer);
var
  I, X, Y, Last: Integer;
begin
  if (not FShowChars) or (Length(FChars) = 0) or (FTuneHz <= 0) then
    Exit;
  X := FrequencyToX(FTuneHz) + 6;
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := clWhite;
  Last := -1000;
  for I := High(FChars) downto 0 do
  begin
    if FChars[I].Text = ' ' then
      Continue;
    Y := SecondsToY(FChars[I].Seconds);
    if Y < 0 then
    begin
      { 並びは時刻の順なので、画面から出たらそれより前も出ています。
        The characters are in time order, so once one is off the top the rest
        are too. }
      if FChars[I].Seconds < FNewestRowSeconds then
        Break
        else
        Continue;
    end;
    { 同調の数字は上端に出ます。そこへ文字を描くと重なって、どちらも読めなく
      なります。上端のその高さぶんは空けます。
      The tuned frequency is written at the top; a character there overprints it
      and neither can be read. That much of the top is left alone. }
    if Y < Canvas.TextHeight('M') + 4 then
      Continue;
    { 同じ行に重ねて描くと潰れます。1 文字ぶんの高さを空けます。
      Two characters on one row would overprint; a character's height is kept
      between them. }
    if Abs(Y - Last) < Canvas.TextHeight('M') then
      Continue;
    Canvas.TextOut(X, Y - Canvas.TextHeight('M') div 2, FChars[I].Text);
    Last := Y;
  end;
end;

{ 帯域にいる局の見出しを、その音程の上に並べます（要件 FR-J.5）。

  **横の位置がこの機能そのものです。**受入基準は同調誤差と同じ 1 ビン（12.5 Hz）
  以内で、`FrequencyToX` は同調線と同じ変換なので、線と見出しは必ず同じ桁に立ちます。

  見出しは上端に置きます。**強い局から順に置き、重なるものは飛ばします。**24 局が
  100 Hz 間隔で並ぶと、見出しの幅（6 文字ぶん）に対して間隔が足りません。**全部を
  無理に描くと読めない塊になり、どれがどれか分からなくなります。**飛ばした局も
  一覧には残っているので、失われる情報はありません。

  Lays labels for the stations in the band above their pitches
  (requirement FR-J.5).

  **The horizontal position is the feature.** The acceptance is one bin
  (12.5 Hz), the same as the tuning error, and `FrequencyToX` is the very
  transform the tuning line uses, so the line and a label always stand in the
  same column.

  The labels sit at the top. **The strongest go first and anything that would
  overlap is skipped.** Twenty-four stations at 100 Hz spacing leave less room
  than a six-character label needs; **drawn regardless they become an unreadable
  clump in which nothing can be told apart.** What is skipped is still in the
  list, so nothing is lost. }
procedure TWaterfallView.DrawStations;
var
  Order: array of Integer;
  Taken: array of Integer;
  I, J, Best, Swap, Count, X, From_, To_, Y, Width_: Integer;
begin
  if (not FShowChars) or (Length(FStations) = 0) then
    Exit;

  { 強い順に並べます。局は多くて 24 なので、単純な選択で足ります。
    Ordered by strength; there are at most twenty-four, so a plain selection
    sort is enough. }
  SetLength(Order, Length(FStations));
  for I := 0 to High(Order) do
    Order[I] := I;
  for I := 0 to High(Order) - 1 do
  begin
    Best := I;
    for J := I + 1 to High(Order) do
      if FStations[Order[J]].LevelDb > FStations[Order[Best]].LevelDb then
        Best := J;
    if Best <> I then
    begin
      Swap := Order[I];
      Order[I] := Order[Best];
      Order[Best] := Swap;
    end;
  end;

  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := clWhite;
  Y := 2;
  Count := 0;
  SetLength(Taken, Length(FStations) * 2);
  for I := 0 to High(Order) do
  begin
    if FStations[Order[I]].Text = '' then
      Continue;
    Width_ := Canvas.TextWidth(FStations[Order[I]].Text);
    X := FrequencyToX(FStations[Order[I]].Hz);
    { 見出しは音程の上に中央を合わせます。端では画面の中へ寄せます。
      Centred on the pitch, pulled inside the display at the edges. }
    From_ := Max(0, Min(Width - Width_ - 1, X - Width_ div 2));
    To_ := From_ + Width_;
    J := 0;
    while J < Count do
    begin
      { 2 画素の隙間を要ります。隣り合った見出しは、間が無いと 1 語に見えます。
        Two pixels of gap are required: touching labels read as one word. }
      if (From_ < Taken[J * 2 + 1] + 2) and (To_ + 2 > Taken[J * 2]) then
        Break;
      Inc(J);
    end;
    if J < Count then
      Continue;
    { どの信号の見出しかが分かるよう、音程へ短い線を下ろします。
      A short line drops to the pitch, so which signal the label names is
      visible. }
    Canvas.Pen.Color := clWhite;
    Canvas.Pen.Width := 1;
    Canvas.Line(X, Y + Canvas.TextHeight('M'), X, Y + Canvas.TextHeight('M') + 4);
    Canvas.TextOut(From_, Y, FStations[Order[I]].Text);
    Taken[Count * 2] := From_;
    Taken[Count * 2 + 1] := To_;
    Inc(Count);
  end;
end;

procedure TWaterfallView.Paint;
var
  TickHz: Double;
  X, ScaleTop, BandLeft, BandRight, Older, Split: Integer;
  Caption_: string;
begin
  Canvas.Brush.Color := clBlack;
  Canvas.FillRect(0, 0, Width, Height);
  ScaleTop := Height - Canvas.TextHeight('0') - 4;
  if ScaleTop < 10 then
    ScaleTop := Height;

  if FFilled = 0 then
  begin
    Canvas.Font.Color := clSilver;
    Canvas.TextOut(8, 8, FMessage);
  end
  else
  begin
    if FImageStale then
      RefreshImage;
    { 環の切れ目で 2 つに分けて写します。古い行が上、新しい行が下です。
      Drawn in two pieces split at the ring's seam: older rows above, newer
      rows below. }
    Older := WATERFALL_ROWS - FRow;
    Split := Round(ScaleTop * Older / WATERFALL_ROWS);
    if Older > 0 then
      Canvas.CopyRect(Rect(0, 0, Width, Split), FBitmap.Canvas,
        Rect(0, FRow, FColumns, WATERFALL_ROWS));
    if FRow > 0 then
      Canvas.CopyRect(Rect(0, Split, Width, ScaleTop), FBitmap.Canvas,
        Rect(0, 0, FColumns, FRow));
  end;

  DrawCharacters(ScaleTop);
  DrawStations;

  { 目盛り。500 Hz ごとに刻みます。/ Ticks every 500 Hz. }
  Canvas.Pen.Color := clGray;
  Canvas.Font.Color := clSilver;
  TickHz := 500;
  while TickHz < FTopHz do
  begin
    X := FrequencyToX(TickHz);
    Canvas.Line(X, ScaleTop, X, ScaleTop + 3);
    Canvas.TextOut(Max(0, X - 12), ScaleTop + 3, IntToStr(Round(TickHz)));
    TickHz := TickHz + 500;
  end;

  if FTuneHz > 0 then
  begin
    { 残している帯域を薄く塗り、狙っている音程に線を引きます。
      Shade the band being kept and draw a line at the pitch being aimed at. }
    if FHalfWidthHz > 0 then
    begin
      BandLeft := FrequencyToX(FTuneHz - FHalfWidthHz);
      BandRight := FrequencyToX(FTuneHz + FHalfWidthHz);
      Canvas.Pen.Color := clNavy;
      Canvas.Line(BandLeft, 0, BandLeft, ScaleTop);
      Canvas.Line(BandRight, 0, BandRight, ScaleTop);
    end;
    X := FrequencyToX(FTuneHz);
    Canvas.Pen.Color := clYellow;
    Canvas.Line(X, 0, X, ScaleTop);
    Canvas.Font.Color := clYellow;
    Caption_ := Format('%.0f Hz', [FTuneHz]);
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(Min(Width - Canvas.TextWidth(Caption_) - 2, X + 4), 2, Caption_);
    Canvas.Brush.Style := bsSolid;
  end;

  if Focused then
  begin
    Canvas.Pen.Color := clWhite;
    Canvas.Brush.Style := bsClear;
    Canvas.Rectangle(0, 0, Width, Height);
    Canvas.Brush.Style := bsSolid;
  end;
end;

function TWaterfallView.LowestHz: Double;
begin
  Result := LowestTunable(FSampleRate);
end;

function TWaterfallView.HighestHz: Double;
begin
  Result := HighestTunable(FSampleRate);
end;

procedure TWaterfallView.ApplyTune(Value, Requested: Double);
var
  Wanted: Double;
begin
  if Value <= 0 then
    Wanted := 0
  else
    Wanted := QuantizeTone(ClampDouble(Value, LowestTunable(FSampleRate),
      HighestTunable(FSampleRate)));
  FRequestedHz := Requested;
  if Abs(Wanted - FTuneHz) < 0.01 then
    Exit;
  FTuneHz := Wanted;
  Invalidate;
  if Assigned(FOnTuneChanged) then
    FOnTuneChanged(Self);
end;

procedure TWaterfallView.SetTuneHz(Value: Double);
begin
  { 求められた値そのものが希望でもあるため、案内は出ません。
    The value asked for is also what was wanted, so no guidance follows. }
  ApplyTune(Value, Value);
end;

procedure TWaterfallView.SetHalfWidthHz(Value: Double);
begin
  if Abs(Value - FHalfWidthHz) < 0.01 then
    Exit;
  FHalfWidthHz := Value;
  Invalidate;
end;

procedure TWaterfallView.NudgeTune(Steps: Integer);
var
  Wanted: Double;
begin
  if FTuneHz <= 0 then
    Exit;
  Wanted := FTuneHz + Steps * TUNER_STEP_HZ;
  ApplyTune(Wanted, Wanted);
end;

procedure TWaterfallView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Wanted: Double;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus then
    SetFocus;
  if Button = mbLeft then
  begin
    Wanted := XToFrequency(X);
    { 範囲へ寄せてから渡します。0 は「同調しない」の意味を持つため、左端に
      近いクリックをそのまま渡すと、同調するつもりが解除になります。

      Clamp before handing it over: 0 means "not tuned", so passing a click
      near the left edge straight through would clear the tuning when the
      operator meant to set it. }
    ApplyTune(ClampDouble(Wanted, LowestTunable(FSampleRate),
      HighestTunable(FSampleRate)), Wanted);
  end
  else if Button = mbRight then
    SetTuneHz(0);
end;

function TWaterfallView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  if FTuneHz <= 0 then
    Exit(inherited DoMouseWheel(Shift, WheelDelta, MousePos));
  NudgeTune(Sign(WheelDelta));
  Result := True;
end;

procedure TWaterfallView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_UP, VK_RIGHT:
      begin
        NudgeTune(1);
        Key := 0;
      end;
    VK_DOWN, VK_LEFT:
      begin
        NudgeTune(-1);
        Key := 0;
      end;
    VK_ESCAPE:
      begin
        SetTuneHz(0);
        Key := 0;
      end;
  else
    inherited KeyDown(Key, Shift);
  end;
end;

end.
