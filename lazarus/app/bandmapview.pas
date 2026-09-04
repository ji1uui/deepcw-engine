unit BandMapView;

{ 帯域にいる局を 1 行ずつ並べて見せる部品です（要件 FR-J.1）。

  **20 局分の受信テキストを並べても読めません。**運用者が知りたいのは全文ではなく
  「誰が」「どの周波数で」「いつ」「呼べる状態か」の 4 つで、全文は行を選んだときに
  出せば足ります。

  この部品は**受け取ったものをそのまま描くだけ**で、解釈はしません。呼出符号を
  どこまで信じてよいか（要件 FR-J.7）、密集しているかどうか（要件 FR-J.6）、いま
  解析しているかどうか（要件 FR-I.7）は、いずれも DeepCW.BandMap が決めた値を
  読むだけです。**描く側が判断を持つと、画面を見なければ検証できなくなります。**

  A control that lists the stations in the band, one to a row (requirement
  FR-J.1).

  **Twenty transcripts side by side cannot be read.** What an operator wants is
  not the full text but who, on what frequency, when, and whether they can be
  called; the full text can wait until a row is chosen.

  This control **draws what it is handed and interprets nothing.** How far a call
  sign may be trusted (requirement FR-J.7), whether a stretch is crowded
  (requirement FR-J.6) and whether a station is being analysed (requirement
  FR-I.7) are all values DeepCW.BandMap decided. **Judgement in the drawing code
  could only be verified by looking at the screen.** }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Controls, Graphics, Forms, StdCtrls, LCLType,
  DeepCW.Types, DeepCW.BandMap, ViewColors;

