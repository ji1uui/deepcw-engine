
# Data & Compatibility

## Principle
> 新バージョンが古い利用者データを壊さないことを優先する。

## Versioned Data
対象:
- settings
- QSO logs
- cache
- replay metadata
- plugin manifest
- event schema
- exported files

必要に応じschema versionを持つ。

## Migration
migrationでは:
- source version確認
- validation
- atomic write
- backup / rollback
- partial failure handling
- idempotency
を検討する。

## Corruption Tolerance
- malformed input
- truncated file
- unknown field
- unsupported future version
を安全に扱う。

## API / ABI Stability
対象:
- public Pascal interface
- plugin API
- DLL/dylib interface
- calling convention
- serialized event
- provider contract

breaking changeはversioningとmigration方針を伴う。

## Configuration Management
- default
- range
- dependency
- deprecated setting
- migration
- expert-only setting
を管理する。

設定項目を無制限に増やさず、Autoで吸収可能な複雑さはUIへ露出しない。

## Determinism
同一input + same settings + same algorithm versionで
可能な限り再現可能な結果を得る。

OS/CPU差で完全一致不能な場合は許容差を定義する。

## DoD
- schema/API影響を説明
- migration必要性を判断
- backward compatibility確認
- malformed/old dataを必要に応じて検証
