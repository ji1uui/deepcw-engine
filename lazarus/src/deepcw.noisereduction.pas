unit DeepCW.NoiseReduction;

{ ノイズ低減の受け口です（要件 FR-N）。**中身（AI のモデル）は保留**で、
  いまは「使わない」（素通し）だけが選べます。

  取り決め（**中身を足すときも守ること**）:

  1. **生の音は変えません。**低減は**復号へ渡す写し**にだけ掛けます。聴き直し・
     録音・ウォーターフォールは生の音のままです（Raw Observation と区別する。
     利用者がいつでも生の音に戻れる——選択を「使わない」にすれば戻る）。
  2. **受信の 4 つの入口を同じに通します**: 流し込み・ファイルの復号・多局の
     ファイルの復号・語の読み直し。**入口ごとに違えば、同じ音が入口で違う文字に
     なります。**送信訓練は利用者の鍵の測定なので通しません。
  3. **使わないときは費用ゼロ**です（写しも作らない。`Active` が False）。
  4. 画面のスレッドで呼びます。ワーカーへ渡す前に掛けます。**重い処理を足す
     ときは、この取り決めを見直すこと**（流し込みは 0.2 秒ごと。付録 C.4）。
  5. **使えない低減は選べません**（`Available`）。設定に知らない鍵があれば
     素通しに戻ります（fail-soft）。
  6. **未決**: `Process` には、続いて届く流し込みの細切れと、それとは独立した
     一続きの音（ファイル・読み直し・「モデルの聴いている音」）の両方が来ます。
     **内側に状態を持つ低減は、この 2 つを分けて扱う必要があります**（中身を
     足すときに決める）。

  The interface for noise reduction (requirement FR-N). **The contents (an AI
  model) are pending**; only "off" (pass-through) can be chosen for now.

  Rules (**to be kept when the contents arrive**):

  1. **Raw audio is never changed.** Reduction is applied only to **the copy
     handed to the decoder**; replay, recording and the waterfall keep the raw
     audio (kept apart from the Raw Observation; the operator can always go
     back to raw by choosing "off").
  2. **All four receive entry points go through it alike**: the live stream,
     file decoding, multi-station file decoding and word re-checking. **If they
     differed, the same audio would become different characters by entry
     point.** Sending practice measures the operator's own keying and does not
     go through it.
  3. **Off costs nothing** (no copy is even made; `Active` is False).
  4. Called on the UI thread, before audio is handed to a worker. **Adding a
     heavy process means revisiting this rule** (the stream is fed every 0.2 s;
     appendix C.4).
  5. **An unavailable reducer cannot be chosen** (`Available`); an unknown key
     in the settings falls back to pass-through (fail-soft).
  6. **Open**: `Process` receives both the consecutive pieces of the live
     stream and independent clips (a file, a re-check, "what the model hears").
     **A reducer with inner state must tell the two apart** (to be decided when
     the contents arrive). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DeepCW.Types;

const
  { 設定に書く鍵。**訳しません。**/ The keys written to settings; never translated. }
  NOISE_KEY_OFF = 'off';
  NOISE_KEY_AI = 'ai';

type
  TNoiseReducer = class
  public
    { 設定に書く鍵。/ The key written to settings. }
    function Key: string; virtual; abstract;
    { 選べるか。/ Whether it can be chosen. }
    function Available: Boolean; virtual; abstract;
    { 何かをするか。False なら呼ぶ側は写しも作りません。
      Whether it does anything; when False the caller makes no copy. }
    function Active: Boolean; virtual; abstract;
    { 復号へ渡す写しに掛けます。**生の音を渡してはいけません。**
      Applied to the copy handed to the decoder. **Never pass the raw audio.** }
    procedure Process(var Samples: TSingleArray; SampleRate: Integer); virtual; abstract;
    { 受信を始め直すときに、内側の状態を捨てます。/ Drops internal state on a new start. }
    procedure Reset; virtual;
  end;

  { 素通し（使わない）。/ Pass-through ("off"). }
  TBypassReducer = class(TNoiseReducer)
  public
    function Key: string; override;
    function Available: Boolean; override;
    function Active: Boolean; override;
    procedure Process(var Samples: TSingleArray; SampleRate: Integer); override;
  end;

  { AI による低減の席。**中身は保留**で、選べません（`Available` が False）。
    The seat for AI reduction. **Its contents are pending**; it cannot be chosen
    (`Available` is False). }
  TAiReducer = class(TNoiseReducer)
  public
    function Key: string; override;
    function Available: Boolean; override;
    function Active: Boolean; override;
    procedure Process(var Samples: TSingleArray; SampleRate: Integer); override;
  end;

{ 鍵から作ります。**知らない鍵・使えない低減は素通し**になります。
  Makes one from a key; **an unknown key or an unavailable reducer gives
  pass-through.** }
function CreateNoiseReducer(const Key: string): TNoiseReducer;

{ 復号へ渡す音を返します。使わないなら**同じ配列をそのまま**（写さない）、
  使うなら写しに掛けたものを返します。/ The audio to hand to the decoder: **the
  same array** when off (no copy), otherwise a processed copy. }
function ForDecoder(Reducer: TNoiseReducer; const Samples: TSingleArray;
  SampleRate: Integer): TSingleArray;

implementation

procedure TNoiseReducer.Reset;
begin
end;

function TBypassReducer.Key: string;
begin
  Result := NOISE_KEY_OFF;
end;

function TBypassReducer.Available: Boolean;
begin
  Result := True;
end;

function TBypassReducer.Active: Boolean;
begin
  Result := False;
end;

procedure TBypassReducer.Process(var Samples: TSingleArray; SampleRate: Integer);
begin
end;

function TAiReducer.Key: string;
begin
  Result := NOISE_KEY_AI;
end;

function TAiReducer.Available: Boolean;
begin
  { モデルが同梱されるまで選べません。/ Not choosable until a model is bundled. }
  Result := False;
end;

function TAiReducer.Active: Boolean;
begin
  Result := False;
end;

procedure TAiReducer.Process(var Samples: TSingleArray; SampleRate: Integer);
begin
  raise EDeepCW.Create('AI noise reduction is not available yet.');
end;

function CreateNoiseReducer(const Key: string): TNoiseReducer;
begin
  if Key = NOISE_KEY_AI then
  begin
    Result := TAiReducer.Create;
    if Result.Available then
      Exit;
    Result.Free;
  end;
  Result := TBypassReducer.Create;
end;

function ForDecoder(Reducer: TNoiseReducer; const Samples: TSingleArray;
  SampleRate: Integer): TSingleArray;
begin
  if (Reducer = nil) or not Reducer.Active then
    Exit(Samples);
  Result := Copy(Samples);
  Reducer.Process(Result, SampleRate);
end;

end.
