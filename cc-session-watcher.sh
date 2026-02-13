#!/bin/bash
# Claude Codeの複数セッション同時監視対応スクリプト for WSL
# メインセッションごとにログファイルを分離し、サブエージェントのログも親セッションに統合出力する

# ================= 設定 =================
# 出力先ディレクトリ（スクリプト配置場所/logs）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"

# 監視するプロジェクトディレクトリ
SESSION_DIR="$HOME/.claude/projects"

# セッションごとの既読状態を保存するディレクトリ
STATE_DIR="$HOME/.claude/sync_state"

# タイムゾーン設定（環境変数で上書き可能）
export LOG_TZ="${LOG_TZ:-Asia/Tokyo}"

# 詳細出力モード（true: システムタグも出力する、false: フィルタで除外する）
VERBOSE="${VERBOSE:-true}"
# ========================================

mkdir -p "$LOG_DIR"
mkdir -p "$STATE_DIR"

# セッションIDの短縮表示（先頭8文字）
short_id() {
    local full_id="$1"
    echo "${full_id:0:8}"
}

# JSONLファイルからメインセッションIDを特定する
# メインセッション → 自身のファイル名（拡張子除去）
# サブエージェント → 親ディレクトリ名（= メインセッションID）
get_parent_session_id() {
    local session_file="$1"
    if [[ "$session_file" == *"/subagents/"* ]]; then
        # .../SESSION_ID/subagents/agent-xxx.jsonl → SESSION_ID
        basename "$(dirname "$(dirname "$session_file")")"
    else
        # .../SESSION_ID.jsonl → SESSION_ID
        local fname=$(basename "$session_file")
        echo "${fname%.jsonl}"
    fi
}

# UTC ISO8601タイムスタンプをLOG_TZのHH:MMに変換するシェル関数
# 例: LOG_TZ=Asia/Tokyo の場合 "2026-02-13T01:06:02.420Z" → "10:06"
utc_to_local_hhmm() {
    local utc_ts="$1"
    TZ="$LOG_TZ" date -d "$utc_ts" '+%H:%M' 2>/dev/null || echo "${utc_ts:11:5}"
}

