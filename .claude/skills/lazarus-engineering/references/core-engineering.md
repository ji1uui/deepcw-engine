
# Core Engineering

## Operating Model
> Inspect → Model → Plan → Implement → Verify → Review → Report

## Inspect
対象unit、caller/callee、関連型、test、build設定、類似実装を確認する。
事実・推測・提案を区別する。

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
reset --hard、clean -fd、force push等を無断で行わない。
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
