unit DeepCW.BandMap;

{ 局ごとの文字列を、運用者が読める一覧の 1 行へ翻訳します（要件 FR-J）。

  多局同時受信（DeepCW.Multi）が出すのは**事実**です。「この音程から、この時刻に、
  この文字が出た」。運用者が知りたいのはその生の文字列ではなく、
  **「誰が」「どの周波数で」「いつ」「呼べる状態か」**の 4 つです。ここはその
  翻訳だけを行います。

  層を分けてあるのには理由があります。呼出符号の確からしさは四段構えで、
  第 1 段（形の検査）と第 2 段（複数回の一致）はここで完結しますが、第 3 段
  （手元の一覧との照合）と第 4 段（実在の確認）は外部の資料や通信を伴います
  （要件 FR-K）。**復号の機械にその知識を持たせると、後で通信まで抱え込みます。**

  Translates each station's characters into one readable row (requirement FR-J).

  Multi-station reception (DeepCW.Multi) produces **facts**: this pitch, at this
  time, gave these characters. What an operator wants is not that raw string but
  **who, on what frequency, when, and whether they can be called.** This unit
  does only that translation.

  The layers are separate for a reason. A call sign's trustworthiness is built in
  four stages: the first (the shape rule) and the second (agreement between
  sightings) are settled here, while the third (checking a list held locally) and
  the fourth (confirming the station exists) involve outside material and outside
  traffic (requirement FR-K). **Giving the decoding machine that knowledge would
  eventually give it the network traffic too.** }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, DeepCW.Types, DeepCW.Decoder, DeepCW.Callsign, DeepCW.Multi,
  DeepCW.Exchange;

const
  { CQ を出していると見なす、最後の根拠からの時間。要件は「根拠が消えたら区別も
    消す」なので、古い CQ をいつまでも根拠にはしません。
    How long a CQ counts as evidence. The requirement is that the distinction
    goes when its evidence goes, so an old CQ does not stand for ever. }
  BANDMAP_CALLING_SECONDS = 120.0;

  { 一覧の右端に添える、直近の文字数。全文は行を選んだときに出します。
    How many recent characters ride along at the end of a row; the whole
    transcript appears when the row is chosen. }
  BANDMAP_RECENT_CHARS = 28;

  { 同じ符号がこの回数出たら「複数回の一致」と見なします（要件 FR-J.7）。
    実運用では呼出符号を 2 回続けて送るのが普通で、付録 H では 40 回中、誤った
    まま一致した例は 0 件でした。
    How many sightings count as agreement (requirement FR-J.7). Sending a call
    sign twice is ordinary practice, and in appendix H no wrong reading ever
    agreed with itself across forty attempts. }
  BANDMAP_AGREEMENT = 2;

