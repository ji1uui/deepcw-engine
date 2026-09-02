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
  DeepCW.Types, DeepCW.Dsp, DeepCW.Tuner;

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
    { 直前にクリックされた音程。丸めも範囲の制限も掛けていない値です。
      画面側が「その音程には合わせられない」と案内するために使います
      （要件 FR-D.4）。

      The pitch of the last click, before rounding or clamping. The form uses
      it to explain that a pitch could not be tuned (requirement FR-D.4). }
    FRequestedHz: Double;
    FHalfWidthHz: Double;
    FOnTuneChanged: TNotifyEvent;
    FMessage: string;

    procedure Configure(ASampleRate: Integer);
    procedure PushRow(const Magnitudes: TDoubleArray);
    function XToFrequency(X: Integer): Double;
    function FrequencyToX(Hz: Double): Integer;
    procedure RefreshImage;
    procedure NudgeTune(Steps: Integer);
    { Value を同調先とし、Requested には丸めや範囲の制限を掛ける前の値を残し
      ます。両者が離れているかどうかで、画面側は「寄せた」ことを案内できます。

      Tunes to Value while recording in Requested what was asked for, before
      rounding or clamping. The gap between the two is how the form knows to
      explain that the pitch was moved. }
    procedure ApplyTune(Value, Requested: Double);
    procedure SetTuneHz(Value: Double);
    procedure SetHalfWidthHz(Value: Double);
  protected
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
    procedure PushSamples(const Samples: TSingleArray; ASampleRate: Integer);
    procedure Clear;

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

  FRow := (FRow + 1) mod WATERFALL_ROWS;
  if FFilled < WATERFALL_ROWS then
    Inc(FFilled);
  FImageStale := True;
end;

procedure TWaterfallView.PushSamples(const Samples: TSingleArray;
  ASampleRate: Integer);
var
  Frame: TDoubleArray;
  Magnitudes: TDoubleArray;
  I, Taken, Offset: Integer;
begin
  if Length(Samples) = 0 then
    Exit;
  if (ASampleRate > 0) and (ASampleRate <> FSampleRate) then
    Configure(ASampleRate);
  if FFFT = nil then
    Exit;

  SetLength(Frame, FFFTSize);
  Offset := 0;
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
