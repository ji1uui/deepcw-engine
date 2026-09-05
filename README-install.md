# 導入手順

## 構成

```
CLAUDE.md                                  ← リポジトリルートに置く（常時ロード）
.claude/skills/
├── lazarus-engineering/SKILL.md           ← 全変更で使う中核。! でgit状態を注入
│   └── references/                        ← 必要時のみ読まれる参照文書
├── lazarus-radio-dsp/SKILL.md             ← paths でDSP系ファイル限定
├── lazarus-cross-platform/SKILL.md        ← paths でビルド・OS依存ファイル限定
├── lazarus-data-compat/SKILL.md           ← paths でschema・設定・plugin限定
├── lazarus-security-privacy/SKILL.md      ← paths で送信系・認証系限定
└── lazarus-release/SKILL.md               ← 手動呼び出しのみ（/lazarus-release）
```

## 設置

```bash
cd /path/to/your/repo
unzip ~/Downloads/lazarus-claude-code-bundle.zip -d .
```

`.claude` は隠しディレクトリなので `ls -a` で確認する。

既に `CLAUDE.md` がある場合は上書きせず、内容を突き合わせてから統合する。

## 確認

```bash
claude plugin validate .claude/skills   # frontmatterの構文チェック（v2.1.233以降）
claude                                   # セッション開始
```

セッション内で `/skills` を実行し、6つが並ぶことを確認する。
`/lazarus-engineering` を打つと、冒頭にgit statusとfpcのバージョンが埋まった状態で読み込まれる。

## 調整が必要な箇所

各 `paths` のグロブは実際のディレクトリ構成を見ていない推測値。
`/skills` で発動しない、または無関係なファイルで発動する場合は各SKILL.mdの `paths` を直す。
変更はセッション中に自動検知されるので再起動不要。
