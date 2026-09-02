program cw_loopback;

{ 送信から受信までを通して確かめる自己診断です。

  DeepCW.Morse の送信機でメッセージを送出し、得られた音声をそのまま DeepCW の
  デコーダへ入力して、両者を比較します。サウンドカードを使わずに全体の経路を
  検証できるため、ビルドと ONNX Runtime の健全性を最も手軽に確認できます。

  Transmit-then-receive self test.

  Keys a message with the DeepCW.Morse transmitter, feeds the resulting audio
  straight into the DeepCW decoder and compares the two. It exercises the whole
  chain without a sound card, which makes it the quickest way to confirm that a
  build and its ONNX Runtime are healthy. }

{$mode objfpc}{$H+}

uses
  SysUtils, Math, DeepCW.Types, DeepCW.Onnx, DeepCW.Morse, DeepCW.Decoder,
  DeepCW.Wave;

const
  MESSAGES: array[0..5] of string = (
    'CQ CQ DE JA1ABC K',
    'HELLO WORLD FROM LAZARUS',
    'TNX FER QSO 73 ES GL',
    'RST 599 599 NAME TARO QTH TOKYO',
    'TEST DE 7K1ABC/1 PSE K',
    'WX SUNNY 25C RIG 100W ANT DIPOLE');

var
  ModelPath: string = '';
  MetadataPath: string = '';
  RuntimePath: string = '';
  Decoder: TDeepCWDecoder;
  Timing: TCWTiming;
  Options: TCWToneOptions;
  Samples: TSingleArray;
  Index, Passed, Total: Integer;
  Expected, Decoded, Key, Value: string;
  Wpm, ToneHz, Noise: Double;

function PadToMinimum(const Input: TSingleArray; SampleRate: Integer): TSingleArray;
var
  Needed: Integer;
begin
  { モデルは 5 秒未満の音声を受け付けないため、短いメッセージにはエラーを
    返す代わりに末尾へ無音を加えます。

    The model rejects anything under five seconds, so short messages get
    trailing silence rather than an error. }
  Needed := Ceil((DEEPCW_MIN_SECONDS + 0.2) * SampleRate);
  if Length(Input) >= Needed then
    Exit(Input);
  Result := Copy(Input, 0, Length(Input));
  SetLength(Result, Needed);
end;

begin
  Index := 1;
  while Index < ParamCount do
  begin
    Key := ParamStr(Index);
    Value := ParamStr(Index + 1);
    case Key of
      '--model': ModelPath := Value;
      '--metadata': MetadataPath := Value;
      '--onnxruntime': RuntimePath := Value;
    else
      begin
        WriteLn(StdErr, 'Unknown option: ', Key);
        Halt(2);
      end;
    end;
    Inc(Index, 2);
  end;

  if ModelPath = '' then
    ModelPath := LocateDataFile('model.onnx');
  if MetadataPath = '' then
    MetadataPath := LocateDataFile('model.onnx.json');

  try
    LoadOnnxRuntime(RuntimePath);
    WriteLn('ONNX Runtime ', OnnxRuntimeVersion);
    Decoder := TDeepCWDecoder.Create(ModelPath, MetadataPath);
    try
      Passed := 0;
      Total := 0;
      for Index := 0 to High(MESSAGES) do
      begin
        Expected := NormalizeText(MESSAGES[Index]);

        { 速度、音程、雑音を変え、単一の設定に偏らないようにします。
        Vary speed, pitch and noise so the test covers more than one setting. }
        Wpm := 16 + 4 * (Index mod 4);
        ToneHz := 500 + 150 * (Index mod 5);
        Noise := 0.02 * (Index mod 3);

        Timing := DefaultTiming;
        Timing.CharWpm := Wpm;
        Timing.TextWpm := Wpm;

        Options := DefaultToneOptions;
        Options.ToneHz := ToneHz;
        Options.NoiseAmplitude := Noise;

        Samples := PadToMinimum(TextToPCM(MESSAGES[Index], Timing, Options),
          Options.SampleRate);
        Decoded := Decoder.DecodeLongSamples(Samples, Options.SampleRate);

        Inc(Total);
        if Decoded = Expected then
        begin
          Inc(Passed);
          WriteLn(Format('  ok   %2.0f wpm %4.0f Hz noise %.2f  %s', [Wpm, ToneHz, Noise, Decoded]));
        end
        else
          WriteLn(Format('  FAIL %2.0f wpm %4.0f Hz noise %.2f%s    sent    "%s"%s    received "%s"',
            [Wpm, ToneHz, Noise, LineEnding, Expected, LineEnding, Decoded]));
      end;

      WriteLn(Format('%d of %d messages decoded exactly.', [Passed, Total]));
      if Passed <> Total then
        Halt(1);
    finally
      Decoder.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      Halt(1);
    end;
  end;
end.