type
  { 行が選ばれたことを知らせます。番号と音程の両方を渡すのは、呼び出し側が同調
    （音程）と本文の取り出し（番号）の両方を行うためです。
    Reports that a row was chosen. Both the number and the pitch are passed
    because the caller both tunes, by pitch, and fetches the text, by number. }
  TStationChosenEvent = procedure(Sender: TObject; Id: Int64;
    Hz: Double) of object;

  TBandMapView = class(TCustomControl)
  private
    FEntries: TBandEntries;
    FNowSeconds: Double;
    FScrollBar: TScrollBar;
    FMeasure: TBitmap;
    FTopRow: Integer;
    FRowHeight: Integer;
    FUnit: Integer;
    FSelected: Int64;
    FOnStationChosen: TStationChosenEvent;
    FEmptyMessage: string;
    function VisibleRows: Integer;
    procedure MeasureFont;
    procedure UpdateScrollBar;
    procedure ScrollBarChanged(Sender: TObject);
    procedure SetTopRow(Value: Integer);
    function RowAt(Y: Integer): Integer;
    procedure DrawRow(Index, AtY: Integer);
  protected
    procedure Paint; override;
    procedure SetParent(AParent: TWinControl); override;
    procedure Resize; override;
    procedure FontChanged(Sender: TObject); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { 一覧を差し替えます。NowSeconds は受信開始からの秒で、「いつ聞こえたか」を
      出すのに使います。
      Replaces the list. NowSeconds is seconds since reception began, used to say
      how long ago each was heard. }
    procedure SetEntries(const Value: TBandEntries; NowSeconds: Double);
    procedure Clear;
    function Count: Integer;

    { 行に出す言葉。描くためのものですが、**何を出すかは要件そのもの**なので
      公開してあります。確かでない符号、密集している範囲、いつ聞こえたかを、
      画面を見ずに確かめられます（要件 FR-J.1・FR-J.6・FR-J.7）。

      The words a row shows. They exist for drawing, but **what is shown is the
      requirement itself**, so they are public: an uncertain call sign, a crowded
      stretch and how long ago a station was heard can all be checked without
      looking at the screen (requirements FR-J.1, FR-J.6 and FR-J.7). }
    function NameCaption(Index: Integer): string;
    function AgeCaption(Index: Integer): string;
    { 選ばれている局の番号。0 なら選ばれていません。
      The chosen station's number, or zero for none. }
    function SelectedId: Int64;
    { 番号で行を選びます。一覧の外から選び直すためのものです。
      Selects a row by number, for choosing from outside the list. }
    procedure SelectId(Id: Int64);

    { 局がいないときに出す言葉。空欄のままだと、動いていないのか局がいないのかが
      分かりません（要件 FR-A.3 の考え方）。
      What to say when there are no stations. An empty panel does not distinguish
      nothing working from nothing there (the thinking behind requirement
      FR-A.3). }
    property EmptyMessage: string read FEmptyMessage write FEmptyMessage;
    property OnStationChosen: TStationChosenEvent read FOnStationChosen
      write FOnStationChosen;

    property Align;
    property Anchors;
    property BorderSpacing;
    property Color;
    property Font;
    property TabStop;
  end;

implementation

const
  { 桁の幅を、文字の高さの何倍で取るか。日本語と英数字が混じるので、等幅の桁数
    ではなく高さを基準にします。
    Column widths as multiples of the character height. Japanese and Latin text
    are mixed, so the height is a steadier basis than a count of characters. }
  COLUMN_FREQUENCY = 4.6;
  COLUMN_NAME = 6.2;
  COLUMN_STATE = 3.4;
  COLUMN_AGE = 3.4;

constructor TBandMapView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  TabStop := True;
  Color := clWindow;
  Font.Name := 'Monospace';
  Font.Size := 10;
  FSelected := 0;
  FEmptyMessage := '受信を始めると、聞こえている局がここに並びます。';

  FMeasure := TBitmap.Create;
  FMeasure.SetSize(1, 1);

  { Align を使うと、まだ親を持たない段階で LCL の整列処理が走ってしまうため、
    位置は Resize で自分で決めます。TranscriptView と同じ扱いです。
    Using Align would run LCL's layout while this control still has no parent, so
    the bar is positioned by hand in Resize, as TranscriptView does. }
  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Kind := sbVertical;
  FScrollBar.Parent := Self;
  FScrollBar.OnChange := @ScrollBarChanged;
  MeasureFont;
end;

destructor TBandMapView.Destroy;
begin
  FreeAndNil(FMeasure);
  inherited Destroy;
end;

procedure TBandMapView.SetParent(AParent: TWinControl);
begin
  inherited SetParent(AParent);
  MeasureFont;
  UpdateScrollBar;
end;

procedure TBandMapView.MeasureFont;
begin
  if FMeasure = nil then
    Exit;
  FMeasure.Canvas.Font := Font;
  FUnit := Max(8, FMeasure.Canvas.TextHeight('Mg'));
  FRowHeight := FUnit + 6;
end;

function TBandMapView.VisibleRows: Integer;
begin
  Result := Max(1, ClientHeight div Max(1, FRowHeight));
end;

procedure TBandMapView.UpdateScrollBar;
var
  Hidden: Integer;
begin
  if FScrollBar = nil then
    Exit;
  Hidden := Max(0, Length(FEntries) - VisibleRows);
  FScrollBar.Max := Hidden;
  FScrollBar.PageSize := 1;
  { 見え隠れではなく、使える・使えないで示します。**Visible を切り替えると親の
    整列処理が走り、それが Resize を呼び、Resize がここを呼ぶ**という輪ができます。
    Enabled rather than Visible: **changing Visible runs the parent's layout,
    which calls Resize, which calls this** — a loop. }
  FScrollBar.Enabled := Hidden > 0;
  if FScrollBar.Position <> ClampInt(FTopRow, 0, Hidden) then
  begin
    { 位置を入れる間だけ通知を外します。外さないと、ここから ScrollBarChanged が
      呼ばれ、そこからまたここへ戻ります。
      The notification is detached while the position is set; left attached, this
      calls ScrollBarChanged, which calls back into here. }
    FScrollBar.OnChange := nil;
    FScrollBar.Position := ClampInt(FTopRow, 0, Hidden);
    FScrollBar.OnChange := @ScrollBarChanged;
  end;
end;

procedure TBandMapView.ScrollBarChanged(Sender: TObject);
begin
  SetTopRow(FScrollBar.Position);
end;

procedure TBandMapView.SetTopRow(Value: Integer);
begin
  Value := ClampInt(Value, 0, Max(0, Length(FEntries) - VisibleRows));
  if Value = FTopRow then
    Exit;
  FTopRow := Value;
  UpdateScrollBar;
  Invalidate;
end;

procedure TBandMapView.SetEntries(const Value: TBandEntries;
  NowSeconds: Double);
begin
  FEntries := Value;
  FNowSeconds := NowSeconds;
  FTopRow := ClampInt(FTopRow, 0, Max(0, Length(FEntries) - VisibleRows));
  UpdateScrollBar;
  Invalidate;
end;

procedure TBandMapView.Clear;
begin
  FEntries := nil;
  FTopRow := 0;
  FSelected := 0;
  UpdateScrollBar;
  Invalidate;
end;

function TBandMapView.Count: Integer;
begin
  Result := Length(FEntries);
end;

function TBandMapView.SelectedId: Int64;
begin
  Result := FSelected;
end;

procedure TBandMapView.SelectId(Id: Int64);
begin
  if FSelected = Id then
    Exit;
  FSelected := Id;
  Invalidate;
end;

function TBandMapView.AgeCaption(Index: Integer): string;
var
  Age: Double;
begin
  Age := FNowSeconds - FEntries[Index].LastSeconds;
  if Age < 0 then
    Age := 0;
  if Age < 10 then
    Result := 'いま'
  else if Age < 60 then
    Result := Format('%.0f秒', [Age])
  else
    Result := Format('%.0f分', [Age / 60]);
end;

function TBandMapView.NameCaption(Index: Integer): string;
begin
  { 密集している範囲は、1 局として読んだふりをしません（要件 FR-J.6）。
    A crowded stretch is not passed off as one station (requirement FR-J.6). }
  if FEntries[Index].Crowded > 0 then
    Exit(Format('密集 %d', [FEntries[Index].Crowded + 1]));
  case FEntries[Index].Trust of
    ctNone: Result := '';
    ctShape: Result := FEntries[Index].Callsign + ' ?';
  else
    Result := FEntries[Index].Callsign;
  end;
end;

procedure TBandMapView.DrawRow(Index, AtY: Integer);
var
  X, Width_: Integer;
  Chosen: Boolean;
  Name_: string;
begin
  Chosen := FEntries[Index].Id = FSelected;
  if Chosen then
  begin
    Canvas.Brush.Color := clHighlight;
    Canvas.Brush.Style := bsSolid;
    Canvas.FillRect(0, AtY, ClientWidth, AtY + FRowHeight);
    Canvas.Font.Color := clHighlightText;
  end
  else
  begin
    Canvas.Brush.Style := bsClear;
    { 薄く描くのは、**聞こえているのに読んでいない**行だけです。送信を止めた
      だけの局まで薄くすると、能力が足りていないように見えます。止めた局は
      「いつ聞こえたか」の欄で分かります（要件 FR-I.7）。
      Only a row that is **audible and not being read** is drawn faintly. Fading a
      station that merely stopped would suggest the machine could not keep up;
      that it stopped is what the age column says (requirement FR-I.7). }
    if FEntries[Index].Cut then
      Canvas.Font.Color := BlendColor(Color, Font.Color, 0.45)
    else
      Canvas.Font.Color := Font.Color;
  end;

  X := 4;
  Canvas.TextOut(X, AtY + 3, Format('%.0f', [FEntries[Index].Hz]));
  Inc(X, Round(COLUMN_FREQUENCY * FUnit));

  Name_ := NameCaption(Index);
  { CQ を出している局は、呼出符号を太字にします。「呼べる状態か」が一覧の主眼です
    （要件 FR-J.2）。
    A station calling CQ has its name in bold: whether a station can be called is
    the point of the list (requirement FR-J.2). }
  if FEntries[Index].Calling then
    Canvas.Font.Style := Canvas.Font.Style + [fsBold];
  Canvas.TextOut(X, AtY + 3, Name_);
  Canvas.Font.Style := Canvas.Font.Style - [fsBold];
  Inc(X, Round(COLUMN_NAME * FUnit));

  { 呼べる状態か、読めていないかを 1 語で示します。両方は起こりません。切り捨てた
    局は解析していないので、CQ を出しているかどうかも分からないためです。
    One word for whether a station can be called or is not being read; both cannot
    apply, since a station that was cut is not analysed and so it is not known
    whether it is calling. }
  if FEntries[Index].Cut then
    Canvas.TextOut(X, AtY + 3, '休止')
  else if FEntries[Index].Calling then
    Canvas.TextOut(X, AtY + 3, 'CQ');
  Inc(X, Round(COLUMN_STATE * FUnit));

  Canvas.TextOut(X, AtY + 3, AgeCaption(Index));
  Inc(X, Round(COLUMN_AGE * FUnit));

  Width_ := ClientWidth - X - 8 - FScrollBar.Width;
  if Width_ > FUnit then
    Canvas.TextOut(X, AtY + 3, FEntries[Index].Recent);
end;

procedure TBandMapView.Paint;
var
  Row, Index, RowTop: Integer;
begin
  Canvas.Brush.Color := Color;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(0, 0, ClientWidth, ClientHeight);
  Canvas.Font := Font;

  if Length(FEntries) = 0 then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Color := BlendColor(Color, Font.Color, 0.55);
    Canvas.TextOut(6, 6, FEmptyMessage);
    Exit;
  end;

  Row := 0;
  Index := FTopRow;
  while (Index < Length(FEntries)) and (Row < VisibleRows) do
  begin
    RowTop := Row * FRowHeight;
    DrawRow(Index, RowTop);
    Inc(Row);
    Inc(Index);
  end;
end;

procedure TBandMapView.Resize;
begin
  inherited Resize;
  if FScrollBar = nil then
    Exit;
  FScrollBar.SetBounds(Max(0, ClientWidth - FScrollBar.Width), 0,
    FScrollBar.Width, ClientHeight);
  UpdateScrollBar;
  Invalidate;
end;

procedure TBandMapView.FontChanged(Sender: TObject);
begin
  inherited FontChanged(Sender);
  MeasureFont;
  UpdateScrollBar;
  Invalidate;
end;

function TBandMapView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  SetTopRow(FTopRow - Sign(WheelDelta) * 3);
  Result := True;
end;

procedure TBandMapView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_UP: SetTopRow(FTopRow - 1);
    VK_DOWN: SetTopRow(FTopRow + 1);
    VK_PRIOR: SetTopRow(FTopRow - VisibleRows);
    VK_NEXT: SetTopRow(FTopRow + VisibleRows);
    VK_HOME: SetTopRow(0);
    VK_END: SetTopRow(Length(FEntries));
  else
    inherited KeyDown(Key, Shift);
    Exit;
  end;
  Key := 0;
end;

function TBandMapView.RowAt(Y: Integer): Integer;
begin
  Result := -1;
  if FRowHeight <= 0 then
    Exit;
  Result := FTopRow + Y div FRowHeight;
  if (Result < 0) or (Result >= Length(FEntries)) then
    Result := -1;
end;

procedure TBandMapView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Index: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then
    Exit;
  if CanFocus then
    SetFocus;
  Index := RowAt(Y);
  if Index < 0 then
    Exit;
  FSelected := FEntries[Index].Id;
  Invalidate;
  { 選ぶことと、選んだ結果どうするかは分けます。ここは選ばれたことだけを知らせ、
    同調するかどうかはフォームが決めます（要件 FR-J.3）。
    Choosing and acting on the choice are kept apart: this only reports the
    choice, and the form decides whether to tune (requirement FR-J.3). }
  if Assigned(FOnStationChosen) then
    FOnStationChosen(Self, FEntries[Index].Id, FEntries[Index].Hz);
end;

end.
