#!/usr/bin/env python3
"""Cat Tax Agent — receives a cat photo, judges it, issues a stall permit."""

import base64
import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

WORKSPACE = os.environ.get("A2H_WORKSPACE", "/workspace")
AGENT_DIR = os.environ.get("A2H_AGENT_DIR", "/opt/agent")
API_URL = os.environ["ANTHROPIC_BASE_URL"] + "/messages"
API_KEY = os.environ["ANTHROPIC_API_KEY"]

def log(msg):
    line = json.dumps({"ts": datetime.now(timezone.utc).isoformat(), "msg": msg})
    with open(f"{WORKSPACE}/progress.ndjson", "a") as f:
        f.write(line + "\n")

def write_output(text, image_url=None):
    content = [{"type": "text", "text": text}]
    if image_url:
        content.append({"type": "image", "source": {"type": "url", "url": image_url, "mime": "image/png"}})
    envelope = {
        "apiVersion": "a2h/v2",
        "status": "success",
        "messages": [{"role": "assistant", "content": content}],
    }
    with open(f"{WORKSPACE}/output.json", "w") as f:
        json.dump(envelope, f, ensure_ascii=False)

def call_claude(system_prompt, messages, max_tokens=500):
    body = {
        "model": "claude-sonnet-4-6",
        "max_tokens": max_tokens,
        "system": system_prompt,
        "messages": messages,
    }
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        API_URL,
        data=data,
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        result = json.loads(resp.read())
    return result["content"][0]["text"]


def main():
    log("Cat Tax Inspector starting...")

    # Read input.json
    with open(f"{WORKSPACE}/input.json") as f:
        input_obj = json.load(f)

    # Extract user text and image
    user_text = ""
    image_url = None
    image_mime = "image/jpeg"

    for msg in input_obj.get("messages", []):
        if msg.get("role") != "user":
            continue
        for part in msg.get("content", []):
            if part.get("type") == "text":
                user_text += part.get("text", "") + " "
            elif part.get("type") == "image":
                source = part.get("source", {})
                if source.get("type") == "url":
                    image_url = source.get("url")
                    image_mime = source.get("mime", "image/jpeg")
                elif source.get("type") == "path":
                    # Local file in workspace
                    fpath = os.path.join(WORKSPACE, source.get("path", ""))
                    if os.path.isfile(fpath):
                        image_url = f"file://{fpath}"
                        image_mime = source.get("mime", "image/jpeg")

    user_text = user_text.strip()
    log(f"user_text={user_text[:50]} has_image={image_url is not None}")

    # Load system prompt
    skill_path = os.path.join(AGENT_DIR, "SKILL.md")
    if os.path.isfile(skill_path):
        with open(skill_path) as f:
            system_prompt = f.read()
    else:
        system_prompt = "You judge cat photos. Respond in JSON."

    # Build Claude messages
    if image_url and not image_url.startswith("file://"):
        # Download image and base64 encode
        log(f"Downloading image from URL ({len(image_url)} chars)...")
        try:
            req = urllib.request.Request(image_url, headers={"User-Agent": "a2h-agent/1.0"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                img_data = resp.read()
                resp_code = resp.getcode()
            img_b64 = base64.b64encode(img_data).decode()
            log(f"Image downloaded: {len(img_data)} bytes, http={resp_code}, b64_len={len(img_b64)}")

            messages = [{
                "role": "user",
                "content": [
                    {"type": "image", "source": {"type": "base64", "media_type": image_mime, "data": img_b64}},
                    {"type": "text", "text": user_text or "请判断这张照片"},
                ],
            }]
        except Exception as e:
            log(f"Image download failed: {e}")
            write_output(f"📷 图片下载失败：{e}\n\n请重新上传一张猫片试试。")
            return
    elif image_url and image_url.startswith("file://"):
        # Local file
        fpath = image_url[7:]
        with open(fpath, "rb") as f:
            img_data = f.read()
        img_b64 = base64.b64encode(img_data).decode()
        messages = [{
            "role": "user",
            "content": [
                {"type": "image", "source": {"type": "base64", "media_type": image_mime, "data": img_b64}},
                {"type": "text", "text": user_text or "请判断这张照片"},
            ],
        }]
    else:
        # No image
        messages = [{"role": "user", "content": user_text or "没有发送图片"}]

    # Call Claude
    log("Calling Claude for cat inspection...")
    try:
        reply_text = call_claude(system_prompt, messages)
    except Exception as e:
        log(f"Claude API failed: {e}")
        write_output(f"AI 审核服务暂时不可用：{e}")
        return

    log(f"Claude reply: {reply_text[:100]}")

    # Parse verdict
    try:
        verdict_obj = json.loads(reply_text)
        verdict = verdict_obj.get("verdict", "UNKNOWN")
        comment = verdict_obj.get("comment", "审核完毕")
    except json.JSONDecodeError:
        verdict = "UNKNOWN"
        comment = reply_text

    log(f"verdict={verdict}")

    if verdict == "APPROVED":
        # Upload permit to S3 via presigned PUT URL
        upload_url = None
        upload_slots = input_obj.get("_upload", {}).get("slots", {})
        upload_url = upload_slots.get("output-1.png")

        permit_path = os.path.join(AGENT_DIR, "stall-permit.png")
        permit_download_url = None

        if upload_url and os.path.isfile(permit_path):
            log("Uploading stall permit to S3...")
            try:
                with open(permit_path, "rb") as f:
                    permit_data = f.read()
                req = urllib.request.Request(
                    upload_url,
                    data=permit_data,
                    method="PUT",
                    headers={"Content-Type": "image/png"},
                )
                urllib.request.urlopen(req, timeout=30)
                permit_download_url = upload_url
                log("Permit uploaded OK")
            except Exception as e:
                log(f"Permit upload failed: {e}")

        result_text = f"🎉 猫税审核通过！\n\n{comment}\n\n你的 A2H Market 摆摊许可证已发放，请查收附件！"
        write_output(result_text, permit_download_url)
    elif verdict == "NO_IMAGE":
        write_output("📷 没看到猫片哦！请发一张你家猫主子的照片，AI 验猫官等着审核呢～")
    else:
        write_output(f"❌ 猫税审核未通过\n\n{comment}\n\n请发一张真实的猫咪照片再试一次！")

    log("done")


if __name__ == "__main__":
    main()
