# Student runbook — 45-min workshop companion

**For:** IGDTUW students attending the BuildSpace 2.0 × GDG workshop on 25 April.
**What you'll do:** Follow the real [AlloyDB Omni + EmbeddingGemma codelab](https://codelabs.developers.google.com/alloydb-omni-gke-embeddings) on your own GKE cluster. The speaker runs a local shadow setup on stage so you can see expected outputs at each checkpoint.

---

## Pre-work — before Saturday 25 April

**This is mandatory. Without it, the session won't fit in 45 minutes.** Complete by Thursday night, 23 April.

### 1. GCP project (15 min)

- Sign up at [cloud.google.com/free](https://cloud.google.com/free) if you don't have an account
- New accounts get **₹25,000 (~$300) free credit** — this workshop will cost ~₹300–500
- Create a project, enable billing on it
- Note your **project ID** (something like `cymbal-workshop-ik-234`)

> ⚠ **No credit card?** Ask the GDG organizer at least 3 days before the session — they can often pull Google Cloud Skills Boost credits that bypass this.

### 2. Enable APIs (3 min, but takes 5 min for APIs to activate)

In Cloud Shell, once:

```bash
gcloud config set project YOUR_PROJECT_ID
gcloud services enable container.googleapis.com compute.googleapis.com
```

### 2a. ⚠ Bump your SSD quota (1 min, critical)

**New GCP projects ship with a 250 GB SSD regional quota — GKE's default 3-node cluster needs 300 GB. Without this fix you'll hit `SSD_TOTAL_GB exceeded` on cluster creation.**

Two ways to solve it:

- **Option A (easiest):** Use the fixed cluster-create command in Step 4 below, which uses `pd-standard` boot disks. This bypasses the SSD quota entirely.
- **Option B (also do this):** Request a quota increase at [console.cloud.google.com/iam-admin/quotas](https://console.cloud.google.com/iam-admin/quotas) — filter `SSD_TOTAL_GB` + region `us-central1`, request **500 GB**. Usually auto-approved in minutes. You'll want this for AlloyDB Omni's data volumes later anyway.

### 3. Hugging Face account (5 min)

- Sign up at [huggingface.co](https://huggingface.co)
- Go to [huggingface.co/google/embeddinggemma-300m](https://huggingface.co/google/embeddinggemma-300m)
- **Accept the Gemma license** on that page — if you skip this, the TEI pod 403s silently on session day
- Create a **read-access token** at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens), save it somewhere

### 4. (Optional, strongly recommended) Pre-warm the cluster

If you want a head start on Saturday, do Steps 1–3 of the codelab at home — just **create the GKE cluster** and install **cert-manager** + the **AlloyDB Omni operator** before you arrive. Session-day you jump to Step 4 and save 15 minutes.

```bash
# Matches the codelab Step 3, with two trial-account fixes baked in:
#   --disk-type=pd-standard  → avoids 250 GB SSD_TOTAL_GB quota wall
#   --disk-size=50           → 50 GB × 3 nodes = 150 GB total, well under any default
# The --workload-pool flag is critical; without it Step 5 silently 403s.
export PROJECT_ID=$(gcloud config get project)
gcloud container clusters create alloydb-ai-gke \
  --project=${PROJECT_ID} \
  --region=us-central1 \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
  --release-channel=rapid \
  --machine-type=e2-standard-4 \
  --num-nodes=1 \
  --disk-type=pd-standard \
  --disk-size=50
```

> ⚠ If you pre-create the cluster, **it costs ~$0.40/hour (≈₹33/hr) while idle**. Delete it Friday night if you're going to recreate Saturday, or leave it running if you're confident you'll be at the session.
>
> ⚠ **If you skip `--disk-type=pd-standard`** you WILL hit `Quota 'SSD_TOTAL_GB' exceeded. Limit: 250.0` on new projects. The codelab's default assumes higher quotas than trial accounts have.

---

## Session day — 45-minute flow

Session starts 10:00 AM sharp. Doors open at 09:45 for Wi-Fi + Cloud Shell warmup.

### What to bring

- Laptop (any OS) with a modern browser (Chrome / Firefox / Edge)
- The HuggingFace token from pre-work
- Your GCP project ID

### Minute-by-minute

| Time | You are doing | Speaker is doing |
|---|---|---|
| **10:00 – 10:03** | Open Cloud Shell. Run `gcloud config set project YOUR_ID`. | Kickoff, slide 1–3. |
| **10:03 – 10:08** | — (listen) | Fast concept tour: embeddings, `<->`, vector search. Slides 4–7. |
| **10:08 – 10:18** | **Codelab Step 3.** `gcloud container clusters create …`. This takes ~8 minutes. While it runs, **continue to Step 4** — deploy cert-manager in parallel. | While you wait: slide 10 (architecture) stays on screen. Speaker runs the equivalent query on their local laptop to show what "done" looks like. |
| **10:18 – 10:24** | **Codelab Step 4.** Deploy the AlloyDB Omni operator via Helm. Create the `DBCluster` resource. | Slide 11–12 (AlloyDB Omni, Operators) as you deploy. |
| **10:24 – 10:30** | **Codelab Step 5.** Deploy the TEI / EmbeddingGemma pod. You'll need your HuggingFace token here. Wait ~3 min for the image pull. | Slide 13 (TEI + EmbeddingGemma). Speaker demos `SELECT left(embedding::text, 120)` on their local. |
| **10:30 – 10:38** | **Codelab Step 6a.** Register the model with `google_ml.create_model()`. Load the Cymbal products from GCS. Start embedding generation — **this takes ~8 minutes, be patient**. | During your 8-min wait: slide 14 (request flow), slide 18 (hero query preview). Speaker runs the hero query on their 40-product local mirror, so you see exactly what your output will look like. |
| **10:38 – 10:43** | **Codelab Step 6b — YOUR HERO MOMENT.** Run the semantic-search query on your own cluster. See Meyer Lemon Tree, Birch Tree, Boxwood Bush and other garden products in your top-5. Try your own natural-language query. | Speaker celebrates, runs the same query on their 40-plant local mirror — concept identical, dataset curated for Delhi teaching flavor. |
| **10:43 – 10:45** | **MANDATORY:** `gcloud container clusters delete alloydb-ai-gke --region=us-central1 --quiet` + delete any compute instances you created. Do not leave the room without confirming this runs. | QR code to the full codelab. Homework. Thanks. |

---

## What if you fall behind?

- **Cluster still creating at minute 15?** Don't panic — keep going with Step 4 (cert-manager) in a parallel terminal; Kubernetes commands queue cleanly.
- **Stuck on an error?** Raise your hand — helpers will circulate. Don't silently fall behind.
- **Can't finish by 10:43?** Fine — you can finish at home tonight on the same cluster. Just **set a billing alert** at $20 before you leave and delete the cluster Sunday at latest.

---

## Teardown (the most important slide)

Before you leave, **run this on your project:**

```bash
# 1. Delete the cluster
gcloud container clusters delete alloydb-ai-gke \
  --region=us-central1 --project=YOUR_PROJECT_ID --quiet

# 2. Delete persistent disks that outlive the cluster
gcloud compute disks list --project=YOUR_PROJECT_ID
gcloud compute disks delete DISK_NAME \
  --region=us-central1 --project=YOUR_PROJECT_ID --quiet

# 3. Confirm nothing is left
gcloud compute instances list --project=YOUR_PROJECT_ID
gcloud container clusters list --project=YOUR_PROJECT_ID
```

Also: set a billing alert at ₹1500 in [GCP Billing → Budgets](https://console.cloud.google.com/billing/budgets). Insurance.

---

## After the workshop — finish the codelab

You now have the hands-on foundation. To go deeper:

1. **Finish the codelab:** steps 7 onwards — ScaNN index, more complex queries.
2. **Swap the dataset:** your own product catalog, movie reviews, class notes, anything.
3. **Connect Gemini for RAG:** retrieve top-5 documents → send to Gemini API → grounded chatbot. Full link in slide 23's QR.

Tag the speaker on LinkedIn when you build something — we want to see it.

---

## FAQ

**Q: I don't have a credit card, how do I enable billing?**
A: Ask the GDG organizer 3 days before the session — they can often arrange Qwiklabs / Google Cloud Skills Boost credits.

**Q: Can I run all this on my laptop instead of GKE?**
A: You can run pgvector in Docker locally (like the speaker does). See the local-setup folder in the workshop repo. But GKE is the authentic production experience — do at least once on cloud.

**Q: The session is 45 min but the codelab says 90 min. How?**
A: We pre-provision what we can via pre-work, parallelize long operations, and skip a few non-essential steps on session day. You'll finish the rest at home.

**Q: What if my Wi-Fi drops mid-cluster-creation?**
A: Cloud Shell runs in your browser tab but executes commands on Google's servers — your cluster keeps creating even if your laptop disconnects. Just reopen Cloud Shell and reattach.

**Q: Why AlloyDB Omni and not just plain Postgres with pgvector?**
A: For student projects, pgvector is often enough (and simpler). AlloyDB Omni adds ScaNN index + Google-scale performance for production. We show the Omni version because that's what the codelab uses — but you'll hear the speaker say "start with pgvector" in slide 21.
