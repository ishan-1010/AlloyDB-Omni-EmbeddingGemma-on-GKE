# Local pgvector setup — run the idea on your laptop

**Purpose:** Reproduce the same semantic-search flow the main codelab teaches, but entirely on your machine via Docker + pgvector. Useful if you don't have GCP access, want to iterate faster, or want to see what "vectors in Postgres" looks like before you pay for a GKE cluster.

This is **pgvector in Docker**, not AlloyDB Omni. Same `<->` operator, same SQL idioms — the difference is the vector index algorithm (HNSW here vs ScaNN on AlloyDB) and the embedding model (384-dim MiniLM here vs 768-dim EmbeddingGemma on GKE).

---

## One-time setup (~10 minutes)

```bash
cd demo/local-setup

# 1. Install the embedding library
python3 -m venv .venv
source .venv/bin/activate
pip install sentence-transformers

# 2. Generate embeddings for the 40 products
python generate_embeddings.py
# → writes seed.sql (~40 INSERTs with 384-dim vectors)

# 3. Generate embeddings for stage queries
python generate_query_vectors.py
# → writes query_vectors.sql

# 4. Start the DB (pulls pgvector image on first run)
docker compose up -d

# 5. Load the stage query vectors (seed.sql auto-loaded by Docker)
docker exec -i cymbal-pgvector psql -U cymbal -d cymbal < query_vectors.sql
```

Verify it's alive:

```bash
docker exec -it cymbal-pgvector psql -U cymbal -d cymbal -c \
  "SELECT count(*), round(avg(price)::numeric, 2) FROM cymbal_products;"
```

Expected: `count=40, avg=... ` — you're good.

---

## Running queries

Open a psql session into the container:

```bash
docker exec -it cymbal-pgvector psql -U cymbal -d cymbal
\pset pager off
\timing on
```

`queries.sql` contains the demo queries with matching checkpoints to the main GKE flow.

---

## Pre-computed query vectors — why

`generate_query_vectors.py` precomputes embeddings for a handful of natural-language queries and writes them to `query_vectors.sql`. This lets you run the hero lookup without round-tripping through Python each time.

If you prefer live query embedding, either:

1. Load `sentence-transformers` into the pgvector container and wire a custom function, or
2. Call out to a small Python helper that returns a vector literal you paste into psql.

Both add latency the pre-bake approach avoids; pick what matches your teaching goal.

---

## Teardown

```bash
docker compose down -v   # stops container, removes volume
```

---

## Troubleshooting

- **`vector` extension missing** → you're on a vanilla postgres image. `docker-compose.yml` uses `pgvector/pgvector:pg16` — confirm the image tag.
- **Embeddings script hangs on first run** → it's downloading ~80 MB model weights. Happens once.
- **Hero query returns weird top-5** → the model is 384-dim MiniLM, not Google's 768-dim EmbeddingGemma. Results are semantically sensible but not identical. Good enough for a teaching reference; label it accurately if asked.
