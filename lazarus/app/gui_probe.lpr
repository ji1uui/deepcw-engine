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
  DeepCW.Review,
  WaterfallView, TranscriptView;

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

procedure TProbeTranscript.Tap(X, Y: Integer);
begin
  MouseDown(mbLeft, [], X, Y);
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

{ いま使っている実メモリ（kB）。取れない環境では 0 を返します。
  Resident memory in kilobytes, or 0 where it cannot be read. }
function ResidentKb: Int64;
{$IFDEF LINUX}
var
  Lines: TStringList;
  I: Integer;
  Line: string;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile('/proc/self/status');
    except
      Exit;
    end;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if Pos('VmRSS:', Line) = 1 then
      begin
        Line := Trim(Copy(Line, 7, Length(Line)));
        Result := StrToInt64Def(Trim(Copy(Line, 1, Pos(' ', Line + ' ') - 1)), 0);
        Exit;
      end;
    end;
  finally
    Lines.Free;
  end;
end;
{$ELSE}
begin
  Result := 0;
end;
{$ENDIF}

{ 復号済みの文字を並べたものを作ります。長時間の受信で溜まった状態を模します。
  Builds a run of decoded characters, standing in for what accumulates over a
  long session. }
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
  BeforeKb, AfterKb: Int64;
  View: TProbeView;
  Watcher: TWatcher;
  Audio: TSingleArray;
  Rate, X, Frame: Integer;
  OutDir: string;
  Shot: TBitmap;
  Started: TDateTime;
  Elapsed: Double;
  Choice: TChoiceWatcher;
  History: TAudioHistory;
  Picked: TDecodedChar;
  Replay: TSingleArray;
  GotFrom, GotTo: Double;
  PickedIndex, PlayRate: Integer;

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
  View.PushSamples(Audio, Rate);
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
  View.PushSamples(TestAudio(44100), 44100);
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
  View.PushSamples(SweptAudio(8000, 900, 1000, 12), 8000);
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
  View.PushSamples(SweptAudio(8000, 900, 1000, 12), 8000);
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
  View.PushSamples(NoiseOnly(8000, 12), 8000);
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
  View.PushSamples(TestAudio(8000), 8000);
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
      View.PushSamples(Audio, 8000);
      View.Touch;
      View.PaintTo(Shot.Canvas, 0, 0);
    end;
    BeforeKb := ResidentKb;
    for Repeats := 1 to 500 do
    begin
      View.PushSamples(Audio, 8000);
      View.Touch;
      View.PaintTo(Shot.Canvas, 0, 0);
    end;
    AfterKb := ResidentKb;
  finally
    Shot.Free;
  end;
  WriteLn(Format('  500 回の描画: %d kB → %d kB（差 %d kB）',
    [BeforeKb, AfterKb, AfterKb - BeforeKb]));
  { 500 回で 20 MB 増えるなら、毎秒 10 回の描画で 1 時間に 1.4 GB になる。
    Twenty megabytes over five hundred paints is 1.4 GB an hour at ten paints
    a second. }
  Check('描画を繰り返してもメモリが増え続けない',
    (BeforeKb = 0) or (AfterKb - BeforeKb < 20000),
    Format('(差 %d kB)', [AfterKb - BeforeKb]));

  Watcher.Free;
  Form.Free;

  WriteLn;
  if Failures = 0 then
    WriteLn('すべての確認に通りました。')
  else
    WriteLn(Format('%d 件が通りませんでした。', [Failures]));
  Halt(Ord(Failures > 0));
end.
