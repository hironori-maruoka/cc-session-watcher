# cc-session-watcher

Claude Codeのセッションログ（JSONL）をリアルタイムで人間可読なMarkdownに変換する監視スクリプト。

## 機能

- `~/.claude/projects/` 配下のJSONLセッションファイルを**5秒間隔**でポーリング監視
- メインセッションとサブエージェントのログを**親セッション単位で1つのMarkdownファイル**に統合出力
- サブエージェントへの親プロンプト（delegateブロック）を初回検出時に自動抽出・記録
- サブエージェント出力は `>` 引用符（Markdown blockquote）で視覚的に区別
- **増分同期**: 前回処理済みの行はスキップし、新規行のみを追記

## 使い方

```bash
# 基本実行（タイムゾーン: Asia/Tokyo）
./cc-session-watcher.sh

# タイムゾーン指定
LOG_TZ=America/New_York ./cc-session-watcher.sh

# システムタグを除外して実行（デフォルトはVERBOSE=trueで全メッセージ出力）
VERBOSE=false ./cc-session-watcher.sh

# バックグラウンド実行
./cc-session-watcher.sh &
```

フォアグラウンドで常駐するため、バックグラウンド実行または別ターミナルでの起動を推奨。`Ctrl+C` で停止する。

## 監視対象の条件

以下のすべてを満たすJSONLファイルが処理対象となる:

| 条件 | 値 | 根拠 |
|------|---|------|
| 配置場所 | `~/.claude/projects/` 配下（再帰検索） | Claude Codeのセッション保存先 |
| ファイル更新 | **過去60分以内**に更新されたファイル | 古いセッションを除外 |
| ファイルサイズ | **1000バイト超** | 空・極小ファイルを除外 |
| メッセージ日時 | **当日UTC 00:00以降**のメッセージのみ抽出 | 過去日のメッセージを除外 |

## 出力仕様

### ログファイル

- 出力先: `cc-session-watcher/logs/`（自動作成）
- ファイル名: `YYYYMMDD_HHMM_セッションID先頭8文字.md`
  - 例: `20260213_1430_5be84aff.md`
- 同一親セッションのメイン・サブエージェントログは1ファイルに統合

### 出力フォーマット

```markdown
# Claude Session: 5be84aff

--- Main Session (2026-02-13 14:30:00) ---

**User** (14:30):
ユーザーのメッセージ

**Claude**:
Claudeの応答

--- Subagent: agent-a766d97 (2026-02-13 14:31:00) ---
>
> **Prompt** (agent-a766d97, 14:31):
> ```
> 親から渡されたプロンプト全文
> ```
>
> **Claude**:
> サブエージェントの応答
```

### フィルタリング

以下のメッセージは出力から除外される（`VERBOSE=false` の場合のみ。デフォルト `VERBOSE=true` では全メッセージを出力する）:

- `<system-reminder>`, `<local-command>`, `<command-name>`, `<task-notification>`, `<ide_opened_file>`, `<ide_selection>` を含むuserメッセージ（Claude Code内部のシステムメッセージ）

以下は詳細出力モードに関係なく常に除外される:

- `No response requested` で始まるassistantメッセージ
- サブエージェントの先頭userメッセージ（`**Prompt**` ブロックとして別途出力されるため重複排除）

## ファイル構成

| ファイル | 説明 |
|---------|------|
| `cc-session-watcher.sh` | メインスクリプト（監視ループ・JSONL→Markdown変換・プロンプト抽出） |
| `test_cc_session_watcher.sh` | テストスクリプト（モックデータ生成・29項目のアサーション） |

## 設定（環境変数）

すべて環境変数で上書き可能。未設定時はデフォルト値が使われる。

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `VERBOSE` | `true` | 詳細出力モード。`true`: システムタグも含めて全メッセージを出力、`false`: システムタグを除外 |
| `LOG_TZ` | `Asia/Tokyo` | タイムスタンプ表示のタイムゾーン（IANA形式） |
| `LOG_DIR` | `(スクリプト配置場所)/logs` | ログ出力先ディレクトリ |
| `STATE_DIR` | `~/.claude/sync_state` | 同期状態ファイルの保存先 |

## 状態管理

本スクリプトは増分同期方式で動作する。`STATE_DIR` に以下のファイルを保存し、前回処理済みの行をスキップする:

| ファイル | 内容 |
|---------|------|
| `{session_id}.state` | 処理済みの行数（次回はこの行以降のみ処理） |
| `{parent_session_id}.logname` | 出力先ログファイル名（親セッション単位で共有） |

### ログが出力されない場合

1. **状態ファイルが残っている**: 前回実行で全行が処理済みとして記録されている。再取得するには状態をリセットする:
   ```bash
   rm ~/.claude/sync_state/*.state ~/.claude/sync_state/*.logname
   ```
2. **セッションが古い**: 60分以上更新されていないJSONLファイルは対象外
3. **ファイルが小さい**: 1000バイト以下のJSONLファイルは対象外
4. **前日のメッセージ**: 当日UTC 00:00以前のメッセージは抽出されない

## テスト

```bash
bash cc-session-watcher/test_cc_session_watcher.sh
```

テストスクリプトはモックJSONLデータを自動生成し、関数単体テスト（時刻変換・プロンプト抽出・JSONL解析）と統合テスト（sync_session end-to-end）の計29項目を実行する。

## 前提環境

**実行環境**: WSL / Linux（DevContainer含む）。macOSのBSD dateでは `-d` オプションの動作が異なるため非対応。

**必須ソフトウェア**:

| 依存 | 用途 |
|------|------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (CLI) | セッションJSONLの生成元。`~/.claude/projects/` にセッションデータを保存する |
| bash 4+ | 正規表現マッチ（`=~`）、部分文字列展開（`${var:0:8}`） |
| jq | JSONLのパース・フィルタリング・プロンプト抽出 |
| GNU date | `-d` オプションによるタイムスタンプ変換 |
| GNU find | `-print0` オプション |
