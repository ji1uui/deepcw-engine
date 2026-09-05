---
description: Lazarus / Free Pascalでの調査、計画、実装、検証、レビュー、報告の共通手順。Object Pascalのリソース所有権、LCLとスレッド、テスト、git安全性、完了報告の形式を含む。Lazarus、Free Pascal、Object Pascal、LCL、TThread、.pas / .lpr / .lfm / .lpi ファイルの変更、レビュー、設計相談のときに使う。
when_to_use: コードを読む前、変更方針を立てるとき、レビューを求められたとき、作業結果を報告するとき。
allowed-tools: Bash(git status *) Bash(git diff *) Bash(git log *) Bash(fpc -i*) Bash(uname *)
---

# Lazarus Engineering

## 現在の作業状態

- 変更ファイル: !`git status --short 2>&1 || true`
- 差分規模: !`git diff --stat HEAD 2>&1 || true`
- 直近コミット: !`git log --oneline -5 2>&1 || true`
- コンパイラ: !`fpc -iV 2>&1 || true`
- 実行環境: !`uname -srm 2>&1 || true`

上の未コミット変更は利用者の作業中の内容である。破棄も上書きもしない。
`fpc -iV` が空、または実行環境が想定と異なる場合、ビルド結果を cross-platform verified と報告しない。

## Operating Model

> Inspect → Model → Plan → Implement → Verify → Review → Report

## Inspect

対象unit、caller/callee、関連型、test、build設定、類似実装を確認する。
事実・推測・提案を区別して述べる。

## Model

変更対象について最低限以下を把握する。

- responsibility
- input / output
- ownership / lifetime
- thread context
- state transitions
- failure boundary
- externally observable behavior

## Scope Control

- 要求に必要な最小変更
- 将来用途だけの抽象化禁止
- 新依存は必要性、license、platform、maintenance、security、performanceを確認

## Object Pascal

- resource ownershipは原則 try..finally
- try..exceptは回復境界で使用し、握りつぶさない
- interface公開範囲を最小化
- Integer / Int64 / NativeInt / Single / Double / signednessを確認
- thread終了前の参照先破棄を防ぐ
- FreeAndNilを機械的に使用しない

## UI / Threading

- UI threadをblockしない
- workerからLCLを直接操作しない
- 原則 TThread.Queue
- lock中のI/O、UI通知、未知callbackを避ける
- subscriber例外を障害分離する

## Testing

1. changed-unit test
2. related integration test
3. build
4. regression
5. diff review

testを通すためにassertionを弱めたりskipしたりしない。

## Git Safety

既存の未commit変更を保護する。
`reset --hard`、`clean -fd`、force push等を無断で行わない。
要求されていないcommitを行わない。

## Completion Report

- Changes
- Design / Root cause
- Verification
- UX / Behavioral impact
- Compatibility impact
- Performance impact
- Remaining risks
- Not verified

実行していない検証は **NOT VERIFIED** と明記する。

## References

必要になったときだけ読む。

- 状態遷移、イベント順序、時刻、クロック → [references/state-and-time.md](references/state-and-time.md)
- ログ出力、診断、計測、再現性 → [references/observability.md](references/observability.md)
- 機能設計、UI、自動化、AI補正、エラー提示 → [references/user-experience.md](references/user-experience.md)
- タスク定義の雛形 → [references/task-prompt-template.md](references/task-prompt-template.md)
- 製品固有仕様の置き場所 → [references/architecture-docs.md](references/architecture-docs.md), [references/quality-model.md](references/quality-model.md)
