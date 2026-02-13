#!/bin/bash
# cc-session-watcher.sh の関数単体テスト

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="/tmp/test_cc_log"
SESSION_ID="test-session-00000000-0000-0000-0000-000000000000"

# テスト用にLOG_DIR/STATE_DIR/LOG_TZを上書き
export LOG_DIR="$TEST_DIR/logs"
export STATE_DIR="$TEST_DIR/state"
export LOG_TZ="Asia/Tokyo"
rm -rf "$LOG_DIR" "$STATE_DIR"
mkdir -p "$LOG_DIR" "$STATE_DIR"

# テスト用モックデータを生成
setup_mock_data() {
    local base="$TEST_DIR/$SESSION_ID"
    mkdir -p "$base/subagents"

    # メインセッションJSONL
    cat > "$TEST_DIR/$SESSION_ID.jsonl" <<'JSONL'
{"type":"user","message":{"role":"user","content":"テストユーザーメッセージ"},"timestamp":"2026-02-13T01:00:00.000Z"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"テスト応答です。"}]},"timestamp":"2026-02-13T01:01:00.000Z"}
JSONL

    # サブエージェント1: 文字列content
    cat > "$base/subagents/agent-atest01.jsonl" <<'JSONL'
{"type":"user","agentId":"atest01","parentUuid":null,"message":{"role":"user","content":"担当グループ: R1-G1\n使用するツールは Read, Glob のみ\nテスト指示です。file_pathキーを使ってJSON出力せよ。"},"timestamp":"2026-02-13T01:00:00.000Z"}
{"type":"assistant","agentId":"atest01","message":{"role":"assistant","content":[{"type":"text","text":"タスクを開始します。"}]},"timestamp":"2026-02-13T01:00:30.000Z"}
{"type":"assistant","agentId":"atest01","message":{"role":"assistant","content":[{"type":"text","text":"処理完了しました。"}]},"timestamp":"2026-02-13T01:01:00.000Z"}
JSONL

    # サブエージェント2: 配列content
    cat > "$base/subagents/agent-atest02.jsonl" <<'JSONL'
{"type":"user","agentId":"atest02","parentUuid":null,"message":{"role":"user","content":[{"type":"text","text":"配列形式のプロンプトテスト"}]},"timestamp":"2026-02-13T01:00:00.000Z"}
{"type":"assistant","agentId":"atest02","message":{"role":"assistant","content":[{"type":"text","text":"配列プロンプト受信OK。"}]},"timestamp":"2026-02-13T01:00:30.000Z"}
JSONL
}

setup_mock_data

