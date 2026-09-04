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
  { 文字がひとつ選ばれたことを知らせます。番号は文字配列上の位置です。
    Reports that one character was chosen; the index is into the character
    array. }
  TCharChosenEvent = procedure(Sender: TObject; Index: Integer) of object;

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
    { 選ばれている文字。-1 なら選ばれていません。聴き直しの起点になります
      （要件 FR-E.10）。
      The chosen character, or -1 for none; it is where a replay starts
      (requirement FR-E.10). }
    FSelected: Integer;
    FOnCharChosen: TCharChosenEvent;
    { 検索語と、見つかった位置（文字配列上の開始番号）。位置は昇順に並びます
      （要件 FR-B.5）。
      The search term and where it was found, as start indices into the
      character array, in ascending order (requirement FR-B.5). }
    FNeedle: string;
    FMatches: array of Integer;
    FMatchLength: Integer;
    FCurrentMatch: Integer;
    procedure SetSelected(Value: Integer);
    procedure Rescan;
    procedure GoToMatch(Which: Integer);
    { その文字が一致の中にあるか。無ければ -1、あれば何番目の一致か。
      Whether the character is inside a hit: -1 if not, else which hit. }
    function MatchAt(Index: Integer): Integer;
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
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
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

    { 画面上の点にある文字の番号。無ければ -1 を返します。行末より右を指した
      ときは、その行の最後の文字を返します。押した位置がわずかに外れただけで
      「何も選べない」となるより、そのほうが操作として素直です。

      The index of the character at a point, or -1. A point past the end of a
      line gives that line's last character: it reads better than refusing to
      select because the press landed slightly wide. }
    function IndexAt(X, Y: Integer): Integer;

    { 番号で文字を取り出します。範囲外なら False を返します。
      Fetches one character by index, returning False when out of range. }
    function CharItem(Index: Integer; out Value: TDecodedChar): Boolean;

    { 選ばれている文字を、画面に見えるところまで送ります。
      Scrolls the chosen character into view. }
    procedure ScrollToSelected;

    { 受信テキストの中を探します（要件 FR-B.5）。

      大文字・小文字は区別しません。空文字を渡すと検索を解除します。受信が
      続いていても、文字が増えるたびに探し直すので、あとから届いた分も見つかり
      ます。

      Searches the received text (requirement FR-B.5).

      Case is ignored, and an empty term clears the search. The scan is redone
      whenever characters arrive, so text that appears later is found too. }
    procedure Search(const Needle: string);
    procedure NextMatch;
    procedure PreviousMatch;
    { 見つかった数と、いま何番目にいるか（1 起点、0 はどこにもいない）。
      How many were found and which one is current, counting from one, with zero
      meaning none. }
    function MatchCount: Integer;
    function CurrentMatch: Integer;
    property SearchTerm: string read FNeedle;

    { 選ばれている文字。設定すると、その文字が枠で囲まれます。
      The chosen character; setting it draws a box around that character. }
    property SelectedIndex: Integer read FSelected write SetSelected;
    property OnCharChosen: TCharChosenEvent read FOnCharChosen
      write FOnCharChosen;

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
  FSelected := -1;

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
  { 差し替えで文字数が減ったら、選び直しになります。範囲の外を指したまま
    にすると、聴き直しが別の場所を鳴らします。
    A replacement with fewer characters invalidates the choice; leaving it
    pointing outside the array would replay the wrong place. }
  if FSelected >= Length(FChars) then
    FSelected := -1;
  { 文字が増えれば一致も変わります。探し直さないと、あとから届いた分は
    いつまでも見つかりません（要件 FR-B.5）。
    New characters change what matches; without a rescan, text that arrives
    later would never be found (requirement FR-B.5). }
  if FNeedle <> '' then
    Rescan;
  Relayout;
  Invalidate;
end;

procedure TTranscriptView.Clear;
begin
  FChars := nil;
  FPendingFrom := MaxInt;
  FFollowTail := True;
  FTopLine := 0;
  FSelected := -1;
  FMatches := nil;
  FMatchLength := 0;
  FCurrentMatch := -1;
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

procedure TTranscriptView.SetSelected(Value: Integer);
begin
  if (Value < 0) or (Value >= Length(FChars)) then
    Value := -1;
  if Value = FSelected then
    Exit;
  FSelected := Value;
  Invalidate;
end;

