
# User Experience / Human-in-the-loop

## North Star
> 利用者が信号を見つけ、理解し、判断し、交信し、記録し、学び、試行できること。

## Experience Outcomes
- Communicate
- Discover
- Collect
- Compete
- Learn
- Experiment

各機能を少なくとも1つのOutcomeへ結びつける。

## Technical + UX Acceptance Criteria
TechnicalだけでなくUX条件も書く。

例:
- Auto補正が識別できる
- Rawに戻れる
- low-confidenceを断定表示しない
- UIがfreezeしない

## System Status Visibility
必要に応じ:
receiving / transmitting / mode / frequency / AFC / signal /
decoder / confidence / Auto-Manual / replay-live / sync status

progressive disclosureを使い、情報過多を避ける。

## Confidence UX
- 色だけに依存しない
- Physical ConfidenceとContext Supportを混同しない
- 推論結果をRaw decodeとして見せない
- 必要時に理由を説明できる

## Human Control
必要に応じ:
- Auto / Manual
- Reject
- Undo
- Restore Raw
- Don't suggest again
- parameter override

## Error Recovery
エラー時に可能な範囲で:
1. 何が起きたか
2. 何に影響するか
3. データは保全されているか
4. 次に何ができるか

## Latency is UX
確認:
- input-to-visual
- signal-to-decode
- click-to-response
- mode-switch
- startup
- save/sync completion

## Cognitive Load
- Defaultはprimary task優先
- Advancedは段階的開示
- mode間で共通操作を一貫
- Expert制御を残す

## Accessibility
- color-only禁止
- contrast / font size
- keyboard
- focus order
- scaling
- accessible status

## Failure Isolation as Task Continuity
- QSL障害でもQSO継続
- plugin障害でも本体継続
- network障害でもlocal log継続
- decoder失敗でもRaw/Replay/別decoder利用可能

## Explainability
必要時に:
- なぜこの候補か
- なぜこのdecoderか
- なぜContext補正されたか
を説明可能にする。

## Reversibility
Undo / Restore / Replay / Rawを重要品質として扱う。

## UX DoD
- Experience Outcomeが説明可能
- primary workflow成立
- system status可視
- Human Control適切
- recovery pathあり
- accessibility退行なし
- UX acceptance criteria確認
