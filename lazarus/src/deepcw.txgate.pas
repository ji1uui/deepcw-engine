unit DeepCW.TxGate;

{ 自局が送っている間、受信の復号を止めます（要件 FR-T.4）。

  無線機で送ると、その音（サイドトーン・モニター）が受信の入力に入ることが
  あります。そのまま復号すると**自局の送信を受信として読み**、「DE の直後」が
  自局になり、一覧・記録・「受信から」に自局の符号が入ります。

  取り決め:

  1. **止めるのは復号へ渡す音だけ**です。聴き直し・録音・ウォーターフォールは
     生の音のままです（起きたことはそのまま残す。Raw Observation）。
  2. 止めている間は、**同じ長さの無音**を渡します。音を抜くと、復号器の時計
     （経過秒）が保管庫とずれ、聴き直しが別の場所を鳴らします（要件 FR-E.10）。
  3. いつまで止めるかは、**無線機が送り終える見込み**（`KeyedUntil`）に余白
     （`TX_GATE_HANG_MS`）を足した時刻までです。鍵のスレッドが「失敗」に
     なっても、渡し済みの語は無線機が送り続けうるので、見込みまで止めます。
  4. 画面のスレッドだけが使います（0.2 秒ごとの流し込みから）。

  Stops decoding the reception while the station is sending (requirement
  FR-T.4). Sending through the rig can put its sound (sidetone, monitor) into
  the receive input; decoded as it is, **one's own sending is read as
  reception**, the call after DE becomes one's own, and it lands in the list,
  the log and "from reception".

  Rules:

  1. **Only the audio handed to the decoder is silenced.** Replay, recording and
     the waterfall keep the raw audio (what happened is kept as it happened).
  2. While silenced, **silence of the same length** is handed over. Dropping
     audio would shift the decoder's clock (elapsed seconds) against the store,
     and a replay would sound the wrong place (requirement FR-E.10).
  3. It stays silenced until **the rig is expected to finish** (`KeyedUntil`)
     plus a margin (`TX_GATE_HANG_MS`). Even when the keyer thread has failed,
     the rig may still be sending the words handed to it, so the expectation
     holds.
  4. Used on the UI thread only (from the 0.2 s feed). }

{$mode objfpc}{$H+}

interface

uses
  DeepCW.Types;

const
  { 送り終える見込みのあと、なお止める時間（ミリ秒）。無線機の鍵の遅れ・
    音声装置の遅れ・流し込みの刻み（0.2 秒）を覆う長さです（付録 BS.4）。
    **実機では測っていません。**
    How long to stay silenced after the expected end (ms): covers the rig's
    keying lag, the audio device latency and the 0.2 s feed step
    (appendix BS.4). **Not measured on a real rig.** }
  TX_GATE_HANG_MS = 700;

type
  TTxReceiveGate = class
  private
    FHangMs: QWord;
    FMuteUntil: QWord;
  public
    constructor Create(HangMs: QWord = TX_GATE_HANG_MS);
    { 鍵の様子を伝えます。`Sending` は鍵のスレッドが送っている最中か、
      `KeyedUntil` は渡し済みの語を送り終える見込みの時刻（0 なら無し）。
      Reports the keyer: `Sending` while the keyer thread is sending,
      `KeyedUntil` the expected end of the words handed over (0 for none). }
    procedure Update(Sending: Boolean; KeyedUntil, NowMs: QWord);
    { いま復号を止めるか。/ Whether decoding is silenced now. }
    function Muted(NowMs: QWord): Boolean;
  end;

{ 同じ長さの無音。/ Silence of the same length. }
function SilenceLike(const Samples: TSingleArray): TSingleArray;

implementation

constructor TTxReceiveGate.Create(HangMs: QWord);
begin
  inherited Create;
  FHangMs := HangMs;
  FMuteUntil := 0;
end;

procedure TTxReceiveGate.Update(Sending: Boolean; KeyedUntil, NowMs: QWord);
begin
  if Sending and (NowMs + FHangMs > FMuteUntil) then
    FMuteUntil := NowMs + FHangMs;
  if (KeyedUntil > 0) and (KeyedUntil + FHangMs > FMuteUntil) then
    FMuteUntil := KeyedUntil + FHangMs;
end;

function TTxReceiveGate.Muted(NowMs: QWord): Boolean;
begin
  Result := NowMs < FMuteUntil;
end;

function SilenceLike(const Samples: TSingleArray): TSingleArray;
begin
  Result := nil;
  SetLength(Result, Length(Samples));
  if Length(Result) > 0 then
    FillChar(Result[0], Length(Result) * SizeOf(Single), 0);
end;

end.
