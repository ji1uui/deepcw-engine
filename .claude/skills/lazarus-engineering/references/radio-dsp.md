
# Radio / DSP

## Signal Contract
変更前に必要な値を確認する。
Sample rate / block size / FFT size / window / overlap / center frequency /
baud or symbol rate / filter bandwidth / AFC range / buffer length / latency budget.

## Real-time Path
Audio Capture → Ring Buffer → DSP Worker → Decoder → Result Queue → Application/UI

Audio/IQ/sample-level dataをEvent Busへ流さない。

## DSP Hot Path
- per-block heap allocation回避
- blocking I/O禁止
- UI同期禁止
- 長時間lock禁止
- NaN / Infinity / divide-by-zero / overflow防止
- silenceでも安定状態を維持

## Evidence Model
分離保持:
- Raw Observation
- Physical Confidence
- Decoder Consensus
- FEC Evidence
- Context Support

ContextでRaw/Physical結果を不可逆に上書きしない。

## Reception State Estimation
必要に応じ:
S/N / noise floor / drift / QSB / impulsive noise /
adjacent QRM / co-channel QRM / clipping / AGC instability.

Observation → State Estimation → Portfolio Selection → Decode

## Algorithm Portfolio
Normal / Robust / Low-SNR / QRM-resistant / Drift-tolerant等を
state / confidence / CPU budgetに応じて選択する。

## Golden WAV
最低:
Strong / Medium / Weak / Very Weak / QSB / Drift /
Adjacent QRM / Co-channel QRM / Impulse / Clipping / Silence / Truncated.

期待値:
- decode result
- max errors
- no-crash
- false decode
- latency where relevant

## Replay
LiveAudioSourceとWavReplaySourceを同一DSP pipelineへ入力する。

## Performance
Intel N150相当を基準に可能な範囲で:
CPU / processing time / max processing time / queue depth /
dropped samples / memory / allocation.

原則:
processing_time < audio_block_duration

## Mode Specific
CW:
tone / threshold / timing / speed / segmentation / AFC / overlap

RTTY:
Mark/Space / shift / baud / polarity / ATC / AFC / selective fading / QRM

PSK:
carrier recovery / symbol timing / phase / AFC

Olivia:
multi-tone / synchronization / interleaving / FEC / latency

FT8/FT4:
preprocess → sync → candidate → refine → demod → LLR → LDPC → CRC → unpack
