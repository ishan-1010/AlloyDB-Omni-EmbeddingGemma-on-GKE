# Workshop Handbook — Exact Commands, End-to-End

> **What this is:** A codelab-style walkthrough with the *exact* commands that were tested end-to-end on a fresh GCP trial project on **2026-04-22 → 23**. Every command below either ran successfully on that run or is a copy-paste safe correction of one that failed.
>
> **What this is NOT:** A replacement for the upstream [AlloyDB Omni + EmbeddingGemma codelab](https://codelabs.developers.google.com/alloydb-omni-gke-embeddings). It's a companion. Where we deviate from the codelab, the deviation is flagged with **[TRIAL-FIX]**.
>
> **Sources:** [`demo/workshop-cloudshell-speedrun.sh`](../demo/workshop-cloudshell-speedrun.sh) (the automated run) and [`docs/ACTUAL_HERO_RESULTS.md`](ACTUAL_HERO_RESULTS.md) (real outputs captured).

---

## Table of contents

0. [Prereqs](#0-prereqs)
1. [Enable APIs](#1-enable-apis)
2. [Create the GKE cluster](#2-create-the-gke-cluster-trial-fix)
3. [Wire kubectl](#3-wire-kubectl)
4. [Install cert-manager](#4-install-cert-manager)
5. [Install the AlloyDB Omni operator](#5-install-the-alloydb-omni-operator-helm)
6. [Deploy the DBCluster](#6-deploy-the-dbcluster-trial-fix)
7. [Create the `demo` database](#7-create-the-demo-database-hidden-codelab-assumption)
8. [Create the HuggingFace secret](#8-create-the-huggingface-secret-order-matters)
9. [Deploy TEI + EmbeddingGemma](#9-deploy-tei--embeddinggemma-trial-fix)
10. [Register the model in AlloyDB](#10-register-the-model-in-alloydb)
11. [Load the Cymbal schema + data](#11-load-the-cymbal-schema--data)
12. [Generate embeddings](#12-generate-embeddings-the-slow-step)
13. [Hero query](#13-hero-query--real-output)
14. [Bonus: semantic generality](#14-bonus-semantic-generality)
15. [EXPLAIN ANALYZE — where the time goes](#15-explain-analyze--where-the-time-goes)
16. [MANDATORY teardown](#16-mandatory-teardown)

Appendices: [A — Every trial-account deviation](#a--every-trial-account-deviation) · [B — Failure modes + one-line fixes](#b--failure-modes--one-line-fixes) · [C — Real cost data](#c--real-cost-data)

---

## 0. Prereqs

Before you start:

- A GCP project with billing enabled. A trial / free-tier account is fine — we ran the whole thing on $5 of credit.
- HuggingFace account with the Gemma license accepted at [huggingface.co/google/embeddinggemma-300m](https://huggingface.co/google/embeddinggemma-300m).
- HuggingFace read token exported as `HF_TOKEN`. **Never paste the token into a shared doc.**
- Cloud Shell open in that project (recommended — avoids local gcloud/kubectl version drift).

```bash
# In Cloud Shell, before anything else:
export HF_TOKEN="hf_..."                       # your token, read scope
gcloud config set project YOUR_PROJECT_ID      # confirm you're in the right project
```

---

## 1. Enable APIs

```bash
gcloud services enable container.googleapis.com compute.googleapis.com
```

Takes 30 sec. Container Engine + Compute are the only two APIs needed end-to-end.

---

## 2. Create the GKE cluster **[TRIAL-FIX]**

**Codelab default fails on a trial account** with `Quota 'SSD_TOTAL_GB' exceeded. Limit: 250.0`. Trial accounts cap regional SSD at 250 GB; a default 3-node cluster wants ~300 GB. Fix: use `pd-standard` boot disks and cap size.

```bash
export PROJECT_ID=$(gcloud config get project)
export LOCATION=us-central1
export CLUSTER_NAME=alloydb-ai-gke
export MACHINE_TYPE=e2-standard-4

gcloud container clusters create "$CLUSTER_NAME" \
  --project="$PROJECT_ID" --region="$LOCATION" \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --release-channel=rapid --machine-type="$MACHINE_TYPE" \
  --num-nodes=1 \
  --disk-type=pd-standard \
  --disk-size=50
```

- `--num-nodes=1` per zone × 3 zones (regional cluster) = 3 nodes total. You cannot go below 1 per zone.
- `--workload-pool` is the one flag students skip; without it, Step 5 (operator Helm install) silently 403s later.
- Expect **~8 min** wall clock. Move on to Step 4 in parallel if you want (cert-manager doesn't need the cluster alive).

---

## 3. Wire kubectl

```bash
gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$LOCATION"
kubectl get nodes
```

You should see 3 nodes in `Ready` status. If you see `gke-gcloud-auth-plugin not found`, run `gcloud auth login` and retry — Cloud Shell occasionally loses the plugin after session drops.

---

## 4. Install cert-manager

The AlloyDB Omni operator's webhook needs cert-manager for its TLS certs.

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.yaml
kubectl wait --for=condition=Available --timeout=300s deployment -n cert-manager --all
```

`kubectl wait` blocks until all three cert-manager deployments (controller, webhook, cainjector) go Available. ~90 sec.

---

## 5. Install the AlloyDB Omni operator (Helm)

The codelab pins operator `1.2.0`. We used whatever `gs://alloydb-omni-operator/latest` pointed to on 22 Apr — version `1.6.3`. Both work.

```bash
export GCS_BUCKET=alloydb-omni-operator
export HELM_PATH=$(gcloud storage cat gs://$GCS_BUCKET/latest)
export OPERATOR_VERSION="${HELM_PATH%%/*}"

gcloud storage cp "gs://$GCS_BUCKET/$HELM_PATH" ./ --recursive

helm install alloydbomni-operator "alloydbomni-operator-${OPERATOR_VERSION}.tgz" \
  --create-namespace --namespace alloydb-omni-system \
  --atomic --timeout 5m
```

`--atomic` rolls back automatically if the install doesn't converge in 5 min. ~2 min on success.

---

## 6. Deploy the DBCluster **[TRIAL-FIX]**

**Two codelab defaults fail on trial-account sized nodes:**

- **`memory: 8Gi`** → AlloyDB pod goes `Pending` with `Insufficient memory`. An `e2-standard-4` has 16 GB and cert-manager + kube-system already eat ~6 GB. Cap at `4Gi`.
- **`storageClass: standard-rwo`** → not present on a default GKE cluster. Use `standard`.

Write the manifest and apply it:

```bash
cat > my-omni.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: db-pw-my-omni
type: Opaque
data:
  my-omni: "VmVyeVN0cm9uZ1Bhc3N3b3Jk"   # base64("VeryStrongPassword")
---
apiVersion: alloydbomni.dbadmin.goog/v1
kind: DBCluster
metadata:
  name: my-omni
spec:
  databaseVersion: "15.13.0"
  primarySpec:
    adminUser:
      passwordRef:
        name: db-pw-my-omni
    features:
      googleMLExtension:
        enabled: true
    resources:
      cpu: 1
      memory: 4Gi           # [TRIAL-FIX] codelab default 8Gi → Pending
      disks:
      - name: DataDisk
        size: 20Gi
        storageClass: standard    # [TRIAL-FIX] codelab uses standard-rwo
    dbLoadBalancerOptions:
      annotations:
        networking.gke.io/load-balancer-type: "internal"
  allowExternalIncomingTraffic: true
YAML

kubectl apply -f my-omni.yaml
```

**Watch it come up:**

```bash
# Poll every 10 sec until clusterphase=DBClusterReady
for i in {1..60}; do
  phase=$(kubectl get dbclusters.alloydbomni.dbadmin.goog my-omni -n default \
    -o jsonpath='{.status.primary.phase}' 2>/dev/null || echo "")
  clusterphase=$(kubectl get dbclusters.alloydbomni.dbadmin.goog my-omni -n default \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  echo "[${i}/60] primary=$phase  cluster=$clusterphase"
  [[ "$clusterphase" == "DBClusterReady" ]] && break
  sleep 10
done
```

**Gotcha:** it's normal to see a transient `Error` phase mid-reconcile — the operator is still wiring things. Wait until `DBClusterReady`. ~4 min total.

---

## 7. Create the `demo` database (hidden codelab assumption)

The codelab's Step 6 silently assumes you are in a database called `demo` when it runs `CREATE EXTENSION vector;`. That database does NOT exist by default. Create it once:

```bash
export DBPOD=$(kubectl get pod \
  --selector=alloydbomni.internal.dbadmin.goog/dbcluster=my-omni,alloydbomni.internal.dbadmin.goog/task-type=database \
  -n default -o jsonpath='{.items[0].metadata.name}')

kubectl exec -i "$DBPOD" -n default -c database -- \
  psql "postgresql://postgres:VeryStrongPassword@localhost:5432/postgres?sslmode=require" \
  -c "CREATE DATABASE demo;"
```

**Why the URI form?** `psql -h localhost -U postgres` fails silently on the password prompt because stdin is consumed by heredoc. Passing the URI with embedded password + `sslmode=require` is the only shape that works inside `kubectl exec -i`. From here onward we'll use that pattern everywhere.

---

## 8. Create the HuggingFace secret (**order matters**)

**Must be created BEFORE the TEI deployment**. If TEI is applied first, it sticks in `CreateContainerConfigError` with `Error: secret "hf-secret" not found` for 30+ minutes before you notice (because `kubectl wait` hides the reason behind a timeout).

```bash
kubectl create secret generic hf-secret \
  --from-literal=hf_api_token="$HF_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The `--dry-run=client | kubectl apply` shape makes the command idempotent — re-running it updates the secret in place instead of failing with "already exists".

---

## 9. Deploy TEI + EmbeddingGemma **[TRIAL-FIX]**

**Codelab defaults that fail on trial nodes:**

- **`cpu: 6, memory: 24Gi`** → pod unschedulable, requests exceed node capacity. Use `cpu: 2, memory: 4Gi`.
- **`nodeSelector: cloud.google.com/machine-family: c3`** → no `c3` nodes exist on trial accounts. Remove.
- **Service port `8080`** → needs to be `80` so AlloyDB's model-registration URL can use `http://tei-service.default.svc.cluster.local/embed` without a port.

```bash
cat > tei-deploy.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tei-deployment
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tei-server
  template:
    metadata:
      labels:
        app: tei-server
    spec:
      # [TRIAL-FIX] no nodeSelector: cloud.google.com/machine-family: c3
      containers:
        - name: tei-container
          image: ghcr.io/huggingface/text-embeddings-inference:cpu-latest
          resources:
            requests: { cpu: "2", memory: "4Gi" }    # [TRIAL-FIX] was 6/24
            limits:   { cpu: "4", memory: "8Gi" }
          env:
            - name: MODEL_ID
              value: google/embeddinggemma-300m
            - name: HF_API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-secret
                  key: hf_api_token
          ports:
            - containerPort: 80
          volumeMounts:
            - mountPath: /data
              name: data
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: tei-service
spec:
  selector:
    app: tei-server
  ports:
    - port: 80              # [TRIAL-FIX] codelab sometimes shows 8080
      targetPort: 80
YAML

kubectl apply -f tei-deploy.yaml
kubectl wait --for=condition=Available --timeout=600s deployment/tei-deployment
```

First reconcile pulls a ~2 GB image + downloads EmbeddingGemma weights from HF. ~4 min. If `kubectl wait` is still waiting past 6 min, check `kubectl describe pod` and `kubectl logs` — see Appendix B.

---

## 10. Register the model in AlloyDB **[OPERATOR-DRIFT]**

This teaches the database that `google_ml.embedding('embedding-gemma', 'text')` should be an HTTP POST to the TEI service.

> **Operator version matters.** AlloyDB Omni operator `1.6.3` (what we run) removed the `tei_text_embedding_*_transform` helpers that older codelab versions referenced. It also made `google_ml.create_model` a **procedure** (`CALL`, not `SELECT`). Working pattern for 1.6.x: use TEI's **OpenAI-compatible endpoint** (`/v1/embeddings`) with `model_provider => 'custom'` and the built-in `openai_text_embedding_*_transform` functions — since TEI's OpenAI-compat response shape matches OpenAI exactly.

```bash
kubectl exec -i "$DBPOD" -n default -c database -- \
  psql "postgresql://postgres:VeryStrongPassword@localhost:5432/demo?sslmode=require" \
  -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS google_ml_integration CASCADE;
ALTER SYSTEM SET google_ml_integration.enable_model_support = 'on';
SELECT pg_reload_conf();

CALL google_ml.create_model(
  model_id               => 'embedding-gemma',
  model_request_url      => 'http://tei-service.default.svc.cluster.local/v1/embeddings',
  model_provider         => 'custom',
  model_type             => 'text_embedding',
  model_qualified_name   => 'google/embeddinggemma-300m',
  model_in_transform_fn  => 'google_ml.openai_text_embedding_input_transform',
  model_out_transform_fn => 'google_ml.openai_text_embedding_output_transform'
);
SQL
```

**Why this shape works (operator 1.6.3, validated 2026-04-24):**

- **`/v1/embeddings`** — TEI's OpenAI-compat endpoint. Returns `{"object":"list","data":[{"embedding":[...]}]}`, identical to OpenAI's shape. TEI's native `/embed` returns a raw `[[floats]]` array that no built-in transform currently unwraps.
- **`model_provider => 'custom'`** — not `'open_ai'`, because the `open_ai` provider has a hardcoded URL validator requiring the `api.openai.com` domain. `'custom'` skips that check.
- **`model_provider => 'hugging_face'`** also fails — it expects the HF Inference Endpoints response shape, not TEI's.
- **`openai_text_embedding_*_transform`** — ship with `google_ml_integration`. They parse OpenAI-shaped JSON. Work unchanged against TEI's OpenAI-compat output.

**Verify the model actually calls TEI:**

```bash
kubectl exec -i "$DBPOD" -n default -c database -- \
  psql "postgresql://postgres:VeryStrongPassword@localhost:5432/demo?sslmode=require" \
  -c "SELECT left(google_ml.embedding('embedding-gemma', 'hello world')::text, 120) AS sample;"
```

Expected: `{-0.21454078,0.0266105,0.06666797,...` — floats coming through `google_ml.embedding()`.

### If you need to re-register

`create_model` errors on duplicate `model_id`. Drop first:

```sql
CALL google_ml.drop_model('embedding-gemma');
```

### Common errors on this step

| Error | Cause | Fix |
|---|---|---|
| `is a procedure ... use CALL` | You used `SELECT google_ml.create_model(...)` | Switch to `CALL` (the AlloyDB API changed between 1.2.x and 1.6.x) |
| `Invalid model_in_transform_fn: google_ml.tei_text_embedding_input_transform` | Operator 1.6.3 no longer ships TEI-specific transforms | Use `openai_*_transform` against `/v1/embeddings` (the recipe above) |
| `Invalid request url ... for provider OpenAI. Please use ... api.openai.com/` | You used `model_provider => 'open_ai'` with a non-OpenAI URL | Switch to `model_provider => 'custom'` |
| `invalid input syntax for type json ... Token "(" is invalid` | Registered with `hugging_face` provider against TEI's `/embed` endpoint — response shape mismatch | Recipe above (custom + /v1/embeddings + openai transforms) |

---

## 11. Load the Cymbal schema + data

All four files (one schema + three CSVs) live in a public GCS bucket. The `database` container inside the AlloyDB pod has `psql` but **no `gcloud`** — so we download on Cloud Shell, copy into the pod with `kubectl cp`, then `\copy` from psql.

```bash
# Phase 1: Download on Cloud Shell (where gcloud lives)
gcloud storage cp gs://cloud-training/gcc/gcc-tech-004/cymbal_demo_schema.sql /tmp/
gcloud storage cp gs://cloud-training/gcc/gcc-tech-004/cymbal_products.csv    /tmp/
gcloud storage cp gs://cloud-training/gcc/gcc-tech-004/cymbal_inventory.csv   /tmp/
gcloud storage cp gs://cloud-training/gcc/gcc-tech-004/cymbal_stores.csv      /tmp/

# Phase 2: Copy into the DB pod's /tmp (-c database targets the Postgres container)
kubectl cp /tmp/cymbal_demo_schema.sql default/$DBPOD:/tmp/cymbal_demo_schema.sql -c database
kubectl cp /tmp/cymbal_products.csv    default/$DBPOD:/tmp/cymbal_products.csv    -c database
kubectl cp /tmp/cymbal_inventory.csv   default/$DBPOD:/tmp/cymbal_inventory.csv   -c database
kubectl cp /tmp/cymbal_stores.csv      default/$DBPOD:/tmp/cymbal_stores.csv      -c database

# Phase 3: Load from psql inside the pod
kubectl exec -i "$DBPOD" -n default -c database -- \
  psql "postgresql://postgres:VeryStrongPassword@localhost:5432/demo?sslmode=require" \
  -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
\i /tmp/cymbal_demo_schema.sql
SET search_path = public;                -- [CRITICAL] pg_dump blanks search_path in line 12; reset so unqualified \copy resolves
\copy cymbal_products  FROM '/tmp/cymbal_products.csv'  WITH (FORMAT csv, HEADER true);
\copy cymbal_inventory FROM '/tmp/cymbal_inventory.csv' WITH (FORMAT csv, HEADER true);
\copy cymbal_stores    FROM '/tmp/cymbal_stores.csv'    WITH (FORMAT csv, HEADER true);
SQL
```

**Why the `SET search_path = public;` is non-optional:** The schema SQL file is pg_dump output. Line 12 of it is `SELECT pg_catalog.set_config('search_path', '', false);` — pg_dump's standard opener that blanks search_path so its fully-qualified `public.tablename` references work during restore. That setting persists for the rest of your psql session, so subsequent unqualified `\copy cymbal_products` fails with `relation "cymbal_products" does not exist`. One line resets it.

**Why not the old `\! gcloud storage cp ...` pattern:** `\!` shells out to the pod's shell, but the `database` container is a minimal Postgres image with no gcloud SDK. That errors with `sh: 1: gcloud: not found`. Download-on-host + `kubectl cp` is the portable fix.

After this you have **941 rows in `cymbal_products`** (US retail products — the upstream codelab dataset).

**Verify:**

```bash
kubectl exec -i "$DBPOD" -n default -c database -- \
  psql "postgresql://postgres:VeryStrongPassword@localhost:5432/demo?sslmode=require" \
  -c "SELECT
        (SELECT count(*) FROM cymbal_products)  AS products,
        (SELECT count(*) FROM cymbal_inventory) AS inventory,
        (SELECT count(*) FROM cymbal_stores)    AS stores;"
```

Expect 941 products.

---

## 12. Generate embeddings (the slow step)

One `INSERT ... SELECT` that calls the model once per row, serially. CPU-only inference on `e2-standard-4` takes **~15–25 minutes for 941 rows** (measured live: ~1.3 sec per embedding, variance 0.4–5 sec depending on product-description length). You cannot speed this up without GPU nodes or parallel embedding (neither is in scope here).

Older versions of this handbook said "~8 min" — that figure is unreliable on trial-account CPU nodes. If you're under a 45-min session budget, expect the INSERT to continue past the session end for students running hands-on. The **shadow-demo pattern** solves this: speaker shows a pre-embedded cluster for the hero query, students' `INSERT` keeps running in the background and they see their own results later.

```bash
kubectl exec -i "$DBPOD" -n default -c database -- \
  psql "postgresql://postgres:VeryStrongPassword@localhost:5432/demo?sslmode=require" \
  -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO cymbal_embedding (uniq_id, description, embedding)
SELECT uniq_id,
       product_description,
       google_ml.embedding('embedding-gemma', product_description)::vector(768)
FROM cymbal_products
WHERE product_description IS NOT NULL;
SQL
```

**Sanity check after it finishes** (pick any row — all should have a 768-dim vector):

```sql
SELECT uniq_id,
       vector_dims(embedding) AS dims,
       left(embedding::text, 150) AS first_150_chars
FROM cymbal_embedding LIMIT 1;
```

Real output from 23 Apr:

```
 uniq_id: 72380122311d120f193f601da1b5f244
 dims:    768
 first_150_chars: [-0.08797259,-0.011677752,0.026522823,...
```

---

## 13. Hero query — real output

**Query:** *"What kind of fruit trees grow well here?"* filtered to `store_id=1583, inventory>0`.

```sql
SELECT cp.product_name,
       left(cp.product_description, 80) AS description,
       cp.sale_price,
       cs.zip_code,
       (ce.embedding <=> google_ml.embedding('embedding-gemma',
           'What kind of fruit trees grow well here?')::vector) AS distance
FROM cymbal_products  cp
JOIN cymbal_embedding ce ON ce.uniq_id   = cp.uniq_id
JOIN cymbal_inventory ci ON ci.uniq_id   = cp.uniq_id
JOIN cymbal_stores    cs ON cs.store_id  = ci.store_id
  AND ci.inventory > 0
  AND cs.store_id = 1583
ORDER BY distance ASC
LIMIT 5;
```

**Real result** (captured 23 Apr, `docs/ACTUAL_HERO_RESULTS.md`):

```
     product_name      | sale_price | zip_code | distance
-----------------------+------------+----------+----------
 Cherry Tree           |      75.00 |    93230 |  0.52105
 California Lilac      |       5.00 |    93230 |  0.56394
 Toyon                 |      10.00 |    93230 |  0.56700
 Rose Bush             |      50.00 |    93230 |  0.57315
 California Peppertree |      25.00 |    93230 |  0.57509

Time: 20,487 ms
```

**Observation for the audience:** "cherry" is nowhere in the query string. The model semantically connected "fruit trees" → Cherry Tree. That's the whole point.

**The `<=>` operator** is cosine distance. 0 = identical; 1 = orthogonal. 0.52 is "moderately similar" — expected for a semantic match.

---

## 14. Bonus: semantic generality

Different query, no store filter, proves the result wasn't cherry-picked:

```sql
SELECT cp.product_name, cp.sale_price,
       (ce.embedding <=> google_ml.embedding('embedding-gemma',
           'something cheap for my patio')::vector) AS distance
FROM cymbal_products  cp
JOIN cymbal_embedding ce ON ce.uniq_id = cp.uniq_id
ORDER BY distance ASC
LIMIT 5;
```

**Real result:**

```
 product_name  | sale_price | distance
---------------+------------+----------
 Garden Rake   |      20.00 |  0.53231
 Wheelbarrow   |      50.00 |  0.53508
 Watering Can  |      10.00 |  0.54338
 Garden Trowel |      15.00 |  0.54852
 Hat           |       5.00 |  0.54902
```

None of these product names contain "cheap" or "patio". The model understood **intent**: cheap + outdoor → garden tools + affordable.

---

## 15. EXPLAIN ANALYZE — where the time goes

Run the hero query prefixed with `EXPLAIN ANALYZE`. The real plan looks like this:

```
Limit  (cost=216.50..216.52 rows=5 width=83)
       (actual time=6.549..6.554 rows=5 loops=1)
  ->  Sort  (cost=216.50..218.86 rows=941 width=83)
        Sort Key: ((ce.embedding <=> '[...768 floats...]'::vector))
        Sort Method: top-N heapsort  Memory: 25kB
        ->  Hash Join  (cost=34.17..200.87 rows=941 width=83)
              Hash Cond: ((cp.uniq_id)::text = (ce.uniq_id)::text)
              ->  Seq Scan on cymbal_products cp
              ->  Seq Scan on cymbal_embedding ce

Planning Time:   20,153.978 ms   ← TIME SPENT CALLING TEI TO EMBED THE QUERY TEXT
Execution Time:       6.641 ms   ← ACTUAL VECTOR SEARCH + JOIN + SORT
```

**The story:** 99.97% of the 20.5-second wall time was the HTTP call to TEI to embed `"fruit trees..."`. Once the query vector existed, AlloyDB searched all 941 vectors, joined, and sorted in **6.6 ms**.

**The production lesson:** cache query embeddings, OR embed at write-time (not read-time). Never in a user-facing request path with cold model calls.

---

## 16. MANDATORY teardown

**A running cluster costs ~$0.40/hour.** Overnight = $10. **Don't be the person who forgets.**

### Why the obvious `clusters delete` isn't enough

GKE cluster delete removes the nodes, boot disks, and control plane — but **NOT everything**. These survive a naive delete:

1. **Persistent Volumes (PVs)** backing PVCs with `reclaimPolicy: Retain` — AlloyDB's DataDisk (20 Gi pd-standard) and operator's control-plane disks (2–10 Gi pd-balanced). ~8 disks per AlloyDB DBCluster.
2. **Load balancer forwarding rules** from `al-my-omni-rw-elb` LoadBalancer service — ~$18/month each if orphaned.
3. **Static IP addresses** (only if you reserved one — we don't in this recipe, but defensive check).

### Safe teardown order — delete apps first, then cluster

Doing this *in this order* lets the operator release resources cleanly before the cluster evaporates under it:

```bash
# 1. Uninstall apps — lets their controllers release LBs + PVs
kubectl delete deployment tei-deployment --ignore-not-found
kubectl delete service    tei-service    --ignore-not-found
kubectl delete dbcluster  my-omni        -n default --ignore-not-found --timeout=60s

# 2. Uninstall the AlloyDB operator (before the cluster — prevents orphaning)
helm uninstall alloydbomni-operator -n alloydb-omni-system 2>/dev/null || true
kubectl delete namespace alloydb-omni-system --ignore-not-found --timeout=60s

# 3. Now delete the cluster itself
gcloud container clusters delete "$CLUSTER_NAME" \
  --region="$LOCATION" --project="$PROJECT_ID" --quiet

# 4. Sweep orphan disks (PVs whose PVCs were never released)
#    Filter "-users:*" catches disks that aren't attached to any VM
gcloud compute disks list --project="$PROJECT_ID" --filter="-users:*"

# Delete each orphan individually, or batch-delete all at once:
for row in $(gcloud compute disks list --project="$PROJECT_ID" --filter="-users:*" \
             --format="value(name,zone)"); do
  name=$(echo "$row" | awk '{print $1}')
  zone=$(echo "$row" | awk '{print $2}')
  [[ -n "$name" && -n "$zone" ]] && \
    gcloud compute disks delete "$name" --zone="$zone" --project="$PROJECT_ID" --quiet
done

# 5. Sweep orphan forwarding rules (LBs that outlived the Service)
gcloud compute forwarding-rules list --project="$PROJECT_ID"
# For each entry that shouldn't be there:
#   gcloud compute forwarding-rules delete <NAME> --region="$LOCATION" --project="$PROJECT_ID" --quiet

# 6. Final check — all three should return "Listed 0 items."
gcloud container clusters list --project="$PROJECT_ID"
gcloud compute instances list --project="$PROJECT_ID"
gcloud compute disks list     --project="$PROJECT_ID" --filter="-users:*"
```

### Pre-run insurance — set a billing alert BEFORE step 2

This is the 30-second move that would prevent every "GDG got a ₹3000 bill" story:

1. Open [GCP Billing → Budgets & alerts](https://console.cloud.google.com/billing/budgets)
2. Create a budget of **$5** (or ₹400) for this project
3. Email alerts at 50%, 90%, 100%

You'll get an email the moment the project crosses $2.50. Trial credit caps at $300 anyway, but the alert tells you *why* spend is climbing before it's too late.

### Real-world example of why safe-order matters

Running `gcloud container clusters delete` without first deleting the DBCluster CR has been observed to leave 8 persistent disks orphaned (6× pd-balanced, 2× pd-standard 20 GB). At GCP's PD prices that's ~$5/month per cluster-tear-down done wrong. Run the workshop 3 times, forget each time, and you have ₹1200+ of invisible persistent-disk bills accumulating. Plus one orphan forwarding rule = ~₹1500 on top. That's exactly how a single workshop turns into a ₹3000 bill without anyone realizing.

The safe-order teardown above closes every known orphan path.

---

## A — Every trial-account deviation

Codelab-as-written assumes a "normal" GCP project with default enterprise quotas. Trial accounts don't have those. These three deviations are the entire delta:

| # | Codelab says | Trial-account reality | Our fix |
|---|---|---|---|
| 1 | Cluster uses `pd-balanced` SSD boot disks (implied by default) | `SSD_TOTAL_GB` capped at 250 GB; 3-node cluster needs ~300 | `--disk-type=pd-standard --disk-size=50` |
| 2 | DBCluster `memory: 8Gi` | `e2-standard-4` has 16 GB, cert-manager + kube-system eat ~6, can't fit 8 | `memory: 4Gi` |
| 3 | TEI `cpu: 6, memory: 24Gi`, `nodeSelector: c3`, service port `8080` | No c3 nodes on trial; 6/24 exceeds node capacity; port mismatch with AlloyDB URL | `cpu: 2, memory: 4Gi`, no nodeSelector, port `80` |

If a student hits any of these on session day, point at this table.

---

## B — Failure modes + one-line fixes

| Symptom | Root cause | Fix |
|---|---|---|
| `Quota 'SSD_TOTAL_GB' exceeded. Limit: 250.0` on cluster create | Trial account SSD cap | Re-run with `--disk-type=pd-standard --disk-size=50` |
| AlloyDB pod stuck `Pending`, event `Insufficient memory` | DBCluster `memory: 8Gi` too high for node | `kubectl patch dbcluster my-omni --type=merge -p '{"spec":{"primarySpec":{"resources":{"memory":"4Gi"}}}}'` |
| TEI pod stuck `CreateContainerConfigError`, event `secret "hf-secret" not found` | HF secret created AFTER TEI deployment | Re-create the secret (step 8), then `kubectl rollout restart deployment/tei-deployment` |
| `gke-gcloud-auth-plugin not found` | Cloud Shell session dropped | `gcloud auth login && gcloud container clusters get-credentials alloydb-ai-gke --region=us-central1` |
| `psql` hangs on heredoc | `-h localhost -U postgres` form needs interactive password | Switch to `psql "postgresql://postgres:VeryStrongPassword@localhost:5432/demo?sslmode=require"` |
| Cloud Shell tab freezes when opened in a second browser tab | Cloud Shell session hijack — one active session per user | Close the second tab; use a K8s `Job` for any long-running work instead of a foreground shell |
| `kubectl wait` times out without clear reason | Real error hiding in pod status | `kubectl describe pod POD && kubectl logs POD` BEFORE assuming slow pull |

See also [FAILURE_MODES_AND_FIXES.md](FAILURE_MODES_AND_FIXES.md) for the full playbook with captured error text.

---

## C — Real cost data

Captured 22–23 Apr from a fresh trial project:

- **Total spent** across multiple failed cluster creates + one successful run + ~14-hour overnight idle + hero query + teardown: **$2.03**
- **TryGCP credit remaining:** $2.97 of $5
- **Realistic per-student cost for the 45-min session:** $0.40–$0.60
- **40 students total:** $16–$24 — not the $42 that pure spec-sheet math suggests

Per-minute billing + trial-tier pricing is the reason the real number is under the theoretical.

---

## Cross-references

- [TRIAL_ACCOUNT_GUIDE.md](TRIAL_ACCOUNT_GUIDE.md) — deep dive on quota gymnastics
- [FAILURE_MODES_AND_FIXES.md](FAILURE_MODES_AND_FIXES.md) — all errors we hit, with exact fixes
- [ACTUAL_HERO_RESULTS.md](ACTUAL_HERO_RESULTS.md) — raw terminal captures
- [../demo/workshop-cloudshell-speedrun.sh](../demo/workshop-cloudshell-speedrun.sh) — unattended end-to-end script
- [../demo/student-runbook.md](../demo/student-runbook.md) — session-day companion
