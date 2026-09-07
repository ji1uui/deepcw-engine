program gui_probe;

{ 受信画面の描画部品の検証用プログラムです。

  画面のない環境でも、部品を実際に生成し、音声を流し込み、描画させ、クリック
  やホイールの操作を与えて、結果を PNG に書き出せます。GUI の不具合は組み上げ
  てからでないと出ないため、これがないと確かめようがありません
  （要件 NFR-7.1）。

  A harness for the receive tab's drawing controls.

  Even without a display it creates the control for real, feeds it audio, makes
  it paint, and applies clicks and wheel events, writing the result out as a
  PNG. GUI defects only appear once things are assembled, so without this there
  would be no way to check (requirement NFR-7.1). }

{$mode objfpc}{$H+}

uses
  SysUtils, DateUtils, Math, Classes, Interfaces, Forms, Controls, Graphics, LCLType,
  DeepCW.Types, DeepCW.Morse, DeepCW.Tuner, DeepCW.Decoder,
  DeepCW.Review, DeepCW.Multi, DeepCW.BandMap, DeepCW.Exchange, DeepCW.Watch,
  DeepCW.Platform,
  WaterfallView, TranscriptView, BandMapView;

type
  { 部品の保護された入力処理は、そのままでは外から呼べません。派生させて
    公開の入口を付けます。試験のためだけの薄い覆いです。

    The control's input handlers are protected, so a descendant exposes them.
    This is a thin shim that exists only for the test. }
  TProbeView = class(TWaterfallView)
  public
    procedure Tap(X: Integer; Button: TMouseButton);
    procedure Wheel(Delta: Integer);
    procedure Press(AKey: Word);
    { 描画のたびに画像を作り直させます。実際に新しい行が来たときと同じ費用に
      なります。
      Forces the image to be rebuilt on every paint, matching what a newly
      arrived row costs. }
    procedure Touch;
    { 周波数から桁を引きます。試験のためだけの入口です。
      Maps a frequency to a column; an entry point for the test alone. }
    function ColumnFor(Hz: Double): Integer;
    { 桁から周波数を引きます。/ Maps a column back to a frequency. }
    function FrequencyAt(X: Integer): Double;
  end;

  { バンドマップの押下も、そのままでは外から呼べません。
    The band map's press handler is protected too. }
  TProbeBandMap = class(TBandMapView)
  public
    procedure Tap(Y: Integer);
  end;

  { 待ち符号の引き当て。/ The watch lookup. }
  TWatchingFor = class
    List: TWatchedCalls;
    function Lookup(const Callsign: string): string;
  end;

  { 選ばれた局を控えます。/ Records the station that was chosen. }
  TStationWatcher = class
    Id: Int64;
    Hz: Double;
    Count: Integer;
    procedure Choose(Sender: TObject; AId: Int64; AHz: Double);
  end;

  { 受信テキストの押下も、そのままでは外から呼べません。
    The transcript's press handler is protected too. }
  TProbeTranscript = class(TTranscriptView)
  public
    procedure Tap(X, Y: Integer);
  end;

  { 同調の通知が届いたかを数えます。/ Counts the tuning notifications. }
  TWatcher = class
    Changes: Integer;
    procedure Changed(Sender: TObject);
  end;

  { どの文字が選ばれたかを控えます。/ Records which character was chosen. }
  TChoiceWatcher = class
    Chosen: Integer;
    Count: Integer;
    constructor Create;
    procedure Choose(Sender: TObject; Index: Integer);
  end;

procedure TProbeView.Tap(X: Integer; Button: TMouseButton);
begin
  MouseDown(Button, [], X, 40);
end;

procedure TProbeView.Wheel(Delta: Integer);
begin
  DoMouseWheel([], Delta, Point(0, 0));
end;

procedure TProbeView.Press(AKey: Word);
begin
  KeyDown(AKey, []);
end;

procedure TProbeView.Touch;
begin
  MarkImageStale;
end;

function TProbeView.ColumnFor(Hz: Double): Integer;
begin
  Result := FrequencyToX(Hz);
end;

function TProbeView.FrequencyAt(X: Integer): Double;
begin
  Result := XToFrequency(X);
end;

procedure TProbeTranscript.Tap(X, Y: Integer);
begin
  MouseDown(mbLeft, [], X, Y);
end;

procedure TProbeBandMap.Tap(Y: Integer);
begin
  MouseDown(mbLeft, [], 10, Y);
end;

function TWatchingFor.Lookup(const Callsign: string): string;
begin
  Result := MatchedWatch(Callsign, List);
end;

procedure TStationWatcher.Choose(Sender: TObject; AId: Int64; AHz: Double);
begin
  Id := AId;
  Hz := AHz;
  Inc(Count);
end;

constructor TChoiceWatcher.Create;
begin
  inherited Create;
  Chosen := -1;
end;

procedure TChoiceWatcher.Choose(Sender: TObject; Index: Integer);
begin
  Chosen := Index;
  Inc(Count);
end;

procedure TWatcher.Changed(Sender: TObject);
begin
  Inc(Changes);
end;

var
  Failures: Integer = 0;

procedure Check(const What: string; Passed: Boolean; const Detail: string = '');
begin
  if Passed then
    WriteLn('  ok   ', What)
  else
  begin
    WriteLn('  NG   ', What, ' ', Detail);
    Inc(Failures);
  end;
end;

{ 2 つの信号と雑音からなる試験音を作ります。
  Builds a test signal of two carriers plus noise. }
function TestAudio(SampleRate: Integer): TSingleArray;
var
  Timing: TCWTiming;
  Options: TCWToneOptions;
  First, Second: TSingleArray;
  I: Integer;
begin
  RandSeed := 99;
  Timing := DefaultTiming;
  Timing.CharWpm := 20;
  Timing.TextWpm := 20;
  Options := DefaultToneOptions;
  Options.SampleRate := SampleRate;
  Options.Amplitude := 0.5;
  Options.NoiseAmplitude := 0.05;
  Options.ToneHz := 700;
  First := TextToPCM('CQ CQ DE JA1ABC K', Timing, Options);
  Options.ToneHz := 1900;
  Options.NoiseAmplitude := 0;
  Second := TextToPCM('TEST TEST DE JH2XYZ', Timing, Options);
  SetLength(Result, Max(Length(First), Length(Second)));
  for I := 0 to High(Result) do
  begin
    Result[I] := 0;
    if I <= High(First) then
      Result[I] := Result[I] + First[I];
    if I <= High(Second) then
      Result[I] := Result[I] + 0.7 * Second[I];
  end;
end;

{ 音程が徐々に上がっていく連続音です。/ A tone that sweeps upward. }
function SweptAudio(SampleRate: Integer; FromHz, ToHz, Seconds: Double): TSingleArray;
var
  I, N: Integer;
  Phase, Hz: Double;
begin
  RandSeed := 11;
  N := Round(Seconds * SampleRate);
  SetLength(Result, N);
  Phase := 0;
  for I := 0 to N - 1 do
  begin
    Hz := FromHz + (ToHz - FromHz) * I / N;
    Phase := Phase + 2 * Pi * Hz / SampleRate;
    Result[I] := 0.5 * Sin(Phase) + 0.02 * (Random + Random - 1);
  end;
end;

{ 雑音だけ。/ Noise alone. }
function NoiseOnly(SampleRate: Integer; Seconds: Double): TSingleArray;
var
  I: Integer;
begin
  RandSeed := 12;
  SetLength(Result, Round(Seconds * SampleRate));
  for I := 0 to High(Result) do
    Result[I] := 0.05 * (Random + Random - 1);
end;

{ 実メモリの読み取りは `DeepCW.Platform` にあります。**同じものを実行ファイル
  ごとに写すと、片方だけを直したことに気づけません**（教訓 10.11）。
  Reading the memory lives in `DeepCW.Platform`: **a copy per executable is a
  copy that can be fixed in one place and not the other** (lesson 10.11). }

{ 復号済みの文字を並べたものを作ります。長時間の受信で溜まった状態を模します。
  Builds a run of decoded characters, standing in for what accumulates over a
  long session. }
{ 文字列から、時刻と確からしさの付いた文字の並びを作ります。
  Builds timed, confident characters from a string. }
function CharsOf(const Text: string): TDecodedChars;
var
  I: Integer;
begin
  SetLength(Result, Length(Text));
  for I := 1 to Length(Text) do
  begin
    Result[I - 1].Text := Text[I];
    Result[I - 1].Seconds := 300 + (I - 1) * 0.2;
    Result[I - 1].EndSeconds := Result[I - 1].Seconds;
    Result[I - 1].Confidence := 0.99;
  end;
end;

function BuildChars(Count: Integer): TDecodedChars;
const
  ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ';
var
  I: Integer;
begin
  RandSeed := 5;
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
  begin
    Result[I].Text := ALPHABET[1 + Random(Length(ALPHABET))];
    Result[I].Seconds := I * 0.24;
    Result[I].EndSeconds := Result[I].Seconds + 0.2;
    Result[I].Confidence := 0.99 + Random * 0.01;
  end;
end;

{ 決まった受信文から文字を作ります。BuildChars は乱数なので、呼出符号を狙って
  置けません。
  Builds characters from a fixed transcript: BuildChars is random, so a call
  sign cannot be planted in it. }
function CharsFrom(const Text: string): TDecodedChars;
var
  I: Integer;
begin
  SetLength(Result, Length(Text));
  for I := 1 to Length(Text) do
  begin
    Result[I - 1].Text := Text[I];
    Result[I - 1].Seconds := (I - 1) * 0.24;
    Result[I - 1].EndSeconds := Result[I - 1].Seconds + 0.2;
    Result[I - 1].Confidence := 0.99;
  end;
end;

{ 文字 First〜Last の下端付近で、白でない画素を数えます。下線の太さを判じる
  ためだけの補助です。文字そのものに掛からないよう、行の下 3 画素だけを見ます。
  Counts the non-white pixels near the bottom of characters First..Last, purely
  to judge the underline's weight. Only the lowest three pixels of the row are
  examined so the glyphs themselves are not counted. }
function DebugInk(Shot: TBitmap): Integer;
var X, Y: Integer;
begin
  Result := 0;
  for Y := 0 to Shot.Height - 1 do
    for X := 0 to Shot.Width - 1 do
      if Shot.Canvas.Pixels[X, Y] <> clWhite then Inc(Result);
end;

function InkedUnder(Shot: TBitmap; View: TTranscriptView;
  First, Last: Integer): Integer;
var
  X, Y: Integer;
  Head, Tail: TRect;
begin
  Result := 0;
  Head := View.CharRect(First);
  Tail := View.CharRect(Last);
  if (Head.Right <= Head.Left) or (Tail.Right <= Tail.Left) then
    Exit;
  for Y := Max(0, Head.Bottom - 3) to Min(Shot.Height - 1, Head.Bottom - 1) do
    for X := Max(0, Head.Left) to Min(Shot.Width - 1, Tail.Right - 1) do
      if Shot.Canvas.Pixels[X, Y] <> clWhite then
        Inc(Result);
end;

procedure SaveView(View: TWaterfallView; const FileName: string);
var
  Shot: TBitmap;
  Png: TPortableNetworkGraphic;
begin
  Shot := TBitmap.Create;
  Png := TPortableNetworkGraphic.Create;
  try
    Shot.SetSize(View.Width, View.Height);
    View.PaintTo(Shot.Canvas, 0, 0);
    Png.Assign(Shot);
    Png.SaveToFile(FileName);
    WriteLn('  書き出し: ', FileName);
  finally
    Png.Free;
    Shot.Free;
  end;
end;

const
  { 22 WPM で連続受信した場合、1 万文字が約 40 分、5 万文字が約 3 時間半。
    At 22 WPM ten thousand characters is about forty minutes of solid copy and
    fifty thousand about three and a half hours. }
  SIZES: array[0..3] of Integer = (1000, 10000, 50000, 200000);
  { 押す位置。先頭の行でも桁でもない、どこか中ほどを選びます。
    The point pressed: somewhere in the middle rather than the first row or
    column. }
  REPLAY_PROBE_X = 120;
  REPLAY_PROBE_Y = 40;
var
  Form: TForm;
  Transcript: TProbeTranscript;
  Chars: TDecodedChars;
  SetMs, PaintMs: Double;
  Repeats: Integer;
  Before, After_: TMemoryUse;
  View: TProbeView;
  Watcher: TWatcher;
  Audio: TSingleArray;
  Rate, X, Frame: Integer;
  OutDir: string;
  Shot: TBitmap;
  Started: TDateTime;
  Elapsed: Double;
  Choice: TChoiceWatcher;
  Chooser: TStationWatcher;
  BandMap: TProbeBandMap;
  Logs: TStationLogs;
  Entries: TBandEntries;
  History: TAudioHistory;
  Picked: TDecodedChar;
  Replay: TSingleArray;
  GotFrom, GotTo: Double;
  PickedIndex, PlayRate: Integer;
  Ex: TExchange;
  Underlined, Marked, Thin, Thick, Y: Integer;
  Waiting: TWatchingFor;
  Marks: TStationLabels;
  Aligned: TDecodedChars;
  Worst, Err, T, Fed: Double;
  Step_, Shown_: Integer;

begin
  OutDir := ParamStr(1);
  if OutDir = '' then
    OutDir := GetTempDir;
  Rate := 8000;

  Application.Initialize;
  Form := TForm.Create(nil);
  Form.SetBounds(0, 0, 800, 300);
  View := TProbeView.Create(Form);
  View.Parent := Form;
  View.Align := alClient;
  Watcher := TWatcher.Create;
  Watcher.Changes := 0;
  View.OnTuneChanged := @Watcher.Changed;
  Form.Show;
  Application.ProcessMessages;

  WriteLn('ウォーターフォールの検証 / waterfall checks');

  { 音声が来る前でも描けること。/ It paints before any audio arrives. }
  SaveView(View, IncludeTrailingPathDelimiter(OutDir) + 'waterfall_empty.png');
  Check('音声なしで描画できる', True);

  Audio := TestAudio(Rate);
  View.PushSamples(Audio, Rate, 0);
  Application.ProcessMessages;
  Check('標本化周波数を取り込む', View.SampleRate = Rate,
    Format('(%d)', [View.SampleRate]));
  SaveView(View, IncludeTrailingPathDelimiter(OutDir) + 'waterfall_signals.png');

  { クリックした位置の周波数へ同調すること（要件 FR-D.1）。
    A click tunes to the frequency at that position (requirement FR-D.1). }
  X := Round(1900 / 3000 * (View.Width - 1));
  View.Tap(X, mbLeft);
  Application.ProcessMessages;
  Check('クリックで同調する', Abs(View.TuneHz - 1900) <= TUNER_STEP_HZ,
    Format('(%.1f Hz)', [View.TuneHz]));
  Check('同調の変化が通知される', Watcher.Changes = 1,
    Format('(%d 回)', [Watcher.Changes]));

  View.HalfWidthHz := BandwidthHalfWidth(tbAuto);
  Application.ProcessMessages;
  SaveView(View, IncludeTrailingPathDelimiter(OutDir) + 'waterfall_tuned.png');

  { ホイールと上下キーが 1 ビンずつ動かすこと（要件 FR-D.2）。
    The wheel and the arrow keys move one bin (requirement FR-D.2). }
  View.TuneHz := 1900;
  View.Wheel(120);
  Check('ホイールで 12.5 Hz 上がる',
    Abs(View.TuneHz - (1900 + TUNER_STEP_HZ)) < 0.01,
    Format('(%.1f Hz)', [View.TuneHz]));
  View.Wheel(-120);
  Check('ホイールで 12.5 Hz 下がる', Abs(View.TuneHz - 1900) < 0.01,
    Format('(%.1f Hz)', [View.TuneHz]));

  View.Press(VK_UP);
  Check('上キーで 12.5 Hz 上がる',
    Abs(View.TuneHz - (1900 + TUNER_STEP_HZ)) < 0.01,
    Format('(%.1f Hz)', [View.TuneHz]));
  View.Press(VK_DOWN);
  Check('下キーで 12.5 Hz 下がる', Abs(View.TuneHz - 1900) < 0.01,
    Format('(%.1f Hz)', [View.TuneHz]));

  { 範囲の外は断らず、いちばん近いところへ寄せること（要件 FR-D.4）。
    Out of range is not refused but moved to the nearest (requirement FR-D.4). }
  View.Tap(0, mbLeft);
  Check('範囲外でも同調は成立する', View.TuneHz >= View.LowestHz,
    Format('(%.1f Hz)', [View.TuneHz]));
  Check('寄せたことが分かる', View.RequestedHz < View.LowestHz,
    Format('(要求 %.1f Hz)', [View.RequestedHz]));

  { 右クリックで解除できること。/ A right click clears the tuning. }
  View.Tap(X, mbRight);
  Check('右クリックで解除する', View.TuneHz = 0, Format('(%.1f Hz)', [View.TuneHz]));

  { 録音周波数が変わっても壊れないこと。/ It survives a change of rate. }
  View.PushSamples(TestAudio(44100), 44100, 0);
  Application.ProcessMessages;
  Check('録音周波数の変更に耐える', View.SampleRate = 44100,
    Format('(%d)', [View.SampleRate]));
  SaveView(View, IncludeTrailingPathDelimiter(OutDir) + 'waterfall_44k.png');

  View.Clear;
  Application.ProcessMessages;
  Check('クリアしても描画できる', True);

  { 動いていく信号を追いかけること（要件 FR-D.7）。合成した掃引音を流し込み、
    同調点が付いてくるかを見ます。
    Following a signal that moves (requirement FR-D.7): a swept tone is fed in
    and the tuned pitch is expected to come with it. }
  View.Clear;
  View.Tracking := True;
  View.TuneHz := 900;
  Watcher.Changes := 0;
  View.PushSamples(SweptAudio(8000, 900, 1000, 12), 8000, 0);
  Application.ProcessMessages;
  Check('動いた信号を追いかける', Abs(View.TuneHz - 1000) <= 60,
    Format('(%.1f Hz、目標 1000 Hz)', [View.TuneHz]));
  Check('追跡による変化だと分かる', Watcher.Changes > 0,
    Format('(%d 回)', [Watcher.Changes]));
  SaveView(View, IncludeTrailingPathDelimiter(OutDir) + 'waterfall_track.png');

  { 追跡を切れば動かないこと。周波数を決め打ちで見張る場合のためです。
    With tracking off it must not move, for an operator watching one
    frequency deliberately. }
  View.Clear;
  View.Tracking := False;
  View.TuneHz := 900;
  View.PushSamples(SweptAudio(8000, 900, 1000, 12), 8000, 0);
  Application.ProcessMessages;
  Check('追跡を切れば動かない', Abs(View.TuneHz - 900) < 0.01,
    Format('(%.1f Hz)', [View.TuneHz]));

  { 信号がいなければ雑音を追いかけないこと。符号の切れ目で流されると、
    読めていた局を見失います。
    With no signal it must not chase noise; drifting away during a gap would
    lose a station that was being read. }
  View.Clear;
  View.Tracking := True;
  View.TuneHz := 900;
  View.PushSamples(NoiseOnly(8000, 12), 8000, 0);
  Application.ProcessMessages;
  Check('無信号では動かない', Abs(View.TuneHz - 900) < 0.01,
    Format('(%.1f Hz)', [View.TuneHz]));

  { 描画の費用を測ります。BGRABitmap のような描画ライブラリを持ち込むかどうかは、
    ここが遅いかどうかで決まります。標準の LCL で足りているなら、配布物を増やす
    理由がありません（要件 NFR-1.5、NFR-8）。

    Measures what drawing costs. Whether to bring in a drawing library such as
    BGRABitmap turns on whether this is slow; if the plain LCL suffices there
    is no reason to add to what has to be distributed
    (requirements NFR-1.5, NFR-8). }
  View.PushSamples(TestAudio(8000), 8000, 0);
  Application.ProcessMessages;
  Shot := TBitmap.Create;
  try
    Shot.SetSize(View.Width, View.Height);
    Started := Now;
    for Frame := 1 to 100 do
    begin
      View.Touch;
      View.PaintTo(Shot.Canvas, 0, 0);
    end;
    Elapsed := MilliSecondsBetween(Now, Started) / 100;
  finally
    Shot.Free;
  end;
  { 文字を重ねたときの描画（要件 FR-D.6 を入れたあと）。**長い受信で溜まった
    文字を毎回すべて見ていたら、時間が経つほど画面が重くなります。**画面に入る
    のは 10 秒ぶんだけなので、溜まった量に関わらず変わらないはずです。

    Drawing with the characters laid over (after requirement FR-D.6). **Walking
    every character accumulated over a long session on every paint would make
    the display heavier the longer it ran.** Only ten seconds' worth is ever on
    screen, so the cost should not follow how much has piled up. }
  Aligned := BuildChars(200000);
  for Frame := 0 to High(Aligned) do
    { 受信開始からの時刻を、画面が持つ 10 秒よりずっと古いところから並べます。
      Times laid out from long before the ten seconds the display holds. }
    Aligned[Frame].Seconds := View.NewestSeconds - (High(Aligned) - Frame) * 0.04;
  View.SetCharacters(Aligned);
  View.ShowCharacters := True;
  View.TuneHz := 700;
  Application.ProcessMessages;
  Shot := TBitmap.Create;
  try
    Shot.SetSize(View.Width, View.Height);
    Started := Now;
    for Frame := 1 to 100 do
    begin
      View.Touch;
      View.PaintTo(Shot.Canvas, 0, 0);
    end;
    PaintMs := MilliSecondsBetween(Now, Started) / 100;
  finally
    Shot.Free;
  end;
  WriteLn(Format('  20 万文字を重ねた描画: %.2f ms', [PaintMs]));
  { 30 fps（要件 NFR-1.6）は 1 枚 33 ms。文字を重ねてもそこへ届くこと。
    Thirty frames a second (requirement NFR-1.6) is 33 ms a frame; the overlay
    must not put it past that. }
  Check('文字を重ねても 1 枚 33 ms 未満', PaintMs < 33,
    Format('(%.2f ms)', [PaintMs]));
  Check('文字を重ねても、重ねない場合の 3 倍を超えない', PaintMs < Elapsed * 3 + 1,
    Format('(%.2f ms 対 %.2f ms)', [PaintMs, Elapsed]));

  { **画面より新しい文字ばかりのとき。**受信のあとにファイルを読ませると、
    波形は 0 秒から数え直し、手元の文字は前の受信の時刻を持ったまま、という
    瞬間があり得ます。そこで 1 文字ずつ全部を見ていたら、20 万文字ぶん歩きます。
    **All the characters newer than the display.** Reading a file after a live
    reception leaves the waterfall counting from zero for a moment while the
    characters still carry the previous reception's times. Walking them one by
    one would walk all two hundred thousand. }
  for Frame := 0 to High(Aligned) do
    Aligned[Frame].Seconds := View.NewestSeconds + 1000 + Frame * 0.04;
  View.SetCharacters(Aligned);
  Application.ProcessMessages;
  Shot := TBitmap.Create;
  try
    Shot.SetSize(View.Width, View.Height);
    Started := Now;
    for Frame := 1 to 20 do
    begin
      View.Touch;
      View.PaintTo(Shot.Canvas, 0, 0);
    end;
    PaintMs := MilliSecondsBetween(Now, Started) / 20;
  finally
    Shot.Free;
  end;
  WriteLn(Format('  画面より新しい 20 万文字での描画: %.2f ms', [PaintMs]));
  Check('画面に無い文字ばかりでも 1 枚 33 ms 未満', PaintMs < 33,
    Format('(%.2f ms)', [PaintMs]));
  View.ShowCharacters := False;
  View.SetCharacters(nil);
  View.TuneHz := 0;

  WriteLn(Format('  1 回の描画: %.2f ms（毎秒 25 行の更新で %.1f %%）',
    [Elapsed, Elapsed * 25 / 10]));
  Check('描画が 1 行あたり 5 ms 未満', Elapsed < 5.0,
    Format('(%.2f ms)', [Elapsed]));

  { ── 受信テキストの部品 ──
    常設シャックでは何時間も流し聞きする。文字は溜まる一方であり、**溜まった
    分だけ描画と複製が重くなるなら、長く使うほど画面が鈍る。**時間を測って
    確かめる（要件 NFR-1.5）。

    A shack runs for hours and the characters only accumulate. **If drawing and
    copying grow with what has accumulated, the display gets slower the longer
    it is used.** This is timed rather than assumed (requirement NFR-1.5). }
  { 長いファイルを一度に流したときの費用。版 2.25 で、ファイルの復号でも波形を
    出すようにしました。**画面に残るのは末尾の 10 秒ぶんだけなのに、渡された
    ぶんすべてに FFT を掛けていたら、長いファイルで画面が止まります。**
    利用者が「デコード」を押してから絵が出るまでの間、操作を受け付けません。

    The cost of one long file at once. Since version 2.25 a file decode draws the
    waterfall too. **Only the last ten seconds survive on screen, so running an
    FFT over everything handed in would freeze the display on a long file** --
    the operator gets no response between pressing decode and the picture
    appearing. }
  View.Clear;
  SetLength(Audio, 8000 * 600);
  for Frame := 0 to High(Audio) do
    Audio[Frame] := 0;
  Started := Now;
  View.PushSamples(Audio, 8000, 0);
  Elapsed := MilliSecondsBetween(Now, Started);
  WriteLn(Format('  10 分の音を一度に流す: %.0f ms', [Elapsed]));
  { 押してから 200 ms を超えると、止まったと感じます（画面の更新間隔と同じ）。
    Past 200 ms -- the display's own refresh interval -- it reads as a freeze. }
  Check('10 分の音でも 200 ms 未満', Elapsed < 200, Format('(%.0f ms)', [Elapsed]));
  { **飛ばした分だけ基準を進めていること。**進め忘れると、10 分のファイルの
    末尾の行が「10 秒目」になり、文字がまったく別の場所へ並びます。速くする
    ついでに時刻を壊すのが、いちばんありがちな失敗です。
    **The origin must move forward by what was skipped.** Forgetting it would
    date the last row of a ten-minute file at ten seconds, and the characters
    would line up somewhere else entirely. Breaking the time while making it
    faster is the easiest mistake to make. }
  Check('飛ばしても末尾の行の時刻が合っている',
    Abs(View.NewestSeconds - 600.0) < 0.3,
    Format('(%.2f 秒、渡したのは 0〜600 秒)', [View.NewestSeconds]));
  Audio := nil;

  { ── 復号文字の時刻整列（要件 FR-D.6）──
    受入基準は「位置誤差 100 ms 以内」。**時刻を画面の高さへ写し、そこから時刻へ
    戻して、元と何秒ずれるかで測ります。**画素を数えないのは、この部品の
    `PaintTo` が中身を描かないためです（付録 S.7）。

    Aligning the decoded characters in time (requirement FR-D.6). The acceptance
    is a position error within 100 ms: **a time is mapped to a height and back,
    and the gap is measured.** No pixels are counted, because this control's
    PaintTo draws no content (appendix S.7). }
  WriteLn;
  WriteLn('文字の時刻整列の検証 / time alignment checks');
  View.Clear;
  { 10 秒ぶんの音を、実際の受信と同じように 0.2 秒ずつ渡します。時刻は
    呼び出し側が数えて渡します。
    Ten seconds of audio handed over in 0.2 s pieces, as a real reception does,
    with the caller counting the time. }
  Fed := 0;
  while Fed < 10.0 do
  begin
    View.PushSamples(NoiseOnly(8000, 0.2), 8000, Fed);
    Fed := Fed + 0.2;
  end;
  Application.ProcessMessages;
  Check('渡した時刻のぶんだけ行が進んでいる',
    Abs(View.NewestSeconds - 10.0) < 0.2,
    Format('(%.3f 秒、渡したのは %.1f 秒)', [View.NewestSeconds, Fed]));

  { 時刻 → 画面の高さ → 時刻。往復のずれが受入基準そのものです。
    Time to height and back; the round trip is the acceptance criterion. }
  Worst := 0;
  Shown_ := 0;
  T := View.NewestSeconds;
  while T > View.NewestSeconds - 9.0 do
  begin
    Y := View.SecondsToY(T);
    if Y >= 0 then
    begin
      Err := Abs(View.SecondsAtY(Y) - T);
      if Err > Worst then
        Worst := Err;
      Inc(Shown_);
    end;
    T := T - 0.05;
  end;
  WriteLn(Format('  %d 点で測った最大のずれ: %.0f ms', [Shown_, Worst * 1000]));
  Check('測れた点がある', Shown_ > 100, Format('(%d 点)', [Shown_]));
  Check('位置のずれが 100 ms 以内', Worst <= 0.1,
    Format('(%.0f ms)', [Worst * 1000]));

  { 画面の外は「無い」と言うこと。**古すぎる文字を端に貼り付けると、そこに
    無かった音を指します。**
    Anything off the display must say so: **pinning too old a character to the
    edge would point at sound that was never there.** }
  Check('新しすぎる時刻は画面に無い',
    View.SecondsToY(View.NewestSeconds + 1.0) < 0,
    Format('(%d)', [View.SecondsToY(View.NewestSeconds + 1.0)]));
  Check('古すぎる時刻は画面に無い',
    View.SecondsToY(View.NewestSeconds - 60.0) < 0,
    Format('(%d)', [View.SecondsToY(View.NewestSeconds - 60.0)]));

  { 新しい行ほど下にあること。順序が逆なら、読んだ順と見える順が食い違います。
    Newer rows sit lower; reversed, the order read and the order seen would
    disagree. }
  Check('新しい文字ほど下に来る',
    View.SecondsToY(View.NewestSeconds) >
    View.SecondsToY(View.NewestSeconds - 5.0),
    Format('(%d vs %d)', [View.SecondsToY(View.NewestSeconds),
      View.SecondsToY(View.NewestSeconds - 5.0)]));

  { 時刻が飛んだら数え直すこと。受信のやり直しやファイルの復号で起こります。
    **黙って繋げると、以後ずっと文字が別の行を指します。**
    A jump in the time restarts the count, as a fresh reception or a file decode
    does. **Joining them silently would point every character at the wrong row
    from then on.** }
  View.PushSamples(NoiseOnly(8000, 0.2), 8000, 500.0);
  Application.ProcessMessages;
  Check('時刻が飛んだら数え直す', Abs(View.NewestSeconds - 500.0) < 0.3,
    Format('(%.3f 秒)', [View.NewestSeconds]));

  { ── ここからが受入基準そのもの ──
    上の往復は、目盛りの粗さしか測っていません。**時刻の基準が丸ごとずれても
    往復では相殺され、気づけません**（実際、窓の中心を採る補正を外しても上の
    確認は 1 つも落ちませんでした）。

    音が**画面のどこに出るか**で測り直します。無音・音・無音の順に渡し、明るく
    なった行の中心が、その音を送った時刻と何秒ずれるかを見ます。これが
    「復号文字をウォーターフォール上の対応時刻に整列表示する」の意味です。

    ── the acceptance criterion itself ──
    The round trip above measures only the coarseness of the grid. **A wholesale
    shift of the time base cancels out in a round trip and goes unnoticed** --
    and indeed, removing the correction that takes the middle of the window
    broke none of the checks above.

    So it is measured again by **where the sound lands on screen**: silence, a
    tone, silence, and the middle of the band that brightens is compared with
    the time the tone was sent. That is what aligning the characters means. }
  View.Clear;
  Fed := 0;
  View.PushSamples(NoiseOnly(8000, 3.0), 8000, Fed);
  Fed := Fed + 3.0;
  { 音の**真ん中**の時刻。文字もここへ置かれます。
    The middle of the tone; a character would be placed here too. }
  T := Fed + 0.25;
  View.PushSamples(SweptAudio(8000, 700, 700, 0.5), 8000, Fed);
  Fed := Fed + 0.5;
  View.PushSamples(NoiseOnly(8000, 3.0), 8000, Fed);
  Fed := Fed + 3.0;
  Application.ProcessMessages;

  Shot := TBitmap.Create;
  try
    Shot.SetSize(View.Width, View.Height);
    View.PaintTo(Shot.Canvas, 0, 0);
    { 700 Hz の列だけを、いちばん新しい行から上へ見ます。明るさで重みを付けた
      中心を採るのは、音の端がぼやけるためです。
      Only the 700 Hz column is read, from the newest row upwards. The centre is
      weighted by brightness because the tone's edges blur. }
    X := View.ColumnFor(700);
    Thick := View.SecondsToY(View.NewestSeconds);
    Worst := 0;
    Err := 0;
    for Y := 0 to Thick do
    begin
      { 受信が始まる前の高さは見ません。まだ音の来ていない範囲で、**測る対象が
        ありません。**（画面の最上端 1 画素には、画布へ写したときの端の差が
        出ます。）
        Heights from before the reception began are not read: no sound has
        arrived there, so **there is nothing to measure.** (The topmost pixel
        also carries an edge difference from copying onto a canvas.) }
      if View.SecondsAtY(Y) < 0 then
        Continue;
      Marked := Shot.Canvas.Pixels[X, Y];
      { 明るさは緑成分で見ます。この配色では信号が緑〜黄で出ます。
        Brightness is read from the green channel: signals come out green to
        yellow in this palette. }
      Underlined := (Marked shr 8) and $FF;
      if Underlined > 120 then
      begin
        Worst := Worst + Underlined;
        Err := Err + Underlined * Y;
      end;
    end;
    Check('音の出た行が見つかる', Worst > 0, Format('(重み %.0f)', [Worst]));
    if Worst > 0 then
    begin
      Y := Round(Err / Worst);
      WriteLn(Format('  送った時刻 %.2f 秒 / 画面が示す時刻 %.2f 秒（ずれ %.0f ms）',
        [T, View.SecondsAtY(Y), Abs(View.SecondsAtY(Y) - T) * 1000]));
      Check('音の出た位置と送った時刻のずれが 100 ms 以内',
        Abs(View.SecondsAtY(Y) - T) <= 0.1,
        Format('(%.0f ms)', [Abs(View.SecondsAtY(Y) - T) * 1000]));
    end;
  finally
    Shot.Free;
  end;

  { 文字を渡しても落ちないこと。同調していなければ何も重ねません。
    Handing over characters must not break anything; untuned, nothing is laid
    over. }
  SetLength(Aligned, 3);
  for Step_ := 0 to 2 do
  begin
    Aligned[Step_].Text := Chr(Ord('A') + Step_);
    Aligned[Step_].Seconds := View.NewestSeconds - Step_ * 0.5;
    Aligned[Step_].EndSeconds := Aligned[Step_].Seconds;
    Aligned[Step_].Confidence := 0.99;
  end;
  View.SetCharacters(Aligned);
  View.ShowCharacters := True;
  Application.ProcessMessages;
  SaveView(View, IncludeTrailingPathDelimiter(OutDir) + 'waterfall_aligned.png');
  Check('文字を渡しても描画できる', True);
  View.ShowCharacters := False;
  View.SetCharacters(nil);

  { ── 局の見出しをウォーターフォールへ重ねる（要件 FR-J.5）──
    受入基準は「位置は同調誤差と同じ 1 ビン以内」。1 ビンは 12.5 Hz です。

    見出しの横位置は `FrequencyToX` で決めます。**同調線が使うのと同じ変換**
    なので、線と見出しは必ず同じ桁に立ちます。その変換の誤差を、周波数 →桁 →
    周波数で測ります。

    往復では系統的なずれを見つけられません（付録 V.3）。ここでそれでよいのは、
    **この変換がクリックに対して既に検証されている**ためです（要件 FR-D.1、
    「クリックした位置の周波数へ同調する」）。見出しはその変換に相乗りします。
    あわせて、見出しが実際に描かれることを画素で確かめます。

    Laying the stations' labels over the waterfall (requirement FR-J.5). The
    acceptance is one bin -- 12.5 Hz -- the same as the tuning error.

    A label's column comes from `FrequencyToX`, **the very transform the tuning
    line uses**, so a line and a label always stand in the same column. That
    transform's error is measured frequency to column and back.

    A round trip cannot catch a systematic shift (appendix V.3); it is enough
    here because **the transform is already verified against clicks**
    (requirement FR-D.1, tuning to the frequency clicked). The labels ride on
    it. That a label is actually drawn is checked from the pixels as well. }
  WriteLn;
  WriteLn('局の見出しの検証 / station label checks');
  View.Clear;
  View.PushSamples(TestAudio(8000), 8000, 0);
  View.TuneHz := 0;
  View.ShowCharacters := True;
  Application.ProcessMessages;

  Worst := 0;
  T := 300;
  while T <= 2800 do
  begin
    Err := Abs(View.FrequencyAt(View.ColumnFor(T)) - T);
    if Err > Worst then
      Worst := Err;
    T := T + 12.5;
  end;
  WriteLn(Format('  300〜2800 Hz で測った位置の最大のずれ: %.1f Hz', [Worst]));
  Check('見出しの位置が 1 ビン（12.5 Hz）以内', Worst <= 12.5,
    Format('(%.1f Hz)', [Worst]));

  { 名前のある局にだけ見出しが付くこと。名前の無い局に「何か居る」と書いても、
    ウォーターフォールがすでにそれを示しています。
    Only a named station gets a label; writing "something is here" adds nothing
    to what the waterfall already shows. }
  SetLength(Marks, 3);
  Marks[0].Hz := 700; Marks[0].Text := 'JH2XYZ'; Marks[0].LevelDb := 30;
  Marks[1].Hz := 1900; Marks[1].Text := 'JA1ABC ✓'; Marks[1].LevelDb := 25;
  Marks[2].Hz := 1200; Marks[2].Text := ''; Marks[2].LevelDb := 28;
  View.SetStations(Marks);
  Application.ProcessMessages;
  Shot := TBitmap.Create;
  try
    Shot.SetSize(View.Width, View.Height);
    Shot.Canvas.Brush.Color := clBlack;
    Shot.Canvas.FillRect(0, 0, Shot.Width, Shot.Height);
    View.PaintTo(Shot.Canvas, 0, 0);
    { 上端 40 行に白い画素があるか。見出しと、音程へ下ろす線が白です。
      White pixels in the top forty rows: the labels and the lines dropped to
      their pitches are white. }
    Underlined := 0;
    Marked := 0;
    { 最上端の 1 行は数えません。画布へ写したときの端の差で白くなります
      （付録 V.5 で見つけたもの）。
      The topmost row is not counted: copying onto a canvas leaves it white
      (found in appendix V.5). }
    for Y := 1 to 40 do
      for X := 1 to Shot.Width - 2 do
        if Shot.Canvas.Pixels[X, Y] = clWhite then
        begin
          Inc(Underlined);
          if Abs(X - View.ColumnFor(1200)) < 30 then
            Inc(Marked);
        end;
    Check('見出しが描かれている', Underlined > 50,
      Format('(白い画素 %d)', [Underlined]));
    Check('名前の無い局には見出しを出さない', Marked = 0,
      Format('(1200 Hz の周りに %d 画素)', [Marked]));
  finally
    Shot.Free;
  end;

  { 重なるときは強い局を残すこと。同じ音程に 2 つ置けば、必ず重なります。
    The stronger wins a collision; two labels at one pitch always collide. }
  SetLength(Marks, 2);
  Marks[0].Hz := 1000; Marks[0].Text := 'WEAKCALL'; Marks[0].LevelDb := 10;
  Marks[1].Hz := 1000; Marks[1].Text := 'JH2XYZ'; Marks[1].LevelDb := 30;
  View.SetStations(Marks);
  Application.ProcessMessages;
  Shot := TBitmap.Create;
  try
    Shot.SetSize(View.Width, View.Height);
    Shot.Canvas.Brush.Color := clBlack;
    Shot.Canvas.FillRect(0, 0, Shot.Width, Shot.Height);
    View.PaintTo(Shot.Canvas, 0, 0);
    Underlined := 0;
    for Y := 1 to 40 do
      for X := 1 to Shot.Width - 2 do
        if Shot.Canvas.Pixels[X, Y] = clWhite then
          Inc(Underlined);
    { 2 つ描けば、1 つのときより白い画素がはっきり増えます。
      Two labels would leave markedly more white than one. }
    Thin := Underlined;
    SetLength(Marks, 1);
    Marks[0].Hz := 1000; Marks[0].Text := 'JH2XYZ'; Marks[0].LevelDb := 30;
    View.SetStations(Marks);
    Application.ProcessMessages;
    Shot.Canvas.FillRect(0, 0, Shot.Width, Shot.Height);
    View.PaintTo(Shot.Canvas, 0, 0);
    Thick := 0;
    for Y := 1 to 40 do
      for X := 1 to Shot.Width - 2 do
        if Shot.Canvas.Pixels[X, Y] = clWhite then
          Inc(Thick);
    Check('重なる見出しは 1 つに絞る', Thin = Thick,
      Format('(2 つ渡して %d 画素、1 つ渡して %d 画素)', [Thin, Thick]));

    { **描かれた見出しが、本当にその音程の上にあること。**上の位置の確認は
      変換そのものを測っただけで、描くときに別の桁を使っていても気づけません
      （付録 V.3 と同じ落とし穴）。白い画素の左右の端から中心を求めます。
      **That the label drawn really stands above its pitch.** The check above
      measures the transform alone and would not notice the drawing using a
      different column (the same trap as appendix V.3). The centre is taken from
      the leftmost and rightmost white pixels. }
    Underlined := Shot.Width;
    Marked := -1;
    { 上端の 1 行と左右の端の 1 桁は数えません。画布へ写したときの端の差で
      白くなります（付録 V.5 で見つけたのと同じもの）。
      The topmost row and the outermost column on each side are not counted:
      copying onto a canvas leaves them white (the same edge difference found in
      appendix V.5). }
    for Y := 1 to 40 do
      for X := 1 to Shot.Width - 2 do
        if Shot.Canvas.Pixels[X, Y] = clWhite then
        begin
          if X < Underlined then
            Underlined := X;
          if X > Marked then
            Marked := X;
        end;
    Check('見出しが音程の上に立っている',
      (Marked >= 0) and
      (Abs(View.FrequencyAt((Underlined + Marked) div 2) - 1000) <= 30),
      Format('(中心 %d 桁 ＝ %.0f Hz、音程は 1000 Hz)',
        [(Underlined + Marked) div 2,
         View.FrequencyAt((Underlined + Marked) div 2)]));
  finally
    Shot.Free;
  end;

  { 24 局でも描画が重くならないこと。 }
  SetLength(Marks, 24);
  for X := 0 to 23 do
  begin
    Marks[X].Hz := 700 + X * 100;
    Marks[X].Text := Format('JH%dABC', [X mod 10]);
    Marks[X].LevelDb := 30 - X * 0.5;
  end;
  View.SetStations(Marks);
  Application.ProcessMessages;
  Shot := TBitmap.Create;
  try
    Shot.SetSize(View.Width, View.Height);
    Started := Now;
    for Frame := 1 to 100 do
    begin
      View.Touch;
      View.PaintTo(Shot.Canvas, 0, 0);
    end;
    PaintMs := MilliSecondsBetween(Now, Started) / 100;
  finally
    Shot.Free;
  end;
  WriteLn(Format('  24 局の見出しを重ねた描画: %.2f ms', [PaintMs]));
  Check('24 局の見出しでも 1 枚 33 ms 未満', PaintMs < 33,
    Format('(%.2f ms)', [PaintMs]));
  View.SetStations(nil);
  View.ShowCharacters := False;

  WriteLn;
  WriteLn('受信テキストの検証 / transcript checks');
  Transcript := TProbeTranscript.Create(Form);
  Transcript.Parent := Form;
  Transcript.Align := alClient;
  View.Visible := False;
  Application.ProcessMessages;

  Shot := TBitmap.Create;
  try
    Shot.SetSize(Form.ClientWidth, Form.ClientHeight);
    for Frame := 0 to High(SIZES) do
    begin
      Chars := BuildChars(SIZES[Frame]);

      Started := Now;
      for Repeats := 1 to 10 do
        Transcript.SetChars(Chars);
      SetMs := MilliSecondsBetween(Now, Started) / 10;

      Started := Now;
      for Repeats := 1 to 10 do
        Transcript.PaintTo(Shot.Canvas, 0, 0);
      PaintMs := MilliSecondsBetween(Now, Started) / 10;

      WriteLn(Format('  %7d 文字: 差し替え %6.1f ms / 描画 %6.1f ms',
        [SIZES[Frame], SetMs, PaintMs]));
      { 受信中は毎秒数回これを行う。1 回 100 ms を超えれば画面が目に見えて
        鈍る。
        This runs several times a second while receiving; past 100 ms each the
        display visibly drags. }
      Check(Format('%d 文字で差し替えが 100 ms 未満', [SIZES[Frame]]),
        SetMs < 100, Format('(%.1f ms)', [SetMs]));
      Check(Format('%d 文字で描画が 100 ms 未満', [SIZES[Frame]]),
        PaintMs < 100, Format('(%.1f ms)', [PaintMs]));
    end;
  finally
    Shot.Free;
  end;

  { ── 受信テキストの中を探せること（要件 FR-B.5）──
    探して見つかるだけでは足りない。**受信は続いており、文字は 0.2 秒ごとに
    増える。**そのたびに探し直しても、見ている場所が先頭へ戻ってしまえば、
    溜まったテキストの中を辿ることはできない。増えても位置が動かないことを
    確かめる。

    Searching the received text (requirement FR-B.5). Finding a hit is not
    enough: **reception continues and characters arrive five times a second.**
    If each rescan sent the operator back to the first hit, walking through what
    has accumulated would be impossible. That the position holds as text arrives
    is what is checked here. }
  WriteLn;
  WriteLn('検索の検証 / search checks');
  Chars := BuildChars(300);
  { 探す語を、狙った 3 か所だけに置きます。生成した文字にたまたま現れないよう、
    実際に使われない綴りを選びます。
    The term is planted at exactly three places, spelled so that it cannot occur
    by chance in the generated characters. }
  Chars[20].Text := 'Q'; Chars[21].Text := 'R'; Chars[22].Text := 'Z';
  Chars[150].Text := 'Q'; Chars[151].Text := 'R'; Chars[152].Text := 'Z';
  Chars[280].Text := 'Q'; Chars[281].Text := 'R'; Chars[282].Text := 'Z';
  for X := 0 to High(Chars) do
    if (Chars[X].Text = 'Q') and (X <> 20) and (X <> 150) and (X <> 280) then
      Chars[X].Text := 'A';
  Transcript.SetChars(Chars);
  Transcript.FollowTail := False;

  Transcript.Search('QRZ');
  Check('置いた数だけ見つかる', Transcript.MatchCount = 3,
    Format('(%d 件)', [Transcript.MatchCount]));
  Check('探したら最初の 1 件へ行く',
    (Transcript.CurrentMatch = 1) and (Transcript.SelectedIndex = 20),
    Format('(%d 件目、%d 文字目)',
      [Transcript.CurrentMatch, Transcript.SelectedIndex]));

  Transcript.Search('qrz');
  Check('大文字小文字を区別しない', Transcript.MatchCount = 3,
    Format('(%d 件)', [Transcript.MatchCount]));

  Transcript.NextMatch;
  Check('次へ進む',
    (Transcript.CurrentMatch = 2) and (Transcript.SelectedIndex = 150),
    Format('(%d 件目、%d 文字目)',
      [Transcript.CurrentMatch, Transcript.SelectedIndex]));
  Transcript.PreviousMatch;
  Check('前へ戻る', Transcript.SelectedIndex = 20,
    Format('(%d 文字目)', [Transcript.SelectedIndex]));
  Transcript.PreviousMatch;
  Check('先頭より前は末尾へ回る', Transcript.SelectedIndex = 280,
    Format('(%d 文字目)', [Transcript.SelectedIndex]));
  Transcript.NextMatch;
  Check('末尾より先は先頭へ回る', Transcript.SelectedIndex = 20,
    Format('(%d 文字目)', [Transcript.SelectedIndex]));

  { **受信が続いても、見ている場所が動かないこと。**ここが崩れると、
    溜まったテキストを辿れない。
    **The position must hold as reception continues**, or what has accumulated
    cannot be walked through. }
  Transcript.NextMatch;
  PickedIndex := Transcript.SelectedIndex;
  Chars := Copy(Chars, 0, Length(Chars));
  SetLength(Chars, Length(Chars) + 40);
  for X := 300 to High(Chars) do
  begin
    Chars[X].Text := 'E';
    Chars[X].Seconds := X * 0.24;
    Chars[X].EndSeconds := Chars[X].Seconds + 0.2;
    Chars[X].Confidence := 0.99;
  end;
  Transcript.SetChars(Chars);
  Check('文字が増えても見ている場所が動かない',
    (Transcript.SelectedIndex = PickedIndex) and (Transcript.CurrentMatch = 2),
    Format('(%d 文字目、%d 件目)',
      [Transcript.SelectedIndex, Transcript.CurrentMatch]));

  { あとから届いた分も見つかること。届いたきり探し直さなければ、見つからない。
    Text that arrives later must be found too; without a rescan it never would
    be. }
  Chars[320].Text := 'Q'; Chars[321].Text := 'R'; Chars[322].Text := 'Z';
  Transcript.SetChars(Chars);
  Check('あとから届いた分も見つかる', Transcript.MatchCount = 4,
    Format('(%d 件)', [Transcript.MatchCount]));

  Transcript.Search('');
  Check('空にすれば検索が解ける', Transcript.MatchCount = 0,
    Format('(%d 件)', [Transcript.MatchCount]));

  { 20 万文字でも、文字が届くたびの探し直しが目に見える遅れにならないこと。
    受信中は毎秒数回起きる。
    The rescan on every arrival must stay imperceptible at two hundred thousand
    characters; it happens several times a second while receiving. }
  Chars := BuildChars(200000);
  Transcript.SetChars(Chars);
  Transcript.Search('QRZ');
  Started := Now;
  for Repeats := 1 to 10 do
    Transcript.SetChars(Chars);
  SetMs := MilliSecondsBetween(Now, Started) / 10;
  WriteLn(Format('  20 万文字での探し直し: %.1f ms', [SetMs]));
  Check('20 万文字でも探し直しが 100 ms 未満', SetMs < 100,
    Format('(%.1f ms)', [SetMs]));
  Transcript.Search('');

  { ── 受信テキストから音へ戻れること（要件 FR-E.10）──
    押した場所と、鳴らす音の場所が一致していなければ、この機能は成り立たない。
    **ずれていても音は鳴るので、動かして耳で聴くだけでは気づけない。**押下から
    文字の番号を求め、その文字の時刻で保管庫を引き、返ってきた音が本当にその
    時刻のものかを、値そのもので確かめる。

    Getting from the transcript back to the sound (requirement FR-E.10).
    The feature only works if the place pressed and the place played are the
    same. **Sound comes out either way, so running it and listening does not
    reveal a mismatch.** The index is taken from a press, the store is read at
    that character's time, and the audio that comes back is checked by value. }
  { ── 呼出符号の強調（要件 FR-E.1）──
    描くのは部品、決めるのは呼ぶ側。ここでは「渡した位置のとおりに印が付くか」
    と「押した場所がどの符号かを言えるか」を見ます。**画素を数えないのは、
    下線の太さや位置を変えたときに試験が壊れるのを避けるためです。**見たいのは
    見た目ではなく、どの文字が符号として扱われているかです。

    Highlighting call signs (requirement FR-E.1). The control draws, the caller
    decides; what is checked here is that the spans handed over are the ones
    marked, and that a press can be told which call sign it landed on. **No
    pixels are counted:** changing the underline's weight or position must not
    break the test, because what matters is which characters are treated as a
    call sign, not how they look. }
  WriteLn;
  WriteLn('呼出符号の強調の検証 / call sign highlight checks');
  Chars := CharsFrom('JA1ABC DE JH2XYZ UR 599 K');
  Ex := ReadExchange(Chars);
  Transcript.FollowTail := False;
  Transcript.SetChars(Chars);
  Transcript.SetCallsigns(Ex.Callsigns, Ex.Chosen);
  Application.ProcessMessages;

  Check('符号の数だけ印が付く', Transcript.CallsignCount = 2,
    Format('(%d)', [Transcript.CallsignCount]));
  Check('相手と見た符号が印の中にある',
    (Transcript.ChosenCallsign >= 0) and
    (Transcript.CallsignSpan(Transcript.ChosenCallsign).Text = 'JH2XYZ'),
    Transcript.CallsignSpan(Transcript.ChosenCallsign).Text);

  { 符号の中の文字は符号と分かり、外の文字は分からないこと。0〜5 が JA1ABC、
    7〜8 が DE、10〜15 が JH2XYZ です。
    Characters inside a call sign are recognised and those outside are not:
    0-5 is JA1ABC, 7-8 is DE and 10-15 is JH2XYZ. }
  Check('符号の先頭の文字が符号と分かる', Transcript.CallsignAt(0) = 0,
    Format('(%d)', [Transcript.CallsignAt(0)]));
  Check('符号の末尾の文字が符号と分かる', Transcript.CallsignAt(5) = 0,
    Format('(%d)', [Transcript.CallsignAt(5)]));
  Check('語間の空白は符号でない', Transcript.CallsignAt(6) < 0,
    Format('(%d)', [Transcript.CallsignAt(6)]));
  Check('DE は符号でない', Transcript.CallsignAt(7) < 0,
    Format('(%d)', [Transcript.CallsignAt(7)]));
  Check('2 つ目の符号は 2 つ目と分かる', Transcript.CallsignAt(10) = 1,
    Format('(%d)', [Transcript.CallsignAt(10)]));

  { 印の付いた文字を数えて、符号の文字数と一致すること。取りこぼしも付けすぎも
    ここで出ます。
    Counting the marked characters against the call signs' length catches both a
    miss and an overreach. }
  Underlined := 0;
  Marked := 0;
  for X := 0 to High(Chars) do
    if Transcript.CallsignAt(X) >= 0 then
    begin
      Inc(Underlined);
      if Transcript.CallsignAt(X) = Transcript.ChosenCallsign then
        Inc(Marked);
    end;
  Check('印の付いた文字数が符号の長さと合う', Underlined = 12,
    Format('(%d)', [Underlined]));
  Check('相手と見た符号の文字数が合う', Marked = 6, Format('(%d)', [Marked]));

  { **見た目の違い（下線の太さ）はここでは確かめていません。**この試験用の
    描画経路（PaintTo）はスクロールバーしか描かず、文字も線も画布に出ません。
    画素を数える試験を書いて分かりました。見た目は実機の画面で確かめます。

    **The visual difference (the underline's weight) is not checked here.** The
    control's PaintTo path, as driven by this probe, renders only the scroll bar:
    neither glyphs nor lines reach the canvas. Writing a pixel-counting test is
    what revealed it. The appearance is checked on the real screen instead. }

  { 文字を差し替えたら、古い位置は捨てられること。捨てないと、次の受信文の
    無関係な文字に下線が残ります。
    Replacing the characters must drop the old spans, or unrelated characters in
    the next transcript would keep the underline. }
  Transcript.SetChars(CharsFrom('CQ CQ K'));
  Check('文字を差し替えたら印が消える', Transcript.CallsignCount = 0,
    Format('(%d)', [Transcript.CallsignCount]));
  Check('印が消えれば相手も無い', Transcript.ChosenCallsign < 0,
    Format('(%d)', [Transcript.ChosenCallsign]));

  { 受信をやり直したときも捨てられること。差し替えと消去は別の道なので、
    片方だけ直しても気づけません。
    Cleared for a fresh reception, the spans must go too: replacing and clearing
    are separate paths, and fixing one would not show up in the other. }
  Chars := CharsFrom('JA1ABC DE JH2XYZ K');
  Ex := ReadExchange(Chars);
  Transcript.SetChars(Chars);
  Transcript.SetCallsigns(Ex.Callsigns, Ex.Chosen);
  Check('消す前は印がある', Transcript.CallsignCount = 2,
    Format('(%d)', [Transcript.CallsignCount]));
  Transcript.Clear;
  Check('消せば印も消える', Transcript.CallsignCount = 0,
    Format('(%d)', [Transcript.CallsignCount]));
  Check('消せば相手も無い', Transcript.ChosenCallsign < 0,
    Format('(%d)', [Transcript.ChosenCallsign]));

  { 符号が無い受信文でも落ちないこと。 }
  Chars := CharsFrom('CQ CQ CQ K');
  Ex := ReadExchange(Chars);
  Transcript.SetChars(Chars);
  Transcript.SetCallsigns(Ex.Callsigns, Ex.Chosen);
  Check('符号が無ければ印も無い', Transcript.CallsignCount = 0,
    Format('(%d)', [Transcript.CallsignCount]));
  Check('符号が無ければどこを当てても符号でない',
    (Transcript.CallsignAt(0) < 0) and (Transcript.CallsignAt(5) < 0));

  WriteLn;
  WriteLn('聴き直しの検証 / replay checks');
  Chars := BuildChars(400);
  Transcript.SetChars(Chars);
  Transcript.FollowTail := False;
  Transcript.SelectedIndex := -1;
  Choice := TChoiceWatcher.Create;
  Transcript.OnCharChosen := @Choice.Choose;
  Application.ProcessMessages;

  { 文字の幅も行の高さも部品が決めるので、ここでは特定の桁を狙いません。ある
    一点を押し、同じ一点を当て直して、押下と当てが同じ番号を指すことを見ます。
    食い違えば、枠で囲まれる文字と鳴る音が別のものになります。
    The character width and line height are the control's business, so no
    particular column is aimed at. One point is pressed and the same point is
    hit-tested: the press and the hit test must name the same character, or the
    character boxed and the sound played would be different ones. }
  Transcript.Tap(REPLAY_PROBE_X, REPLAY_PROBE_Y);
  PickedIndex := Transcript.IndexAt(REPLAY_PROBE_X, REPLAY_PROBE_Y);
  Check('押した位置の文字が選ばれる',
    (Choice.Count = 1) and (Choice.Chosen = PickedIndex) and
    (Transcript.SelectedIndex = PickedIndex),
    Format('(通知 %d 回、選ばれた %d、当てた %d)',
      [Choice.Count, Choice.Chosen, PickedIndex]));
  Check('選ばれた文字を取り出せる',
    Transcript.CharItem(PickedIndex, Picked), '(取り出せなかった)');

  { 押した文字の時刻に、値がその時刻そのものである音を入れておく。取り出した
    音の先頭が違う値なら、時刻の対応がずれている。
    Audio whose value is its own time is stored, so a first sample that does not
    match means the mapping from time to sound has slipped. }
  History := TAudioHistory.Create(REVIEW_DEFAULT_SECONDS, Rate);
  try
    SetLength(Audio, Round(200 * Rate));
    for X := 0 to High(Audio) do
      Audio[X] := X / Rate;
    History.Append(Audio, Rate, 0);
    if Transcript.CharItem(PickedIndex, Picked) then
    begin
      Replay := History.Extract(Picked.Seconds, Picked.EndSeconds,
        GotFrom, GotTo, PlayRate);
      Check('選んだ文字の時刻で音を引ける', Length(Replay) > 0, '(空で返った)');
      Check('引いた音がその時刻のものである',
        (Length(Replay) > 0) and
        (Abs(Replay[0] - Picked.Seconds) < 2 / Rate),
        Format('(%.4f を求めて %.4f が返った)',
          [Picked.Seconds, Replay[0]]));
      Check('引いた区間の申告が求めた区間と合う',
        SameValue(GotFrom, Picked.Seconds, 1 / Rate) and
        SameValue(GotTo, Picked.EndSeconds, 1 / Rate),
        Format('(求め %.4f..%.4f / 返り %.4f..%.4f)',
          [Picked.Seconds, Picked.EndSeconds, GotFrom, GotTo]));
    end;
    { 文字数が減る差し替えのあとも、範囲の外を指したままにしない。
      A replacement with fewer characters must not leave the choice pointing
      outside the array. }
    Transcript.SetChars(BuildChars(10));
    Check('文字が減ったら選び直しになる', Transcript.SelectedIndex < 0,
      Format('(%d のままだった)', [Transcript.SelectedIndex]));
  finally
    History.Free;
  end;
  Choice.Free;
  Transcript.OnCharChosen := nil;

  { ── バンドマップ（要件 FR-J）──
    20 局を 1 画面で見渡せること、行を選べること、そして**確かでないものを確か
    そうに見せていないこと。**呼出符号は 1 文字違えば別人なので、一覧に出た時点で
    運用者はそれを事実として扱う。ここは嘘をつきやすい場所である。

    The band map (requirement FR-J). Twenty stations must fit on one screen, a row
    must be selectable, and **nothing uncertain may be shown as if it were
    certain.** A call sign one letter out is a different person, and the moment it
    appears in a list the operator treats it as fact. This is where it is easiest
    to lie. }
  WriteLn;
  WriteLn('バンドマップの検証 / band map checks');
  BandMap := TProbeBandMap.Create(Form);
  BandMap.Parent := Form;
  BandMap.Align := alClient;
  Transcript.Visible := False;
  View.Visible := False;
  Application.ProcessMessages;

  SetLength(Logs, 24);
  for X := 0 to 23 do
  begin
    Logs[X] := Default(TStationLog);
    Logs[X].Id := 100 + X;
    Logs[X].Hz := 600 + X * 100;
    Logs[X].LevelDb := 30 - X * 0.5;
    Logs[X].LastSeconds := 300 - X;
    Logs[X].Heard := X < 22;
    Logs[X].Analysed := X < 20;
    Logs[X].Chars := nil;
  end;
  { 3 種類の局を作り分ける。確かなもの、1 度きりのもの、密集しているもの。
    Three kinds of station: certain, seen once, and crowded. }
  Logs[0].Chars := CharsOf('CQ CQ DE JH2XYZ JH2XYZ K ');
  Logs[1].Chars := CharsOf('JA1ABC DE JH3DEF K ');
  Logs[2].Crowded := 3;
  Logs[2].Chars := CharsOf('CQ DE JA1ABC ');

  Entries := BuildBandEntries(Logs, 320);
  BandMap.SetEntries(Entries, 320);
  Application.ProcessMessages;
  Check('24 局ぶんの行を持つ', BandMap.Count = 24,
    Format('(%d 行)', [BandMap.Count]));

  { 複数回一致したものは、そのまま名前として出す。 }
  Check('一致した呼出符号はそのまま出す', BandMap.NameCaption(0) = 'JH2XYZ',
    Format('("%s")', [BandMap.NameCaption(0)]));
  { 1 度きりのものは、確かでないと分かる形で出す（要件 FR-J.7）。 }
  Check('1 度きりの呼出符号は確かでないと分かる',
    (Pos('JH3DEF', BandMap.NameCaption(1)) > 0) and
    (BandMap.NameCaption(1) <> 'JH3DEF'),
    Format('("%s")', [BandMap.NameCaption(1)]));
  { 待っていた局には印が付き、待っていない局には付かないこと（要件 FR-I.4）。
    **知らせは一度きりで流れてしまうので、行にも残ります。**席を外していて案内を
    見逃しても、一覧を見ればどれが待っていた局か分かります。
    The station waited for is marked and the others are not (requirement FR-I.4).
    **An announcement goes by once, so the row carries it too**: an operator who
    was away can still see which row it was. }
  Check('待っていなければ印は付かない',
    Pos('★', BandMap.NameCaption(0)) = 0,
    Format('("%s")', [BandMap.NameCaption(0)]));
  Waiting := TWatchingFor.Create;
  try
    Waiting.List := ParseWatchList('JH2XYZ');
    Entries := BuildBandEntries(Logs, 320, nil, @Waiting.Lookup);
    BandMap.SetEntries(Entries, 320);
    Application.ProcessMessages;
    Check('待っていた局に印が付く',
      (Pos('★', BandMap.NameCaption(0)) > 0) and
      (Pos('JH2XYZ', BandMap.NameCaption(0)) > 0),
      Format('("%s")', [BandMap.NameCaption(0)]));
    Check('待っていない局には印が付かない',
      Pos('★', BandMap.NameCaption(1)) = 0,
      Format('("%s")', [BandMap.NameCaption(1)]));
    { 確かでない符号には付かないこと。JH3DEF は 1 度きりなので、待っていても
      印は付きません。
      An uncertain call sign carries no mark: JH3DEF was seen once, so even when
      waited for it stays unmarked. }
    Waiting.List := ParseWatchList('JH3DEF');
    Entries := BuildBandEntries(Logs, 320, nil, @Waiting.Lookup);
    BandMap.SetEntries(Entries, 320);
    Check('確かでない符号には印が付かない',
      Pos('★', BandMap.NameCaption(1)) = 0,
      Format('("%s")', [BandMap.NameCaption(1)]));
  finally
    Waiting.Free;
  end;
  { 元に戻してから続けます。/ Restored before going on. }
  Entries := BuildBandEntries(Logs, 320);
  BandMap.SetEntries(Entries, 320);
  Application.ProcessMessages;

  { 密集している範囲は、1 局として読んだふりをしない（要件 FR-J.6）。 }
  Check('密集は呼出符号を出さずに密集と示す',
    (Pos('密集', BandMap.NameCaption(2)) > 0) and
    (Pos('JA1ABC', BandMap.NameCaption(2)) = 0),
    Format('("%s")', [BandMap.NameCaption(2)]));
  { いつ聞こえたかが読めること。 }
  Check('いつ聞こえたかを言葉で出す', BandMap.AgeCaption(0) <> '',
    Format('("%s")', [BandMap.AgeCaption(0)]));
  { 切り捨てた局と、送信を止めただけの局を、同じ見え方にしないこと（要件 FR-I.7）。
    A station that was cut and one that merely stopped must not look the same
    (requirement FR-I.7). }
  Check('聞こえていて読んでいない局だけが切り捨て',
    Entries[20].Cut and Entries[21].Cut and not Entries[22].Cut and
    not Entries[19].Cut,
    Format('(20:%s 21:%s 22:%s)', [BoolToStr(Entries[20].Cut, True),
      BoolToStr(Entries[21].Cut, True), BoolToStr(Entries[22].Cut, True)]));

  { 行を押すと、その局が選ばれて通知される（要件 FR-J.3）。 }
  Chooser := TStationWatcher.Create;
  BandMap.OnStationChosen := @Chooser.Choose;
  BandMap.Tap(BandMap.Height div 2 - BandMap.Height div 2 + 4);
  Check('押した行が選ばれる', BandMap.SelectedId = Logs[0].Id,
    Format('(%d)', [BandMap.SelectedId]));
  Check('選ばれた局が通知される',
    (Chooser.Count = 1) and (Chooser.Id = Logs[0].Id) and
    SameValue(Chooser.Hz, Logs[0].Hz, 0.1),
    Format('(%d 回、%d、%.0f Hz)', [Chooser.Count, Chooser.Id, Chooser.Hz]));

  { 局がいないときに、黙って空にしない。動いていないのか局がいないのかが
    分からなくなる。 }
  BandMap.Clear;
  Check('消しても選択が残らない', BandMap.SelectedId = 0,
    Format('(%d)', [BandMap.SelectedId]));
  Check('局がいなければ 0 行', BandMap.Count = 0);
  BandMap.SetEntries(Entries, 320);

  { 20 局を毎秒描き直しても遅れないこと。 }
  Shot := TBitmap.Create;
  try
    Shot.SetSize(Form.ClientWidth, Form.ClientHeight);
    Started := Now;
    for Repeats := 1 to 20 do
      BandMap.PaintTo(Shot.Canvas, 0, 0);
    PaintMs := MilliSecondsBetween(Now, Started) / 20;
    WriteLn(Format('  24 局の描画: %.1f ms', [PaintMs]));
    Check('24 局の描画が 50 ms 未満', PaintMs < 50,
      Format('(%.1f ms)', [PaintMs]));
  finally
    Shot.Free;
  end;
  Chooser.Free;
  BandMap.Visible := False;
  View.Visible := True;
  Application.ProcessMessages;

  { ── 長時間使ったときにメモリが増え続けないこと ──
    常設シャックは何時間も動かしたままになる。**増え続けるなら、いつか止まる。**
    描画を繰り返して実メモリを測る（要件 NFR-4）。

    A shack leaves this running for hours. **If memory grows without bound it
    eventually stops.** Drawing is repeated and resident memory measured
    (requirement NFR-4). }
  WriteLn;
  WriteLn('メモリの検証 / memory checks');
  View.Visible := True;
  Transcript.Visible := False;
  Application.ProcessMessages;
  Shot := TBitmap.Create;
  try
    Shot.SetSize(Form.ClientWidth, Form.ClientHeight);
    Audio := SweptAudio(8000, 700, 900, 1);
    { 先に少し回してから測り始めます。最初の確保を増加と数えないためです。
      A warm-up first, so the initial allocations are not counted as growth. }
    for Repeats := 1 to 50 do
    begin
      View.PushSamples(Audio, 8000, 0);
      View.Touch;
      View.PaintTo(Shot.Canvas, 0, 0);
    end;
    Before := MemoryUse;
    for Repeats := 1 to 500 do
    begin
      View.PushSamples(Audio, 8000, 0);
      View.Touch;
      View.PaintTo(Shot.Canvas, 0, 0);
    end;
    After_ := MemoryUse;
  finally
    Shot.Free;
  end;
  WriteLn(Format('  500 回の描画: %s → %d kB（差 %d kB）',
    [MemoryUseCaption(Before), After_.Kilobytes,
     After_.Kilobytes - Before.Kilobytes]));
  { 500 回で 20 MB 増えるなら、毎秒 10 回の描画で 1 時間に 1.4 GB になる。
    Twenty megabytes over five hundred paints is 1.4 GB an hour at ten paints
    a second. }
  { **測れない環境では「通った」と言いません**（教訓 10.14）。
    **Where it cannot be measured, this does not say it passed** (lesson
    10.14). }
  if Before.Kind = mkNone then
    WriteLn('  --   メモリを測れない環境のため、増加の検査は行いません')
  else
    Check('描画を繰り返してもメモリが増え続けない',
      After_.Kilobytes - Before.Kilobytes < 20000,
      Format('(差 %d kB)', [After_.Kilobytes - Before.Kilobytes]));

  Watcher.Free;
  Form.Free;

  WriteLn;
  if Failures = 0 then
    WriteLn('すべての確認に通りました。')
  else
    WriteLn(Format('%d 件が通りませんでした。', [Failures]));
  Halt(Ord(Failures > 0));
end.
