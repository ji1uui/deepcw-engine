unit TrendView;

{ 送信訓練の点数の推移を折れ線で見せる部品です（要件 FR-H.10）。

  **1 回の点数は、その日の調子です。**上達したかどうかは、並べてはじめて
  分かります。5 点の改善が誤差ではないことは測ってある（付録 AG.4、同じ技量で
  種を変えたときの標準偏差 3.0 点）ので、**線の上下には意味があります。**

  この部品は**受け取ったものをそのまま描くだけ**で、解釈はしません。どの記録を
  並べるか（鍵の種類で絞る）も、どの項目を出すかも、`DeepCW.FistLog` が決めた
  結果を読むだけです。**描く側が判断を持つと、画面を見なければ検証できなく
  なります**（`BandMapView` と同じ考え方）。

  A control that shows how the send-practice scores move, as a line
  (requirement FR-H.10).

  **One session's score is how that day went.** Whether anything improved only
  appears once they are put side by side -- and since an improvement of five
  points has been measured not to be noise (appendix AG.4: a standard deviation
  of 3.0 points across seeds at one skill), **the rise and fall of the line
  means something.**

  This control **draws what it is handed and interprets nothing**: which records
  to line up (narrowed by the kind of key) and which item to show are decided in
  `DeepCW.FistLog`. **Judgement in the drawing code could only be verified by
  looking at the screen** -- the same reasoning as `BandMapView`. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Controls, Graphics, Forms,
  DeepCW.Types, DeepCW.FistLog, ViewColors;

type
  TFistTrendView = class(TCustomControl)
  private
    FItems: TFistRecords;
    FShown: TFistItems;
    FEmptyMessage: string;
    FMeasure: TBitmap;
    FUnit: Integer;
    { 描く先。**画面に描くときも、試験で画布へ描くときも同じ道を通します。**
      `PaintTo` は、この種の部品では中身を描きません（付録 S.7）。描く道が
      1 本でなければ、**確かめた絵と画面に出る絵が別物になります。**
      Where the drawing goes. **The same path serves the screen and a bitmap in
      a test**: `PaintTo` draws no content for a control like this one
      (appendix S.7), and with two paths **what was checked would not be what
      appears.** }
    FTarget: TCanvas;
    FWidth: Integer;
    FHeight: Integer;
    function Target: TCanvas;
    function PlotLeft: Integer;
    function PlotTop: Integer;
    function PlotRight: Integer;
    function PlotBottom: Integer;
    function XOf(Index: Integer): Integer;
    function YOf(Score: Double): Integer;
    procedure MeasureFont;
    procedure DrawGrid;
    procedure DrawLine_(Which: TFistItem);
    procedure DrawLegend;
  protected
    procedure Paint; override;
    procedure FontChanged(Sender: TObject); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { 並べる記録を差し替えます。**古い順**に渡してください。
      Replaces the records shown; hand them over **oldest first.** }
    procedure SetItems(const Value: TFistRecords);
    { 出す項目。空なら総合だけを出します。
      Which items to show; empty shows the overall alone. }
    procedure SetShown(const Value: TFistItems);
    { 与えられた画布へ、与えられた大きさで描きます。**画面もここを通ります。**
      Draws onto the canvas given, at the size given. **The screen comes through
      here too.** }
    procedure DrawTo(ACanvas: TCanvas; AWidth, AHeight: Integer);
    function Count: Integer;
    property EmptyMessage: string read FEmptyMessage write FEmptyMessage;
  end;

{ 項目ごとの色。**同じ項目はいつも同じ色**でなければ、前に見た絵と比べられません。
  The colour of each item: **the same item always in the same colour**, or it
  could not be compared with the picture seen last time. }
function ItemColor(Which: TFistItem): TColor;

implementation

const
  { 目盛りは 0 から 100 まで。**点数の幅に合わせて伸び縮みさせません。**
    伸ばすと、1 点の違いが大きな山に見えます。
    The scale runs from nought to a hundred and **does not stretch to fit**:
    stretched, a difference of one point would look like a mountain. }
  SCORE_LOW = 0;
  SCORE_HIGH = 100;
  GRID_STEP = 25;
  MARKER = 3;

function ItemColor(Which: TFistItem): TColor;
begin
  case Which of
    fiSpeed: Result := TColor($00C08000);       { 青緑 }
    fiClarity: Result := TColor($000080FF);     { 橙 }
    fiSeparation: Result := TColor($00400080);  { 紫 }
    fiSpacing: Result := TColor($0060A000);     { 緑 }
    { **灰は使いません。**文字の縁を滑らかにする処理が中間の灰を作るため、
      画素で確かめる試験が、線と文字を見分けられなくなります。
      **Not grey**: anti-aliased text makes greys of its own, and a test that
      counts pixels could not then tell a line from a letter. }
    fiCopyability: Result := TColor($00B000B0); { 紫 }
  else
    Result := TColor($00202020);                { 総合は濃く }
  end;
end;

constructor TFistTrendView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  Color := clWindow;
  FShown := [fiOverall];
  FEmptyMessage := 'まだ記録がありません。訓練を 1 回終えると、ここに推移が出ます。';
  FMeasure := TBitmap.Create;
  FMeasure.SetSize(1, 1);
  MeasureFont;
end;

destructor TFistTrendView.Destroy;
begin
  FMeasure.Free;
  inherited Destroy;
end;

procedure TFistTrendView.MeasureFont;
begin
  FMeasure.Canvas.Font.Assign(Font);
  FUnit := Max(6, FMeasure.Canvas.TextWidth('0'));
end;

procedure TFistTrendView.FontChanged(Sender: TObject);
begin
  inherited FontChanged(Sender);
  MeasureFont;
  Invalidate;
end;

procedure TFistTrendView.SetItems(const Value: TFistRecords);
begin
  FItems := Value;
  Invalidate;
end;

procedure TFistTrendView.SetShown(const Value: TFistItems);
begin
  if Value = [] then
    FShown := [fiOverall]
  else
    FShown := Value;
  Invalidate;
end;

function TFistTrendView.Count: Integer;
begin
  Result := Length(FItems);
end;

function TFistTrendView.Target: TCanvas;
begin
  if FTarget <> nil then
    Result := FTarget
  else
    Result := Canvas;
end;

function TFistTrendView.PlotLeft: Integer;
begin
  { 左は目盛りの数字の幅だけ空けます。/ Room for the scale's numbers. }
  Result := 4 * FUnit;
end;

function TFistTrendView.PlotTop: Integer;
begin
  Result := 8;
end;

function TFistTrendView.PlotRight: Integer;
begin
  Result := Max(PlotLeft + 1, FWidth - 8);
end;

function TFistTrendView.PlotBottom: Integer;
begin
  { 下は日付と凡例の 2 行ぶんを空けます。
    Room at the foot for the dates and the legend. }
  Result := Max(PlotTop + 1, FHeight - 2 * (FMeasure.Canvas.TextHeight('0') + 4));
end;

function TFistTrendView.XOf(Index: Integer): Integer;
begin
  if Length(FItems) <= 1 then
    Exit((PlotLeft + PlotRight) div 2);
  Result := PlotLeft +
    Round((PlotRight - PlotLeft) * Index / (Length(FItems) - 1));
end;

function TFistTrendView.YOf(Score: Double): Integer;
begin
  Score := ClampDouble(Score, SCORE_LOW, SCORE_HIGH);
  Result := PlotBottom -
    Round((PlotBottom - PlotTop) * (Score - SCORE_LOW) / (SCORE_HIGH - SCORE_LOW));
end;

procedure TFistTrendView.DrawGrid;
var
  Score: Integer;
  Y: Integer;
  Caption_: string;
begin
  Target.Pen.Style := psSolid;
  Target.Pen.Width := 1;
  Score := SCORE_LOW;
  while Score <= SCORE_HIGH do
  begin
    Y := YOf(Score);
    Target.Pen.Color := BlendColor(Color, Font.Color, 0.15);
    Target.Line(PlotLeft, Y, PlotRight, Y);
    Target.Font.Color := BlendColor(Color, Font.Color, 0.55);
    Caption_ := IntToStr(Score);
    Target.TextOut(PlotLeft - 4 - Target.TextWidth(Caption_),
      Y - Target.TextHeight(Caption_) div 2, Caption_);
    Inc(Score, GRID_STEP);
  end;

  { 端の日付だけを書きます。**すべて書くと読めません。**
    Only the dates at the ends: **all of them could not be read.** }
  if Length(FItems) > 0 then
  begin
    Target.Font.Color := BlendColor(Color, Font.Color, 0.55);
    Caption_ := FormatDateTime('mm"/"dd', FItems[0].When_);
    Target.TextOut(PlotLeft, PlotBottom + 3, Caption_);
    if Length(FItems) > 1 then
    begin
      Caption_ := FormatDateTime('mm"/"dd', FItems[High(FItems)].When_);
      Target.TextOut(PlotRight - Target.TextWidth(Caption_), PlotBottom + 3,
        Caption_);
    end;
  end;
end;

procedure TFistTrendView.DrawLine_(Which: TFistItem);
var
  I, X, Y, LastX, LastY: Integer;
  Value: Double;
  Started: Boolean;
begin
  Target.Pen.Color := ItemColor(Which);
  Target.Brush.Color := ItemColor(Which);
  Target.Brush.Style := bsSolid;
  { 総合は太く描きます。**どれが総合かが、色を覚えていなくても分かります。**
    The overall is drawn thicker, **so which line it is can be told without
    remembering the colours.** }
  if Which = fiOverall then
    Target.Pen.Width := 2
  else
    Target.Pen.Width := 1;

  Started := False;
  LastX := 0;
  LastY := 0;
  for I := 0 to High(FItems) do
  begin
    Value := ItemScore(FItems[I], Which);
    { 写しやすさは、測っていない回がある（課題文なしのとき）。**測っていない
      ものを 0 点として描かない。**線を切って、無かったことを見せます。
      Copyability is not measured every time -- not when there was no text.
      **What was not measured is not drawn as nought**: the line breaks instead,
      and the gap shows. }
    if (Which = fiCopyability) and (Value <= 0) then
    begin
      Started := False;
      Continue;
    end;
    X := XOf(I);
    Y := YOf(Value);
    if Started then
      Target.Line(LastX, LastY, X, Y);
    { 点が詰まってきたら印は打ちません。**重なって団子になるためです。**
      速さのためではありません（500 回ぶんの実測は 26.6 ms → 25.1 ms で、
      費用の大半は線そのものでした）。
      No marker once the points crowd together: **they would merge into a
      blob.** Not for speed -- measured over five hundred sessions it went from
      26.6 ms to 25.1 ms, the cost being the lines themselves. }
    if (Length(FItems) < 2) or
       (XOf(1) - XOf(0) >= 2 * MARKER + 2) then
      Target.Ellipse(X - MARKER, Y - MARKER, X + MARKER + 1, Y + MARKER + 1);
    LastX := X;
    LastY := Y;
    Started := True;
  end;
  Target.Pen.Width := 1;
end;

procedure TFistTrendView.DrawLegend;
var
  Which: TFistItem;
  X, Y, Width_: Integer;
begin
  Y := FHeight - FMeasure.Canvas.TextHeight('0') - 3;
  X := PlotLeft;
  for Which := Low(TFistItem) to High(TFistItem) do
  begin
    if not (Which in FShown) then
      Continue;
    Width_ := Target.TextWidth(FIST_ITEM_NAMES[Which]);
    if X + Width_ + 3 * FUnit > PlotRight then
      Break;
    Target.Brush.Color := ItemColor(Which);
    Target.Brush.Style := bsSolid;
    Target.FillRect(X, Y + 5, X + FUnit, Y + 9);
    Target.Brush.Style := bsClear;
    Target.Font.Color := Font.Color;
    Target.TextOut(X + FUnit + 4, Y, FIST_ITEM_NAMES[Which]);
    Inc(X, FUnit + 6 + Width_ + FUnit);
  end;
end;

procedure TFistTrendView.Paint;
begin
  DrawTo(Canvas, ClientWidth, ClientHeight);
end;

procedure TFistTrendView.DrawTo(ACanvas: TCanvas; AWidth, AHeight: Integer);
var
  Which: TFistItem;
begin
  FTarget := ACanvas;
  FWidth := AWidth;
  FHeight := AHeight;
  try
  Target.Brush.Color := Color;
  Target.Brush.Style := bsSolid;
  Target.FillRect(0, 0, FWidth, FHeight);
  Target.Brush.Style := bsClear;
  Target.Font.Assign(Font);

  if Length(FItems) = 0 then
  begin
    Target.Font.Color := BlendColor(Color, Font.Color, 0.55);
    Target.TextOut(6, 6, FEmptyMessage);
    Exit;
  end;

  DrawGrid;
  { 総合は最後に描きます。**重なったとき、いちばん見たい線が上に来ます。**
    The overall is drawn last, **so that where lines cross, the one most wanted
    is the one on top.** }
  for Which := Low(TFistItem) to High(TFistItem) do
    if (Which in FShown) and (Which <> fiOverall) then
      DrawLine_(Which);
  if fiOverall in FShown then
    DrawLine_(fiOverall);
  DrawLegend;
  finally
    FTarget := nil;
  end;
end;

end.
