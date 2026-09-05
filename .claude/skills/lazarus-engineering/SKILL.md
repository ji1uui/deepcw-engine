---
name: lazarus-engineering
description: Lazarus / Free Pascal（Object Pascal）で書かれた無線通信アプリケーションの設計、実装、レビュー、検証、リリース判定を行うためのSkill。CW/RTTY/PSK/Olivia/FT8等のDSP・デコーダ、Windows/macOSクロスプラットフォーム対応、スレッド設計、状態遷移と時刻、ログ・設定のスキーマ互換性、Plugin/ABI、セキュリティとプライバシー、可観測性、UX、品質ゲートを扱う。ユーザーがLazarus、Free Pascal、Object Pascal、LCL、TThread、無線デコーダ、モデム、QSOログ、コンテストロガー、ハムログ、あるいはこれらのコードのレビューや設計相談に言及したら、「Skillを使って」と明示されなくても必ず使用する。
---

# Lazarus Radio Application Engineering

## Mission

このアプリケーションの最上位目的は「復調器を実装すること」ではない。
利用者が信号を見つけ、状況を理解し、適切に判断し、交信を成立させ、
記録し、振り返り、学び、試行できることを支援する。

技術的最適化は、利用者価値、正しさ、安全性、可逆性、互換性を損なってはならない。

## Target

- Language: Object Pascal
- IDE / Compiler: Lazarus 4.x / Free Pascal
- Platforms: Windows / macOS
- CPU architectures: x86_64 / ARM64 where supported
- Baseline PC: Intel N150相当
- Architecture: UI / Application / Modem / DSP / Audio-IQ
- Cross-cutting foundations: X Computing / Y Intelligent Processing / Z Quality

## Permanent Rules

これらは下位のreference文書より優先する。

- 実コード、caller/callee、test、build設定、architecture docsを確認してから変更する。
- 存在しないAPI、型、unit、設定、仕様を推測しない。
- 要求に必要な最小範囲を変更する。
- 無関係なrefactor、整形、改名を混在させない。
- Audio/IQなどの高頻度データをEvent Busへ流さない。
- DSP hot pathにblocking I/O、UI同期、不要なheap allocation、長時間lockを追加しない。
- Worker threadからLCL UIを直接操作しない。
- Raw Observation / Physical Confidence / Decoder Consensus / FEC Evidence / Context Supportを混同しない。
- Auto/AI/Context補正は利用者がReject / Undo / Restore Rawできる設計を優先する。
- Receiveはfail-soft、Transmitはfail-safeを基本方針とする。
- OS依存性は散在させず、Platform Boundaryへ限定する。
- データ形式・Plugin API・外部ABIの互換性を意識する。
- 実行していない検証を成功と報告しない。
- 現在の実行OSだけで成功しても cross-platform verified と報告しない。

## Operating Model

> Inspect → Model → Plan → Implement → Verify → Review → Report

作業の性質に応じて、以下のreferenceを読んでから進める。
常に `references/core-engineering.md` を最初に読むこと。それ以外は該当するものだけを読む。

| 状況 | 読むreference |
| --- | --- |
| すべての変更（必読） | `references/core-engineering.md` |
| OS差異、ビルド、パス、フォント、署名、ARM64 | `references/cross-platform.md` |
| 復調、フィルタ、AGC、同期、FEC、デコーダ、モデム | `references/radio-dsp.md` |
| 機能設計、UI、自動化、AI補正、エラー提示 | `references/user-experience.md` |
| 状態遷移、イベント順序、時刻、クロック、同期 | `references/state-and-time.md` |
| ログ、設定、キャッシュ、schema、Plugin API、ABI | `references/data-and-compatibility.md` |
| ログ出力、診断、計測、再現、トラブルシュート | `references/observability.md` |
| 認証情報、位置情報、送信制御、外部ライブラリ、telemetry | `references/security-and-privacy.md` |
| リリース判定、パッケージング、Smoke Test | `references/release-quality.md` |
| タスク定義の雛形が必要なとき | `references/task-prompt-template.md` |
| 製品固有仕様をどこに書くかの判断 | `references/architecture-docs.md`, `references/quality-model.md` |

## Quality Gates

変更内容に応じ、以下を組み合わせて検証する。

Build / Unit Test / Integration Test / Golden WAV / Replay / Performance /
Cross-platform / UX Scenario / Compatibility / Security / Privacy / Packaging / Smoke Test

未実施項目は **NOT VERIFIED** と明記する。実行していない検証を成功と報告しない。

## Completion Report

作業の最後に、以下の見出しで報告する。

- Changes
- Design / Root cause
- Verification
- UX / Behavioral impact
- Compatibility impact
- Performance impact
- Remaining risks
- Not verified

## Documentation Rule

- Skill = どう考え、どう実装・検証するか
- Architecture Docs = この製品で何を実現するか
- Task Prompt = 今回何を変えるか

製品固有で変化する仕様はSkillに書かず、プロジェクト側の `docs/architecture/` に置く。