# jqでJSONLをパースしてMarkdown形式に変換する共通関数
parse_jsonl() {
    local session_file="$1"
    local last_line="$2"
    local TODAY_START_UTC=$(date -u -d "today 00:00:00" +"%Y-%m-%dT%H:%M:%S")

    # サブエージェントの先頭userメッセージ（=親からのプロンプト）はextract_subagent_promptで
    # 別途出力するため、parse_jsonlではスキップする。先頭行の特徴: parentUuid==null かつ agentId存在
    # jqではタイムスタンプをそのまま出力し、シェル側でLOG_TZに変換する
    # 詳細出力モード: VERBOSE=true の場合フィルタ無効（全出力）、false の場合システムタグを除外
    local filter_enabled="false"
    if [ "$VERBOSE" != "true" ]; then
        filter_enabled="true"
    fi

    tail -n +$((last_line + 1)) "$session_file" | jq -r --arg today_start "$TODAY_START_UTC" --arg filter "$filter_enabled" '
        select(.type == "user" or .type == "assistant") |
        select((.timestamp // "9999") >= $today_start) |
        # サブエージェント先頭のuserメッセージ（プロンプト）をスキップ
        if (.type == "user" and has("agentId") and .parentUuid == null) then empty
        elif .type == "user" then
            (.timestamp // "") as $ts |
            if ((.message.content // .content) | type) == "string" then
                (.message.content // .content // "") as $content |
                if ($filter == "true" and ($content | test("<local-command|<command-name>|<system-reminder>|<task-notification>|<ide_opened_file>|<ide_selection>"; "i"))) then
                    empty
                else
                    "@@USER@@" + $ts + "@@END\n" + $content
                end
            elif ((.message.content // .content) | type) == "array" then
                ((.message.content // .content)[] | select(.type == "text") |
                if ($filter == "true" and (.text | test("<local-command|<command-name>|<system-reminder>|<task-notification>|<ide_opened_file>|<ide_selection>"; "i"))) then
                    empty
                else
                    "@@USER@@" + $ts + "@@END\n" + .text
                end )
            else empty end
        elif .type == "assistant" then
            if (.message.content | type) == "array" then
                (.message.content[] | select(.type == "text") |
                if (.text | test("^No response requested"; "i")) then
                    empty
                else
                    "\n**Claude**:\n" + .text
                end )
            else empty end
        else empty end
    ' 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" =~ ^@@USER@@(.*)@@END$ ]]; then
            local local_time=$(utc_to_local_hhmm "${BASH_REMATCH[1]}")
            echo ""
            echo "**User** (${local_time}):"
        else
            echo "$line"
        fi
    done
}

# サブエージェントJSONLの先頭行から親→子プロンプトを抽出する関数
# 先頭行の構造: { type:"user", agentId:"xxx", message:{role:"user", content:"プロンプト全文"}, timestamp:"...", ... }
# 出力形式: **Prompt** (agent-xxx, HH:MM): + コードブロック
extract_subagent_prompt() {
    local session_file="$1"
    local first_line
    first_line=$(head -1 "$session_file")

    # agentIdが存在するuserメッセージのみ対象
    local agent_id
    agent_id=$(printf '%s' "$first_line" | jq -r '
        select(.type == "user" and has("agentId") and .agentId != null) | .agentId
    ' 2>/dev/null) || return 0
    [ -z "$agent_id" ] && return 0

    local timestamp
    timestamp=$(printf '%s' "$first_line" | jq -r '.timestamp // ""' 2>/dev/null)

    local content
    content=$(printf '%s' "$first_line" | jq -r '
        if (.message.content | type) == "array" then
            [.message.content[] | select(.type == "text") | .text] | join("\n")
        else
            (.message.content // "")
        end
    ' 2>/dev/null)
    [ -z "$content" ] && return 0

    local local_time
    local_time=$(utc_to_local_hhmm "$timestamp")

    echo ""
    echo "**Prompt** (agent-${agent_id}, ${local_time}):"
    echo '```'
    echo "$content"
    echo '```'
}

sync_session() {
    local session_file="$1"
    local session_id=$(basename "$session_file" .jsonl)
    local state_file="${STATE_DIR}/${session_id}.state"

    # 親セッションIDを特定し、出力先ファイルを決定
    local parent_id=$(get_parent_session_id "$session_file")
    local short=$(short_id "$parent_id")
    local logname_file="${STATE_DIR}/${parent_id}.logname"
    local target_log
    if [ -f "$logname_file" ]; then
        target_log="${LOG_DIR}/$(cat "$logname_file")"
    else
        local created_ts=$(TZ="$LOG_TZ" date +"%Y%m%d_%H%M")
        local logname="${created_ts}_${short}.md"
        echo "$logname" > "$logname_file"
        target_log="${LOG_DIR}/${logname}"
    fi

    # セクションヘッダーを生成
    local section_header
    if [[ "$session_file" == *"/subagents/"* ]]; then
        local agent_name="${session_id}"
        section_header="Subagent: ${agent_name}"
    else
        section_header="Main Session"
    fi

    # このセッションの最後の行数を読み込む（ファイルがなければ0）
    local last_line=0
    if [ -f "$state_file" ]; then
        last_line=$(cat "$state_file")
    fi

    # 現在の行数を取得
    local current_lines=$(wc -l < "$session_file")

    # 新しい行がある場合のみ処理
    if [ "$current_lines" -gt "$last_line" ]; then
        # サブエージェント初回検出時: 親から渡されたプロンプトを抽出
        local prompt_content=""
        if [ "$last_line" -eq 0 ] && [[ "$session_file" == *"/subagents/"* ]]; then
            prompt_content=$(extract_subagent_prompt "$session_file")
        fi

        local new_content=$(parse_jsonl "$session_file" "$last_line")

        if [ -n "$new_content" ] || [ -n "$prompt_content" ]; then
            # サブエージェントの出力には引用符(>)を付加して区別する
            if [[ "$session_file" == *"/subagents/"* ]]; then
                prompt_content=$(echo "$prompt_content" | sed 's/^/> /')
                new_content=$(echo "$new_content" | sed 's/^/> /')
            fi

            if [ ! -s "$target_log" ]; then
                echo "# Claude Session: ${short}" > "$target_log"
                echo "" >> "$target_log"
            fi

            local timestamp=$(TZ="$LOG_TZ" date +"%Y-%m-%d %H:%M:%S")
            echo "--- ${section_header} (${timestamp}) ---" >> "$target_log"

            # プロンプトがあれば先に出力
            if [ -n "$prompt_content" ]; then
                echo "$prompt_content" >> "$target_log"
            fi

            if [ -n "$new_content" ]; then
                echo "$new_content" >> "$target_log"
            fi
            echo "" >> "$target_log"
        fi

        # このセッションの行数を個別の状態ファイルに保存
        echo "$current_lines" > "$state_file"
    fi
}

echo "Watching all active Claude sessions (per-session log files)..."
echo "Log directory: $LOG_DIR"

while true; do
    # 過去60分以内に更新されたすべてのjsonlファイルを検索してループ処理
    # メインセッション + サブエージェントの両方を対象にする
    find "$SESSION_DIR" \
        -name "*.jsonl" -type f -mmin -60 -size +1000c -print0 2>/dev/null | \
    while IFS= read -r -d '' SESSION; do
        sync_session "$SESSION"
    done

    sleep 5
done
