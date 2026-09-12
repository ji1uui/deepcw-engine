unit HistogramView;

{ 送信した符号の長さの分布を見せる部品です（要件 FR-H.9）。

  **点数は「どれだけ離れているか」を 1 つの数にしたものです。**その元になった
  分布を見せると、**なぜその点数なのかが目で分かります。**符号内の間隔と
  文字間の山が重なっていれば、区切りの明瞭が低い理由はそれです。

  左に音（短点・長点）、右に無音（符号内・文字間・語間）を、**同じ横軸**で
  並べます。比べたいのはそれぞれの中での重なりであり、音と無音を重ねても
  読み取るものがありません。

  横軸は短点いくつぶんかです。**秒で描くと、速度を変えたときに同じ癖が別の形に
  見えます。**目安（1・3・7）に縦線を引き、自分の山がそこからどれだけずれて
  いるかが分かるようにします。

  この部品は**受け取ったものをそのまま描くだけ**で、数えるのは `DeepCW.Fist`
  です（`TrendView` と同じ考え方）。

  A control showing how long the sent elements were (requirement FR-H.9).

  **A score is how far apart things are, reduced to one number.** Showing the
  distributions behind it **makes the reason visible**: where the gap inside a
  character overlaps the gap between characters, that is why the break between
  characters scores low.

  Sound on the left (dit, dah) and silence on the right (inside, between
  characters, between words), **on one shared axis**: what is worth comparing is
  the overlap within each, and laying sound over silence would leave nothing to
  read.

  The axis is in dits. **Drawn in seconds, the same habit would look like a
  different shape at another speed.** Marks at one, three and seven show how far
  a hand sits from them.

  The control **draws what it is handed**; the counting lives in `DeepCW.Fist`,
  as it does for `TrendView`. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Controls, Graphics, Forms,
  DeepCW.Types, DeepCW.Fist, ViewColors;

type
  TFistHistogramView = class(TCustomControl)
  private
    FMeasurement: TFistMeasurement;
    FEmptyMessage: string;
    FMeasure: TBitmap;
    FUnit: Integer;
    FTarget: TCanvas;
    FWidth: Integer;
    FHeight: Integer;
    function Target_: TCanvas;
    procedure MeasureFont;
    { 1 つの区画に、指定した種別の山を重ねて描きます。
      Draws the named kinds over one another inside one panel. }
    procedure DrawPanel(Left_, Right_: Integer; const Title: string;
      const Kinds: array of TElementKind; const Marks: array of Double);
  protected
    procedure Paint; override;
    procedure FontChanged(Sender: TObject); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { 測定を差し替えます。要素を持たない測定を渡すと、何も描きません。
      Replaces the measurement; one without elements draws nothing. }
    procedure SetMeasurement(const Value: TFistMeasurement);
    { 与えられた画布へ描きます。**画面もここを通ります**（教訓 10.37）。
      Draws onto the canvas given; **the screen comes through here too**
      (lesson 10.37). }
    procedure DrawTo(ACanvas: TCanvas; AWidth, AHeight: Integer);
    function Count: Integer;
    property EmptyMessage: string read FEmptyMessage write FEmptyMessage;
  end;

{ 種別ごとの色。**同じ種別はいつも同じ色**でなければ、前に見た絵と比べられません。
  The colour of each kind: **the same kind always in the same colour**, or it
  could not be compared with the picture seen last time. }
function ElementColor(Kind: TElementKind): TColor;

implementation

const
  { 目盛りの縦線を引く位置（短点いくつぶんか）。
    Where the marks go, in dits. }
  TONE_MARKS: array[0..1] of Double = (1, 3);
  GAP_MARKS: array[0..2] of Double = (1, 3, 7);

function ElementColor(Kind: TElementKind): TColor;
begin
  case Kind of
    ekDit: Result := TColor($00C08000);    { 青 }
    ekDah: Result := TColor($000080FF);    { 橙 }
    ekIntra: Result := TColor($0060A000);  { 緑 }
    ekChar: Result := TColor($00B000B0);   { 紫 }
    ekWord: Result := TColor($00303030);   { 濃い灰 }
  else
    Result := clGray;
  end;
end;

constructor TFistHistogramView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  Color := clWindow;
  FEmptyMessage :=
    '訓練を 1 回終えると、ここに符号の長さの分布が出ます。';
  FMeasure := TBitmap.Create;
  FMeasure.SetSize(1, 1);
  MeasureFont;
end;

destructor TFistHistogramView.Destroy;
begin
  FMeasure.Free;
  inherited Destroy;
end;

procedure TFistHistogramView.MeasureFont;
begin
  FMeasure.Canvas.Font.Assign(Font);
  FUnit := Max(6, FMeasure.Canvas.TextWidth('0'));
end;

procedure TFistHistogramView.FontChanged(Sender: TObject);
begin
  inherited FontChanged(Sender);
  MeasureFont;
  Invalidate;
end;

function TFistHistogramView.Target_: TCanvas;
begin
  if FTarget <> nil then
    Result := FTarget
  else
    Result := Canvas;
end;

procedure TFistHistogramView.SetMeasurement(const Value: TFistMeasurement);
begin
  FMeasurement := Value;
  Invalidate;
end;

function TFistHistogramView.Count: Integer;
begin
  Result := Length(FMeasurement.Elements);
end;

procedure TFistHistogramView.DrawPanel(Left_, Right_: Integer;
  const Title: string; const Kinds: array of TElementKind;
  const Marks: array of Double);
var
  Counts: TCounts;
  Highest, I, K, X, Y, Top_, Bottom_, BarWidth, Legend: Integer;
  Caption_: string;
begin
  Top_ := FMeasure.Canvas.TextHeight('0') + 8;
  Bottom_ := FHeight - 2 * (FMeasure.Canvas.TextHeight('0') + 6);
  if Bottom_ <= Top_ then
    Exit;

  Target_.Font.Color := Font.Color;
  Target_.TextOut(Left_, 2, Title);

  { 山の高さは、**この区画の中でいちばん多い升**に合わせます。音と無音で
    数が違うため、全体で合わせると片方が潰れます。
    The height is scaled to the tallest bucket **in this panel**: sound and
    silence differ in number, and one scale for both would flatten one of
    them. }
  Highest := 1;
  for K := 0 to High(Kinds) do
  begin
    Counts := Histogram(FMeasurement.Elements, Kinds[K], FMeasurement.DitSeconds);
    for I := 0 to High(Counts) do
      if Counts[I] > Highest then
        Highest := Counts[I];
  end;

  { 目安の縦線。**自分の山がそこからどれだけずれているかが分かります。**
    The marks: **how far a hand sits from them.** }
  Target_.Pen.Color := BlendColor(Color, Font.Color, 0.25);
  Target_.Pen.Style := psDot;
  for I := 0 to High(Marks) do
  begin
    X := Left_ + Round((Right_ - Left_) * Marks[I] / FIST_HISTOGRAM_MAX_UNITS);
    Target_.Line(X, Top_, X, Bottom_);
    Caption_ := IntToStr(Round(Marks[I]));
    Target_.Font.Color := BlendColor(Color, Font.Color, 0.55);
    Target_.TextOut(X + 2, Bottom_ + 2, Caption_);
  end;
  Target_.Pen.Style := psSolid;

  { 横軸（0 の線）。/ The baseline. }
  Target_.Pen.Color := BlendColor(Color, Font.Color, 0.35);
  Target_.Line(Left_, Bottom_, Right_, Bottom_);

  BarWidth := Max(1, (Right_ - Left_) div FIST_HISTOGRAM_BUCKETS);
  Legend := FHeight - FMeasure.Canvas.TextHeight('0') - 2;
  X := Left_;
  for K := 0 to High(Kinds) do
  begin
    Counts := Histogram(FMeasurement.Elements, Kinds[K], FMeasurement.DitSeconds);
    { **塗り潰しません。**重なりが見えなくなります。枠線だけで描けば、
      2 つの山が重なっているところがそのまま見えます。
      **Not filled**: a filled bar hides what lies behind it. Outlines leave the
      overlap of two distributions visible, which is the whole point. }
    Target_.Pen.Color := ElementColor(Kinds[K]);
    Target_.Brush.Style := bsClear;
    for I := 0 to High(Counts) do
    begin
      if Counts[I] = 0 then
        Continue;
      Y := Bottom_ - Round((Bottom_ - Top_) * Counts[I] / Highest);
      Target_.Rectangle(
        Left_ + Round((Right_ - Left_) * I / FIST_HISTOGRAM_BUCKETS), Y,
        Left_ + Round((Right_ - Left_) * I / FIST_HISTOGRAM_BUCKETS) + BarWidth,
        Bottom_ + 1);
    end;

    { 凡例 / the legend }
    Target_.Brush.Color := ElementColor(Kinds[K]);
    Target_.Brush.Style := bsSolid;
    Target_.FillRect(X, Legend + 5, X + FUnit, Legend + 9);
    Target_.Brush.Style := bsClear;
    Target_.Font.Color := Font.Color;
    Target_.TextOut(X + FUnit + 3, Legend, FIST_ELEMENT_NAMES[Kinds[K]]);
    Inc(X, FUnit + 6 + Target_.TextWidth(FIST_ELEMENT_NAMES[Kinds[K]]) + FUnit);
  end;
end;

procedure TFistHistogramView.Paint;
begin
  DrawTo(Canvas, ClientWidth, ClientHeight);
end;

procedure TFistHistogramView.DrawTo(ACanvas: TCanvas; AWidth, AHeight: Integer);
var
  Middle: Integer;
begin
  FTarget := ACanvas;
  FWidth := AWidth;
  FHeight := AHeight;
  try
    Target_.Brush.Color := Color;
    Target_.Brush.Style := bsSolid;
    Target_.FillRect(0, 0, FWidth, FHeight);
    Target_.Brush.Style := bsClear;
    Target_.Font.Assign(Font);

    if (Length(FMeasurement.Elements) = 0) or (FMeasurement.DitSeconds <= 0) then
    begin
      Target_.Font.Color := BlendColor(Color, Font.Color, 0.55);
      Target_.TextOut(6, 6, FEmptyMessage);
      Exit;
    end;

    Middle := FWidth div 2;
    DrawPanel(8, Middle - 12, '音の長さ（短点いくつぶん）',
      [ekDit, ekDah], TONE_MARKS);
    DrawPanel(Middle + 8, FWidth - 8, '間隔の長さ（短点いくつぶん）',
      [ekIntra, ekChar, ekWord], GAP_MARKS);
  finally
    FTarget := nil;
  end;
end;

end.