type
  { 呼出符号をどこまで信じてよいか。要件 FR-K の四段に対応します。

    **第 3 段は、自局の交信記録で満たします**（要件 FR-K.11）。交信した相手は
    確かに実在します。しかも**通信もプライバシーの代償も要りません。**手元の
    一覧との照合（FR-K.9）と実在の確認（FR-K.3〜K.6）は、同じ第 3・第 4 段へ
    あとから合流します。どの資料で満たしたのかは `TrustSource` に入ります。

    **第 4 段は、この版では設定されません。**

    How far a call sign may be trusted, matching the four stages of requirement
    FR-K.

    **The third stage is met by the operator's own contact log**
    (requirement FR-K.11): a station that has been worked certainly exists, and
    **it costs neither traffic nor privacy to know it.** A locally held roster
    (FR-K.9) and an outside check (FR-K.3-K.6) join the same two stages later;
    what filled the stage is named in `TrustSource`.

    **The fourth stage is never set in this version.** }
  TCallsignTrust = (
    ctNone,      { 候補が無い / no candidate }
    ctShape,     { 形が規則に合う。1 度きり / the shape fits, seen once }
    ctAgreed,    { 同じ符号が複数回出た / the same call sign came out repeatedly }
    ctInRoster,  { 手元の資料にある / in material held locally }
    ctVerified); { 実在を確認した（未実装）/ confirmed to exist (not built) }

  { 一覧の 1 行。/ One row of the list. }
  TBandEntry = record
    Id: Int64;
    Hz: Double;
    LevelDb: Double;
    HalfWidthHz: Double;
    FirstSeconds: Double;
    LastSeconds: Double;
    { 読み取れた呼出符号と、その確からしさ。Trust が ctShape どまりのものは
      「まだ確かでない」と分かる形で見せてください（要件 FR-J.7）。
      The call sign read and how far it is trusted. Anything no further than
      ctShape must be shown as not yet certain (requirement FR-J.7). }
    Callsign: string;
    Trust: TCallsignTrust;
    { 同じ符号が出た回数と、いちばん良かったときの文字の確からしさ。
      How many times the same call sign came out, and the character confidence of
      the best of those sightings. }
    Sightings: Integer;
    Confidence: Single;
    { CQ を出しているか（要件 FR-J.2）。根拠は受信文の中の CQ です。
      Whether the station is calling CQ (requirement FR-J.2), on the evidence of a
      CQ in its transcript. }
    Calling: Boolean;
    { いま聞こえているか。/ Whether it is audible now. }
    Heard: Boolean;
    { いま解析の対象になっているか（要件 FR-I.7）。
      Whether it is being analysed (requirement FR-I.7). }
    Analysed: Boolean;
    { 能力の都合で読んでいない局か。**聞こえているのに読んでいない**場合だけ
      真です。送信を止めただけの局と混同しないための区別で、混同すると、
      止めただけの局を「切り捨てた」と見せることになります（要件 FR-I.7）。
      Whether it was cut for want of capacity: true only when it is **audible and
      not being read.** The distinction keeps it apart from a station that simply
      stopped, which would otherwise be shown as one that was cut
      (requirement FR-I.7). }
    Cut: Boolean;
    { この音程に畳み込まれた別の峰の数（要件 FR-J.6）。0 より大きい行は、
      1 局として読んだふりをせず「密集」と示してください。
      How many peaks were folded into this pitch (requirement FR-J.6). A row
      greater than zero must be shown as crowded rather than pretending to have
      read one station. }
    Crowded: Integer;
    { 直近の文字。一覧の中で「いま何を送っているか」の気配を伝えます。
      The most recent characters, giving a sense of what is being sent now. }
    Recent: string;
    { この局と交信したことがあるか（要件 FR-J.4）。記録が無ければ区別しません。

      **呼出符号が確かでないうちは、交信済みとは言いません。**1 文字違いの別人を
      「交信済み」と示すのは、示さないより悪いためです。判定は BuildBandEntries
      に渡された引き当ての手続きが行い、この層は記録の中身を知りません
      （要件 FR-K の段を足す先が同じ場所になります）。

      Whether this station has been worked before (requirement FR-J.4); with no
      log there is no distinction to draw.

      **Nothing is called worked while the call sign is not certain**: showing a
      station one letter away as already worked is worse than showing nothing.
      The lookup is done by the procedure handed to BuildBandEntries, and this
      layer knows nothing of the log's contents — which is where the further
      stages of FR-K will attach. }
    Worked: Boolean;

    { 待っている呼出符号に当たったか（要件 FR-I.4）。当たっていれば、待っていた
      ほうの符号が入ります。空なら当たっていません。

      **交信済みと同じ条件で、確かな符号にだけ付けます。**1 文字違いの別人を
      「待っていた局です」と知らせるのは、黙っているより悪いためです。付録 T.2 の
      実測では、この条件を課しても見逃しは増えませんでした。

      The watched call sign this row matched (requirement FR-I.4), or empty for
      none.

      **It is drawn only on a certain call sign, on the same condition as the
      worked mark**: announcing whoever is one letter away as the station waited
      for is worse than staying silent. The measurement in appendix T.2 found
      that requiring it costs no misses. }
    Watched: string;

    { 第 3 段を満たした資料の名前（要件 FR-K.11・FR-K.9）。空なら第 3 段では
      ありません。

      **どの資料で確かめたのかを残します。**「一覧にあり」とだけ出すと、
      自分の交信記録で確かめたのか、配られた一覧にあったのかが分かりません。
      根拠の強さが違うので、そこは同じ言葉にしません。

      What material met the third stage (requirements FR-K.11, FR-K.9); empty
      when the stage was not reached.

      **Which material confirmed it is kept.** Shown only as "in a list", there
      would be no telling one's own log from a roster someone distributed, and
      those are not evidence of the same strength. }
    TrustSource: string;
  end;
  TBandEntries = array of TBandEntry;

