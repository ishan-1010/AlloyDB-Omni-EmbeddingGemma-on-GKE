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

Before the steps: **[Concepts primer](#concepts-primer--the-mental-model-you-need)** — if any of kubectl/pod/operator/embedding feels fuzzy, read that first.

---

## Concepts primer — the mental model you need

This section explains *what the pieces actually are* before you start running commands. If you already know Kubernetes + embeddings, skim. If not, read linearly — each concept builds on the previous one.

### Containers, images, and pods

- **Container image** — a frozen snapshot of software: OS libraries, a binary, and its config, all packaged as a portable file. Think of it as "a computer's full install, compressed into a zip". Example: `ghcr.io/huggingface/text-embeddings-inference:cpu-latest`.
- **Container** — a *running instance* of an image. One image can be run many times → many containers.
- **Pod (Kubernetes)** — the smallest unit Kubernetes manages. A pod holds one or more containers that share a network + storage. 99% of pods have one container; sidecars (monitoring, proxies) are the exception. You can think of a pod as "one logical app, possibly made of helper containers".

### Kubernetes (K8s) — container orchestration

Kubernetes is a control system for running containers across many machines. You describe what you want ("run 3 copies of this pod, keep it available, restart if crashed"), K8s continuously makes reality match your description. Built by Google, open source, industry-standard since ~2017.

**Why not just `docker run`?** Because Docker runs on *one* machine, doesn't restart crashed containers, doesn't handle networking across machines, doesn't do rolling updates. K8s does all of that.

### GKE (Google Kubernetes Engine) — managed K8s

GKE = Kubernetes, but Google runs the hard parts for you:
- Control plane (API server, etcd, scheduler) — Google's problem
- Worker nodes (VMs running your pods) — Google provisions, you pay per hour
- Auto-repair, auto-upgrade, networking, load balancers — Google
- You just declare workloads and consume

### Cluster, nodes, namespaces

- **Cluster** — one Kubernetes installation. Has one control plane + 1-N worker nodes. "The cluster" = the unit you interact with.
- **Node** — one VM (or physical machine) that runs pods. Our cluster has 3 nodes (`e2-standard-4` VMs, 4 vCPU / 16 GiB RAM each). Nodes are interchangeable — Kubernetes schedules pods onto whichever has room.
- **Namespace** — a logical subfolder inside a cluster. Used for separation: `default` for your workloads, `kube-system` for Kubernetes internals, `alloydb-omni-system` for the AlloyDB operator. Namespaces aren't security boundaries, just organization + scoping.

### kubectl — the Kubernetes CLI

`kubectl` is how you talk to the cluster. You run `kubectl <verb> <resource>` and it talks to the cluster's API over HTTPS. Examples:

- `kubectl get pods -n default` — list pods in the default namespace
- `kubectl apply -f my-omni.yaml` — submit a YAML describing what you want
- `kubectl exec -i POD -c database -- psql ...` — run a command inside a specific container of a specific pod (like SSH, but for pods)
- `kubectl logs -l app=tei-server` — read logs from matching pods

**Mental model:** kubectl is just an HTTP client that speaks the Kubernetes REST API, with handy shortcuts.

### Declarative config + YAML

You don't tell Kubernetes "create this pod" imperatively. You submit a YAML file describing the *desired state* ("I want a Deployment of 3 replicas running image X, exposed via Service Y"). Kubernetes' controllers reconcile reality toward the spec continuously. This is what makes it self-healing — if a node dies, the controller spawns a replacement pod on another node, because reality drifted from spec.

### Deployments, Services, Secrets, PersistentVolumeClaims

The workshop uses these built-in Kubernetes resource types:

- **Deployment** — "I want N replicas of this pod running, keep them running, update them gracefully when I change the image". Used for TEI.
- **Service** — a stable DNS name + IP that load-balances to pods matching a label selector. Pods come and go (new IPs each time); Service endpoint doesn't change. Used for `tei-service` so AlloyDB can always reach TEI at `tei-service.default.svc.cluster.local`.
- **Secret** — key-value store for sensitive data (HF token, DB passwords). Mounted into pods as environment variables or files. Base64-encoded at rest (not encrypted by default — it's access-controlled, not secure-by-cryptography).
- **PersistentVolumeClaim (PVC)** — a request for storage. "I want 20 GiB of pd-standard disk". Kubernetes provisions a matching PersistentVolume (backed by a GCP persistent disk) and mounts it into the pod. Survives pod restarts — your database data lives here.

### Custom Resources + Operators (CRDs) — the advanced bit

Kubernetes is extensible. Anyone can define new *types* of resources (like a new noun: `DBCluster`) and write a controller to reconcile them. These are called Custom Resources:

- **CRD (Custom Resource Definition)** — the *schema* for a new resource type. "A DBCluster has these fields: `databaseVersion`, `primarySpec`, etc." Install a CRD once per cluster.
- **Custom Resource (CR)** — an *instance* of a CRD. E.g., your `my-omni` DBCluster YAML is a CR.
- **Operator** — a long-running controller inside the cluster that watches CRs of a type and makes reality match. The AlloyDB Omni operator watches `DBCluster` resources, spawns the right pods, manages backups, handles failover. Think of it as "a robot DBA living inside your cluster".

This is how a single short YAML (`kind: DBCluster`) becomes "Postgres running across multiple containers with cert-managed TLS". The operator does all the hard work behind the scenes.

### Helm — the package manager

Helm is to Kubernetes what `apt`/`brew` is to Linux/macOS. Packages = "charts" (templated YAMLs with knobs). The AlloyDB Omni operator ships as a Helm chart; one `helm install` drops 20+ Kubernetes resources into your cluster (CRDs, RBAC rules, controller Deployment, ServiceAccount, etc.). You could write all those YAMLs yourself; Helm abstracts the mess.

### AlloyDB Omni vs AlloyDB (managed)

Google has two flavours:

- **AlloyDB (managed)** — Google runs it on GCP. You just consume it. Per-hour bill, GCP-only.
- **AlloyDB Omni** — same engine, you run it anywhere (your laptop, any Kubernetes, any VM). Free for dev/testing. We use this today.

Both are PostgreSQL-wire-compatible (100% drop-in). On top of stock Postgres they add:
- **ScaNN vector index** — Google Research's Approximate Nearest Neighbor search. Lets you scale vector queries to millions of rows.
- **Columnar accelerator** — speeds up analytical queries.
- **`google_ml.*` functions** — SQL-level wrappers around ML endpoints (this is the step-10 magic).

### pgvector — the open-source vector type for Postgres

Open-source Postgres extension that adds:
- A new column type: `vector(N)` — stores N floats.
- Distance operators: `<->` (Euclidean / L2), `<=>` (cosine), `<#>` (negative inner product).
- Index types: HNSW, IVFFlat (approximate nearest neighbor indexes).

AlloyDB Omni includes pgvector as a dependency. Our `cymbal_embedding` table has an `embedding vector(768)` column powered by pgvector.

### Embeddings + EmbeddingGemma + TEI

- **Embedding** — a way to represent text (or images, audio) as a list of numbers such that "similar things → similar numbers". 768 numbers in our case.
- **EmbeddingGemma** — Google's open-source text embedding model. 308M parameters, produces 768-dim vectors. Smaller than most LLMs (GPT-3 is 175B parameters = 570× bigger). Runs on CPU, ~2 GB RAM.
- **TEI (Text Embeddings Inference)** — HuggingFace's Rust-based server for running embedding models. You give it an HTTP endpoint; it loads the model weights, serves a `POST /v1/embeddings` API that returns vectors. Stateless, horizontally scalable.

Together: TEI is the **process** serving the model; EmbeddingGemma is the **model weights** it loads. TEI without a model = useless server; model without TEI = unusable weight file.

### HuggingFace + HF_TOKEN

HuggingFace is "GitHub for ML models" — they host Gemma, BERT, Llama, thousands of others. Some models are *gated*: you need an account + accepted license + read token to download them. `HF_TOKEN` in our workshop is that read token. TEI uses it to download the EmbeddingGemma weights at pod startup.

### cert-manager

Kubernetes doesn't come with TLS-certificate issuance built in. cert-manager is a Kubernetes controller that automates certificate lifecycle (issue from Let's Encrypt / internal CA / AlloyDB operator, rotate before expiry, mount into pods). The AlloyDB Omni operator requires cert-manager to exist in the cluster before it installs, because the operator needs TLS for its webhook and for pod-to-pod AlloyDB traffic.

### `google_ml.create_model` + `google_ml.embedding` — SQL-level ML calls

AlloyDB Omni's `google_ml_integration` extension teaches Postgres to make HTTP calls to ML endpoints, from inside SQL.

- **`CALL google_ml.create_model(...)`** — registers a named endpoint. You tell AlloyDB "here's a URL, here's what shape of request/response, here's a nickname for it" — once. It stores this in metadata.
- **`SELECT google_ml.embedding('model_name', 'input text')`** — runs the model on the input, inside any SQL query. Internally it makes an HTTP POST, parses the JSON response (via transform functions), returns a `float[]` that you can cast to `vector(768)`.

This is what lets you write:

```sql
SELECT * FROM products
ORDER BY embedding <=> google_ml.embedding('embedding-gemma', 'user query')::vector
LIMIT 5;
```

…and have the database call the ML server itself, no Python middleware needed.

### One paragraph summary

You run `gcloud` to create a **GKE cluster** (nodes = VMs). You use `kubectl` to install **cert-manager**, then the **AlloyDB Omni operator** (a controller that watches **DBCluster** custom resources). You submit a DBCluster YAML; the operator spawns a Postgres pod with pgvector + google_ml extensions. Separately you deploy a **TEI server pod** loading **EmbeddingGemma**. Postgres and TEI talk to each other via cluster-internal DNS (`tei-service.default.svc.cluster.local`). You register TEI with Postgres using `google_ml.create_model` (one SQL procedure call). From then on, SQL queries can embed text and do cosine-distance search in one statement. When done, `gcloud container clusters delete` tears it all down (mostly — check the teardown section for orphan-disk gotchas).

With that mental model in place, the numbered steps below make sense: each one is setting up one piece of that picture.

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

> **What this step is doing:** GCP APIs are gated — you must *enable* each one on your project before it accepts requests. We enable `container.googleapis.com` (lets you create GKE clusters) and `compute.googleapis.com` (lets you create VMs, disks, networks — the building blocks GKE uses). Enabling is free; only the resources you subsequently create bill you.

```bash
gcloud services enable container.googleapis.com compute.googleapis.com
```

Takes 30 sec. Container Engine + Compute are the only two APIs needed end-to-end.

---

## 2. Create the GKE cluster **[TRIAL-FIX]**

> **What this step is doing:** Provisioning a GKE cluster = asking Google to spin up a managed Kubernetes control plane + 3 VMs (our worker nodes), put them on an internal network, and configure the control plane to accept your kubectl requests. After this, you have an empty cluster — no pods running yet. Total: ~8 min. Billing starts the moment nodes are up (~$0.40/hr).
>
> Flags decoded:
> - `--region=us-central1` — regional cluster, 1 node per zone × 3 zones = 3 nodes (highly available)
> - `--machine-type=e2-standard-4` — 4 vCPU / 16 GiB per node (cheapest tier that fits AlloyDB + TEI)
> - `--release-channel=rapid` — get the newest Kubernetes version (needed for some AlloyDB operator features)
> - `--workload-pool` — enables Workload Identity, required for the operator Helm install to authenticate
> - `--disk-type=pd-standard --disk-size=50` — **[TRIAL-FIX]** use HDD-backed boot disks to stay under the 250 GB SSD quota cap

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

> **What this step is doing:** Your cluster has an API endpoint (a private IP + TLS cert). `kubectl` needs to know (a) the endpoint URL, (b) how to authenticate to it. `get-credentials` fetches both and writes them into `~/.kube/config`. After this, every subsequent `kubectl` command in this shell hits *your* cluster.
>
> `kubectl get nodes` is a sanity check — it asks the API server "list all nodes" and confirms you can reach and authenticate to the cluster.

```bash
gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$LOCATION"
kubectl get nodes
```

You should see 3 nodes in `Ready` status. If you see `gke-gcloud-auth-plugin not found`, run `gcloud auth login` and retry — Cloud Shell occasionally loses the plugin after session drops.

---

## 4. Install cert-manager

> **What this step is doing:** Installing cert-manager = applying a YAML that contains ~30 Kubernetes resources (CRDs for `Certificate`/`Issuer`, a controller Deployment, a webhook, RBAC rules). After this, the cluster has a new capability: "anyone can request TLS certificates via `kind: Certificate` custom resources and cert-manager will issue them." We don't use cert-manager directly — we install it because the AlloyDB operator (next step) depends on it to issue its own TLS certs. Prerequisite plumbing.

The AlloyDB Omni operator's webhook needs cert-manager for its TLS certs.

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.yaml
kubectl wait --for=condition=Available --timeout=300s deployment -n cert-manager --all
```

`kubectl wait` blocks until all three cert-manager deployments (controller, webhook, cainjector) go Available. ~90 sec.

---

## 5. Install the AlloyDB Omni operator (Helm)

> **What this step is doing:** The operator is a controller that lives in the cluster and knows how to manage AlloyDB Omni instances. Installing it via Helm = running a templated bundle of ~20 Kubernetes resources: a CRD (`DBCluster`), a Deployment (the controller pod), RBAC roles, a ServiceAccount, webhooks (validating incoming DBCluster YAMLs). After this step, your cluster understands the new noun "DBCluster" and has a robot watching for them. We don't create a DBCluster yet — we install the robot that *will* create one when we ask.

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

> **What this step is doing:** Submitting a `DBCluster` YAML = handing the operator a declarative spec: *"I want Postgres 15.13, 1 CPU, 4 GiB RAM, a 20 GiB data disk, with the google_ml extension enabled, accessible via an internal load balancer."* The operator's reconciliation loop reads this, provisions the pod(s), attaches the disk (via a PVC), mounts the password Secret, sets up TLS, and moves the DBCluster's `status.phase` to `DBClusterReady` when everything is actually serving. YAML-to-running-database = ~4 min.
>
> Two things get created here:
> 1. A **Secret** (`db-pw-my-omni`) holding the Postgres admin password, base64-encoded
> 2. A **DBCluster** CR (`my-omni`) that references that Secret

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

> **What this step is doing:** The DBCluster gave you a Postgres *server* (with the `postgres` default database). The codelab's later steps assume a database named `demo` already exists — but nothing created it. So we run `CREATE DATABASE demo;` once. `kubectl exec` gets you a shell inside the `database` container, `psql` connects locally via the URI (with password embedded because heredoc stdin can't handle a password prompt), and we issue the CREATE. One-time setup.
>
> **Common gotcha on this step:** `Connection refused` if you run this immediately after `kubectl apply`. The pod is `Running` at the K8s level but Postgres inside is still booting (WAL recovery, etc.). Wait for `status.phase = DBClusterReady` (≈3–4 min after apply), not pod-Ready.

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

> **What this step is doing:** TEI (next step) needs your HuggingFace token to download EmbeddingGemma (a gated model — license required). We don't want to hardcode the token in the TEI Deployment YAML; that's a security anti-pattern. Instead we create a Kubernetes Secret (named `hf-secret`) that stores the token, and the TEI pod spec will *reference* the Secret via `env.valueFrom.secretKeyRef`. The token never appears in YAML or logs.
>
> **Why the `--dry-run=client | kubectl apply` pattern:** makes the command idempotent — re-running updates the Secret instead of failing with "already exists". Safer in scripts.

**Must be created BEFORE the TEI deployment**. If TEI is applied first, it sticks in `CreateContainerConfigError` with `Error: secret "hf-secret" not found` for 30+ minutes before you notice (because `kubectl wait` hides the reason behind a timeout).

```bash
kubectl create secret generic hf-secret \
  --from-literal=hf_api_token="$HF_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The `--dry-run=client | kubectl apply` shape makes the command idempotent — re-running it updates the secret in place instead of failing with "already exists".

---

## 9. Deploy TEI + EmbeddingGemma **[TRIAL-FIX]**

> **What this step is doing:** Creating a Deployment + Service pair. The Deployment says *"run 1 replica of the TEI container, give it the HF_TOKEN secret as an env var, request 2 CPU / 4 GiB memory"*. The Service exposes that pod on a stable DNS name (`tei-service.default.svc.cluster.local`) port 80. When the pod boots, TEI reads `MODEL_ID=google/embeddinggemma-300m`, downloads the model weights from HuggingFace (using HF_TOKEN for auth), loads into RAM, starts HTTP server. After `kubectl wait --for=condition=Available`, the pod is ready to serve embeddings.

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

> **What this step is doing:** Three related actions inside Postgres:
> 1. **`CREATE EXTENSION google_ml_integration`** — loads the AlloyDB Omni extension that adds the `google_ml.*` schema (functions + model metadata tables) to Postgres.
> 2. **`ALTER SYSTEM SET ... = 'on'` + `pg_reload_conf()`** — turns on the feature flag that permits outbound HTTP calls from SQL.
> 3. **`CALL google_ml.create_model(...)`** — stores metadata about TEI in `google_ml.model_info_view`: the URL, the response-shape transforms, a nickname (`embedding-gemma`). Does *not* test the endpoint — just stores the config. The first real HTTP call happens when you later run `google_ml.embedding(...)`.

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

> **What this step is doing:** Three phases because the `database` container is a minimal Postgres image (no `gcloud` SDK):
> 1. **Download** the schema SQL + 3 CSV files from a public GCS bucket to Cloud Shell's filesystem (where `gcloud` is available)
> 2. **`kubectl cp`** those files into the pod's `/tmp` (kubernetes' equivalent of `scp` for pods)
> 3. **Run psql inside the pod** — creates pgvector extension, loads the schema file (which creates 4 tables: `cymbal_products`, `cymbal_embedding`, `cymbal_inventory`, `cymbal_stores`), and `\copy`s 941 products + inventory + store rows from the CSVs into those tables.
>
> After this: tables exist and have data, but the `embedding` column of `cymbal_embedding` is empty. Step 12 fills it.

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