{ 検索語を探し直します。

  文字配列を 1 度だけ走査します。受信中は文字が増えるたびに呼ばれるため、
  20 万文字でも目に見える遅れにならないことを試験で押さえています
  （`gui_probe`）。

  Rescans for the search term with a single pass over the character array. It
  runs on every arrival of new text, so that it stays imperceptible even at two
  hundred thousand characters is held by a test (`gui_probe`). }
procedure TTranscriptView.Rescan;
var
  Index, Offset, Count, Anchor: Integer;
  Hit: Boolean;
  Needle: string;
begin
  { いま見ている 1 件を、位置で覚えておきます。受信中は文字が届くたびに探し
    直すので、覚えずに番号を捨てると、**見ている場所が 0.2 秒ごとに先頭へ
    戻ります。**
    The hit being looked at is remembered by position. The rescan runs on every
    arrival of text while receiving, so discarding the index would **send the
    operator back to the first hit five times a second.** }
  Anchor := -1;
  if (FCurrentMatch >= 0) and (FCurrentMatch <= High(FMatches)) then
    Anchor := FMatches[FCurrentMatch];
  FMatches := nil;
  FMatchLength := 0;
  FCurrentMatch := -1;
  Needle := UpperCase(FNeedle);
  if (Needle = '') or (Length(FChars) = 0) then
    Exit;
  FMatchLength := Length(Needle);
  Count := 0;
  for Index := 0 to Length(FChars) - FMatchLength do
  begin
    Hit := True;
    for Offset := 0 to FMatchLength - 1 do
      { 1 文字は 1 要素です。空白も 1 要素なので、語をまたぐ検索も素直に
        当たります。
        One character is one element, spaces included, so a term spanning a word
        space matches as written. }
      if UpperCase(FChars[Index + Offset].Text) <> Needle[Offset + 1] then
      begin
        Hit := False;
        Break;
      end;
    if Hit then
    begin
      if Count = Length(FMatches) then
        SetLength(FMatches, Max(16, Count * 2));
      FMatches[Count] := Index;
      if Index = Anchor then
        FCurrentMatch := Count;
      Inc(Count);
    end;
  end;
  SetLength(FMatches, Count);
end;

procedure TTranscriptView.Search(const Needle: string);
begin
  FNeedle := Needle;
  { 語を変えたら、前の語で見ていた位置は意味を失います。
    A new term makes the position held for the old one meaningless. }
  FCurrentMatch := -1;
  Rescan;
  Invalidate;
  if Length(FMatches) > 0 then
    { 探したら、まず最初の 1 件へ連れていきます。見つかったと言うだけでは、
      どこにあるのか分かりません。
      A search takes the operator to the first hit: saying that something was
      found does not say where it is. }
    GoToMatch(0);
end;

{ 何番目かの一致へ移ります。番号は端で折り返します。件数が少ないときに、
  端で止まって進めなくなるより素直です。
  Moves to one of the hits, wrapping at either end: wrapping reads better than
  stopping dead at the end when there are only a few. }
procedure TTranscriptView.GoToMatch(Which: Integer);
begin
  if Length(FMatches) = 0 then
    Exit;
  while Which < 0 do
    Inc(Which, Length(FMatches));
  FCurrentMatch := Which mod Length(FMatches);
  SetSelected(FMatches[FCurrentMatch]);
  ScrollToSelected;
  Invalidate;
end;

procedure TTranscriptView.NextMatch;
begin
  GoToMatch(FCurrentMatch + 1);
end;

procedure TTranscriptView.PreviousMatch;
begin
  GoToMatch(FCurrentMatch - 1);
end;

{ 描くのは画面に見えている文字だけなので、1 文字ごとに二分探索しても軽いままです。
  Only visible characters are painted, so a binary search per character stays
  cheap. }
function TTranscriptView.MatchAt(Index: Integer): Integer;
var
  Low_, High_, Middle: Integer;
begin
  Result := -1;
  if (FMatchLength = 0) or (Length(FMatches) = 0) then
    Exit;
  Low_ := 0;
  High_ := High(FMatches);
  while Low_ <= High_ do
  begin
    Middle := (Low_ + High_) div 2;
    if FMatches[Middle] > Index then
      High_ := Middle - 1
    else
      Low_ := Middle + 1;
  end;
  { High_ は「開始が Index 以下」の最後の一致を指します。
    High_ now points at the last hit starting at or before Index. }
  if (High_ >= 0) and (Index < FMatches[High_] + FMatchLength) then
    Result := High_;