# 関数をロード（while trueループの手前まで）
eval "$(sed -n '/^short_id()/,/^echo "Watching/{ /^echo "Watching/d; p; }' "$SCRIPT_DIR/cc-session-watcher.sh")"

# SCRIPT_DIRを再設定（extract_subagent_prompt.pyのパス解決用）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0

assert_contains() {
    local label="$1" content="$2" expected="$3"
    if echo "$content" | grep -qF "$expected"; then
        echo "  PASS: $label"
        ((PASS++))
    else
        echo "  FAIL: $label"
        echo "    expected to contain: $expected"
        echo "    actual (first 3 lines): $(echo "$content" | head -3)"
        ((FAIL++))
    fi
}

assert_not_empty() {
    local label="$1" content="$2"
    if [ -n "$content" ]; then
        echo "  PASS: $label"
        ((PASS++))
    else
        echo "  FAIL: $label (empty output)"
        ((FAIL++))
    fi
}

assert_empty() {
    local label="$1" content="$2"
    if [ -z "$content" ]; then
        echo "  PASS: $label"
        ((PASS++))
    else
        echo "  FAIL: $label (expected empty but got output)"
        ((FAIL++))
    fi
}

# ================================================
echo "=== Test 1: utc_to_local_hhmm ==="
result=$(utc_to_local_hhmm "2026-02-13T01:06:02.420Z")
assert_contains "UTC 01:06 → LOG_TZ 10:06" "$result" "10:06"

result=$(utc_to_local_hhmm "2026-02-13T15:30:00.000Z")
assert_contains "UTC 15:30 → LOG_TZ 00:30" "$result" "00:30"

# ================================================
echo ""
echo "=== Test 2: extract_subagent_prompt (文字列content) ==="
result=$(extract_subagent_prompt "$TEST_DIR/$SESSION_ID/subagents/agent-atest01.jsonl")
assert_not_empty "出力が空でない" "$result"
assert_contains "agent-IDが含まれる" "$result" "agent-atest01"
assert_contains "ローカル時刻が含まれる" "$result" "10:00"
assert_contains "Promptヘッダーがある" "$result" "**Prompt**"
assert_contains "プロンプト本文が含まれる" "$result" "担当グループ: R1-G1"
assert_contains "file_pathキー指示が含まれる" "$result" "file_pathキーを使って"

# ================================================
echo ""
echo "=== Test 3: extract_subagent_prompt (配列content) ==="
result=$(extract_subagent_prompt "$TEST_DIR/$SESSION_ID/subagents/agent-atest02.jsonl")
assert_not_empty "出力が空でない" "$result"
assert_contains "配列形式のプロンプトが抽出される" "$result" "配列形式のプロンプトテスト"

# ================================================
echo ""
echo "=== Test 4: extract_subagent_prompt (メインセッション=agentIdなし) ==="
result=$(extract_subagent_prompt "$TEST_DIR/$SESSION_ID.jsonl")
assert_empty "メインセッションでは空出力" "$result"

# ================================================
echo ""
echo "=== Test 5: parse_jsonl (Userメッセージ + タイムゾーン変換) ==="
result=$(parse_jsonl "$TEST_DIR/$SESSION_ID.jsonl" 0)
assert_not_empty "出力が空でない" "$result"
assert_contains "**User**ヘッダーがある" "$result" "**User**"
assert_contains "ローカル時刻(10:00)が含まれる" "$result" "10:00"
assert_contains "ユーザーメッセージ本文" "$result" "テストユーザーメッセージ"
assert_contains "Claude応答も出力される" "$result" "テスト応答です"

# ================================================
echo ""
echo "=== Test 6: parse_jsonl (サブエージェント) ==="
result=$(parse_jsonl "$TEST_DIR/$SESSION_ID/subagents/agent-atest01.jsonl" 0)
assert_not_empty "出力が空でない" "$result"
assert_contains "Claude応答が含まれる" "$result" "タスクを開始します"
assert_contains "2番目のClaude応答も含まれる" "$result" "処理完了しました"

# ================================================
echo ""
echo "=== Test 7: sync_session (統合テスト) ==="
sync_session "$TEST_DIR/$SESSION_ID.jsonl"
sync_session "$TEST_DIR/$SESSION_ID/subagents/agent-atest01.jsonl"
sync_session "$TEST_DIR/$SESSION_ID/subagents/agent-atest02.jsonl"

log_file=$(ls "$LOG_DIR"/*.md 2>/dev/null | head -1)
if [ -n "$log_file" ]; then
    echo "  PASS: ログファイル生成: $(basename "$log_file")"
    ((PASS++))

    log_content=$(cat "$log_file")
    assert_contains "Main Sessionセクション" "$log_content" "Main Session"
    assert_contains "Subagentセクション" "$log_content" "Subagent: agent-atest01"
    assert_contains "Promptブロック" "$log_content" "**Prompt** (agent-atest01"
    assert_contains "プロンプト本文" "$log_content" "担当グループ: R1-G1"
    assert_contains "Claude応答" "$log_content" "タスクを開始します"
    assert_contains "配列promptのSubagent" "$log_content" "Subagent: agent-atest02"
    assert_contains "配列promptの内容" "$log_content" "配列形式のプロンプトテスト"
    assert_contains "サブエージェント引用符(Prompt)" "$log_content" "> **Prompt**"
    assert_contains "サブエージェント引用符(Claude)" "$log_content" "> **Claude**"

    echo ""
    echo "--- 生成されたログ ---"
    cat "$log_file"
    echo "--- ここまで ---"
else
    echo "  FAIL: ログファイルが生成されなかった"
    ((FAIL++))
fi

echo ""
echo "==============================="
echo "結果: PASS=$PASS, FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi
