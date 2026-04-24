#!/usr/bin/env bash
#
# AlloyDB Omni + EmbeddingGemma codelab — UNATTENDED speed-run.
#
# Paste this whole file into Cloud Shell, run it, walk away. ~35-45 min (most of it unattended, during embedding)
# wall-clock. The slowest step (embedding generation on 941 rows) takes
# ~15–25 min on trial e2-standard-4 CPU, dominates the end of the run.
#
# What this script does that the codelab doesn't:
#   1. Trial-account quota-safe cluster (pd-standard boot disks)
#   2. `kubectl wait` between steps so timing doesn't trip you up
#   3. Writes my-omni.yaml + tei-deploy.yaml via heredoc (no editor dance)
#   4. Polls DBClusterReady / Deployment Available programmatically
#   5. Runs the hero query at the end as a smoke test
#
# Expected timing per step (printed live):
#   [1/9] APIs enable           : ~30 sec
#   [2/9] GKE cluster create    : ~8 min   ← unavoidable
#   [3/9] get-credentials       : instant
#   [4/9] cert-manager install  : ~90 sec
#   [5/9] AlloyDB Omni operator : ~2 min
#   [6/9] DBCluster provision   : ~4 min
#   [7/9] TEI / EmbeddingGemma  : ~4 min   ← HF_TOKEN needed
#   [8/9] Model registration    : ~10 sec
#   [9/9] Data + embeddings     : ~15-25 min   ← unavoidable
#   ------------------------------------------------
#   TOTAL                       : ~35-45 min
#
# Prereqs before running:
#   - Cloud Shell open in a billing-enabled project
#   - Your HuggingFace token with Gemma license accepted, exported as HF_TOKEN
#
# Set HF_TOKEN before running:
#   export HF_TOKEN="hf_..."
#   bash workshop-cloudshell-speedrun.sh

set -euo pipefail

# ---------- CONFIG ----------
export PROJECT_ID=$(gcloud config get project)
export LOCATION=us-central1
export CLUSTER_NAME=alloydb-ai-gke
export MACHINE_TYPE=e2-standard-4

: "${HF_TOKEN:?Set HF_TOKEN before running (export HF_TOKEN=hf_...)}"

banner() { printf "\n\033[1;36m==== %s ====\033[0m\n" "$1"; }

banner "[1/9] Enabling APIs in $PROJECT_ID"
gcloud services enable container.googleapis.com compute.googleapis.com

banner "[2/9] Creating GKE cluster (~8 min) — quota-safe pd-standard"
if gcloud container clusters describe "$CLUSTER_NAME" --region="$LOCATION" &>/dev/null; then
  echo "  Cluster already exists, skipping create."
else
  gcloud container clusters create "$CLUSTER_NAME" \
    --project="$PROJECT_ID" --region="$LOCATION" \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --release-channel=rapid --machine-type="$MACHINE_TYPE" \
    --num-nodes=1 --disk-type=pd-standard --disk-size=50
fi

banner "[3/9] Wiring kubectl"
gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$LOCATION"
kubectl get nodes

banner "[4/9] Installing cert-manager"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.yaml
kubectl wait --for=condition=Available --timeout=300s deployment -n cert-manager --all

