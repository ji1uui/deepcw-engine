unit TranscriptView;

{ 受信テキストを、文字ごとの確からしさとともに表示する部品です。

  LCL の TMemo は 1 文字ずつ色を変えられないため、専用の描画部品を用意しました。
  等幅フォントを前提にすることで、桁の割り付けと折り返しが単純になります。
  確信度の低い文字は背景に近づけて薄く描き、確かな文字と同じ顔で見せません
  （要件 FR-C.2）。色ではなく濃淡で区別するため、色覚特性の影響を受けません
  （要件 NFR-5.4）。

  A control that shows received text with each character's certainty.

  LCL's TMemo cannot colour individual characters, so this draws the text
  itself. Assuming a monospaced font keeps column layout and wrapping simple.
  Doubtful characters are drawn closer to the background so they never wear
  the same face as certain ones (requirement FR-C.2); because the cue is
  lightness rather than hue, colour vision does not affect it (NFR-5.4). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Controls, Graphics, Forms, StdCtrls, LCLType,
  DeepCW.Types, DeepCW.Decoder;

type
  { 折り返し後の 1 行が占める、文字配列上の範囲です。
    The range of the character array occupied by one wrapped line. }
  TTranscriptLine = record
    First: Integer;
    Last: Integer;
  end;

  TTranscriptView = class(TCustomControl)
  private
    FChars: TDecodedChars;
    FLines: array of TTranscriptLine;
    FScrollBar: TScrollBar;
    { 文字寸法の測定用。画面のハンドルに依存しないよう、独立した画布を使います。
      An offscreen canvas for measuring, so measurement never depends on the
      control having a window handle yet. }
    FMeasure: TBitmap;
    FTopLine: Integer;
    FCharWidth: Integer;
    FLineHeight: Integer;
    FColumns: Integer;
    FShowDoubt: Boolean;
    FDoubtStrength: Single;
    FFollowTail: Boolean;
    FPendingFrom: Integer;
    function VisibleLines: Integer;
    procedure MeasureFont;
    procedure Relayout;
    procedure UpdateScrollBar;
    procedure ScrollBarChanged(Sender: TObject);
    procedure SetShowDoubt(Value: Boolean);
    procedure SetDoubtStrength(Value: Single);
    procedure SetTopLine(Value: Integer);
    function ShadeFor(Index: Integer): TColor;
  protected
    procedure Paint; override;
    procedure SetParent(AParent: TWinControl); override;
    procedure Resize; override;
    procedure FontChanged(Sender: TObject); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { 表示内容を差し替えます。/ Replaces the displayed text. }
    procedure SetChars(const Value: TDecodedChars);
    procedure Clear;

    { 確定済みとして扱う文字数。これ以降は暫定として薄く描きます
      （要件 FR-B.2 の下地）。

      Characters treated as confirmed; anything beyond is drawn as provisional
      (groundwork for requirement FR-B.2). }
    property PendingFrom: Integer read FPendingFrom write FPendingFrom;

    { 表示中のテキスト全体。コピー用です。/ The whole text, for copying. }
    function AsText: string;
    function CharCount: Integer;

    { 確からしさの濃淡を表示するか。/ Whether to shade by certainty. }
    property ShowDoubt: Boolean read FShowDoubt write SetShowDoubt;
    { 濃淡の強さ 0..1。0 で濃淡なし。/ Shading strength; 0 disables it. }
    property DoubtStrength: Single read FDoubtStrength write SetDoubtStrength;
    { 末尾に追従するか。利用者が遡ると自動的に false になります。
      Whether to follow the tail; scrolling back clears it. }
    property FollowTail: Boolean read FFollowTail write FFollowTail;

    property Align;
    property Anchors;
    property BorderSpacing;
    property Color;
    property Font;
    property TabStop;
  end;

implementation

{ 2 色を Amount(0..1) で混ぜます。/ Blends two colours by Amount. }
function BlendColor(Background, Foreground: TColor; Amount: Single): TColor;
var
  BackRGB, ForeRGB: LongInt;
  R, G, B: Integer;
begin
  Amount := ClampDouble(Amount, 0, 1);
  BackRGB := ColorToRGB(Background);
  ForeRGB := ColorToRGB(Foreground);
  R := Round(Red(BackRGB) + (Red(ForeRGB) - Red(BackRGB)) * Amount);
  G := Round(Green(BackRGB) + (Green(ForeRGB) - Green(BackRGB)) * Amount);
  B := Round(Blue(BackRGB) + (Blue(ForeRGB) - Blue(BackRGB)) * Amount);
  Result := RGBToColor(ClampInt(R, 0, 255), ClampInt(G, 0, 255), ClampInt(B, 0, 255));
end;

constructor TTranscriptView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  TabStop := True;
  Color := clWindow;
  Font.Name := 'Monospace';
  Font.Size := 12;
  FShowDoubt := True;
  FDoubtStrength := 1.0;
  FFollowTail := True;
  FPendingFrom := MaxInt;

  FMeasure := TBitmap.Create;
  FMeasure.SetSize(1, 1);

  { Align を使うと、まだ親を持たない段階で LCL の整列処理が走ってしまうため、
    位置は Resize で自分で決めます。
    Using Align would run LCL's layout while this control still has no parent,
    so the bar is positioned by hand in Resize instead. }
  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Kind := sbVertical;
  FScrollBar.Width := 17;
  FScrollBar.Min := 0;
  FScrollBar.Max := 0;
  FScrollBar.OnChange := @ScrollBarChanged;
  FScrollBar.Parent := Self;
end;

destructor TTranscriptView.Destroy;
begin
  FMeasure.Free;
  inherited Destroy;
end;

procedure TTranscriptView.SetParent(AParent: TWinControl);
begin
  inherited SetParent(AParent);
  if AParent <> nil then
    Relayout;
end;

procedure TTranscriptView.MeasureFont;
begin
  if FMeasure = nil then
    Exit;
  FMeasure.Canvas.Font := Font;
  FCharWidth := Max(1, FMeasure.Canvas.TextWidth('M'));
  FLineHeight := Max(1, FMeasure.Canvas.TextHeight('Mg') + 2);
end;

function TTranscriptView.VisibleLines: Integer;
begin
  if FLineHeight <= 0 then
    Exit(1);
  Result := Max(1, ClientHeight div FLineHeight);
end;

procedure TTranscriptView.Relayout;
var
  Index, LineStart, LastBreak, Count: Integer;

  procedure PushLine(First, Last: Integer);
  begin
    if Count = Length(FLines) then
      SetLength(FLines, Max(16, Count * 2));
    FLines[Count].First := First;
    FLines[Count].Last := Last;
    Inc(Count);
  end;

begin
  { 継承した生成処理から早期に呼ばれることがあるため、部品が揃うまで何もしません。
    The inherited constructor can reach this before the parts exist. }
  if (FMeasure = nil) or (FScrollBar = nil) then
    Exit;
  MeasureFont;
  FColumns := Max(1, (ClientWidth - FScrollBar.Width - 8) div FCharWidth);
  FLines := nil;
  Count := 0;

  Index := 0;
  LineStart := 0;
  LastBreak := -1;
  while Index < Length(FChars) do
  begin
    if FChars[Index].Text = ' ' then
      LastBreak := Index;
    if Index - LineStart + 1 > FColumns then
    begin
      { 空白で折り返せるならそこで、無理なら桁で折ります。
        Break at a space when there is one, otherwise hard-wrap. }
      if LastBreak > LineStart then
      begin
        PushLine(LineStart, LastBreak - 1);
        LineStart := LastBreak + 1;
      end
      else
      begin
        PushLine(LineStart, Index - 1);
        LineStart := Index;
      end;
      LastBreak := -1;
    end;
    Inc(Index);
  end;
  if LineStart < Length(FChars) then
    PushLine(LineStart, Length(FChars) - 1);
  SetLength(FLines, Count);

  if FFollowTail then
    FTopLine := Max(0, Length(FLines) - VisibleLines);
  FTopLine := ClampInt(FTopLine, 0, Max(0, Length(FLines) - 1));
  UpdateScrollBar;
end;

procedure TTranscriptView.UpdateScrollBar;
var
  Hidden: Integer;
begin
  if FScrollBar = nil then
    Exit;
  Hidden := Max(0, Length(FLines) - VisibleLines);
  FScrollBar.Max := Hidden;
  FScrollBar.PageSize := 1;
  FScrollBar.Enabled := Hidden > 0;
  if FScrollBar.Position <> ClampInt(FTopLine, 0, Hidden) then
  begin
    FScrollBar.OnChange := nil;
    FScrollBar.Position := ClampInt(FTopLine, 0, Hidden);
    FScrollBar.OnChange := @ScrollBarChanged;
  end;
end;

procedure TTranscriptView.ScrollBarChanged(Sender: TObject);
begin
  SetTopLine(FScrollBar.Position);
end;

procedure TTranscriptView.SetTopLine(Value: Integer);
var
  Hidden: Integer;
begin
  Hidden := Max(0, Length(FLines) - VisibleLines);
  Value := ClampInt(Value, 0, Hidden);
  if Value = FTopLine then
    Exit;
  FTopLine := Value;
  { 末尾から離れたら追従をやめ、末尾に戻れば再開します（要件 FR-B.5）。
    Stop following once the operator scrolls back; resume at the tail. }
  FFollowTail := FTopLine >= Hidden;
  UpdateScrollBar;
  Invalidate;
end;

procedure TTranscriptView.SetShowDoubt(Value: Boolean);
begin
  if FShowDoubt = Value then
    Exit;
  FShowDoubt := Value;
  Invalidate;
end;

procedure TTranscriptView.SetDoubtStrength(Value: Single);
begin
  Value := ClampDouble(Value, 0, 1);
  if FDoubtStrength = Value then
    Exit;
  FDoubtStrength := Value;
  Invalidate;
end;

procedure TTranscriptView.SetChars(const Value: TDecodedChars);
begin
  FChars := Value;
  Relayout;
  Invalidate;
end;

procedure TTranscriptView.Clear;
begin
  FChars := nil;
  FPendingFrom := MaxInt;
  FFollowTail := True;
  FTopLine := 0;
  Relayout;
  Invalidate;
end;

function TTranscriptView.AsText: string;
begin
  Result := DecodedText(FChars);
end;

function TTranscriptView.CharCount: Integer;
begin
  Result := Length(FChars);
end;

function TTranscriptView.ShadeFor(Index: Integer): TColor;
var
  Strength: Single;
begin
  Strength := 1;
  if FShowDoubt then
    Strength := 1 - DoubtLevel(FChars[Index].Confidence) * FDoubtStrength * 0.72;
  if Index >= FPendingFrom then
    { 暫定部分はさらに控えめに描きます。/ Provisional text is drawn fainter. }
    Strength := Strength * 0.6;
  Result := BlendColor(Color, Font.Color, Strength);
end;

procedure TTranscriptView.Paint;
var
  LineIndex, Index, Row, X, Y: Integer;
begin
  Canvas.Brush.Color := Color;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(0, 0, ClientWidth, ClientHeight);
  Canvas.Font := Font;
  Canvas.Brush.Style := bsClear;

  if Length(FLines) = 0 then
    Exit;

  Row := 0;
  LineIndex := FTopLine;
  while (LineIndex < Length(FLines)) and (Row < VisibleLines) do
  begin
    Y := Row * FLineHeight + 1;
    for Index := FLines[LineIndex].First to FLines[LineIndex].Last do
    begin
      if FChars[Index].Text <> ' ' then
      begin
        X := (Index - FLines[LineIndex].First) * FCharWidth + 4;
        Canvas.Font.Color := ShadeFor(Index);
        Canvas.TextOut(X, Y, FChars[Index].Text);
      end;
    end;
    Inc(Row);
    Inc(LineIndex);
  end;
end;

procedure TTranscriptView.Resize;
begin
  inherited Resize;
  if FScrollBar = nil then
    Exit;
  FScrollBar.SetBounds(Max(0, ClientWidth - FScrollBar.Width), 0,
    FScrollBar.Width, ClientHeight);
  Relayout;
  Invalidate;
end;

procedure TTranscriptView.FontChanged(Sender: TObject);
begin
  inherited FontChanged(Sender);
  if FMeasure = nil then
    Exit;
  Relayout;
  Invalidate;
end;

function TTranscriptView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  SetTopLine(FTopLine - Sign(WheelDelta) * 3);
  Result := True;
end;

procedure TTranscriptView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_UP: SetTopLine(FTopLine - 1);
    VK_DOWN: SetTopLine(FTopLine + 1);
    VK_PRIOR: SetTopLine(FTopLine - VisibleLines);
    VK_NEXT: SetTopLine(FTopLine + VisibleLines);
    VK_HOME: SetTopLine(0);
    VK_END: SetTopLine(MaxInt);
  else
    inherited KeyDown(Key, Shift);
    Exit;
  end;
  Key := 0;
end;

end.
