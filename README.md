# Build with AI · GDG Cloud New Delhi — AlloyDB Omni + GKE + Embeddings (Ishan Katoch)

Workshop kit for a 45-minute hands-on session on **AlloyDB Omni, GKE, and vector search**, built on top of the official [Google Codelab](https://codelabs.developers.google.com/alloydb-omni-gke-embeddings).

**Session:** 25 April 2026 · Indira Gandhi Delhi Technical University for Women
**Codelab:** [AlloyDB Omni + EmbeddingGemma on GKE](https://codelabs.developers.google.com/alloydb-omni-gke-embeddings)

---

## What you'll find here

```
.
├── screenshots/
├── docs/
│   ├── HANDBOOK.md             # ⭐ codelab-style walkthrough with exact commands
│   ├── TRIAL_ACCOUNT_GUIDE.md  # the 3 patches that make the codelab fit a trial GCP account
│   ├── FAILURE_MODES_AND_FIXES.md
│   ├── TROUBLESHOOTING_QUICK_REFERENCE.md
│   ├── ACTUAL_HERO_RESULTS.md  # raw terminal captures from the 23 Apr dry run
│   └── INDEX.md
├── demo/
│   ├── workshop-cloudshell-speedrun.sh    # end-to-end automated script (paste & walk away)
│   ├── student-runbook.md                 # pre-work + 45-min session flow
│   ├── commands.sql                       # just the demo SQL
│   └── local-setup/                       # run the same idea on your laptop (Docker + pgvector)
└── README.md
```

---

## Quick start

**If you want to run the full codelab on GCP (recommended):** open [docs/HANDBOOK.md](docs/HANDBOOK.md) — it's a codelab-style walkthrough with the exact commands that were tested end-to-end, with every trial-account deviation flagged.

**If you hit an error during the run:** check [docs/FAILURE_MODES_AND_FIXES.md](docs/FAILURE_MODES_AND_FIXES.md) for the exact error text → exact fix.

**If you want to run it locally without GCP:** [demo/local-setup/README.md](demo/local-setup/README.md) — Docker Compose + pgvector + a small curated dataset. Takes ~10 minutes.

**If you want a full-send automated run in Cloud Shell:** [demo/workshop-cloudshell-speedrun.sh](demo/workshop-cloudshell-speedrun.sh). Set `HF_TOKEN` and run; ~30 min wall clock.

---

## Why this repo exists (vs just the official codelab)

The upstream codelab is excellent but assumes a "normal" GCP project with full default quotas. A fresh GCP trial account hits three hard quota walls that the codelab doesn't mention:

1. **`SSD_TOTAL_GB` quota (250 GB)** blocks cluster creation with default SSD boot disks.
2. **DBCluster `memory: 8Gi`** doesn't fit alongside cert-manager on `e2-standard-4` nodes.
3. **TEI resource requests + `c3` nodeSelector** don't match trial-tier machine families.

This kit documents the three fixes, captures real output from an end-to-end run so you know what "working" looks like, and encodes the sequence into scripts you can copy-paste.

Full reasoning in [docs/TRIAL_ACCOUNT_GUIDE.md](docs/TRIAL_ACCOUNT_GUIDE.md).

---
