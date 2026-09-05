---
description: 認証情報の取り扱い、コールサインや位置情報などのプライバシー、telemetry、Plugin信頼境界、依存関係とサプライチェーン、Rig/CAT制御の送信安全性。Receiveはfail-soft、Transmitはfail-safe。
when_to_use: PTT、CAT制御、hamlib、送信系、APIキー、トークン、クラウド連携、telemetry、新規依存ライブラリの追加、plugin読み込みに触れるとき。
paths:
  - "**/*rig*"
  - "**/*cat*.pas"
  - "**/*hamlib*"
  - "**/*ptt*"
  - "**/*transmit*"
  - "**/*telemetry*"
  - "**/*auth*"
  - "**/*credential*"
  - "**/*secret*"
  - "**/*plugin*"
user-invocable: true
---

# Security & Privacy

## Secrets

API key / password / token / private credential を
source、log、test fixtureへ埋め込まない。

## Privacy-sensitive Data

callsign / locator / precise location / contact history /
cloud account / network credential / telemetry。

収集・保存・送信は最小限にする。

## Telemetry

導入する場合、opt-in・opt-out / purpose limitation / data minimization /
retention / anonymization where meaningful を定義する。

## Plugin Trust

pluginを信頼しすぎない。built-in trusted / signed third-party / untrusted external を区別する。
例外隔離、timeout、subprocess化を検討する。

## Dependency Governance

新依存では license / maintenance / CVE・security history /
supported OS・arch / update policy / provenance を確認する。

## Supply Chain

releaseでは必要に応じ artifact signing / checksum / dependency integrity /
reproducible build metadata / provenance を管理する。

## Rig / CAT Safety

送信系は高リスク境界として扱う。

確認: unintended PTT / stale command / frequency・mode・split変更 /
retry duplication / reconnect時の古い状態

原則: Receive = fail-soft、Transmit = fail-safe

## DoD

- secret漏えいなし
- privacy impact確認
- plugin/dependency trust boundary確認
- TX変更時はfail-safeを検証
