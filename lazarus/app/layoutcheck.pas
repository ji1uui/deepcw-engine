unit LayoutCheck;

{ 画面の組み方が破綻していないかを、画面そのものに尋ねる部品です。

  高 DPI の画面では、同じ設計でも文字の大きさと配置の広がり方が一致しません
  （要件 NFR-5.1）。**目で見て気づけるのは、たまたま開いたタブの、たまたま
  見えている場所だけ**です。そこで、破綻を 3 つの形に絞って機械に数えさせます。

  - 文字が入る幅が足りない（LCL に「この部品はどれだけ要るか」を訊く）
  - 同じ親の上で 2 つの部品が重なっている
  - 部品が親の外へはみ出している（巻き取れる親は除く）

  **ここは判定するだけで、直しません。**直し方は画面ごとに違います。

  Asks the screen itself whether its layout has broken.

  At a high display resolution the text and the spacing do not grow at the same
  rate, even from one design (requirement NFR-5.1). **The eye only catches this
  on the tab that happens to be open, in the place that happens to be visible**,
  so three shapes of breakage are counted by machine instead:

  - not wide enough for its own text (the LCL is asked what the control needs)
  - two controls on one parent overlapping
  - a control outside its parent (parents that scroll are exempt)

  **This unit only judges; it does not repair.** How to repair depends on the
  screen. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Controls, Forms, StdCtrls, ExtCtrls, ComCtrls;

type
  TLayoutProblemKind = (lpTooNarrow, lpOverlap, lpOutside);

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
  else
    Kind := '親からはみ出している';
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

end.
