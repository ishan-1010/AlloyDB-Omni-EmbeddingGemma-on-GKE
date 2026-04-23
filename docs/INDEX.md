# Workshop Documentation Index

**Event:** BuildSpace 2.0 @ IGDTUW
**Date:** 2026-04-25, 10:00 AM IST (45 min)
**Codelab:** AlloyDB Omni + EmbeddingGemma on GKE

---

## Start here

| File | What it is | When you need it |
|------|-----------|------------------|
| **[HANDBOOK.md](HANDBOOK.md)** | Codelab-style walkthrough with the exact commands that were run end-to-end. Every trial-account deviation flagged. Real hero-query output inline. | You want to actually run it. |
| **[TRIAL_ACCOUNT_GUIDE.md](TRIAL_ACCOUNT_GUIDE.md)** | Deep dive on why the codelab defaults fail on a trial GCP account and the three patches that fix it. | You want to understand *why* the handbook deviates. |
| **[FAILURE_MODES_AND_FIXES.md](FAILURE_MODES_AND_FIXES.md)** | Every real failure we hit during the dry run with exact error text and exact fix. | You hit an error mid-run. |
| **[TROUBLESHOOTING_QUICK_REFERENCE.md](TROUBLESHOOTING_QUICK_REFERENCE.md)** | One-page error → fix cheat sheet. Print before the session. | You need a fast lookup during hands-on. |
| **[ACTUAL_HERO_RESULTS.md](ACTUAL_HERO_RESULTS.md)** | Raw terminal captures of the real hero query, bonus patio query, and `EXPLAIN ANALYZE` from the 23 Apr dry run. | You want to see what "working" looks like before you run it. |

---

## Files outside `docs/`

| Path | Purpose |
|------|---------|
| [`../demo/workshop-cloudshell-speedrun.sh`](../demo/workshop-cloudshell-speedrun.sh) | Unattended end-to-end Cloud Shell script — paste and walk away |
| [`../demo/student-runbook.md`](../demo/student-runbook.md) | Student-facing pre-work + 45-min session flow |
| [`../demo/commands.sql`](../demo/commands.sql) | Just the demo SQL, copy-paste safe |
| [`../demo/local-setup/`](../demo/local-setup/) | Local pgvector shadow demo (Docker Compose) — runs the same idea on your laptop without GCP |
| [`../slides/index.html`](../slides/index.html) | Reveal.js deck with Hinglish speaker notes |

---

## Quick nav by question

| Question | Go to |
|---------|-------|
| "Just give me the commands that worked" | [HANDBOOK.md](HANDBOOK.md) |
| "Why does my cluster create fail with SSD quota error?" | [TRIAL_ACCOUNT_GUIDE.md](TRIAL_ACCOUNT_GUIDE.md) |
| "My AlloyDB pod is stuck Pending" | [FAILURE_MODES_AND_FIXES.md](FAILURE_MODES_AND_FIXES.md) |
| "My TEI pod is stuck CreateContainerConfigError" | [FAILURE_MODES_AND_FIXES.md](FAILURE_MODES_AND_FIXES.md) |
| "What does a successful hero query look like?" | [ACTUAL_HERO_RESULTS.md](ACTUAL_HERO_RESULTS.md) |
| "Can I run this on my laptop instead of GCP?" | [../demo/local-setup/README.md](../demo/local-setup/README.md) |
