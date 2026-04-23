# Trial Account Guide — Codelab Deviations Required

> The upstream codelab at https://codelabs.developers.google.com/alloydb-omni-gke-embeddings assumes a **billing-enabled, quota-upgraded** GCP project. On a free-trial (`$300/90d`) project, **three** parts of the codelab fail without modification. This doc lists every deviation.

---

## TL;DR — The Three Required Patches

| # | Where | Codelab default | ⚠ Trial-account override |
|---|-------|------------------|---------------------------|
| 1 | `gcloud container clusters create` | `--disk-type=pd-balanced --disk-size=100` (implicit) | `--disk-type=pd-standard --disk-size=50` |
| 2 | `my-omni.yaml` DBCluster | `memory: 8Gi` | `memory: 4Gi`, `cpu: 1` |
| 3 | `tei-deployment.yaml` | `cpu: 6, memory: 24Gi` + `nodeSelector: cloud.google.com/machine-family=c3` | `cpu: 2, memory: 4Gi` (limit 6Gi), NO nodeSelector, port `80 → 8080` |

Plus one hidden assumption: the codelab references a `demo` database but never shows its creation — do it manually.

---

## Deviation 1 — Cluster boot disks

### Why it breaks

Free-trial projects have:
- `SSD_TOTAL_GB` quota = **250 GB per region**
- `DISKS_TOTAL_GB` quota = **2 TB per region** (HDD bucket)

Codelab's `gcloud container clusters create my-cluster --region us-central1 --num-nodes=1` with a **regional** cluster creates nodes in 3 zones × 1 node/zone = **3 nodes**, each with the default `pd-balanced` boot disk of 100 GB. That's 300 GB of SSD-backed storage, which exceeds 250 GB.

### The exact error

```
ERROR: (gcloud.container.clusters.create) ResponseError: code=403,
message=Insufficient regional quota to satisfy request: resource
"SSD_TOTAL_GB": request requires '300.0' and is short '50.0'.
project has a quota of '250.0' with '250.0' available.
View and manage quotas at
https://console.cloud.google.com/iam-admin/quotas?usage=USED&project=...
```

Fails at ~35 seconds in.

### The fix

⚠ Add `--disk-type=pd-standard --disk-size=50` to the cluster create command:

```bash
gcloud container clusters create my-cluster \
  --region us-central1 \
  --num-nodes=1 \
  --machine-type=e2-standard-4 \
  --disk-type=pd-standard \
  --disk-size=50 \
  --enable-ip-alias
```

### Why this is safe

- Boot disks only hold OS (Container-Optimized OS) + kubelet cache + container image layers.
- AlloyDB's actual data lives on a separate **PersistentVolumeClaim** (dynamically provisioned, defaults to `pd-standard` anyway).
- TEI's EmbeddingGemma model weights fit in pod memory; no persistent storage needed.
- `pd-standard` is ~3x cheaper too.

### Zero teaching impact

Students won't feel any difference. Model inference speed, SQL query latency, cluster provisioning time — all identical within noise.

---

## Deviation 2 — AlloyDB DBCluster memory

### Why it breaks

Free-trial projects have `CPUs_ALL_REGIONS` = **12 vCPU**. Our cluster uses the full budget: 3 × e2-standard-4 = 3 × 4 vCPU = 12 vCPU. Each `e2-standard-4` node advertises 16 GB RAM but only **~12 GB is allocatable** to pods (kube-reserved + system-reserved + eviction buffer).

Codelab requests:
- AlloyDB pod: 8 GB memory
- Plus sidecars (monitoring, Omni admission controller)
- Plus cert-manager pods (~300 MB across 3 nodes)

On paper this fits, but scheduler bin-packing with all the sidecars leaves no room, especially after kube-system daemonsets (kube-proxy, gke-metrics-agent, fluentbit) claim their share.

### The exact error

```
$ kubectl get dbcluster my-omni
NAME      STATUS    PRIMARYSTATUS    PHASE
my-omni   Error                      Pending

$ kubectl describe pod my-omni-primary-0
Events:
  Warning  FailedScheduling   ... 0/3 nodes are available:
  3 Insufficient memory. preemption: 0/3 nodes are available:
  3 No preemption victims found for incoming pod.
```

### The fix — in `my-omni.yaml`

⚠ Before applying, set memory to 4Gi and cpu to 1:

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: DBCluster
metadata:
  name: my-omni
spec:
  databaseVersion: "15.7.0"
  primarySpec:
    adminUser:
      passwordRef:
        name: db-pw-my-omni
    resources:
      cpu: 1                 # ⚠ trial override (was 2)
      memory: 4Gi            # ⚠ trial override (was 8Gi)
      disks:
        - name: DataDisk
          size: 10Gi
          storageClass: standard
```

### If DBCluster already created, patch live

```bash
kubectl patch dbcluster my-omni -n default --type=merge -p \
  '{"spec":{"primarySpec":{"resources":{"memory":"4Gi","cpu":1}}}}'
