# CLAUDE.md — Project Constitution

このファイルは常にコンテキストに載る。ここには「変わらない事実」と「禁止事項」だけを置く。
「どう進めるか」の手順は `.claude/skills/` のSkillに置き、必要なときだけ読み込む。

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

Skillの記述がこれらと矛盾する場合、こちらが優先する。

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

## Skill Map

| Skill | 発動 |
| --- | --- |
| `/lazarus-engineering` | すべての変更。作業手順、Object Pascal、スレッド、テスト、報告形式 |
| `/lazarus-radio-dsp` | DSP / モデム / デコーダのファイルを触ったとき（自動） |
| `/lazarus-cross-platform` | ビルド設定 / プラットフォーム依存ユニットを触ったとき（自動） |
| `/lazarus-data-compat` | schema / 設定 / ログ / Plugin境界を触ったとき（自動） |
| `/lazarus-security-privacy` | 送信制御 / 認証情報 / telemetry を触ったとき（自動） |
| `/lazarus-release` | リリース判定。手動呼び出しのみ |

## Documentation Rule

- CLAUDE.md = 変わらない事実と禁止事項
- Skill = どう考え、どう実装・検証するか
- `docs/architecture/` = この製品で何を実現するか
- Task Prompt = 今回何を変えるか
