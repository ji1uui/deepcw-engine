unit DeepCW.Practice;

{ 受信練習の出題と採点です（要件 FR-F.3）。

  練習と実運用が同じアプリで続くことが FR-F の目標です。ここが持つのは 2 つだけ
  です。**何を出すか**と、**写したものをどう突き合わせるか。**音を作るのは
  `DeepCW.Morse`、鳴らすのは `DeepCW.Audio` の仕事で、ここは文字しか触りません。

  そのため、このユニットは音声も画面も要らずに試験できます。**出題と採点は、
  練習の値打ちそのものです。**耳で確かめられないものだからこそ、数字で確かめ
  られる形にしてあります。

  The material and the marking for receive practice (requirement FR-F.3).

  FR-F's aim is that practice and operating live in one application. Two things
  belong here: **what to send**, and **how to compare what was copied against
  it.** Making the sound belongs to `DeepCW.Morse` and playing it to
  `DeepCW.Audio`; this unit touches nothing but text.

  So it can be tested without a sound card or a window. **The material and the
  marking are the value of the practice**, and being unable to check them by ear
  is exactly why they are shaped so they can be checked by number. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DeepCW.Types, DeepCW.Morse, DeepCW.Callsign;

type
  { 出題の種類。**文字集合の選択でもあります**（要件 FR-F.3 の受入基準）。
    The kind of material, **which is also the choice of character set**
    (the acceptance criterion of requirement FR-F.3). }
  TExerciseKind = (
    ekLetters,    { 欧文だけ / letters only }
    ekMixed,      { 欧文と数字 / letters and digits }
    ekCallsigns,  { 呼出符号 / call signs }
    ekQso         { QSO の定型文 / the phrases of a contact }
  );

const
  EXERCISE_NAMES: array[TExerciseKind] of string = (
    '欧文（A〜Z）', '欧文と数字', '呼出符号', 'QSO 定型文');

{ 出題を 1 つ作ります。`Groups` は語（5 文字の群、呼出符号、定型文の 1 行）の数、
  `Seed` は乱数の種です。

  **種を受け取るのは、同じ問題をもう一度出せるようにするためです。**試験は同じ
  出題に対する採点を確かめられ、利用者は「さっきと同じ問題をもう一度」を選べます。

  Builds one exercise. `Groups` counts the units -- groups of five characters,
  call signs, or lines of a contact -- and `Seed` seeds the random numbers.

  **The seed is taken so that the same exercise can be given again**: a test can
  check the marking of a known exercise, and an operator can ask for the one they
  just heard. }
function MakeExercise(Kind: TExerciseKind; Groups, Seed: Integer): string;

type
  { 1 文字ぶんの突き合わせ。
    One character's worth of comparison. }
  TCopyMark = (
    cmSame,    { 合っている / copied correctly }
    cmWrong,   { 別の文字を書いた / a different character was written }
    cmMissed,  { 書き落とした / nothing was written }
    cmExtra    { 無いものを書いた / something was written that was not sent }
  );

  TCopyStep = record
    Truth: Char;   { 出題の文字。cmExtra では #0 / the character sent }
    Typed: Char;   { 写した文字。cmMissed では #0 / the character copied }
    Mark: TCopyMark;
  end;
  TCopySteps = array of TCopyStep;

  { 採点の結果。
    The result of marking. }
  TCopyScore = record
    Steps: TCopySteps;
    { 出題の文字数（空白を除く）と、その内訳。
      The characters sent, spaces aside, and what became of them. }
    Total: Integer;
    Same: Integer;
    Wrong: Integer;
    Missed: Integer;
    Extra: Integer;
    Percent: Double;
  end;

{ 写したものを出題と突き合わせます。

  **文字を 1 つ書き落としただけで、あとが全部ずれてはいけません。**「1 文字ずつ
  前から比べる」やり方はそうなります。編集距離の経路をたどり、書き落とし・書き
  足しも含めて並べ直します。

  空白は並べるためには使いますが、**点には数えません。**語の切れ目をどう書くかは
  写し方の癖であって、符号を読めたかどうかとは別のことです。

  大文字小文字と余分な空白は `DeepCW.Morse.NormalizeText` で揃えます。**送れない
  文字は出題にも入らないので、写したほうからも落とします。**

  Compares what was copied against what was sent.

  **One character missed must not throw everything after it out of step**, which
  is what comparing position by position would do. The path of the edit distance
  is followed instead, so a dropped or an added character lines the rest back up.

  Spaces take part in the alignment but **are not scored**: how someone writes
  the breaks between words is a habit of copying, not whether the code was read.

  Case and stray spacing are settled by `DeepCW.Morse.NormalizeText`. **What
  cannot be sent never appears in the exercise, so it is dropped from the copy
  too.** }
function ScoreCopy(const Truth, Typed: string): TCopyScore;

{ 間違いを短い言葉にします（要件 FR-F.5 の材料）。多い順に並べ、上位だけを
  返します。空なら空文字です。
  Puts the mistakes into a short phrase (the material for requirement FR-F.5),
  commonest first and only the top few. Empty when there are none. }
function MistakeSummary(const Score: TCopyScore; Top: Integer = 3): string;

{ 遅延表示（要件 FR-F.4）。

  **「先に自分で写し、後から正解を出す」には、遅らせる時間が要ります。**
  鳴った直後に正解が出れば、写す前に目が拾ってしまう。遅らせれば、頭の中で
  読んでから答え合わせができる。

  0 秒は「鳴ったそばから出す」で、これはこれで初心者の練習になります。

  Delayed reveal (requirement FR-F.4).

  **"Copy it yourself first, see the answer afterwards" needs a delay to be set.**
  An answer that appears the instant the character sounds is picked up by the eye
  before it is copied; delayed, the character is read in the head first and
  checked afterwards.

  Zero seconds means "as it sounds", which is itself how a beginner practises. }
const
  REVEAL_DELAY_DEFAULT_SECONDS = 5;
  REVEAL_DELAY_MAX_SECONDS = 60;

{ 出題の各文字を「見せてよい」時刻（音の先頭からの秒）。

  文字が**鳴り終わった時刻**に `DelaySeconds` を足したものです。鳴り始めでは
  ありません。鳴り終わる前に出せば、聴きながら読むことになります（教訓 10.29 と
  同じ間違い方です）。

  `LeadInSeconds` は音の頭の無音で、`TCWToneOptions.LeadInSeconds` と同じ値を
  渡してください。ここを忘れると、表示が音より先に出ます。

  返る配列は `NormalizeText(Text)` の 1 文字ごとに 1 つで、**必ず増加します。**
  空白のように音を持たない文字は、直前の文字と同じ時刻になります。

  When each character of the exercise may be shown, in seconds from the start of
  the sound.

  It is the time the character **finishes sounding** plus `DelaySeconds`, not the
  time it starts: shown before it finishes, it would be read along with the
  sound rather than copied (the same mistake as lesson 10.29).

  `LeadInSeconds` is the silence before the code, the same value as
  `TCWToneOptions.LeadInSeconds`; forgotten, the text runs ahead of the sound.

  One entry per character of `NormalizeText(Text)`, **never decreasing**. A
  character with no sound of its own, a space, takes the time of the one before
  it. }
function RevealTimes(const Text: string; const Timing: TCWTiming;
  LeadInSeconds, DelaySeconds: Double): TDoubleArray;

{ `ElapsedSeconds` の時点で見せてよいところまで。`RevealTimes` が返した配列を
  そのまま渡してください。
  As much of the exercise as may be shown at `ElapsedSeconds`, given the array
  `RevealTimes` returned. }
function RevealedText(const Text: string; const Times: TDoubleArray;
  ElapsedSeconds: Double): string;

implementation

const
  LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  DIGITS = '0123456789';
  { 5 文字を 1 群にするのは、CW の練習でも試験でも用いられている単位です。
    Groups of five: the unit used in CW practice and in tests of it alike. }
  GROUP_SIZE = 5;

  { 呼出符号を作るための前置符字。**作った符号は `ParseCallsign` に通して確かめ
    ます。**ここに無い形を思いつきで足しても、通らなければ出題になりません。
    Prefixes for building call signs. **What is built is put through
    `ParseCallsign`**, so a form invented here that the rules reject never
    becomes an exercise. }
  PREFIXES: array[0..15] of string = (
    'JA', 'JE', 'JF', 'JH', 'JI', 'JJ', 'JK', 'JR',
    'W', 'K', 'N', 'G', 'DL', 'VK', 'ZL', 'F');

  { QSO の定型文。`%a` と `%b` は**その 1 文の中で決まった 2 局**で、同じ札は
    同じ局を指します。`%r` は信号報告、`%q` は地名です。

    2 つの札を分けているのは、**CQ は自分の符号を 2 度繰り返す**からです。呼ぶ
    たびに違う符号が出る出題では、覚えるのは実際には無い呼び方になります。

    The phrases of a contact. `%a` and `%b` are **two stations settled within the
    one line**, the same mark meaning the same station; `%r` is a report and `%q`
    a place.

    There are two marks because **a CQ repeats the caller's own call sign**: an
    exercise where each repetition drew a different one would teach a call that
    is never made. }
  PHRASES: array[0..5] of string = (
    'CQ CQ DE %a %a K',
    '%a DE %b UR %r %r QTH %q K',
    '%a DE %b TNX FER CALL UR %r BK',
    'R R DE %a QTH %q OP TARO K',
    'TNX FER QSO 73 ES GL DE %a SK',
    '%a DE %b RST %r ES QTH %q HW CPY BK'
  );

  PLACES: array[0..7] of string = (
    'TOKYO', 'OSAKA', 'NAGOYA', 'SAPPORO', 'SENDAI', 'KYOTO', 'KOBE', 'FUKUOKA');

{ 1 つ選びます。/ Picks one. }
function Pick(const Items: array of string): string;
begin
  Result := Items[Random(Length(Items))];
end;

{ 規則を満たす呼出符号を 1 つ作ります。**作ってから確かめます。**
  Builds one call sign that satisfies the rules, **checking after building.** }
function MakeCallsign: string;
var
  Attempt, I, Length_: Integer;
  Candidate: string;
  Parsed: TCallsign;
begin
  for Attempt := 1 to 50 do
  begin
    Candidate := Pick(PREFIXES) + DIGITS[1 + Random(10)];
    Length_ := 2 + Random(2);
    for I := 1 to Length_ do
      Candidate := Candidate + LETTERS[1 + Random(Length(LETTERS))];
    if ParseCallsign(Candidate, Parsed) then
      Exit(Candidate);
  end;
  { ここへは来ない見込みですが、来たときに空を返すよりは、確実に通る形を
    返します。**出題が空になるほうが、運用者にとっては困ります。**
    Reaching here is not expected, but a form known to pass is better than an
    empty string: **an empty exercise is the worse outcome for the operator.** }
  Result := 'JA1ABC';
end;

function MakeExercise(Kind: TExerciseKind; Groups, Seed: Integer): string;
var
  I, J: Integer;
  Set_, Piece, Phrase, CallA, CallB: string;
begin
  Result := '';
  if Groups < 1 then
    Groups := 1;
  RandSeed := Seed;
  case Kind of
    ekLetters: Set_ := LETTERS;
    ekMixed: Set_ := LETTERS + DIGITS;
  else
    Set_ := '';
  end;

  for I := 1 to Groups do
  begin
    case Kind of
      ekLetters, ekMixed:
        begin
          Piece := '';
          for J := 1 to GROUP_SIZE do
            Piece := Piece + Set_[1 + Random(Length(Set_))];
        end;
      ekCallsigns:
        Piece := MakeCallsign;
    else
      begin
        Phrase := Pick(PHRASES);
        { 2 局は 1 文につき 1 度だけ決めます。同じ札が同じ局を指すのは、
          ここで決めているからです。
          The two stations are settled once per line, which is what makes the
          same mark mean the same station. }
        CallA := MakeCallsign;
        repeat
          CallB := MakeCallsign;
        until CallB <> CallA;
        Piece := '';
        J := 1;
        while J <= Length(Phrase) do
        begin
          if (Phrase[J] = '%') and (J < Length(Phrase)) then
          begin
            case Phrase[J + 1] of
              'a': Piece := Piece + CallA;
              'b': Piece := Piece + CallB;
              'r': Piece := Piece + Format('%d%d%d',
                     [3 + Random(3), 5 + Random(5), 5 + Random(5)]);
              'q': Piece := Piece + Pick(PLACES);
            else
              Piece := Piece + Phrase[J + 1];
            end;
            Inc(J, 2);
          end
          else
          begin
            Piece := Piece + Phrase[J];
            Inc(J);
          end;
        end;
      end;
    end;
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Piece;
  end;
  { 送れる形に整えてから返します。**出題が送れない文字を含んでいれば、鳴らした
    ものと出題が食い違います。**
    Normalised before it is returned: **an exercise holding what cannot be sent
    would differ from what was sounded.** }
  Result := NormalizeText(Result);
end;

function ScoreCopy(const Truth, Typed: string): TCopyScore;
var
  A, B: string;
  Cost: array of array of Integer;
  I, J, Count: Integer;
  Steps: TCopySteps;

  function Least(X, Y, Z: Integer): Integer;
  begin
    Result := X;
    if Y < Result then Result := Y;
    if Z < Result then Result := Z;
  end;

begin
  Result := Default(TCopyScore);
  A := NormalizeText(Truth);
  B := NormalizeText(Typed);

  { 編集距離の表を作ります。長さは出題 1 つぶんで、費用は問題になりません。
    The edit distance table; an exercise is short enough that its cost does not
    matter. }
  SetLength(Cost, Length(A) + 1, Length(B) + 1);
  for I := 0 to Length(A) do
    Cost[I, 0] := I;
  for J := 0 to Length(B) do
    Cost[0, J] := J;
  for I := 1 to Length(A) do
    for J := 1 to Length(B) do
      if A[I] = B[J] then
        Cost[I, J] := Cost[I - 1, J - 1]
      else
        Cost[I, J] := 1 + Least(Cost[I - 1, J - 1], Cost[I - 1, J], Cost[I, J - 1]);

  { 経路を後ろからたどり、並べ直します。
    The path is walked backwards and the two are laid side by side. }
  SetLength(Steps, Length(A) + Length(B));
  Count := 0;
  I := Length(A);
  J := Length(B);
  while (I > 0) or (J > 0) do
  begin
    if (I > 0) and (J > 0) and (A[I] = B[J]) then
    begin
      Steps[Count].Truth := A[I];
      Steps[Count].Typed := B[J];
      Steps[Count].Mark := cmSame;
      Dec(I); Dec(J);
    end
    else if (I > 0) and (J > 0) and (Cost[I, J] = Cost[I - 1, J - 1] + 1) then
    begin
      Steps[Count].Truth := A[I];
      Steps[Count].Typed := B[J];
      Steps[Count].Mark := cmWrong;
      Dec(I); Dec(J);
    end
    else if (I > 0) and (Cost[I, J] = Cost[I - 1, J] + 1) then
    begin
      Steps[Count].Truth := A[I];
      Steps[Count].Typed := #0;
      Steps[Count].Mark := cmMissed;
      Dec(I);
    end
    else
    begin
      Steps[Count].Truth := #0;
      Steps[Count].Typed := B[J];
      Steps[Count].Mark := cmExtra;
      Dec(J);
    end;
    Inc(Count);
  end;

  { たどった順は後ろからなので、前から読める向きへ直します。
    The walk ran backwards, so the steps are turned to read forwards. }
  SetLength(Result.Steps, Count);
  for I := 0 to Count - 1 do
    Result.Steps[I] := Steps[Count - 1 - I];

  for I := 0 to Count - 1 do
  begin
    { 空白は並べるためだけに使い、点には数えません。
      Spaces align the two but are not scored. }
    if (Result.Steps[I].Truth = ' ') or (Result.Steps[I].Typed = ' ') then
      Continue;
    case Result.Steps[I].Mark of
      cmSame: begin Inc(Result.Same); Inc(Result.Total); end;
      cmWrong: begin Inc(Result.Wrong); Inc(Result.Total); end;
      cmMissed: begin Inc(Result.Missed); Inc(Result.Total); end;
      cmExtra: Inc(Result.Extra);
    end;
  end;
  if Result.Total > 0 then
    Result.Percent := 100 * Result.Same / Result.Total;
end;

function MistakeSummary(const Score: TCopyScore; Top: Integer): string;
var
  Keys: array of string;
  Counts: array of Integer;
  I, J, Found, Best, BestAt, Shown: Integer;
  Key: string;
begin
  Result := '';
  Keys := nil;
  Counts := nil;
  for I := 0 to High(Score.Steps) do
  begin
    if (Score.Steps[I].Truth = ' ') or (Score.Steps[I].Typed = ' ') then
      Continue;
    case Score.Steps[I].Mark of
      cmWrong: Key := Score.Steps[I].Truth + ' → ' + Score.Steps[I].Typed;
      cmMissed: Key := Score.Steps[I].Truth + ' を落とした';
      cmExtra: Key := Score.Steps[I].Typed + ' を足した';
    else
      Continue;
    end;
    Found := -1;
    for J := 0 to High(Keys) do
      if Keys[J] = Key then
      begin
        Found := J;
        Break;
      end;
    if Found >= 0 then
      Inc(Counts[Found])
    else
    begin
      SetLength(Keys, Length(Keys) + 1);
      SetLength(Counts, Length(Counts) + 1);
      Keys[High(Keys)] := Key;
      Counts[High(Counts)] := 1;
    end;
  end;

  Shown := 0;
  while Shown < Top do
  begin
    Best := 0;
    BestAt := -1;
    for J := 0 to High(Keys) do
      if Counts[J] > Best then
      begin
        Best := Counts[J];
        BestAt := J;
      end;
    if BestAt < 0 then
      Break;
    if Result <> '' then
      Result := Result + '、';
    if Best > 1 then
      Result := Result + Format('%s（%d 回）', [Keys[BestAt], Best])
    else
      Result := Result + Keys[BestAt];
    Counts[BestAt] := 0;
    Inc(Shown);
  end;
end;

function RevealTimes(const Text: string; const Timing: TCWTiming;
  LeadInSeconds, DelaySeconds: Double): TDoubleArray;
var
  Normalized: string;
  Segments: TCWSegments;
  I, Index_: Integer;
  At_, Ends: Double;
begin
  Result := nil;
  Normalized := NormalizeText(Text);
  if Normalized = '' then
    Exit;
  SetLength(Result, Length(Normalized));
  for I := 0 to High(Result) do
    Result[I] := 0;

  Segments := TextToSegments(Normalized, Timing);
  At_ := LeadInSeconds;
  for I := 0 to High(Segments) do
  begin
    Ends := At_ + Segments[I].Duration;
    Index_ := Segments[I].TextIndex;
    { 語間（TextIndex = 0）は、どの文字のものでもありません。
      A word gap belongs to no character. }
    if (Index_ >= 1) and (Index_ <= Length(Result)) then
      if Ends > Result[Index_ - 1] then
        Result[Index_ - 1] := Ends;
    At_ := Ends;
  end;

  { 音を持たない文字（空白）は、直前の文字と同じ時刻にします。そのうえで、
    **戻らないことを保証します。**戻れば、いちど出た文字が消えます。
    A character with no sound of its own takes the time of the one before it,
    and the whole sequence is then forced not to go backwards: **a time that
    went back would take away a character already shown.** }
  for I := 1 to High(Result) do
    if Result[I] < Result[I - 1] then
      Result[I] := Result[I - 1];
  for I := 0 to High(Result) do
    Result[I] := Result[I] + DelaySeconds;
end;

function RevealedText(const Text: string; const Times: TDoubleArray;
  ElapsedSeconds: Double): string;
var
  Normalized: string;
  Count, I: Integer;
begin
  Normalized := NormalizeText(Text);
  Count := 0;
  for I := 0 to High(Times) do
  begin
    if I >= Length(Normalized) then
      Break;
    if Times[I] > ElapsedSeconds then
      Break;
    Count := I + 1;
  end;
  Result := Copy(Normalized, 1, Count);
end;

end.
