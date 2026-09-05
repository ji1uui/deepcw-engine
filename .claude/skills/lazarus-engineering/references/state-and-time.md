
# State & Time

## State Machine Integrity
複雑なworkflowは暗黙フラグの集合ではなく状態機械として整理する。

例:
Idle → Receiving → SignalDetected → Decoding → QSO → Logging

直交状態:
- RX / TX
- Auto / Manual
- Live / Replay
- Online / Offline

状態爆発を避けるため、独立軸は分離する。

## Transition Rules
各遷移で確認:
- trigger
- precondition
- side effect
- rollback
- timeout
- cancellation
- emitted event

不正遷移を明示的に拒否する。

## Temporal Correctness
正しい値だけでなく正しい順序・時刻を保証する。

確認:
- symbol timing
- event ordering
- timestamp source
- timeout
- replay timing
- debounce
- delayed callback

## Clock Architecture
以下を混同しない。
- wall clock
- UTC
- local time
- monotonic clock
- sample clock
- external/NTP-corrected clock

duration計測にはmonotonic clockを優先する。

## FT8 / FT4
特に確認:
- UTC alignment
- system clock offset
- candidate timing
- DT
- replay clock handling

## Sleep / Resume
resume後に:
- stale timer
- negative duration
- duplicated event
- stale audio timestamp
を発生させない。

## DoD
- state transitionが説明可能
- event orderingが明示されている
- timeout/cancel pathがある
- clock sourceが適切
- replayとliveの時間意味論が一致
