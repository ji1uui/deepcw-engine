---
description: リリース判定を品質ゲートとして実行する。Release Pipeline、Regression Taxonomy、Performance Budgeting、Graceful Degradation、Release Matrix、Packaging Validation、Release Evidence。
disable-model-invocation: true
allowed-tools: Bash(git status *) Bash(git log *) Bash(git describe *) Bash(git tag *)
---

# Release Quality

## リポジトリの現状

- 作業ツリー: !`git status --short 2>&1 || true`
- 現在の識別子: !`git describe --tags --always --dirty 2>&1 || true`
- 前回タグからの変更: !`git log --oneline -30 2>&1 || true`

作業ツリーがdirtyな状態をrelease-readyと判定しない。

## Release Pipeline

Build → Unit Test → Integration Test → Golden WAV → Replay → Performance →
Cross-platform → UX Scenario → Compatibility → Security/Privacy checks →
Packaging → Smoke Test → Release

各段階について、実行済み / 未実行 / 失敗 を明示する。
未実行を「問題なし」と書かない。

## Regression Taxonomy

functional / decode / false-decode / latency / CPU / memory /
UX / accessibility / compatibility / packaging

## Performance Budgeting

Audio / DSP / Decoder / UI / Logging / Plugin ごとにbudgetを意識する。
平均だけでなくworst-case / p95 / p99を可能なら確認。

## Graceful Degradation

resource不足時の縮退順序:
visual refresh低下 → secondary analysis停止 → optional decoder停止 → advanced visualization停止

Audio capture / primary decode / log integrityを最後まで守る。

## Release Matrix

supported / experimental / not-tested を明確化する。

例:
- Windows x64: Build / Test / Golden / Package / Smoke
- macOS ARM64: Build / Test / Golden / Package / Smoke
- macOS x64: required or compatibility tier
- Windows ARM64: future / supported tier

## Packaging Validation

インストール後の実環境で:
app起動 / audio permission / native library load / config creation /
replay / live audio / clean shutdown

## Release Evidence

commit・build identifier / compiler version / dependency versions /
test summary / Golden WAV summary / known limitations を残す。

## DoD

「build成功」だけでrelease-readyとしない。
未検証platformとknown regressionを明示する。
