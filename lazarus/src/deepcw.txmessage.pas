unit DeepCW.TxMessage;

{ 無線機で送る文を組み立て、送ってよい形かを確かめます（要件 FR-T.1）。

  文の作り方は 3 つです。

  1. **自動** — 交信の段（CQ・呼び返し・レポート・終わり）と、自局・相手の
     符号・RST から組み立てる（`AutoTemplate` を `ExpandTemplate` で展開）
  2. **定型** — 利用者が書いておいた型を、同じ差し込み（波括弧で囲んだ
     `MYCALL`・`CALL`・`RST`）で展開する
  3. **手入力** — 利用者が書いた文そのもの

  **どれも「送信文の欄」に最終の文として入り、送るのは欄の文そのもの**です
  （見たとおりに送る）。そのため:

  - 差し込みは**組み立てるときに**展開します。**値が無い差し込みは展開せず、
    組み立てを断ります。**「DE  K」のように抜けたまま送らないためです。
  - 送る前の確かめ（`CheckTransmitText`）は、送れない文字を**落とさずに断り**、
    その文字を名指しします。落とせば、送る文と見えている文が食い違います。
    展開されていない差し込み（開き波括弧）も断ります。

  送る文は CW の運用の言葉（英字の略語）なので、**訳しません**。

  Builds the text to be sent by the rig and checks that it may be sent
  (requirement FR-T.1). The text comes from one of three places -- **automatic**
  (from the stage of the contact and the calls/RST), a **template** the
  operator wrote (same macros), or **typed** by hand -- and **all of them end up
  as the final text in the send box; what is sent is exactly that box**
  (what you see is what is keyed). Hence macros are expanded **when composing**,
  and **a macro with no value refuses the composition** instead of leaving a gap
  such as "DE  K"; and the check before sending **refuses, rather than drops,**
  any character that cannot be sent, naming it -- dropping it would make the
  keyed text differ from the shown text. An unexpanded macro (an opening brace) is refused
  too. The text is CW operating language (English abbreviations) and is **not
  translated.** }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, DeepCW.Morse;

const
  { 1 回に送る文の長さの上限（文字）。長い送出は、止められない機種で
    取り返しが付かなくなります。
    The longest text sent at once (characters): a long sending is beyond
    recall on a rig that cannot stop. }
  TX_MAX_CHARS = 160;
  { 1 回の送出の長さの見積もりの上限（秒）。/ Longest estimated sending (s). }
  TX_MAX_SECONDS = 120;

type
  { 交信の段。/ The stage of a contact. }
  TTxStage = (tsCq, tsAnswer, tsReport, tsFinal);

  { 差し込みに入れる値。/ The values the macros take. }
  TTxContext = record
    MyCall: string;
    TheirCall: string;
    Rst: string;
  end;

  { 確かめの結果の種類。**言葉にするのは画面の側です**（`resourcestring`）。
    The kind of check result; **the screen puts it into words.** }
  TTxProblem = (tpNone, tpEmpty, tpUnsendable, tpTooLong, tpUnexpanded,
    tpMissingValue, tpUnknownMacro);

{ 段ごとの自動の型。/ The automatic template for a stage. }
function AutoTemplate(Stage: TTxStage): string;

