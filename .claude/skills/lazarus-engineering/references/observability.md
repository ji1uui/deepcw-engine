
# Observability & Diagnostics

## Goal
> 「失敗した」ではなく、「どこで、なぜ、どの状態で失敗したか」を再現可能にする。

## Log Categories
- APP
- AUDIO
- DSP
- MODEM
- DECODER
- STATE
- QSO
- PLUGIN
- NETWORK
- PERF
- ERROR

## High-value Events
- state transition
- decoder selection
- AFC adjustment
- dropped samples
- buffer overrun
- device disconnect
- plugin failure
- sync failure
- confidence transition
- benchmark summary

sample単位の大量ログは避ける。

## Structured Diagnostics
必要に応じ:
- timestamp
- thread
- mode
- build version
- platform
- algorithm version
- relevant parameters

## User vs Developer Logs
利用者向け:
- actionable
- understandable
- privacy-safe

開発者向け:
- detailed
- reproducible
- correlation可能

## Diagnostic Bundle
必要なら以下をまとめてexportできる設計を検討する。
- sanitized logs
- config snapshot
- platform info
- algorithm versions
- replay reference
- crash/exception context

秘密情報や個人情報を含めない。

## Performance Observability
可能なら:
- avg / max / p95 / p99 processing time
- queue depth
- dropped samples
- allocation pressure
- CPU load

## DoD
- 新しいfailure modeが診断可能
- log floodを起こさない
- sensitive dataを出さない
- runtime overheadが許容範囲
