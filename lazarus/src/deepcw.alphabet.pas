unit DeepCW.Alphabet;

{ 符号の文字の種類（欧文・和文）の受け口です（要件 FR-W、7.2）。**和文の中身は
  保留**で、いまは欧文だけが選べます。

  和文に要るのは次の 3 つで、**どれもまだ無い**ので選べません（`Available`）:

  1. **和文のモデル**（カタカナ 67 文字＋ブランク。リファレンス実装にはあるが
     本リポジトリに無い）。メタデータの文字集合にカナがあれば和文のモデルと
     分かります（`ModelAlphabet`）——**7.2 の「メタデータ駆動のまま保つ」**。
  2. **和文の符号表**（送信・練習の音声生成・送信訓練の課題文。`DeepCW.Morse`
     は欧文だけ）。
  3. **欧文と和文の切り替えの合図**（ホレ・ラタ）の扱い。

  受信した文字は既に文字列（`TDecodedChar.Text`）で持つので、カナ（UTF-8 で
  3 バイト）はそのまま入ります。

  The interface for the kind of characters (international or Wabun)
  (requirement FR-W, section 7.2). **The Wabun contents are pending**; only
  international can be chosen for now. Wabun needs three things, **none of
  which exist yet**, so it cannot be chosen (`Available`): a Wabun **model**
  (67 katakana plus blank; the reference implementation has one, this
  repository does not) -- a kana alphabet in the metadata identifies it
  (`ModelAlphabet`), **keeping section 7.2's "metadata-driven" rule**; a Wabun
  **code table** (sending, practice audio, send-practice texts; `DeepCW.Morse`
  is international only); and handling of the **switching signs** between the
  two. Received characters are already strings (`TDecodedChar.Text`), so a
  kana (three UTF-8 bytes) fits as it is. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DeepCW.Metadata;

const
  { 設定に書く鍵。**訳しません。**/ The keys written to settings; never translated. }
  ALPHABET_KEY_INTERNATIONAL = 'international';
  ALPHABET_KEY_WABUN = 'wabun';

type
  TCwAlphabet = (caInternational, caWabun);

function AlphabetKey(Alphabet: TCwAlphabet): string;
{ 知らない鍵は欧文です（fail-soft）。/ An unknown key means international. }
function AlphabetFromKey(const Key: string): TCwAlphabet;
{ 選べるか。和文は中身が揃うまで False。/ Whether it can be chosen. }
function AlphabetAvailable(Alphabet: TCwAlphabet): Boolean;
{ 読み込んだモデルの文字の種類。**文字集合にカナが 1 つでもあれば和文。**
  The alphabet of a loaded model: **Wabun if its character set holds any kana.** }
function ModelAlphabet(Meta: TDeepCWMetadata): TCwAlphabet;

implementation

function AlphabetKey(Alphabet: TCwAlphabet): string;
begin
  if Alphabet = caWabun then
    Result := ALPHABET_KEY_WABUN
  else
    Result := ALPHABET_KEY_INTERNATIONAL;
end;

function AlphabetFromKey(const Key: string): TCwAlphabet;
begin
  if Key = ALPHABET_KEY_WABUN then
    Result := caWabun
  else
    Result := caInternational;
end;

function AlphabetAvailable(Alphabet: TCwAlphabet): Boolean;
begin
  Result := Alphabet = caInternational;
end;

{ UTF-8 のカタカナ（U+30A0〜U+30FF）とひらがな（U+3040〜U+309F）は、
  先頭のバイトが E3 で、2 バイト目が 81〜83 です。
  UTF-8 katakana (U+30A0..U+30FF) and hiragana (U+3040..U+309F) start with
  byte E3, second byte 81..83. }
function HasKana(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(S) - 1 do
    if (Ord(S[I]) = $E3) and (Ord(S[I + 1]) >= $81) and (Ord(S[I + 1]) <= $83) then
      Exit(True);
end;

function ModelAlphabet(Meta: TDeepCWMetadata): TCwAlphabet;
var
  I: Integer;
begin
  Result := caInternational;
  if Meta = nil then
    Exit;
  for I := 0 to Meta.CharCount - 1 do
    if HasKana(Meta.Chars[I]) then
      Exit(caWabun);
end;

end.