end;

function TTranscriptView.MatchCount: Integer;
begin
  Result := Length(FMatches);
end;

function TTranscriptView.CurrentMatch: Integer;
begin
  if (FCurrentMatch < 0) or (Length(FMatches) = 0) then
    Result := 0
  else
    Result := FCurrentMatch + 1;
end;

function TTranscriptView.IndexAt(X, Y: Integer): Integer;
var
  Row, LineIndex, Column: Integer;
begin
  Result := -1;
  if (Length(FLines) = 0) or (FLineHeight <= 0) or (FCharWidth <= 0) then
    Exit;
  Row := (Y - 1) div FLineHeight;
  if Row < 0 then
    Exit;
  LineIndex := FTopLine + Row;
  if (LineIndex < 0) or (LineIndex >= Length(FLines)) then
    Exit;
  Column := (X - 4) div FCharWidth;
  if Column < 0 then
    Column := 0;
  Result := FLines[LineIndex].First + Column;
  if Result > FLines[LineIndex].Last then
    Result := FLines[LineIndex].Last;
end;

function TTranscriptView.CharItem(Index: Integer; out Value: TDecodedChar): Boolean;
begin
  Result := (Index >= 0) and (Index < Length(FChars));
  if Result then
    Value := FChars[Index];
end;

procedure TTranscriptView.ScrollToSelected;
var
  LineIndex: Integer;
begin
  if FSelected < 0 then
    Exit;
  for LineIndex := 0 to High(FLines) do
    if (FSelected >= FLines[LineIndex].First) and
       (FSelected <= FLines[LineIndex].Last) then
    begin
      if LineIndex < FTopLine then
        SetTopLine(LineIndex)
      else if LineIndex >= FTopLine + VisibleLines then
        SetTopLine(LineIndex - VisibleLines + 1);
      Exit;
    end;
end;

procedure TTranscriptView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Index: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then
    Exit;
  if CanFocus then
    SetFocus;
  Index := IndexAt(X, Y);
  if Index < 0 then
    Exit;
  SetSelected(Index);
  { 選ぶことと、選んだ結果どうするかは分けます。ここは選ばれたことだけを
    知らせ、音を鳴らすかどうかはフォームが決めます。
    Choosing and acting on the choice are kept apart: this only reports the
    choice and the form decides whether to play anything. }
  if Assigned(FOnCharChosen) then
    FOnCharChosen(Self, Index);
end;

procedure TTranscriptView.Paint;
var
  LineIndex, Index, Row, X, Y, Hit: Integer;
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
      X := (Index - FLines[LineIndex].First) * FCharWidth + 4;
      { 見つかった箇所は下地を塗ります。いま見ている 1 件は濃く、ほかは淡く
        塗り分けます。どこにいるのかと、ほかにいくつあるのかが同時に分かる
        ためです（要件 FR-B.5）。
        Hits are given a background: the one being looked at strongly, the rest
        faintly, so that where the operator is and how many others there are
        read at the same time (requirement FR-B.5). }
      Hit := MatchAt(Index);
      if Hit >= 0 then
      begin
        if Hit = FCurrentMatch then
          Canvas.Brush.Color := clHighlight
        else
          Canvas.Brush.Color := BlendColor(Color, clHighlight, 0.30);
        Canvas.Brush.Style := bsSolid;
        Canvas.FillRect(X, Y, X + FCharWidth, Y + FLineHeight);
        Canvas.Brush.Style := bsClear;
      end;
      { 選ばれた文字には枠を描きます。塗り潰すと、濃淡で示している確からしさ
        （要件 FR-B.4）が読めなくなるためです。
        The chosen character is boxed rather than filled: filling would hide
        the shading that carries certainty (requirement FR-B.4). }
      if Index = FSelected then
      begin
        Canvas.Pen.Color := clHighlight;
        Canvas.Brush.Style := bsClear;
        Canvas.Rectangle(X - 1, Y - 1, X + FCharWidth + 1, Y + FLineHeight);
      end;
      if FChars[Index].Text <> ' ' then
      begin
        if Hit = FCurrentMatch then
          { 濃く塗った上には、地と対になる色で描かないと読めません。
            Text on the strong background needs the colour that pairs with it. }
          Canvas.Font.Color := clHighlightText
        else
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