> **What this step is doing:** One SQL statement — `INSERT INTO cymbal_embedding SELECT ... google_ml.embedding(...) FROM cymbal_products` — iterates all 941 product descriptions, makes 941 serial HTTP calls to TEI, gets 941 768-dim vectors back, inserts each into the `cymbal_embedding` table. Under the hood: for each row, AlloyDB's HTTP client hits `tei-service.default.svc.cluster.local/v1/embeddings`, TEI's Rust server runs EmbeddingGemma inference on CPU (~0.4–5 sec per row depending on description length), returns the float array, Postgres casts to `vector(768)` and inserts.
>
> This is the **"pre-compute at write-time"** pattern — do the expensive work once at load time so query-time is just `SELECT embedding WHERE ...`, which is instant. Production systems embed on insert/update via triggers or async workers. Re-embedding only needed when the model itself changes.

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

> **What this step is doing:** The whole workshop in one SQL query. Step-by-step what happens when you execute it:
> 1. Postgres parses + plans the query. During planning, it evaluates the *constant* expression `google_ml.embedding('embedding-gemma', 'What kind...')::vector`. That means right now, Postgres makes an HTTP call to TEI to embed the query string. That HTTP call takes ~20 sec — all of the wall-clock time of this query.
> 2. The resulting 768-dim vector is treated as a constant for the rest of the query.
> 3. Execution: JOIN `cymbal_products` with `cymbal_embedding` (both by `uniq_id`), JOIN `cymbal_inventory` (same key), JOIN `cymbal_stores` (by `store_id`). Filter to `store_id=1583 AND inventory>0`. Compute `ce.embedding <=> constant_vec` (cosine distance) for each surviving row. Sort ascending. Take top 5.
> 4. Return the 5 rows — in our case, Cherry Tree / California Lilac / Toyon / Rose Bush / California Peppertree, all at ZIP 93230.
>
> Total time ~20 seconds. Breakdown: 99.96% is step 1 (embedding the query text), 0.04% is the actual database work. See step 15 for the EXPLAIN ANALYZE proof.

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

