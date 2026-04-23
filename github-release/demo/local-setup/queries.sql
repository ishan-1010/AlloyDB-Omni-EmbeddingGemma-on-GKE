-- ============================================================
-- Shadow-demo queries — mirrors the GKE codelab step-by-step.
-- Run these in your local psql while students are waiting on
-- slow GKE operations. Each block matches a student checkpoint.
-- ============================================================
--
-- Connect:  psql postgresql://cymbal:cymbal@localhost:5432/cymbal
-- Optional: \pset pager off  \timing on

-- ============================================================
-- CHECKPOINT A — "it's still just Postgres"
-- Students: after Step 6 loads their data. You: any time.
-- ============================================================
SELECT count(*) AS total, round(avg(price)::numeric, 2) AS avg_price
FROM cymbal_products;

SELECT product_id, description, price FROM cymbal_products LIMIT 1;


-- ============================================================
-- CHECKPOINT B — "generate an embedding from SQL"
-- On GKE with AlloyDB Omni, students call:
--   google_ml.embedding('embedding-gemma', '...')
-- Locally we already have embeddings pre-computed — show the
-- shape of a stored vector instead:
-- ============================================================
SELECT product_id,
       left(embedding::text, 120) AS vec_preview
FROM cymbal_products
WHERE product_id = 'A-1001';


-- ============================================================
-- CHECKPOINT C — THE HERO QUERY (semantic search)
-- Locally: we use a query vector produced with the SAME model
-- (all-MiniLM-L6-v2) so the top-5 comes out sensible without
-- calling an inference service on the fly.
--
-- To keep the demo punchy, we store a handful of pre-computed
-- query vectors in query_vectors below. Students on GKE call
-- google_ml.embedding() live; you fetch from this table.
-- ============================================================

-- Tiny lookup table of pre-baked query embeddings.
-- Populate this once: run `python generate_query_vectors.py` (see README).
CREATE TABLE IF NOT EXISTS query_vectors (
  query_text TEXT PRIMARY KEY,
  embedding  vector(384)
);

-- The hero query:
SELECT product_id, description, price, store_location
FROM cymbal_products
ORDER BY embedding <->
  (SELECT embedding FROM query_vectors WHERE query_text = 'fruit trees for hot weather')
LIMIT 5;


-- Audience pick — try a different natural-language query:
SELECT product_id, description, price
FROM cymbal_products
ORDER BY embedding <->
  (SELECT embedding FROM query_vectors WHERE query_text = 'low maintenance plant for a small balcony')
LIMIT 5;


-- ============================================================
-- CHECKPOINT D — "the index matters"
-- Compare indexed vs non-indexed search over the same data.
-- Tiny dataset (40 rows) means the delta is small, but visible.
-- Explain: at 10M rows the gap is minutes vs milliseconds.
-- ============================================================
\timing on

-- Without HNSW (exact scan):
EXPLAIN ANALYZE
SELECT product_id FROM cymbal_products_noindex
ORDER BY embedding <->
  (SELECT embedding FROM query_vectors WHERE query_text = 'fruit trees for hot weather')
LIMIT 5;

-- With HNSW index:
EXPLAIN ANALYZE
SELECT product_id FROM cymbal_products
ORDER BY embedding <->
  (SELECT embedding FROM query_vectors WHERE query_text = 'fruit trees for hot weather')
LIMIT 5;


-- ============================================================
-- SANITY CHECK (safe fallback if anything above misbehaves)
-- Nearest products to a known product — no embedding API call.
-- ============================================================
WITH q AS (SELECT embedding AS v FROM cymbal_products WHERE product_id = 'A-1001')
SELECT p.product_id, p.description, (p.embedding <-> q.v) AS distance
FROM cymbal_products p, q
ORDER BY distance LIMIT 5;
