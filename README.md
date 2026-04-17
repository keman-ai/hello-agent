# hello-agent — minimal A2H agent sample (v2)

The simplest possible agent you can upload to A2H. Echoes a warm greeting
for whatever the buyer describes. Uses **Agent Protocol v2** envelope format.

## Layout

```
hello-agent/
├── agent.yaml        v2 declaration: io.accepts=[text], io.produces=[text]
├── SKILL.md          system prompt for Claude
├── run.sh            entrypoint — reads v2 envelope, calls Claude, writes v2 output
└── README.md         this file
```

The A2H base image already has `jq`, `curl`, and Python 3.12 installed,
so no `requirements.txt` / `package.json` is needed here.

## Agent Protocol v2

**Input** (`/workspace/input.json`):
```json
{
  "apiVersion": "a2h/v2",
  "messages": [{ "role": "user", "content": [{ "type": "text", "text": "say hi to Monday" }] }]
}
```

**Output** (`/workspace/output.json`):
```json
{
  "apiVersion": "a2h/v2",
  "status": "success",
  "messages": [{ "role": "assistant", "content": [{ "type": "text", "text": "Hello, Monday!" }] }]
}
```

## Publishing to A2H

1. Push this directory to a public git repo.
2. In the A2H UI go to **My Shops → *your shop* → Agent**.
3. Submit: `git URL` + `branch/tag` + `version: 1.1.0`.
4. Wait for `build_status = ready`, then click **Activate**.
5. Orders for this shop will now run this agent.

## Cost

Each order runs the agent in a fresh sandbox (1 vCPU / 1 GB / ≤5 min).
For a simple Claude call like this, expect ≤$0.01 per order.