> **What this step is doing:** Same query pattern, different natural-language input ("something cheap for my patio"). Tests whether the model understood *intent*, not just keyword overlap. Product names returned (Garden Rake, Wheelbarrow, Watering Can, Garden Trowel, Hat) do NOT contain "cheap" or "patio" anywhere — but the model placed them near that query in embedding space because it learned from training data that outdoor/affordable items semantically cluster with those concepts. Proof that the system generalizes, not memorizes.

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

> **What this step is doing:** `EXPLAIN ANALYZE` is Postgres's profiler. Prefixing any query with it makes Postgres (a) *actually execute* the query, (b) print a tree of what operations it did + how long each took. Two numbers matter:
> - **Planning Time** — time spent in the planner phase. *Normally* microseconds. Here it's 20+ seconds, because planning is where `google_ml.embedding(constant_text)` gets evaluated (it's marked IMMUTABLE, so the planner pre-computes it). That pre-computation IS the HTTP call to TEI.
> - **Execution Time** — time actually scanning + joining + sorting. Here it's 6–9 ms total for everything: 3-way join across 4 tables, cosine distance on 830+ rows, top-5 sort.
>
> The 99.96%/0.04% split is the core production lesson of this whole workshop. Your "slow query" is slow because of ML inference, not because of the database.

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
