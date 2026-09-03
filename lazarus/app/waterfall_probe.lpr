program waterfall_probe;

{ ウォーターフォール部品の検証用プログラムです。

  画面のない環境でも、部品を実際に生成し、音声を流し込み、描画させ、クリック
  やホイールの操作を与えて、結果を PNG に書き出せます。GUI の不具合は組み上げ
  てからでないと出ないため、これがないと確かめようがありません
  （要件 NFR-7.1）。

  A harness for the waterfall control.

  Even without a display it creates the control for real, feeds it audio, makes
  it paint, and applies clicks and wheel events, writing the result out as a
  PNG. GUI defects only appear once things are assembled, so without this there
  would be no way to check (requirement NFR-7.1). }

{$mode objfpc}{$H+}

uses
  SysUtils, DateUtils, Math, Classes, Interfaces, Forms, Controls, Graphics, LCLType,
  DeepCW.Types, DeepCW.Morse, DeepCW.Tuner, WaterfallView;

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

  { 同調の通知が届いたかを数えます。/ Counts the tuning notifications. }
  TWatcher = class
    Changes: Integer;
    procedure Changed(Sender: TObject);
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

var
  Form: TForm;
  View: TProbeView;
  Watcher: TWatcher;
  Audio: TSingleArray;
  Rate, X, Frame: Integer;
  OutDir: string;
  Shot: TBitmap;
  Started: TDateTime;
  Elapsed: Double;

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

  Watcher.Free;
  Form.Free;

  WriteLn;
  if Failures = 0 then
    WriteLn('すべての確認に通りました。')
  else
    WriteLn(Format('%d 件が通りませんでした。', [Failures]));
  Halt(Ord(Failures > 0));
end.
