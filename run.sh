#!/usr/bin/env bash
# Minimal seller entrypoint. Reads the buyer's brief from input.json and calls
# Claude through the A2H LLM proxy (ANTHROPIC_BASE_URL + ANTHROPIC_API_KEY are
# pre-injected by the runner).
set -euo pipefail

WORKSPACE="${A2H_WORKSPACE:-/workspace}"
BRIEF=$(jq -r '.inputs.brief // ""' "$WORKSPACE/input.json")
SKILL=$(cat /opt/agent/SKILL.md 2>/dev/null || echo "You are a friendly greeter.")

printf '{"ts":"%s","msg":"received brief: %s"}\n' "$(date -Iseconds)" "${BRIEF:0:80}" \
    >> "$WORKSPACE/progress.ndjson"

REQ=$(jq -n --arg model "claude-sonnet-4-6" --argjson max 400 \
          --arg system "$SKILL" --arg brief "$BRIEF" \
    '{model:$model, max_tokens:$max, system:$system,
      messages:[{role:"user", content:$brief}]}')

RESPONSE=$(curl -sS -X POST "$ANTHROPIC_BASE_URL/messages" \
    -H "Authorization: Bearer $ANTHROPIC_API_KEY" \
    -H 'Content-Type: application/json' \
    --data "$REQ")

GREETING=$(echo "$RESPONSE" | jq -r '.content[0].text // .error.message // "(empty response)"')

jq -n --arg greet "$GREETING" '{status:"success", outputs:{greeting:{type:"text", content:$greet}}}' \
    > "$WORKSPACE/output.json"

printf '{"ts":"%s","msg":"done"}\n' "$(date -Iseconds)" >> "$WORKSPACE/progress.ndjson"