```

### Why 4 GB is enough

For the 941-row Cymbal demo:
- PG shared_buffers at default (~1 GB) handles the entire working set.
- 768-dim vectors × 941 rows × 4 bytes = ~2.8 MB of embedding data, trivial.
- Query latency for top-5 KNN on 941 rows: <100ms cold, <10ms warm.

You would feel 4 GB pinch with millions of rows or concurrent load — not our scenario.

---

## Deviation 3 — TEI deployment

### Why it breaks

Codelab's `tei-deployment.yaml` defaults:

```yaml
resources:
  requests:
    cpu: "6"
    memory: "24Gi"
nodeSelector:
  cloud.google.com/machine-family: c3
```

Two failures fuse here:
1. `c3` node pools need explicit provisioning + separate CPU quota on trial.
2. Even if we could spin a `c3-highmem-8`, we're already at 12 vCPU — no budget.

### The exact symptom

TEI pod stays `Pending` with:

```
Warning  FailedScheduling  ... 0/3 nodes are available:
3 node(s) didn't match Pod's node affinity/selector.
```

### The fix — rewrite the deployment resources block

⚠ Drop `nodeSelector`, shrink requests:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tei-deployment
spec:
  replicas: 1
  selector:
    matchLabels: { app: tei-server }
  template:
    metadata:
      labels: { app: tei-server }
    spec:
      # NO nodeSelector             # ⚠ removed
      containers:
        - name: tei-container
          image: ghcr.io/huggingface/text-embeddings-inference:cpu-1.5
          args:
            - --model-id=google/embeddinggemma-300m
            - --port=8080
          ports:
            - containerPort: 8080
          env:
            - name: HF_API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-secret
                  key: hf_api_token
          resources:
            requests:
              cpu: "2"              # ⚠ was 6
              memory: "4Gi"         # ⚠ was 24Gi
            limits:
              cpu: "2"
              memory: "6Gi"
```

### Service: port 80 → 8080

⚠ Our service maps external port 80 to container port 8080:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: tei-service
spec:
  selector:
    app: tei-server
  ports:
    - port: 80                       # ⚠ codelab uses 8080
      targetPort: 8080
      protocol: TCP
  type: ClusterIP
```

### Update the model URL in AlloyDB

Where the codelab has:

```sql
SELECT google_ml.create_model(
  model_id => 'tei-embed',
  model_request_url => 'http://tei-service.default.svc.cluster.local:8080/embed',
  model_provider => 'custom',
  ...
);
```

⚠ Change to:

```sql
model_request_url => 'http://tei-service.default.svc.cluster.local:80/embed'
-- or just 'http://tei-service/embed' since 80 is default
```

### Why EmbeddingGemma-300m is fine on 2 CPU / 4 GB

- Model is 300M parameters, ~600 MB on disk, ~1.2 GB RAM resident.
- CPU inference latency: ~200-400ms per embed request on 2 vCPUs.
- For the workshop's 941 `INSERT` + occasional query: totally fine.
- GPU-class latency (<20ms) would need `c3` + CUDA image — not our fight.

---

## Hidden Codelab Assumption — `demo` database

Step 6 of the codelab runs SQL against a database called `demo`. It never shows `CREATE DATABASE demo;` — that SQL is implicitly run on a **jumpbox VM** (`instance-1`) the codelab provisions in an earlier step.

### We skip the jumpbox

Reasons:
1. Extra `gcloud compute instances create` — more CPU quota, more time.
2. `kubectl exec` into the DB pod works fine for our needs.
3. Step 8 teardown includes `instances delete instance-1` — we don't want that dangling reference.

### So add this manually

⚠ First SQL statement of Step 6, before anything else:

```bash
kubectl exec -it my-omni-primary-0 -- psql -U postgres -c "CREATE DATABASE demo;"
```

Then connect to `demo` for the rest:

```bash
kubectl exec -it my-omni-primary-0 -- psql \
  "postgresql://postgres:VeryStrongPassword@localhost:5432/demo?sslmode=require"
```

---

## Summary Checklist Before Session

- [ ] `demo/workshop-cloudshell-speedrun.sh` has `--disk-type=pd-standard --disk-size=50`
- [ ] `my-omni.yaml` has `memory: 4Gi` and `cpu: 1`
- [ ] `tei-deployment.yaml` has no `nodeSelector`, `cpu: 2`, `memory: 4Gi`
- [ ] `tei-service.yaml` has `port: 80, targetPort: 8080`
- [ ] Step 6 SQL starts with `CREATE DATABASE demo;`
- [ ] Model URL uses `:80` not `:8080`

Cross-reference: [FAILURE_MODES_AND_FIXES.md](FAILURE_MODES_AND_FIXES.md) has the recovery playbook if a student hits one of these errors live.