{ 差し込みを展開します。**値の無い差し込みか、知らない差し込みがあれば
  False** を返し、`Problem` と `Detail`（差し込みの名前）で理由を返します。
  Expands the macros. **Returns False on a macro with no value or an unknown
  one**, giving the reason in `Problem` and the macro's name in `Detail`. }
function ExpandTemplate(const Template: string; const Context: TTxContext;
  out Text: string; out Problem: TTxProblem; out Detail: string): Boolean;

{ 送ってよい文かを確かめます。空白の並びは 1 つにそろえ、英字は大文字に
  そろえた文を `Clean` に返します（**文字は落としません**）。送れない文字は
  `Detail` に名指しします。
  Checks whether the text may be sent. Runs of spaces become one and letters
  upper case in `Clean` (**no character is dropped**); a character that cannot
  be sent is named in `Detail`. }
function CheckTransmitText(const Text: string; Wpm: Integer;
  out Clean: string; out Problem: TTxProblem; out Detail: string): Boolean;

{ 送出の長さの見積もり（秒）。/ The estimated sending time (s). }
function EstimateTransmitSeconds(const Text: string; Wpm: Integer): Double;

{ 語ごとに分けます。**止められない機種でも、止めたら次の語からは送らない**
  ようにするため、無線機には語ずつ渡します（`DeepCW.RigKeyer`）。最後の語
  以外は、語の間を空けるための空白を末尾に持ちます。
  Splits into words. **Even on a rig that cannot stop, a stop keeps the next
  word from being sent**, so the rig is handed one word at a time
  (`DeepCW.RigKeyer`). Every word but the last carries a trailing space for
  the word gap. }
function SplitForKeying(const Clean: string): TStringArray;

{ `SplitForKeying` の 1 片を無線機が送り終えるまでの秒数。**末尾の空白の
  ぶんの語間（7 短点）を含みます。**`EstimateTransmitSeconds` は語の間にしか
  語間を置かないので、1 語だけを渡すと末尾の空白を数えません。数えなければ、
  語を渡す間合いが語ごとに語間 1 つぶん早まり、送るほど無線機より先へ進みます
  （付録 BS.1）。
  How long the rig takes for one piece from `SplitForKeying`, **including the
  word gap (7 dits) of its trailing space**. `EstimateTransmitSeconds` only
  puts gaps between words, so a lone word's trailing space counts for nothing;
  left uncounted, each hand-over comes one word gap early and the pacing runs
  further ahead of the rig with every word (appendix BS.1). }
function KeyingSeconds(const Piece: string; Wpm: Integer): Double;

implementation

function AutoTemplate(Stage: TTxStage): string;
begin
  case Stage of
    tsCq: Result := 'CQ CQ CQ DE {MYCALL} {MYCALL} {MYCALL} K';
    tsAnswer: Result := '{CALL} DE {MYCALL} {MYCALL} K';
    tsReport: Result := '{CALL} DE {MYCALL} UR RST {RST} {RST} BK';
  else
    Result := '{CALL} DE {MYCALL} TNX FER QSO 73 TU';
  end;
end;

function ExpandTemplate(const Template: string; const Context: TTxContext;
  out Text: string; out Problem: TTxProblem; out Detail: string): Boolean;
var
  I, Close_: Integer;
  Name, Value: string;
begin
  Text := '';
  Problem := tpNone;
  Detail := '';
  I := 1;
  while I <= Length(Template) do
  begin
    if Template[I] <> '{' then
    begin
      Text := Text + Template[I];
      Inc(I);
      Continue;
    end;
    Close_ := Pos('}', Template, I + 1);
    if Close_ = 0 then
    begin
      Problem := tpUnknownMacro;
      Detail := Copy(Template, I, MaxInt);
      Exit(False);
    end;
    Name := UpperCase(Copy(Template, I + 1, Close_ - I - 1));
    if Name = 'MYCALL' then
      Value := Context.MyCall
    else if Name = 'CALL' then
      Value := Context.TheirCall
    else if Name = 'RST' then
      Value := Context.Rst
    else
    begin
      Problem := tpUnknownMacro;
      Detail := '{' + Name + '}';
      Exit(False);
    end;
    if Trim(Value) = '' then
    begin
      Problem := tpMissingValue;
      Detail := '{' + Name + '}';
      Exit(False);
    end;
    Text := Text + Trim(Value);
    I := Close_ + 1;
  end;
  Result := True;
end;

function CheckTransmitText(const Text: string; Wpm: Integer;
  out Clean: string; out Problem: TTxProblem; out Detail: string): Boolean;
var
  I: Integer;
  Ch: Char;
  PendingSpace: Boolean;
begin
  Clean := '';
  Problem := tpNone;
  Detail := '';
  PendingSpace := False;
  for I := 1 to Length(Text) do
  begin
    Ch := UpCase(Text[I]);
    if (Ch = ' ') or (Ch = #9) or (Ch = #10) or (Ch = #13) then
    begin
      PendingSpace := Clean <> '';
      Continue;
    end;
    if Ch = '{' then
    begin
      Problem := tpUnexpanded;
      Detail := Copy(Text, I, Pos('}', Text + '}', I) - I + 1);
      Exit(False);
    end;
    if MorseForChar(Ch) = '' then
    begin
      Problem := tpUnsendable;
      { UTF-8 の文字は 1 バイトでは切れません。前後を含めて見せます。
        A UTF-8 character cannot be cut at one byte; show it with its context. }
      Detail := Copy(Text, Max(1, I - 3), 8);
      Exit(False);
    end;
    if PendingSpace then
    begin
      Clean := Clean + ' ';
      PendingSpace := False;
    end;
    Clean := Clean + Ch;
  end;
  if Clean = '' then
  begin
    Problem := tpEmpty;
    Exit(False);
  end;
  if (Length(Clean) > TX_MAX_CHARS) or
     (EstimateTransmitSeconds(Clean, Wpm) > TX_MAX_SECONDS) then
  begin
    Problem := tpTooLong;
    Detail := IntToStr(Length(Clean));
    Exit(False);
  end;
  Result := True;
end;

function EstimateTransmitSeconds(const Text: string; Wpm: Integer): Double;
var
  Timing: TCWTiming;
begin
  if Wpm <= 0 then
    Wpm := 20;
  Timing.CharWpm := Wpm;
  Timing.TextWpm := Wpm;
  Result := SegmentsDuration(TextToSegments(Text, Timing));
end;

function KeyingSeconds(const Piece: string; Wpm: Integer): Double;
begin
  if Wpm <= 0 then
    Wpm := 20;
  Result := EstimateTransmitSeconds(Trim(Piece), Wpm);
  if (Piece <> '') and (Piece[Length(Piece)] = ' ') then
    Result := Result + 7 * DitSeconds(Wpm);
end;

function SplitForKeying(const Clean: string): TStringArray;
var
  Words: TStringArray;
  I: Integer;
begin
  Words := Clean.Split([' '], TStringSplitOptions.ExcludeEmpty);
  Result := nil;
  SetLength(Result, Length(Words));
  for I := 0 to High(Words) do
    if I < High(Words) then
      Result[I] := Words[I] + ' '
    else
      Result[I] := Words[I];
end;

end.
