# Failure Modes and Fixes

> Every failure we actually hit during dry runs, with the exact error text and the exact fix. If a student shows you an error, Ctrl-F its most unique word — you'll find it here.

---

## Index

| ID | Failure | Layer | Recoverable live? |
|----|---------|-------|-------------------|
| [A](#failure-a--ssd_total_gb-quota) | Cluster create fails at 35s on SSD quota | gcloud | Yes, 30s |
| [B](#failure-b--dbcluster-failedscheduling) | DBCluster pod stuck `Pending`, insufficient memory | k8s/AlloyDB | Yes, 20s |
| [C](#failure-c--tei-createcontainerconfigerror) | TEI pod stuck `CreateContainerConfigError` — missing HF secret | k8s/TEI | Yes, 30s |
| [D](#failure-d--gke-gcloud-auth-plugin-failed) | `kubectl` auth plugin fails, Cloud Shell dropped session | Cloud Shell | Yes, 45s (needs URL flow) |
| [E](#failure-e--heredoc-bash-interpretation) | Pasted YAML heredoc triggers bash parse errors | Shell hygiene | Cosmetic, ignore |
| [F](#failure-f--psql-authentication--pg_hba-mismatch) | `psql` rejects connection, no `pg_hba.conf` entry | Postgres | Yes, 15s |
| [G](#failure-g--cloud-shell-tab-hijack) | Long-running kubectl dies when new Cloud Shell tab opens | Cloud Shell | Partial — use Jobs |
| [H](#failure-h--kubectl-wait-timeout-masking-real-error) | `kubectl wait` times out for 10 min, hiding real cause | k8s | Yes, diagnose first |

---

## Failure A — `SSD_TOTAL_GB` quota

### Symptom

```
$ gcloud container clusters create my-cluster --region us-central1 ...
Creating cluster my-cluster in us-central1...⠹
ERROR: (gcloud.container.clusters.create) ResponseError: code=403,
message=Insufficient regional quota to satisfy request: resource
"SSD_TOTAL_GB": request requires '300.0' and is short '50.0'.
project has a quota of '250.0' with '250.0' available.
```

Fails at ~35 seconds in. Cluster object is **not created** — safe to re-run.

### Root cause

Regional cluster = 3 zones × 1 node × 100 GB pd-balanced = 300 GB SSD. Trial cap is 250 GB.

### Fix

Re-run with smaller HDD boot disks:

```bash
gcloud container clusters create my-cluster \
  --region us-central1 \
  --num-nodes=1 \
  --machine-type=e2-standard-4 \
  --disk-type=pd-standard \
  --disk-size=50 \
  --enable-ip-alias
```

`pd-standard` draws from `DISKS_TOTAL_GB` (2 TB quota), not `SSD_TOTAL_GB`. See [TRIAL_ACCOUNT_GUIDE.md#deviation-1](TRIAL_ACCOUNT_GUIDE.md#deviation-1--cluster-boot-disks).

---

## Failure B — DBCluster `FailedScheduling`

### Symptom

```
$ kubectl get dbcluster
NAME      STATUS    PRIMARYSTATUS    PHASE
my-omni   Error                      Pending

$ kubectl get pods
NAME                 READY   STATUS    RESTARTS   AGE
my-omni-primary-0    0/2     Pending   0          3m

$ kubectl describe pod my-omni-primary-0 | tail -5
Events:
  Warning  FailedScheduling   default-scheduler
  0/3 nodes are available: 3 Insufficient memory.
```

### Root cause

Codelab requests 8 GB per pod. With `e2-standard-4` (12 GB allocatable) and kube-system + cert-manager + AlloyDB sidecars, scheduler can't find a fit.

### Fix — patch live

```bash
kubectl patch dbcluster my-omni -n default --type=merge -p \
  '{"spec":{"primarySpec":{"resources":{"memory":"4Gi","cpu":1}}}}'
```

Within 20 seconds:
- DBCluster controller sees the change.
- Deletes old pod spec, creates new with 4Gi.
- Pod schedules, starts PG init.

Verify:

```bash
kubectl wait --for=condition=Ready pod/my-omni-primary-0 --timeout=180s
```

---

## Failure C — TEI `CreateContainerConfigError`

### Symptom

```
$ kubectl get pods
NAME                              READY   STATUS                       AGE
tei-deployment-7d8f9c6b5d-xk2pq   0/1     CreateContainerConfigError   30m

$ kubectl describe pod tei-deployment-7d8f9c6b5d-xk2pq | tail -10
Events:
  Warning  Failed   ... Error: secret "hf-secret" not found
```

Status stays at `CreateContainerConfigError` forever — Kubernetes will not auto-recreate the pod; it waits for the secret.

### Root cause

TEI deployment references `env: valueFrom: secretKeyRef: name: hf-secret`. Student skipped the `kubectl create secret` step OR created it with a different name.

### Fix

Make sure `$HF_TOKEN` is set in the Cloud Shell, then:

```bash
kubectl create secret generic hf-secret \
  --from-literal=hf_api_token=$HF_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -
```

The `--dry-run=client | kubectl apply` idiom makes this safe to re-run (handles the "already exists" case).

Pod auto-retries within ~30 seconds. Watch:

```bash
kubectl get pod -l app=tei-server -w
```

### If `$HF_TOKEN` is empty

```bash
# Student needs to paste their HuggingFace token:
read -rs HF_TOKEN && export HF_TOKEN
# then re-run the secret command
```

---

## Failure D — `gke-gcloud-auth-plugin` failed

### Symptom

```
$ kubectl get pods
E0423 00:08:12.445123   12345 memcache.go:265] couldn't get current server API group list:
Get "https://34.41.x.x/api?timeout=32s": getting credentials:
exec: executable gke-gcloud-auth-plugin failed with exit code 1

Unable to connect to the server: getting credentials: exec:
executable gke-gcloud-auth-plugin failed with exit code 1
```

Usually happens after 20-30 minutes of Cloud Shell idle, or after laptop sleep.

### Root cause

Cloud Shell's gcloud session dropped its cached credential. The auth plugin shells out to `gcloud config config-helper`, which needs a live auth.

### Fix

```bash
gcloud auth login
```

Follow the URL, paste the verification code. Session resumes. `kubectl` works again.

### Preemptive

If you know you'll be idle for a while, run a keep-alive:

```bash
while true; do kubectl get ns >/dev/null 2>&1; sleep 60; done &
```

(Not recommended for students — too fiddly.)

---

## Failure E — Heredoc bash interpretation

### Symptom

After pasting a multiline YAML heredoc into Cloud Shell, bash shows:

```
-bash: apiVersion:: command not found
-bash: kind:: command not found
-bash: metadata:: command not found
```

Cosmetically alarming but `kubectl apply` usually ran correctly already.

### Root cause

The paste delivers the `cat <<EOF ... EOF` block, then the terminal echoes the remaining lines into a fresh prompt, where bash tries to execute each YAML line as a command.

### Prevention

Always use **quoted** EOF marker so bash doesn't expand `$VAR` inside:

```bash
cat > my-omni.yaml <<'EOF'
apiVersion: alloydbomni.dbadmin.goog/v1
kind: DBCluster
...
EOF
```

(Single quotes around `'EOF'`.)

### If it already happened

Ignore the errors. Verify the file was written:

```bash
cat my-omni.yaml | head -5
```

If correct, proceed.

---

## Failure F — psql authentication / pg_hba mismatch

### Symptom

```
$ kubectl exec -it my-omni-primary-0 -- psql -U postgres -d demo <<EOF
...
EOF
psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed:
FATAL:  password authentication failed for user "postgres"
```

Or:

```
psql: error: connection to server at "127.0.0.1", port 5432 failed:
FATAL:  no pg_hba.conf entry for host "127.0.0.1", user "postgres",
database "demo", no encryption
```

### Root cause

AlloyDB Omni ships with a strict `pg_hba.conf` that rejects non-SSL localhost connections and requires the password in the URI rather than via env var.

### Fix — use the full URI with `sslmode=require`

```bash
kubectl exec -it my-omni-primary-0 -- psql \
  "postgresql://postgres:VeryStrongPassword@localhost:5432/demo?sslmode=require"
```

Or for one-shot queries:

```bash
kubectl exec -it my-omni-primary-0 -- psql \
  "postgresql://postgres:VeryStrongPassword@localhost:5432/demo?sslmode=require" \
  -c "SELECT count(*) FROM products;"
```

### Password reference

`VeryStrongPassword` is the literal password set in the `db-pw-my-omni` secret created earlier in the codelab. If a student changed it, they need to use their value.

---

## Failure G — Cloud Shell tab hijack

### Symptom

Student has Cloud Shell open in Tab 1, running `kubectl logs -f` or a long `INSERT`. They open a **new browser window** and start a fresh Cloud Shell. Tab 1 shows:

```
Session was transferred to another browser tab.
Reconnect? [y/N]
```

The running process is **dead**. `kubectl exec` commands die with a disconnect.

### Root cause

Cloud Shell is a single-tenant VM per user. Opening it in a second window forcibly migrates the session. Not a bug — intentional.

### Prevention

- **Same browser window, multiple tabs** is fine (they share the session).
- **Separate windows = disaster.** Don't do it.

### Fix for long-running work

If a student needs to run something that must survive disconnects, wrap it in a Kubernetes Job:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: load-products
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: loader
          image: postgres:15
          command:
            - bash
            - -c
            - psql "$DB_URL" -f /data/load.sql
```

For our 45-min workshop, the 941-row INSERT is fast enough (~30s) that a plain `kubectl exec` works. Just don't open a second Cloud Shell window.

---

## Failure H — `kubectl wait` timeout masking real error

### Symptom

```
$ kubectl wait --for=condition=Available deployment/tei-deployment --timeout=600s
error: timed out waiting for the condition on deployments/tei-deployment
```

10 minutes of staring, then a generic timeout. Useless.

### Root cause

`kubectl wait` polls for one condition. If the pod is wedged in `CreateContainerConfigError` (Failure C), `Available` will never flip — but `wait` gives no hint about why.

### Fix — always triage before you wait

Run this diagnostic sequence at any "stuck" sign:

```bash
# 1. What's the pod status?
kubectl get pods -l app=tei-server

# 2. Why is it in that status?
kubectl describe pod -l app=tei-server | tail -30

# 3. If the container started, what does it say?
kubectl logs -l app=tei-server --tail=50
```

**Rule of thumb:** if `kubectl wait` hasn't succeeded within 2× the expected time, stop waiting and diagnose.

---

## Cross-References

- [TRIAL_ACCOUNT_GUIDE.md](TRIAL_ACCOUNT_GUIDE.md) — why these failures exist at all
- [TROUBLESHOOTING_QUICK_REFERENCE.md](TROUBLESHOOTING_QUICK_REFERENCE.md) — one-page printable version for session day
- [HANDBOOK.md](HANDBOOK.md) — the runbook where each of these failures shows up in sequence
