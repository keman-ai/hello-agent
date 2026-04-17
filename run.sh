#!/usr/bin/env bash
# Cat Tax Agent — v2 envelope, supports text + image input, text + image output.
# 1. Reads user message (text + optional image) from v2 envelope
# 2. Sends to Claude with vision to judge if it's a real cat
# 3. If approved, copies stall-permit.png to output
set -euo pipefail

WORKSPACE="${A2H_WORKSPACE:-/workspace}"
AGENT_DIR="${A2H_AGENT_DIR:-/opt/agent}"

printf '{"ts":"%s","msg":"Cat Tax Inspector starting..."}\n' "$(date -Iseconds)" \
    >> "$WORKSPACE/progress.ndjson"

# ── Extract user text ────────────────────────────────────────────
USER_TEXT=$(jq -r '
  [.messages[] | select(.role == "user") | .content[] | select(.type == "text") | .text]
  | join(" ")
' "$WORKSPACE/input.json")

# ── Extract user image (if any) ─────────────────────────────────
# Support both source.type="url" (presigned S3) and source.type="path" (local file)
IMAGE_URL=$(jq -r '
  [.messages[] | select(.role == "user") | .content[] | select(.type == "image") | .source.url]
  | first // empty
' "$WORKSPACE/input.json")

IMAGE_PATH=$(jq -r '
  [.messages[] | select(.role == "user") | .content[] | select(.type == "image") | .source.path]
  | first // empty
' "$WORKSPACE/input.json")

IMAGE_MIME=$(jq -r '
  [.messages[] | select(.role == "user") | .content[] | select(.type == "image") | .source.mime]
  | first // "image/jpeg"
' "$WORKSPACE/input.json")

HAS_IMAGE=false
IMG_B64=""
IMG_MIME="${IMAGE_MIME:-image/jpeg}"

if [ -n "$IMAGE_URL" ] && [ "$IMAGE_URL" != "null" ]; then
    # Download from presigned URL
    TMP_IMG="$WORKSPACE/_input_image.jpg"
    if curl -sS -o "$TMP_IMG" "$IMAGE_URL" && [ -s "$TMP_IMG" ]; then
        HAS_IMAGE=true
        IMG_B64=$(base64 -w0 "$TMP_IMG" 2>/dev/null || base64 "$TMP_IMG")
    fi
elif [ -n "$IMAGE_PATH" ] && [ -f "$WORKSPACE/$IMAGE_PATH" ]; then
    HAS_IMAGE=true
    IMG_B64=$(base64 -w0 "$WORKSPACE/$IMAGE_PATH" 2>/dev/null || base64 "$WORKSPACE/$IMAGE_PATH")
    IMG_MIME=$(file -b --mime-type "$WORKSPACE/$IMAGE_PATH" 2>/dev/null || echo "$IMG_MIME")
fi

printf '{"ts":"%s","msg":"has_image=%s text=%s"}\n' "$(date -Iseconds)" "$HAS_IMAGE" "${USER_TEXT:0:50}" \
    >> "$WORKSPACE/progress.ndjson"

# ── Load system prompt ───────────────────────────────────────────
SKILL=$(cat "$AGENT_DIR/SKILL.md" 2>/dev/null || echo "You judge cat photos. Respond in JSON.")

# ── Build Claude API request ─────────────────────────────────────
if [ "$HAS_IMAGE" = "true" ]; then
    # Vision request: image + text
    REQ=$(jq -n \
        --arg model "claude-sonnet-4-6" \
        --argjson max 500 \
        --arg system "$SKILL" \
        --arg text "${USER_TEXT:-请判断这张照片}" \
        --arg img_b64 "$IMG_B64" \
        --arg img_mime "$IMG_MIME" \
    '{
        model: $model,
        max_tokens: $max,
        system: $system,
        messages: [{
            role: "user",
            content: [
                {type: "image", source: {type: "base64", media_type: $img_mime, data: $img_b64}},
                {type: "text", text: $text}
            ]
        }]
    }')
else
    # Text-only request (no image provided)
    REQ=$(jq -n \
        --arg model "claude-sonnet-4-6" \
        --argjson max 500 \
        --arg system "$SKILL" \
        --arg text "${USER_TEXT:-没有发送图片}" \
    '{
        model: $model,
        max_tokens: $max,
        system: $system,
        messages: [{role: "user", content: $text}]
    }')
fi

printf '{"ts":"%s","msg":"Calling Claude for cat inspection..."}\n' "$(date -Iseconds)" \
    >> "$WORKSPACE/progress.ndjson"

# ── Call Claude ──────────────────────────────────────────────────
RESPONSE=$(curl -sS -X POST "$ANTHROPIC_BASE_URL/messages" \
    -H "Authorization: Bearer $ANTHROPIC_API_KEY" \
    -H 'Content-Type: application/json' \
    --data "$REQ")

REPLY_TEXT=$(echo "$RESPONSE" | jq -r '.content[0].text // .error.message // "(empty)"')
VERDICT=$(echo "$REPLY_TEXT" | jq -r '.verdict // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")

printf '{"ts":"%s","msg":"verdict=%s"}\n' "$(date -Iseconds)" "$VERDICT" \
    >> "$WORKSPACE/progress.ndjson"

# ── Build output ─────────────────────────────────────────────────
COMMENT=$(echo "$REPLY_TEXT" | jq -r '.comment // "审核完毕"' 2>/dev/null || echo "审核完毕")

if [ "$VERDICT" = "APPROVED" ]; then
    # Copy permit to workspace outputs
    mkdir -p "$WORKSPACE/outputs"
    cp "$AGENT_DIR/stall-permit.png" "$WORKSPACE/outputs/stall-permit.png"

    RESULT_TEXT="🎉 猫税审核通过！\n\n$COMMENT\n\n你的 A2H Market 摆摊许可证已发放，请查收附件！"

    jq -n --arg text "$(printf "$RESULT_TEXT")" '{
        "apiVersion": "a2h/v2",
        "status": "success",
        "messages": [{
            "role": "assistant",
            "content": [
                {"type": "text", "text": $text},
                {"type": "image", "source": {"type": "path", "path": "outputs/stall-permit.png", "mime": "image/png"}}
            ]
        }]
    }' > "$WORKSPACE/output.json"
else
    if [ "$VERDICT" = "NO_IMAGE" ]; then
        RESULT_TEXT="📷 没看到猫片哦！请发一张你家猫主子的照片，AI 验猫官等着审核呢～"
    else
        RESULT_TEXT="❌ 猫税审核未通过\n\n$COMMENT\n\n请发一张真实的猫咪照片再试一次！"
    fi

    jq -n --arg text "$(printf "$RESULT_TEXT")" '{
        "apiVersion": "a2h/v2",
        "status": "success",
        "messages": [{
            "role": "assistant",
            "content": [
                {"type": "text", "text": $text}
            ]
        }]
    }' > "$WORKSPACE/output.json"
fi

printf '{"ts":"%s","msg":"done"}\n' "$(date -Iseconds)" >> "$WORKSPACE/progress.ndjson"
