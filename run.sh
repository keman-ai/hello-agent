#!/usr/bin/env bash
# Hello Agent — v2 envelope compatible.
# Reads user message from input.json (Agent Protocol v2 envelope),
# calls Claude through the A2H LLM proxy, writes output.json.
set -euo pipefail

WORKSPACE="${A2H_WORKSPACE:-/workspace}"

# Extract the first user message text from v2 envelope:
# { "messages": [{ "role": "user", "content": [{ "type": "text", "text": "..." }] }] }
USER_TEXT=$(jq -r '
  .messages[]
  | select(.role == "user")
  | .content[]
  | select(.type == "text")
  | .text
' "$WORKSPACE/input.json" | head -1)

SKILL=$(cat /opt/agent/SKILL.md 2>/dev/null || echo "You are a friendly greeter.")

printf '{"ts":"%s","msg":"received: %s"}\n' "$(date -Iseconds)" "${USER_TEXT:0:80}" \
    >> "$WORKSPACE/progress.ndjson"

REQ=$(jq -n --arg model "claude-sonnet-4-6" --argjson max 400 \
          --arg system "$SKILL" --arg user_text "$USER_TEXT" \
    '{model:$model, max_tokens:$max, system:$system,
      messages:[{role:"user", content:$user_text}]}')

RESPONSE=$(curl -sS -X POST "$ANTHROPIC_BASE_URL/messages" \
    -H "Authorization: Bearer $ANTHROPIC_API_KEY" \
    -H 'Content-Type: application/json' \
    --data "$REQ")

GREETING=$(echo "$RESPONSE" | jq -r '.content[0].text // .error.message // "(empty response)"')

# v2 output envelope
jq -n --arg greet "$GREETING" '{
  "apiVersion": "a2h/v2",
  "status": "success",
  "messages": [{
    "role": "assistant",
    "content": [{"type": "text", "text": $greet}]
  }]
}' > "$WORKSPACE/output.json"

printf '{"ts":"%s","msg":"done"}\n' "$(date -Iseconds)" >> "$WORKSPACE/progress.ndjson"