type
  { 交信済みかを引く手続き。記録そのものはここでは持ちません。**復号の側に
    記録の知識を持たせないためです**（要件 FR-K の第 3・4 段は外部の資料と通信を
    伴います）。nil を渡せば、交信済みの区別を付けません。
    The lookup for whether a station has been worked. The log itself is not held
    here, **so that the decoding side carries no knowledge of it** (the third and
    fourth stages of FR-K involve outside material and outside traffic). Passing
    nil draws no such distinction. }
  TWorkedLookup = function(const Callsign: string): Boolean of object;

  { 待っている符号のどれに当たるかを引く手続き。当たらなければ空を返します。
    一覧が待ち符号そのものを持たないのは、交信記録を持たないのと同じ理由です。
    The lookup for which watched call sign a row matches, empty for none. The
    list holds no watch list itself, for the same reason it holds no log. }
  TWatchLookup = function(const Callsign: string): string of object;

  { 手元の一覧に在るかを引く手続き（要件 FR-K.9）。在れば**その一覧の名前**を、
    無ければ空を返します。

    真偽ではなく名前を返すのは、**何で確かめたのかを一覧に出すため**です
    （`TrustSource`）。「一覧にあり」とだけ出すと、自分の交信記録で確かめたのか、
    配られた一覧にあったのかが分かりません。

    一覧そのものをここで持たないのは、交信記録を持たないのと同じ理由です。

    The lookup for whether a call sign is in a locally held roster (requirement
    FR-K.9): **the roster's name** when it is, empty when it is not.

    A name rather than a yes, **so that the list can say what confirmed it**
    (`TrustSource`): shown only as "in a list", there would be no telling one's
    own log from a roster someone distributed.

    The roster itself is not held here, for the same reason the log is not. }
  TRosterLookup = function(const Callsign: string): string of object;

{ 局ごとの読み取り結果を、一覧の行へ翻訳します。渡された引き当て以外に状態を
  持たず、同じ入力からは必ず同じ行が出ます。

  Translates the per-station results into rows. Beyond the lookup it is handed it
  holds no state, and the same input always gives the same rows. }
function BuildBandEntries(const Logs: TStationLogs; NowSeconds: Double;
  Worked: TWorkedLookup = nil; Watch: TWatchLookup = nil;
  Roster: TRosterLookup = nil): TBandEntries;

{ 確からしさを、運用者に見せる短い言葉にします。
  Puts the trust into the few words shown to the operator. }
function TrustCaption(Trust: TCallsignTrust): string;
{ 何で確かめたのかまで含む表示（要件 FR-K.11）。
  The same, naming what confirmed it (requirement FR-K.11). }
function TrustCaption(const Entry: TBandEntry): string;


