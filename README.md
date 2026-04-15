# hello-agent — minimal A2H agent sample

The simplest possible agent you can upload to A2H. Echoes a warm greeting
for whatever the buyer describes. Useful as:

* a **smoke test** for the build pipeline (does CodeBuild + e2b work end-to-end?),
* a **template** when you want to bootstrap your own agent.

## Layout

```
hello-agent/
├── agent.yaml        declaring: 1 text input (brief) → 1 text output (greeting)
├── SKILL.md          the system prompt Claude Code runs with
├── run.sh            shell entrypoint — reads input.json, drives claude-code, writes output.json
└── README.md         this file
```

The A2H base image already has `jq`, `claude-code`, and Python 3.12 installed,
so no `requirements.txt` / `package.json` is needed here.

## Publishing to A2H

1. Push this directory to a public git repo (or a private repo with a PAT in
   A2H dashboard).
2. In the A2H UI go to **My Shops → *your shop* → Agent**.
3. Submit: `git URL` + `branch/tag` + `version: 0.1.0`.
4. Wait for `build_status = ready`, then click **Activate**.
5. Orders for this shop will now run this agent.

## Iterating

- Any change to the prompt → bump `metadata.version` (semver) → submit again.
- A2H keeps all versions; you can rollback by activating an older one.

## Cost

Each order runs the agent in a fresh e2b sandbox (1 vCPU / 1 GB / ≤5 min per
the `resources` + `timeout` in `agent.yaml`). For a simple Claude
call like this, expect ≤$0.01 per order.
