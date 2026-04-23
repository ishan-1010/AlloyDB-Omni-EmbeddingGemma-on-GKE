# Troubleshooting Quick Reference (Print This)

> One-page cheat sheet for session day. Match error text → fix. Full detail in [FAILURE_MODES_AND_FIXES.md](FAILURE_MODES_AND_FIXES.md).

---

## Error → Fix Table

| If you see... | Fix (copy-paste) |
|---------------|------------------|
| `Quota 'SSD_TOTAL_GB' exceeded. Limit: 250.0` | Re-run cluster create with `--disk-type=pd-standard --disk-size=50` |
| `FailedScheduling ... 3 Insufficient memory` (DBCluster pod) | `kubectl patch dbcluster my-omni -n default --type=merge -p '{"spec":{"primarySpec":{"resources":{"memory":"4Gi","cpu":1}}}}'` |
| `CreateContainerConfigError` + `secret "hf-secret" not found` | `kubectl create secret generic hf-secret --from-literal=hf_api_token=$HF_TOKEN --dry-run=client -o yaml \| kubectl apply -f -` |
| `gke-gcloud-auth-plugin failed with exit code 1` | `gcloud auth login` → follow URL → paste code |
| `-bash: apiVersion:: command not found` | Ignore — cosmetic; `kubectl apply` already ran. Use `cat > file <<'EOF'` with quoted EOF next time. |
| `FATAL: password authentication failed` OR `no pg_hba.conf entry` | Use full URI: `psql "postgresql://postgres:VeryStrongPassword@localhost:5432/demo?sslmode=require"` |
| `Session was transferred to another browser tab` | Don't open Cloud Shell in 2+ windows. Stay in one window. |
| `kubectl wait` hangs for >2 min | Stop waiting. Run `kubectl get pods` → `kubectl describe pod <name>` → `kubectl logs <name>` |
| TEI pod `Pending`, nothing happening | `kubectl describe pod -l app=tei-server` — check for `node affinity/selector` → your YAML still has `nodeSelector`, remove it |
| `FailedScheduling ... node affinity/selector` | TEI YAML has `nodeSelector: cloud.google.com/machine-family: c3` — delete those lines, reapply |
| psql `relation "products" does not exist` | You forgot `CREATE DATABASE demo;` or you're connected to `postgres` db, not `demo` |
| `google_ml.embedding(...)` returns NULL or error | Model URL has `:8080` — change to `:80` (or drop port): `http://tei-service/embed` |
| `gcloud container clusters create` hangs >15 min | Ctrl+C, `gcloud container clusters list`, if partial exists: `gcloud container clusters delete --region us-central1 my-cluster --quiet` |

---

## The Three Magic Diagnostic Commands

When anything looks stuck:

```bash
kubectl get pods -A                    # 1. What's not Running?
kubectl describe pod <stuck-pod>       # 2. Why? (look at Events at bottom)
kubectl logs <stuck-pod> --tail=50     # 3. What does the container say?
```

---

## "Is the world on fire?" Health Check

```bash
# Cluster up?
gcloud container clusters list

# AlloyDB running?
kubectl get dbcluster

# TEI running?
kubectl get deploy tei-deployment
kubectl get svc tei-service

# Connectivity AlloyDB → TEI?
kubectl exec my-omni-primary-0 -- wget -qO- http://tei-service/health
```

Expected: `{"status":"ok"}` or similar.

---

## Non-Negotiable Teardown

At 10:42 AM **every student runs**:

```bash
gcloud container clusters delete my-cluster --region us-central1 --quiet
```

And verifies:

```bash
gcloud container clusters list
# Should print "Listed 0 items."
```

---

## Pre-Session Sanity (Do This at 09:45 AM)

```bash
# your demo project
gcloud config get-value project
gcloud auth list
kubectl config current-context
docker compose -f demo/local-setup/docker-compose.yml ps
psql postgresql://postgres:demo@localhost:5433/demo -c "SELECT count(*) FROM plants;"
# Expect: 40
```

---

## The ⚠ Trial-Account Overrides at a Glance

| File / command | Change |
|----------------|--------|
| `gcloud container clusters create` | Add `--disk-type=pd-standard --disk-size=50` |
| `my-omni.yaml` | `memory: 4Gi`, `cpu: 1` |
| `tei-deployment.yaml` | Delete `nodeSelector:` block; `cpu: "2"`, `memory: "4Gi"` |
| `tei-service.yaml` | `port: 80, targetPort: 8080` |
| `google_ml.create_model(...)` | URL ends `:80/embed` (or no port) |
| First SQL of Step 6 | `CREATE DATABASE demo;` |

---

## Phone-A-Friend Contacts

- Speaker on-site
- Event: BuildSpace 2.0 @ IGDTUW
- Date/time: 2026-04-25, 10:00 AM

---

## Links (offline-cached where possible)

- Runbook: `demo/student-runbook.md`
- Speedrun: `demo/workshop-cloudshell-speedrun.sh`
- Upstream codelab: https://codelabs.developers.google.com/alloydb-omni-gke-embeddings
- Full error catalog: [FAILURE_MODES_AND_FIXES.md](FAILURE_MODES_AND_FIXES.md)
- Command handbook: [HANDBOOK.md](HANDBOOK.md)
