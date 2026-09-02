unit DeepCW.Metadata;

{ Reader and validator for model.onnx.json.

  The metadata file is the contract between the exported ONNX graph and the
  front end: it fixes the sample rate, the STFT geometry and the character
  table used by the CTC decoder. Everything in this unit is derived from that
  file so that a re-exported model only requires shipping a new JSON. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, fpjson, jsonparser, DeepCW.Types;

type
  TDeepCWMetadata = class
  private
    FChars: array of string;
    FBlankIndex: Integer;
    FSampleRate: Integer;
    FFFTLength: Integer;
    FHopLength: Integer;
    FFrequencyBins: Integer;
    FNumClasses: Integer;
    FChannelCount: Integer;
    FMinFreqHz: Double;
    FMaxFreqHz: Double;
    FNormalization: string;
    FInputName: string;
    FOutputName: string;
    function GetChars(Index: Integer): string;
    function GetCharCount: Integer;
    procedure Validate;
  public
    procedure LoadFromFile(const FileName: string);
    procedure LoadFromText(const Text: string);

    { First and last+1 FFT bin covered by [MinFreqHz, MaxFreqHz]. }
    function StartBin: Integer;
    function StopBin: Integer;

    property Chars[Index: Integer]: string read GetChars;
    property CharCount: Integer read GetCharCount;
    property BlankIndex: Integer read FBlankIndex;
    property SampleRate: Integer read FSampleRate;
    property FFTLength: Integer read FFFTLength;
    property HopLength: Integer read FHopLength;
    property FrequencyBins: Integer read FFrequencyBins;
    property NumClasses: Integer read FNumClasses;
    property ChannelCount: Integer read FChannelCount;
    property MinFreqHz: Double read FMinFreqHz;
    property MaxFreqHz: Double read FMaxFreqHz;
    property Normalization: string read FNormalization;
    property InputName: string read FInputName;
    property OutputName: string read FOutputName;
  end;

implementation

function TDeepCWMetadata.GetChars(Index: Integer): string;
begin
  if (Index < 0) or (Index > High(FChars)) then
    raise EDeepCW.CreateFmt('Character index %d is outside the model alphabet.', [Index]);
  Result := FChars[Index];
end;

function TDeepCWMetadata.GetCharCount: Integer;
begin
  Result := Length(FChars);
end;

function TDeepCWMetadata.StartBin: Integer;
var
  BinHz: Double;
begin
  BinHz := FSampleRate / FFFTLength;
  Result := Ceil64(FMinFreqHz / BinHz);
end;

function TDeepCWMetadata.StopBin: Integer;
var
  BinHz: Double;
begin
  BinHz := FSampleRate / FFFTLength;
  Result := Floor64(FMaxFreqHz / BinHz) + 1;
end;

procedure TDeepCWMetadata.LoadFromFile(const FileName: string);
var
  Stream: TStringStream;
  Input: TFileStream;
begin
  if not FileExists(FileName) then
    raise EDeepCW.CreateFmt('Metadata file not found: %s', [FileName]);
  Input := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    Stream := TStringStream.Create('');
    try
      Stream.CopyFrom(Input, 0);
      LoadFromText(Stream.DataString);
    finally
      Stream.Free;
    end;
  finally
    Input.Free;
  end;
end;

procedure TDeepCWMetadata.LoadFromText(const Text: string);
var
  Root: TJSONData;
  Obj: TJSONObject;
  CharList: TJSONArray;
  I: Integer;
begin
  Root := GetJSON(Text);
  try
    if not (Root is TJSONObject) then
      raise EDeepCW.Create('The metadata file must contain a JSON object.');
    Obj := TJSONObject(Root);

    CharList := Obj.Get('chars', TJSONArray(nil));
    if CharList = nil then
      raise EDeepCW.Create('The metadata file is missing the "chars" array.');
    SetLength(FChars, CharList.Count);
    for I := 0 to CharList.Count - 1 do
      FChars[I] := CharList.Strings[I];

    FBlankIndex := Obj.Get('blank_index', -1);
    FSampleRate := Obj.Get('sample_rate', 0);
    FFFTLength := Obj.Get('fft_length', 0);
    FHopLength := Obj.Get('hop_length', 0);
    FFrequencyBins := Obj.Get('spectrogram_frequency_bins', 0);
    FNumClasses := Obj.Get('num_classes', 0);
    FChannelCount := Obj.Get('channel_count', 1);
    FMinFreqHz := Obj.Get('spectrogram_min_freq_hz', 0.0);
    FMaxFreqHz := Obj.Get('spectrogram_max_freq_hz', 0.0);
    FNormalization := Obj.Get('normalization', '');
    FInputName := Obj.Get('onnx_input_name', '');
    FOutputName := Obj.Get('onnx_output_name', '');
  finally
    Root.Free;
  end;
  Validate;
end;

procedure TDeepCWMetadata.Validate;
var
  Bins: Integer;
begin
  if Length(FChars) = 0 then
    raise EDeepCW.Create('The metadata "chars" array is empty.');
  if FSampleRate <= 0 then
    raise EDeepCW.Create('The metadata "sample_rate" must be positive.');
  if FFFTLength <= 0 then
    raise EDeepCW.Create('The metadata "fft_length" must be positive.');
  if FHopLength <= 0 then
    raise EDeepCW.Create('The metadata "hop_length" must be positive.');
  if FInputName = '' then
    raise EDeepCW.Create('The metadata is missing "onnx_input_name".');
  if FOutputName = '' then
    raise EDeepCW.Create('The metadata is missing "onnx_output_name".');
  if not SameText(FNormalization, 'log1p') then
    raise EDeepCW.CreateFmt('Unsupported normalization: %s', [FNormalization]);
  if FNumClasses <> Length(FChars) + 1 then
    raise EDeepCW.CreateFmt('num_classes (%d) must be the alphabet size (%d) plus one blank.',
      [FNumClasses, Length(FChars)]);
  if (FBlankIndex < 0) or (FBlankIndex >= FNumClasses) then
    raise EDeepCW.CreateFmt('blank_index (%d) is outside the class range.', [FBlankIndex]);

  Bins := StopBin - StartBin;
  if Bins <> FFrequencyBins then
    raise EDeepCW.CreateFmt('Metadata expects %d frequency bins, but the geometry yields %d.',
      [FFrequencyBins, Bins]);
end;

end.