{ 1 行に出す名前。密集・確からしさ・交信済み・待っていた局の印まで含みます。

  **この規則をここに置くのは、一覧とウォーターフォールで別の文字が出ては困る
  ためです。**同じ局を、一覧では `JH2XYZ ?`、波形では `JH2XYZ` と書いたら、
  どちらを信じるべきか分かりません（要件 FR-J.5・FR-J.7）。

  The name shown for one row, including the crowded, trust, worked and
  waited-for marks.

  **The rule lives here so that the list and the waterfall cannot show different
  text for the same station**: written `JH2XYZ ?` in one and `JH2XYZ` in the
  other, there would be no telling which to believe (requirements FR-J.5,
  FR-J.7). }
function EntryCaption(const Entry: TBandEntry): string;

implementation

{ 語に切る規則と、相手の符号を選ぶ規則は DeepCW.Exchange が持ちます。交信モードの
  記録も同じ規則で選ぶ必要があり、写しを 2 つ置くと食い違うためです。
  Splitting into words and choosing the station's call sign live in
  DeepCW.Exchange: the contact log has to choose by the same rule, and two
  copies would drift apart. }

{ 最後に CQ を送った時刻。無ければ負の値を返します。
  When CQ was last sent, or a negative value if never. }
function LastCallingSeconds(const Words: TWords): Double;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(Words) do
    if Words[I].Text = 'CQ' then
      Result := Words[I].Seconds;
end;

function BuildBandEntries(const Logs: TStationLogs; NowSeconds: Double;
  Worked: TWorkedLookup; Watch: TWatchLookup; Roster: TRosterLookup): TBandEntries;
var
  I: Integer;
  Words: TWords;
  Text: string;
  Calling: Double;
