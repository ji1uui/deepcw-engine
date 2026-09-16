unit LayoutCheck;

{ 画面の組み方が破綻していないかを、画面そのものに尋ねる部品です。

  高 DPI の画面では、同じ設計でも文字の大きさと配置の広がり方が一致しません
  （要件 NFR-5.1）。**目で見て気づけるのは、たまたま開いたタブの、たまたま
  見えている場所だけ**です。そこで、破綻を 3 つの形に絞って機械に数えさせます。

  - 文字が入る幅が足りない（LCL に「この部品はどれだけ要るか」を訊く）
  - 同じ親の上で 2 つの部品が重なっている
  - 部品が親の外へはみ出している（巻き取れる親は除く）

  もうひとつ、Tab の順序が目で追う順序と食い違っていないかも数えます
  （要件 NFR-5.6）。**焦点は 1 つしか無く、動いた跡は残りません。**版 2.46 では
  画面を 26 回撮って比べて見つけた。同じことを窓自身にさせます。

  **ここは判定するだけで、直しません。**直し方は画面ごとに違います。

  Asks the screen itself whether its layout has broken.

  At a high display resolution the text and the spacing do not grow at the same
  rate, even from one design (requirement NFR-5.1). **The eye only catches this
  on the tab that happens to be open, in the place that happens to be visible**,
  so three shapes of breakage are counted by machine instead:

  - not wide enough for its own text (the LCL is asked what the control needs)
  - two controls on one parent overlapping
  - a control outside its parent (parents that scroll are exempt)

  It also counts whether the Tab order disagrees with the order the eye
  follows (requirement NFR-5.6). **There is only one focus and it leaves no
  trail**: version 2.46 found the disagreement by taking 26 pictures of the
  screen and comparing them. The window is asked to do the same work.

  **This unit only judges; it does not repair.** How to repair depends on the
  screen. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Controls, Forms, StdCtrls, ExtCtrls, ComCtrls;

type
  TLayoutProblemKind = (lpTooNarrow, lpOverlap, lpOutside, lpTabOrder);

  TLayoutProblem = record
    Kind: TLayoutProblemKind;
    { どこで起きたか。親から辿った並びで書きます。名前を持たない部品ばかり
      なので、型と文字で示します。
      Where it happened, as a path from the parent. These controls carry no
      names, so the class and the caption stand in for one. }
    Where_: string;
    Detail: string;
  end;
  TLayoutProblems = array of TLayoutProblem;

{ 見えている部品だけを辿って数えます。**見えていないタブは呼び出し側が
  切り替えてから渡してください。**隠れている部品の位置は、まだ決まって
  いないことがあります。

  Walks the visible controls only. **A tab that is not showing must be brought
  to the front by the caller first**: a hidden control's position may not have
  been decided yet. }
function FindLayoutProblems(Root: TWinControl): TLayoutProblems;

{ Tab を 1 周押したときに、焦点が上へ戻る回数の上限です。**1 回は巻き戻し**
  ——最後の部品から先頭へ帰るぶんで、これは要ります。2 回目からが食い違いです
  （要件 NFR-5.6、付録 AT.4）。
  How many times the focus may jump back up during one pass of Tab. **One is
  the wrap** from the last control to the first, which has to happen; a second
  is a disagreement (requirement NFR-5.6, appendix AT.4). }
const
  TAB_BACKWARD_ALLOWED = 1;
  { 1 周とみなす上限。数えきれないときは、輪になっていないと見ます。
    The most stops counted as one pass; beyond it the chain is not a loop. }
  TAB_MAX_STOPS = 300;

{ Tab を 1 周押し、焦点が目で追う順序どおりに動くかを数えます（要件 NFR-5.6）。

  **同じ行の中で左右に動くのは食い違いではありません。**上へ戻ったと数えるのは、
  次の部品が今の部品より**完全に上にある**ときだけです。行の中の部品は縦に
  重なっているので、これで数え違えません。

  Walks one pass of Tab and counts whether the focus moves in the order the eye
  follows (requirement NFR-5.6).

  **Moving left or right within a row is not a disagreement.** A jump back up
  is only counted when the next control lies **entirely above** the current
  one; controls on one row overlap vertically, so a row never counts. }
function FindTabOrderProblems(Root: TWinControl): TLayoutProblems;

{ 1 件を 1 行にします。/ Renders one problem as one line. }
function DescribeProblem(const Problem: TLayoutProblem): string;

{ 部品の呼び名。文字を持つものは文字で、持たないものは型で示します。
  What to call a control: by its text where it has one, by its class otherwise. }
function ControlCaption(Control: TControl): string;

implementation

type
  { Caption は TControl では protected です。読むためだけに開けます。
    Caption is protected in TControl; this opens it for reading alone. }
  TControlOpener = class(TControl)
  end;

  { `FindNextControl` も protected です。Tab を押したときに LCL が選ぶ次の
    部品を、**同じ手続きで**辿るために開けます。自前で順序を組み直すと、
    確かめているのが LCL の振る舞いではなくなります。
    `FindNextControl` is protected too. It is opened so that the next control
    the LCL would choose on Tab is followed **by the same procedure**:
    rebuilding the order here would mean testing something other than what the
    LCL does. }
  TWinControlOpener = class(TWinControl)
  end;

function ControlCaption(Control: TControl): string;
begin
  Result := Control.ClassName;
  if Control = nil then
    Exit('(なし)');
  if TControlOpener(Control).Caption <> '' then
    Result := Result + '「' + TControlOpener(Control).Caption + '」'
  else if Control.Name <> '' then
    Result := Result + '（' + Control.Name + '）';
end;

{ 文字の幅を検査してよい部品かどうか。入力欄や一覧は、中身より狭くても
  巻き取れるので数えません。**数えるのは「文字がそのまま見えるはずの
  部品」**だけです。

  Whether a control's text width may be judged. Edit boxes and lists may be
  narrower than their contents because they scroll; **only controls whose text
  is meant to be read as it stands** are counted. }
function TextMustFit(Control: TControl): Boolean;
begin
  Result := (Control is TLabel) or (Control is TCheckBox) or
    (Control is TRadioButton) or (Control is TButton);
end;

function DescribeProblem(const Problem: TLayoutProblem): string;
var
  Kind: string;
begin
  case Problem.Kind of
    lpTooNarrow: Kind := '文字が入らない';
    lpOverlap: Kind := '重なっている';
    lpOutside: Kind := '親からはみ出している';
  else
    Kind := 'タブ順序が視覚順序と合わない';
  end;
  Result := Format('%s: %s %s', [Kind, Problem.Where_, Problem.Detail]);
end;

procedure Add(var List: TLayoutProblems; Kind: TLayoutProblemKind;
  const Where_, Detail: string);
begin
  SetLength(List, Length(List) + 1);
  List[High(List)].Kind := Kind;
  List[High(List)].Where_ := Where_;
  List[High(List)].Detail := Detail;
end;

function Overlaps(A, B: TControl): Boolean;
begin
  Result := (A.Left < B.Left + B.Width) and (B.Left < A.Left + A.Width) and
    (A.Top < B.Top + B.Height) and (B.Top < A.Top + A.Height);
end;

procedure Walk(Parent: TWinControl; const Path: string;
  var List: TLayoutProblems);
var
  I, J, Wanted, WantedHeight: Integer;
  Child, Other: TControl;
  Scrolls: Boolean;
  Here: string;
begin
  { 巻き取れる親の中では、はみ出しは破綻ではありません。設定タブは実際に
    巻き取る作りです。
    Inside a parent that scrolls, sticking out is not breakage; the settings tab
    scrolls by design. }
  Scrolls := Parent is TScrollingWinControl;
  for I := 0 to Parent.ControlCount - 1 do
  begin
    Child := Parent.Controls[I];
    if not Child.Visible then
      Continue;
    Here := Path + '/' + ControlCaption(Child);

    if TextMustFit(Child) and not Child.AutoSize then
    begin
      Child.GetPreferredSize(Wanted, WantedHeight);
      if (Wanted > 0) and (Child.Width < Wanted) then
        Add(List, lpTooNarrow, Here,
          Format('(幅 %d、要る幅 %d)', [Child.Width, Wanted]));
    end;

    if not Scrolls then
    begin
      if (Child.Left < 0) or (Child.Top < 0) or
        (Child.Left + Child.Width > Parent.ClientWidth) or
        (Child.Top + Child.Height > Parent.ClientHeight) then
        Add(List, lpOutside, Here,
          Format('(位置 %d,%d 大きさ %dx%d、親 %dx%d)',
            [Child.Left, Child.Top, Child.Width, Child.Height,
             Parent.ClientWidth, Parent.ClientHeight]));
    end;

    for J := I + 1 to Parent.ControlCount - 1 do
    begin
      Other := Parent.Controls[J];
      if not Other.Visible then
        Continue;
      if Overlaps(Child, Other) then
        Add(List, lpOverlap, Here,
          Format('と %s (%d,%d %dx%d と %d,%d %dx%d)',
            [ControlCaption(Other), Child.Left, Child.Top, Child.Width,
             Child.Height, Other.Left, Other.Top, Other.Width, Other.Height]));
    end;

    if Child is TWinControl then
      Walk(TWinControl(Child), Here, List);
  end;
end;

function FindLayoutProblems(Root: TWinControl): TLayoutProblems;
begin
  Result := nil;
  if Root = nil then
    Exit;
  Walk(Root, ControlCaption(Root), Result);
end;

function FindTabOrderProblems(Root: TWinControl): TLayoutProblems;
var
  First_, Current, Next_: TWinControl;
  Stops: array of TWinControl;
  A, B: TWinControl;
  I, Backwards: Integer;

  { 中に別の止まり場所を抱えている部品は「入れ物」です。**入れ物の位置は、目が
    見ている場所ではありません**——タブの帯に焦点があるとき、その部品の高さは
    画面いっぱいで、何と比べても「上にある」ことになりません。並びは通しますが、
    位置の比べ合いからは外します。

    A control holding other stops inside it is a container. **A container's
    position is not where the eye is**: with the focus on the tab strip its
    height spans the whole page, so nothing ever counts as above it. Containers
    stay in the chain but take no part in comparing positions. }
  function IsContainer(Control: TWinControl): Boolean;
  begin
    Result := Control.ControlCount > 0;
  end;

begin
  Result := nil;
  if Root = nil then
    Exit;
  First_ := TWinControlOpener(Root).FindNextControl(nil, True, True, False);
  if First_ = nil then
    Exit;

  { まず 1 周ぶんを集めます。**集めてから見るのは、巻き戻し（最後から先頭へ)も
    1 つの歩みとして数えるため**です。歩きながら数えると、輪の閉じ目が抜けます
    ——版 2.50 で、そのせいで本物の食い違いを見逃しました。

    One full pass is collected first. **Collecting before judging is what makes
    the wrap -- last back to first -- count as a step of its own**; judging
    while walking skips the seam of the loop, and in version 2.50 that let a
    real disagreement through. }
  Current := First_;
  repeat
    if IsContainer(Current) = False then
    begin
      SetLength(Stops, Length(Stops) + 1);
      Stops[High(Stops)] := Current;
    end;
    Next_ := TWinControlOpener(Root).FindNextControl(Current, True, True, False);
    if Next_ = nil then
      Break;
    if Length(Stops) > TAB_MAX_STOPS then
    begin
      Add(Result, lpTabOrder, ControlCaption(Root),
        Format('(%d 回押しても先頭へ戻らない)', [TAB_MAX_STOPS]));
      Exit;
    end;
    Current := Next_;
  until Current = First_;

  { 止まり場所が 1 つなら、順序という問いが立ちません。
    With a single stop there is no order to ask about. }
  if Length(Stops) < 2 then
    Exit;

  { 上へ戻る歩みを、まず全部数えます。**超えていたら、どれが巻き戻しかは
    決められません**——輪に始まりが無い以上、1 つだけを「これは正当な巻き戻し」
    と選ぶ根拠がありません。だから超えたときは**全部を挙げます。**1 つだけを
    名指しすると、たまたま最後に見た歩みが犯人にされます（版 2.50 で実際に
    そうなりました）。

    Every jump back up is counted first. **Once the count is exceeded there is
    no telling which one is the wrap**: a loop has no beginning, so nothing
    justifies picking one and calling it legitimate. When the count is
    exceeded, **all of them are reported.** Naming only one makes the culprit
    whichever step happened to be looked at last, as it did in version 2.50. }
  Backwards := 0;
  for I := 0 to High(Stops) do
    if Stops[(I + 1) mod Length(Stops)].ControlOrigin.Y +
      Stops[(I + 1) mod Length(Stops)].Height <= Stops[I].ControlOrigin.Y then
      Inc(Backwards);

  if Backwards > TAB_BACKWARD_ALLOWED then
    for I := 0 to High(Stops) do
    begin
      A := Stops[I];
      B := Stops[(I + 1) mod Length(Stops)];
      if B.ControlOrigin.Y + B.Height <= A.ControlOrigin.Y then
        Add(Result, lpTabOrder, ControlCaption(A),
          Format('から %s へ %d 画素上へ戻る（上へ戻る歩みは %d 回、許すのは %d 回）',
            [ControlCaption(B), A.ControlOrigin.Y - B.ControlOrigin.Y,
             Backwards, TAB_BACKWARD_ALLOWED]));
    end;

  { 輪には始まりが無いので、「上へ戻るのは 1 回」だけでは**巻き戻しの位置が
    どこでも通ってしまいます。**下の段から始まる並びも、回して見れば上から下へ
    単調です。そこで、始まりの場所も見ます——**窓を開いて最初に Tab を押した
    とき、焦点は画面のいちばん上の段に居るべき**です（要件 NFR-5.6）。

    A loop has no beginning, so "one jump back" alone **passes whatever the
    position of the wrap**: an order that starts at the bottom row is still
    monotonic once rotated. The starting point is therefore checked too --
    **on the first Tab after the window opens, the focus belongs on the topmost
    row** (requirement NFR-5.6). }
  for I := 1 to High(Stops) do
    if Stops[I].ControlOrigin.Y + Stops[I].Height <= Stops[0].ControlOrigin.Y then
    begin
      Add(Result, lpTabOrder, ControlCaption(Stops[0]),
        Format('から始まるが、%s のほうが %d 画素上にある',
          [ControlCaption(Stops[I]),
           Stops[0].ControlOrigin.Y - Stops[I].ControlOrigin.Y]));
      Break;
    end;
end;

end.