banner "[5/9] Installing AlloyDB Omni operator via Helm"
export GCS_BUCKET=alloydb-omni-operator
export HELM_PATH=$(gcloud storage cat gs://$GCS_BUCKET/latest)
export OPERATOR_VERSION="${HELM_PATH%%/*}"
gcloud storage cp "gs://$GCS_BUCKET/$HELM_PATH" ./ --recursive
if helm status alloydbomni-operator -n alloydb-omni-system &>/dev/null; then
  echo "  Operator already installed, skipping."
else
  helm install alloydbomni-operator "alloydbomni-operator-${OPERATOR_VERSION}.tgz" \
    --create-namespace --namespace alloydb-omni-system \
    --atomic --timeout 5m
fi

banner "[6/9] Deploying DBCluster (AlloyDB Omni instance)"
cat > my-omni.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: db-pw-my-omni
type: Opaque
data:
  my-omni: "VmVyeVN0cm9uZ1Bhc3N3b3Jk"
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
      memory: 4Gi          # 4Gi (not codelab default 8Gi) — fits on e2-standard-4 with cert-manager overhead
      disks:
      - name: DataDisk
        size: 20Gi
        storageClass: standard
    dbLoadBalancerOptions:
      annotations:
        networking.gke.io/load-balancer-type: "internal"
  allowExternalIncomingTraffic: true
YAML
kubectl apply -f my-omni.yaml

echo "  Waiting for DBClusterReady..."
for i in {1..60}; do
  phase=$(kubectl get dbclusters.alloydbomni.dbadmin.goog my-omni -n default \
    -o jsonpath='{.status.primary.phase}' 2>/dev/null || echo "")
  clusterphase=$(kubectl get dbclusters.alloydbomni.dbadmin.goog my-omni -n default \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  echo "    [${i}/60] primary=$phase  cluster=$clusterphase"
  [[ "$clusterphase" == "DBClusterReady" ]] && break
  sleep 10
done

banner "[7/9] Deploying TEI / EmbeddingGemma pod"
kubectl create secret generic hf-secret \
  --from-literal=hf_api_token="$HF_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

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
      containers:
        - name: tei-container
          image: ghcr.io/huggingface/text-embeddings-inference:cpu-latest
          resources:
            requests: { cpu: "2", memory: "4Gi" }
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
    - port: 80
      targetPort: 80
YAML
kubectl apply -f tei-deploy.yaml
kubectl wait --for=condition=Available --timeout=600s deployment/tei-deployment

banner "[8/9] Register the model in AlloyDB Omni"
DBPOD=$(kubectl get pod \
  --selector=alloydbomni.internal.dbadmin.goog/dbcluster=my-omni,alloydbomni.internal.dbadmin.goog/task-type=database \
  -n default -o jsonpath='{.items[0].metadata.name}')

kubectl exec -i "$DBPOD" -n default -c database -- \
  psql -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS google_ml_integration CASCADE;
ALTER SYSTEM SET google_ml_integration.enable_model_support = 'on';
SELECT pg_reload_conf();

-- Operator 1.6.x: use TEI's OpenAI-compat endpoint + openai_* transforms.
-- The older tei_text_embedding_*_transform functions were removed in 1.6.
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

# [SMOKE TEST] Confirm AlloyDB can actually reach TEI and parse its response
# before burning 15–25 minutes generating 941 embeddings.
banner "[8.5/9] Smoke-testing google_ml.embedding() end-to-end"
SMOKE=$(kubectl exec -i "$DBPOD" -n default -c database -- \
  psql -h localhost -U postgres -d postgres -tAc \
  "SELECT array_length(google_ml.embedding('embedding-gemma', 'hello')::real[], 1);")
if [[ "$SMOKE" == "768" ]]; then
  echo "  ✓ TEI pipeline working (got 768-dim vector)"
else
  echo "  ✗ Smoke test failed. Got: '$SMOKE' (expected '768')"
  echo "  Aborting before the ~20-min embedding generation. Check TEI pod logs:"
  echo "    kubectl logs -l app=tei-server --tail=40"
  exit 1
fi

banner "[9/9] Load Cymbal data + generate embeddings (~15-25 min)"

# Download on Cloud Shell (database container has no gcloud SDK)
gcloud storage cp gs://cloud-training/gcc/gcc-tech-004/cymbal_demo_schema.sql /tmp/
gcloud storage cp gs://cloud-training/gcc/gcc-tech-004/cymbal_products.csv    /tmp/
gcloud storage cp gs://cloud-training/gcc/gcc-tech-004/cymbal_inventory.csv   /tmp/
gcloud storage cp gs://cloud-training/gcc/gcc-tech-004/cymbal_stores.csv      /tmp/

# Copy into pod (-c database targets Postgres container)
kubectl cp /tmp/cymbal_demo_schema.sql default/$DBPOD:/tmp/cymbal_demo_schema.sql -c database
kubectl cp /tmp/cymbal_products.csv    default/$DBPOD:/tmp/cymbal_products.csv    -c database
kubectl cp /tmp/cymbal_inventory.csv   default/$DBPOD:/tmp/cymbal_inventory.csv   -c database
kubectl cp /tmp/cymbal_stores.csv      default/$DBPOD:/tmp/cymbal_stores.csv      -c database

kubectl exec -i "$DBPOD" -n default -c database -- \
  psql -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
\i /tmp/cymbal_demo_schema.sql
SET search_path = public;     -- pg_dump blanked it; reset so unqualified \copy resolves

-- [IDEMPOTENT] Empty any pre-existing data so re-runs don't duplicate rows.
TRUNCATE cymbal_products, cymbal_inventory, cymbal_stores, cymbal_embedding;

\copy cymbal_products  FROM '/tmp/cymbal_products.csv'  WITH (FORMAT csv, HEADER true);
\copy cymbal_inventory FROM '/tmp/cymbal_inventory.csv' WITH (FORMAT csv, HEADER true);
\copy cymbal_stores    FROM '/tmp/cymbal_stores.csv'    WITH (FORMAT csv, HEADER true);

-- Generate embeddings (the slow step, ~15-25 min for 941 rows at CPU)
INSERT INTO cymbal_embedding (uniq_id, description, embedding)
SELECT uniq_id,
       product_description,
       google_ml.embedding('embedding-gemma', product_description)::vector(768)
FROM cymbal_products
WHERE product_description IS NOT NULL;

-- [SANITY] Confirm embeddings actually populated (no silent TEI failures).
DO $$
DECLARE
  total    int;
  non_null int;
BEGIN
  SELECT count(*), count(embedding) INTO total, non_null FROM cymbal_embedding;
  RAISE NOTICE 'cymbal_embedding: total=%, non-null=%', total, non_null;
  IF total < 900 OR non_null < 900 THEN
    RAISE EXCEPTION 'Embedding generation likely failed — expected 941 rows, got total=% non-null=%', total, non_null;
  END IF;
END
$$;
SQL

banner "HERO QUERY — semantic search, end-to-end"
kubectl exec -i "$DBPOD" -n default -c database -- \
  psql -h localhost -U postgres -d postgres <<'SQL'
\timing on
SELECT p.uniq_id, p.product_name, p.sale_price, p.brand,
       (e.embedding <=> google_ml.embedding('embedding-gemma',
          'What kind of fruit trees grow well here?')::vector(768)) AS distance
FROM cymbal_products p JOIN cymbal_embedding e USING (uniq_id)
ORDER BY distance ASC
LIMIT 5;
SQL

banner "DONE. Tear down with:"
cat <<'EOF'
  gcloud container clusters delete alloydb-ai-gke --region=us-central1 --quiet
EOF