begin
  SetLength(Result, Length(Logs));
  for I := 0 to High(Logs) do
  begin
    Result[I].Id := Logs[I].Id;
    Result[I].Hz := Logs[I].Hz;
    Result[I].LevelDb := Logs[I].LevelDb;
    Result[I].HalfWidthHz := Logs[I].HalfWidthHz;
    Result[I].FirstSeconds := Logs[I].FirstSeconds;
    Result[I].LastSeconds := Logs[I].LastSeconds;
    Result[I].Heard := Logs[I].Heard;
    Result[I].Analysed := Logs[I].Analysed;
    Result[I].Cut := Logs[I].Heard and not Logs[I].Analysed;
    Result[I].Crowded := Logs[I].Crowded;

    Words := SplitWords(Logs[I].Chars);
    ChooseCallsign(Words, Result[I].Callsign, Result[I].Sightings,
      Result[I].Confidence);
    if Result[I].Callsign = '' then
      Result[I].Trust := ctNone
    else if Result[I].Sightings >= BANDMAP_AGREEMENT then
      Result[I].Trust := ctAgreed
    else
      Result[I].Trust := ctShape;

    Calling := LastCallingSeconds(Words);
    Result[I].Calling := (Calling >= 0) and
      (NowSeconds - Calling <= BANDMAP_CALLING_SECONDS);

    { 交信済みの区別は、呼出符号が確かなときだけ付けます。**確かでない符号で
      「交信済み」と示すのは、1 文字違いの別人をそう示すことです。**
      The worked distinction is drawn only for a certain call sign: **drawing it
      on an uncertain one draws it on whoever is one letter away.** }
    Result[I].Worked := Assigned(Worked) and
      (Result[I].Trust >= ctAgreed) and Worked(Result[I].Callsign);

    { **交信した相手は、確かに実在します**（要件 FR-K.11）。自分の記録は、
      配られた一覧よりも確かで、通信もプライバシーの代償も要りません。
      記録が無ければ何も変わりません——**無いことを根拠にはしません。**

      **A station that has been worked certainly exists** (requirement FR-K.11).
      One's own record is better evidence than a distributed roster and costs
      neither traffic nor privacy. With no log nothing changes: **its silence is
      never taken as evidence.** }
    Result[I].TrustSource := '';
    if Result[I].Worked then
    begin
      Result[I].Trust := ctInRoster;
      Result[I].TrustSource := '交信記録';
    end
    { **交信記録が先です。**自分が交信した相手であることは、配られた一覧に
      名前があることより確かな根拠です。両方に在るときは、強いほうを言います
      （要件 FR-K.9・FR-K.11）。

      一覧のほうも、確かでない符号には当てません。**1 文字違いの符号を一覧に
      当てれば、隣の実在局の名前で「実在する」と言うことになります**（付録 T.2
      と同じ理由）。

      **One's own log comes first**: having worked a station is better evidence
      than a name in a distributed roster, and where both hold it, the stronger
      one is what gets said (requirements FR-K.9, FR-K.11).

      The roster is not applied to an uncertain call sign either: **matching one
      that is a letter off would call it real on the strength of the
      neighbouring station's entry** (the reasoning of appendix T.2). }
    else if Assigned(Roster) and (Result[I].Trust >= ctAgreed) then
    begin
      Result[I].TrustSource := Roster(Result[I].Callsign);
      if Result[I].TrustSource <> '' then
        Result[I].Trust := ctInRoster;
    end;

    { 待っている符号との照合も、同じ確かさの条件で行います。条件を 2 つに分けると、
      一覧に出ていない符号で知らせが鳴りうることになります。
      The watch is matched on the same trust condition. Two different conditions
      would let an announcement fire on a call sign the list is not showing. }
    Result[I].Watched := '';
    if Assigned(Watch) and (Result[I].Trust >= ctAgreed) then
      Result[I].Watched := Watch(Result[I].Callsign);

    Text := DecodedText(Logs[I].Chars);
    if Length(Text) > BANDMAP_RECENT_CHARS then
      Text := Copy(Text, Length(Text) - BANDMAP_RECENT_CHARS + 1,
        BANDMAP_RECENT_CHARS);
    Result[I].Recent := Trim(Text);
  end;
end;

function EntryCaption(const Entry: TBandEntry): string;
begin
  { 密集している範囲は、1 局として読んだふりをしません（要件 FR-J.6）。
    A crowded stretch is not passed off as one station (requirement FR-J.6). }
  if Entry.Crowded > 0 then
    Exit(Format('密集 %d', [Entry.Crowded + 1]));
  case Entry.Trust of
    ctNone: Result := '';
    ctShape: Result := Entry.Callsign + ' ?';
  else
    Result := Entry.Callsign;
  end;
  { 交信済みの局に印を付けます（要件 FR-J.4）。呼びに行くかどうかの判断が、
    一覧を見ただけで付きます。
    A mark for a station already worked (requirement FR-J.4), so that whether to
    call is decided from the list alone. }
  if Entry.Worked then
    Result := Result + ' ✓';
  { 待っていた局には印を付けます（要件 FR-I.4）。**知らせは一度きりで流れて
    しまうので、行にも残します。**
    A mark for the station being waited for (requirement FR-I.4): **an
    announcement goes by once, so the row carries it too.** }
  if Entry.Watched <> '' then
    Result := Result + ' ★';
end;

function TrustCaption(Trust: TCallsignTrust): string;
begin
  case Trust of
    ctShape: Result := '確認中';
    ctAgreed: Result := '一致';
    ctInRoster: Result := '資料あり';
    ctVerified: Result := '実在確認';
  else
    Result := '';
  end;
end;

function TrustCaption(const Entry: TBandEntry): string;
begin
  Result := TrustCaption(Entry.Trust);
  { **何で確かめたのかまで出します。**「資料あり」だけでは、自分が交信した
    相手なのか、誰かが配った一覧に載っていただけなのかが分かりません。
    **What confirmed it is shown too**: "in material" alone would not say
    whether this is a station one has worked or merely a name on a list somebody
    handed out. }
  if (Entry.TrustSource <> '') and (Entry.Trust = ctInRoster) then
    Result := Entry.TrustSource + 'あり';
end;

end.
