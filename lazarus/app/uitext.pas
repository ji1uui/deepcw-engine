unit UiText;

{ 画面の部品と、そこに出す文言との対応表です（要件 NFR-7.6）。

  **この画面はすべてコードで組んであります。**`.lfm` を読み込む作りなら LCL が
  言語の切替に追随させてくれますが、コードで入れた `Caption` は入れたきりです。
  稼働中に言語を変えても、**文言そのものは切り替わるのに、画面は前の言語のまま**
  になります（実測。付録 BD.1）。

  そこで「もう一度入れ直す道」を用意します。部品を作るときに**文言のありかを
  控えておき**、切り替えのときに控えを舐めて入れ直します。

  **控えるのは文字列ではなく、`resourcestring` のありか（ポインタ）です。**
  `resourcestring` は切り替えのときに中身が入れ替わるので、ありかさえ控えて
  おけば、いつ読んでもそのときの言語で返ります。

  **画面の文字を `.po` と突き合わせて入れ替える方式は採りません。**利用者が
  入力欄に「受信」と打ったら、それまで訳してしまいます。

  **画面を作り直す方式も採りません。**受信中に画面を壊すことになります
  （Receive は fail-soft）。入れ直すだけなら、受信を止めずに切り替えられます。

  The table that ties each control on screen to the words it shows
  (requirement NFR-7.6).

  **This screen is built entirely in code.** Had it been loaded from `.lfm`,
  the LCL would carry a language change through for us; a `Caption` assigned in
  code is assigned once and stays. Changing language while running switches the
  words themselves but **leaves the screen in the old language** (measured;
  appendix BD.1).

  So a way back is kept: as each control is built, **where its words live** is
  noted down, and a switch walks the notes and assigns them again.

  **What is noted is not the string but the address of the `resourcestring`.**
  Its contents are replaced on a switch, so reading through the address always
  gives the current language.

  **Matching the text on screen against the `.po` is not the way**: an operator
  who typed `受信` into an input box would have that translated too.

  **Rebuilding the screen is not the way either**: it would tear the screen down
  mid-reception (receive is fail-soft). Assigning again lets the language change
  without stopping reception. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Controls, StdCtrls;

type
  { `resourcestring` のありか。/ Where a `resourcestring` lives. }
  PResString = ^string;

{ 部品の見出しを控えます。**`Caption` を持つ部品なら何でも構いません**
  （ラベル、ボタン、チェックボックス、枠、タブ）。
  Notes down a control's caption. **Any control with a `Caption` will do**:
  labels, buttons, check boxes, group boxes, tab sheets. }
procedure RegisterCaption(Control_: TControl; Text_: PResString);

{ 選択肢の 1 行を控えます。**`Items.Clear` して入れ直すと選んでいたものが
  消える**ので、行ごとに入れ替えます（実測。付録 BD.1）。

  Notes down one line of a drop-down list. **Clearing and refilling loses the
  operator's choice**, so the lines are replaced one at a time (measured;
  appendix BD.1). }
procedure RegisterItem(Box: TCustomComboBox; Index_: Integer; Text_: PResString);

{ 控えをすべて入れ直します。**言語を変えた直後に呼びます。**
  Assigns every note again. **Called just after the language changes.** }
procedure ApplyTexts;

{ 控えの数。試験と診断のためです。/ How many notes are held; for tests and
  diagnostics. }
function TextCount: Integer;

{ いま部品に入っている、控えてある文言をすべて拾います。**試験のためです。**

  言語を変えて拾い直せば、変わったもの・変わらなかったもの・戻ったものが
  数えられます。**「一度英語にしたら日本語へ戻れない」は、この形でしか
  機械に見つけられません。**

  Collects what every noted control currently shows. **For tests.**

  Collected again after a language change, it counts what changed, what did
  not, and what came back. **"Once in English it cannot return to Japanese" can
  only be caught by machine in this shape.** }
procedure CollectTexts(Into: TStrings);

{ 控えを捨てます。**試験のためだけにあります。**画面は 1 度しか組まないので、
  普段の運用で呼ぶところはありません。
  Drops every note. **For tests only**: the screen is built once, so nothing in
  normal running calls this. }
procedure ForgetTexts;

implementation

type
  { `Caption` は `TControl` では protected です。**公開されている子孫に
    合わせるのではなく、ここで開けます**（`LayoutCheck` と同じやり方）。
    `Caption` is protected on `TControl`. **It is opened here** rather than
    casting to each descendant that publishes it (the same trick as
    `LayoutCheck`). }
  TControlOpener = class(TControl);

  TNoteKind = (nkCaption, nkItem);

  TNote = record
    Kind: TNoteKind;
    Control_: TControl;
    Box: TCustomComboBox;
    Index_: Integer;
    Text_: PResString;
  end;

var
  Notes: array of TNote;
  Count_: Integer = 0;

procedure Keep(const Note: TNote);
begin
  if Count_ > High(Notes) then
    SetLength(Notes, Count_ + 64);
  Notes[Count_] := Note;
  Inc(Count_);
end;

procedure RegisterCaption(Control_: TControl; Text_: PResString);
var
  Note: TNote;
begin
  if (Control_ = nil) or (Text_ = nil) then
    Exit;
  Note := Default(TNote);
  Note.Kind := nkCaption;
  Note.Control_ := Control_;
  Note.Text_ := Text_;
  Keep(Note);
  TControlOpener(Control_).Caption := Text_^;
end;

procedure RegisterItem(Box: TCustomComboBox; Index_: Integer; Text_: PResString);
var
  Note: TNote;
begin
  if (Box = nil) or (Text_ = nil) then
    Exit;
  Note := Default(TNote);
  Note.Kind := nkItem;
  Note.Box := Box;
  Note.Index_ := Index_;
  Note.Text_ := Text_;
  Keep(Note);
  while Box.Items.Count <= Index_ do
    Box.Items.Add('');
  Box.Items[Index_] := Text_^;
end;

procedure ApplyTexts;
var
  I: Integer;
begin
  for I := 0 to Count_ - 1 do
    case Notes[I].Kind of
      nkCaption:
        if Notes[I].Control_ <> nil then
          TControlOpener(Notes[I].Control_).Caption := Notes[I].Text_^;
      nkItem:
        { **並びが変わっていれば触りません。**装置の一覧のように実行中に
          組み直される選択肢は、組み直す側が入れ直します。
          **Left alone when the list has changed**: a drop-down rebuilt while
          running, such as the list of devices, is refilled by whatever
          rebuilds it. }
        if (Notes[I].Box <> nil) and (Notes[I].Index_ < Notes[I].Box.Items.Count) then
          Notes[I].Box.Items[Notes[I].Index_] := Notes[I].Text_^;
    end;
end;

function TextCount: Integer;
begin
  Result := Count_;
end;

procedure CollectTexts(Into: TStrings);
var
  I: Integer;
begin
  if Into = nil then
    Exit;
  Into.Clear;
  for I := 0 to Count_ - 1 do
    case Notes[I].Kind of
      nkCaption:
        if Notes[I].Control_ <> nil then
          Into.Add(TControlOpener(Notes[I].Control_).Caption);
      nkItem:
        if (Notes[I].Box <> nil) and (Notes[I].Index_ < Notes[I].Box.Items.Count) then
          Into.Add(Notes[I].Box.Items[Notes[I].Index_]);
    end;
end;

procedure ForgetTexts;
begin
  Notes := nil;
  Count_ := 0;
end;

end.
