unit DeepCW.Journal;

{ 受信テキストを、時刻付きでファイルへ書き足していく記録です。

  受信中に電源が落ちても、アプリが強制終了されても、**そこまでに確定した分は
  ファイルに残っていなければなりません。**残っていなければ、記録としての用を
  なしません。そのため、1 行できるたびに開いて書いて閉じます。開いたままにして
  終了時にまとめて書く作りは、書けなかったときに何も残りません（要件 FR-B.6）。

  行の切れ目は語間に置きます。1 文字ずつ書くと読めたものではなく、まとめて
  書くと落ちたときに失われる量が増えるためです。

  時刻は、受信を始めた実時刻に、その行の先頭の文字の経過秒を足して求めます。
  書いた瞬間の時刻ではありません。確定は数秒遅れて起こるので、書いた時刻を
  使うと、記録された時刻が実際より遅くなります。

  A record of received text, appended to a file with times.

  If the power goes or the application is killed mid-reception, **what was
  confirmed up to that point must already be in the file.** A record that is not
  there is no record at all. So the file is opened, written and closed once per
  completed line; holding it open and writing everything at exit leaves nothing
  behind when the exit is not clean (requirement FR-B.6).

  Lines break at word spaces: a line per character would be unreadable, and
  larger batches would lose more when something goes wrong.

  The time of a line is the wall clock at which reception began plus the elapsed
  seconds of the line's first character, not the moment it was written.
  Confirmation lags by seconds, so writing time would record everything late. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, DeepCW.Types, DeepCW.Decoder;

const
  { 1 行に許す長さ。語間が来ないまま延々と続く（連続送信、雑音の誤読）場合に、
    ここで折ります。折らないと、落ちたときに失われる量に上限がなくなります。
    The longest line allowed. When no word space arrives — continuous sending, or
    noise being misread — the line is broken here; without a limit there would be
    no bound on how much is lost when something goes wrong. }
  JOURNAL_MAX_LINE = 120;

type
  { 受信テキストの記録。UI スレッドからのみ呼んでください。

    A transcript journal. Call it from the interface thread only. }
  TTranscriptJournal = class
  private
    FDirectory: string;
    FFileName: string;
    FEnabled: Boolean;
    FLastError: string;
    { 書き出し待ちの行と、その行の先頭の文字の経過秒。
      The line waiting to be written and the elapsed seconds of its first
      character. }
    FLine: string;
    FLineSeconds: Double;
    FOrigin: TDateTime;
    FBytes: Int64;
    FLines: Int64;
    procedure WriteLine;
    function EnsureFile: Boolean;
    procedure SetEnabled(Value: Boolean);
  public
    constructor Create(const ADirectory: string);

    { 新しい受信を始めます。AOrigin は経過秒 0 に対応する実時刻です。
      Starts a new reception; AOrigin is the wall clock at elapsed second zero. }
    procedure StartSession(AOrigin: TDateTime);

    { 確定した文字を書き足します。同じ文字を二度渡さないよう、呼び出し側が
      渡す範囲を決めてください。
      Appends confirmed characters. The caller decides the range, so that the
      same character is never handed over twice. }
    procedure Add(const Chars: TDecodedChars);

    { 書き出し待ちの行を、語間を待たずに書き出します。受信を止めるときに
      呼びます。
      Writes the waiting line without waiting for a word space, for when
      reception stops. }
    procedure Flush;

    { 記録を取るかどうか。止めるときは、書き出し待ちの行を先に出します。
      抱えたまま止めると、その語だけが記録から落ちます。
      Whether to journal. Switching it off writes the waiting line out first;
      dropping it would lose exactly one word from the record. }
    property Enabled: Boolean read FEnabled write SetEnabled;
    { 書いているファイル。まだ何も書いていなければ空です。
      The file being written, or empty when nothing has been written yet. }
    property FileName: string read FFileName;
    { 書けなかったときの原因。受信は止めず、ここに残して画面へ出します。
      Why a write failed. Reception is not stopped; the reason is kept here and
      shown on screen. }
    property LastError: string read FLastError;
    property BytesWritten: Int64 read FBytes;
    property LinesWritten: Int64 read FLines;
  end;

{ その日の記録ファイルの名前。日付ごとに分けると、あとから探しやすくなります。
  The name of the day's file; splitting by date makes it findable later. }
function JournalFileFor(const Directory: string; When: TDateTime): string;

implementation

function JournalFileFor(const Directory: string; When: TDateTime): string;
begin
  Result := IncludeTrailingPathDelimiter(Directory) +
    FormatDateTime('yyyy-mm-dd', When) + '.txt';
end;

constructor TTranscriptJournal.Create(const ADirectory: string);
begin
  inherited Create;
  FDirectory := ADirectory;
  FOrigin := Now;
end;

procedure TTranscriptJournal.StartSession(AOrigin: TDateTime);
begin
  { 前の受信の書き残しを、新しい受信の時刻で書いてしまわないよう先に出します。
    Write out the previous reception's remainder first, so it is not stamped
    with the new reception's clock. }
  WriteLine;
  FOrigin := AOrigin;
  FLine := '';
  FLineSeconds := 0;
end;

function TTranscriptJournal.EnsureFile: Boolean;
var
  Wanted: string;
begin
  Result := False;
  if FDirectory = '' then
    Exit;
  Wanted := JournalFileFor(FDirectory, FOrigin + FLineSeconds / SecsPerDay);
  try
    if not DirectoryExists(FDirectory) then
      if not ForceDirectories(FDirectory) then
      begin
        FLastError := '記録の保存先を作れません: ' + FDirectory;
        Exit;
      end;
  except
    on E: Exception do
    begin
      FLastError := '記録の保存先を作れません: ' + E.Message;
      Exit;
    end;
  end;
  FFileName := Wanted;
  Result := True;
end;

procedure TTranscriptJournal.WriteLine;
var
  Stream: TFileStream;
  Text: string;
  Mode: Word;
begin
  if FLine = '' then
    Exit;
  if not EnsureFile then
  begin
    { 書けなくても、待っている行は捨てます。抱え続けると際限なく伸びます。
      The waiting line is dropped even when it cannot be written; holding on to
      it would let it grow without bound. }
    FLine := '';
    Exit;
  end;
  Text := FormatDateTime('yyyy-mm-dd hh:nn:ss',
    FOrigin + FLineSeconds / SecsPerDay) + '  ' + FLine + LineEnding;
  try
    if FileExists(FFileName) then
      Mode := fmOpenWrite or fmShareDenyNone
    else
      Mode := fmCreate or fmShareDenyNone;
    Stream := TFileStream.Create(FFileName, Mode);
    try
      Stream.Seek(0, soEnd);
      Stream.WriteBuffer(Text[1], Length(Text));
      Inc(FBytes, Length(Text));
      Inc(FLines);
      FLastError := '';
    finally
      { 閉じることが書き込みの完了です。ここまで来ていれば、この行は
        強制終了しても残ります。
        Closing is what completes the write: past this point the line survives
        even a kill. }
      Stream.Free;
    end;
  except
    on E: Exception do
      FLastError := '記録を書けません: ' + E.Message;
  end;
  FLine := '';
end;

procedure TTranscriptJournal.SetEnabled(Value: Boolean);
begin
  if FEnabled = Value then
    Exit;
  if not Value then
    WriteLine;
  FEnabled := Value;
end;

procedure TTranscriptJournal.Add(const Chars: TDecodedChars);
var
  I: Integer;
  Piece: string;
begin
  if not FEnabled then
    Exit;
  for I := 0 to High(Chars) do
  begin
    Piece := Chars[I].Text;
    if Piece = ' ' then
    begin
      { 語間で行を閉じます。行頭の語間は捨てます。
        A word space closes the line; one at the start of a line is dropped. }
      if FLine <> '' then
        WriteLine;
      Continue;
    end;
    if FLine = '' then
      FLineSeconds := Chars[I].Seconds;
    FLine := FLine + Piece;
    if Length(FLine) >= JOURNAL_MAX_LINE then
      WriteLine;
  end;
end;

procedure TTranscriptJournal.Flush;
begin
  if FEnabled then
    WriteLine;
end;

end.
