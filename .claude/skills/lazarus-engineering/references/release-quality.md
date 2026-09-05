
# Release Quality

## Release Pipeline
Build
→ Unit Test
→ Integration Test
→ Golden WAV
→ Replay
→ Performance
→ Cross-platform
→ UX Scenario
→ Compatibility
→ Security/Privacy checks
→ Packaging
→ Smoke Test
→ Release

## Regression Taxonomy
失敗を分類する。
- functional regression
- decode regression
- false-decode regression
- latency regression
- CPU regression
- memory regression
- UX regression
- accessibility regression
- compatibility regression
- packaging regression

## Performance Budgeting
機能ごとにbudgetを意識する。
- Audio
- DSP
- Decoder
- UI
- Logging
- Plugin

平均だけでなくworst-case / p95 / p99を可能なら確認。

## Graceful Degradation
resource不足時に中核機能を守る。

例:
visual refresh低下
→ secondary analysis停止
→ optional decoder停止
→ advanced visualization停止

Audio capture / primary decode / log integrityを優先する。

## Release Matrix
例:
- Windows x64: Build / Test / Golden / Package / Smoke
- macOS ARM64: Build / Test / Golden / Package / Smoke
- macOS x64: required or compatibility tier
- Windows ARM64: future / supported tier

supported / experimental / not-testedを明確化する。

## Packaging Validation
インストール後の実環境で:
- app起動
- audio permission
- native library load
- config creation
- replay
- live audio
- clean shutdown
を確認する。

## Release Evidence
release時に:
- commit/build identifier
- compiler version
- dependency versions
- test summary
- Golden WAV summary
- known limitations
を残す。

## DoD
「build成功」だけでrelease-readyとしない。
未検証platformやknown regressionを明示する。
