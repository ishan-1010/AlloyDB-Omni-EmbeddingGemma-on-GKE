-- =========================================================
-- Build with AI · GDG Cloud New Delhi — Live demo commands
-- Source of truth: docs/HANDBOOK.md + docs/ACTUAL_HERO_RESULTS.md
--
-- Prereqs: psql'd into `demo` database on AlloyDB Omni via
--   kubectl exec -i $DBPOD -n default -c database -- \
--     psql "postgresql://postgres:VeryStrongPassword@localhost:5432/demo?sslmode=require"
-- \timing on should be toggled before the hero query.
-- =========================================================


-- =========================================================
-- BEFORE THE SESSION (not shown on screen)
-- =========================================================
-- \pset pager off
-- \timing on
-- SET search_path TO public;


-- =========================================================
-- SLIDE 15 — the cluster is running
-- Run this in a SEPARATE shell tab, not psql.
-- =========================================================
-- kubectl get pods


-- =========================================================
-- SLIDE 16 — "it's still just Postgres"
-- =========================================================
SELECT count(*), round(avg(sale_price)::numeric, 2) AS avg_price
FROM cymbal_products;

SELECT uniq_id, product_name, left(product_description, 80) AS description, sale_price
FROM cymbal_products
LIMIT 1;


-- =========================================================
-- SLIDE 17 — generate a single embedding from SQL
-- =========================================================
SELECT left(
  google_ml.embedding('embedding-gemma',
                      'What kind of fruit trees grow well here?')::text,
  150
) AS preview;


-- =========================================================
-- SLIDE 18 — THE HERO QUERY (semantic search)
-- Expected top result on real data: Cherry Tree (distance ~0.521).
-- Full captured output: docs/ACTUAL_HERO_RESULTS.md
-- =========================================================
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


-- =========================================================
-- SLIDE 19 — BONUS: semantic generality ("patio" query)
-- Expected: Garden Rake, Wheelbarrow, Watering Can, Garden Trowel, Hat.
-- None of those names contain "cheap" or "patio".
-- =========================================================
SELECT cp.product_name, cp.sale_price,
       (ce.embedding <=> google_ml.embedding('embedding-gemma',
           'something cheap for my patio')::vector) AS distance
FROM cymbal_products  cp
JOIN cymbal_embedding ce ON ce.uniq_id = cp.uniq_id
ORDER BY distance ASC
LIMIT 5;


-- =========================================================
-- SLIDE 20 — EXPLAIN ANALYZE (the timing story)
-- Real numbers on 941 rows:
--   Planning Time  : ~20,150 ms   (TEI HTTP call to embed query text)
--   Execution Time :      6.6 ms  (vector search + JOIN + sort)
-- =========================================================
EXPLAIN ANALYZE
SELECT cp.product_name, cp.sale_price,
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


-- =========================================================
-- EMERGENCY FALLBACKS
-- If TEI is slow or errors, these still prove the data is there.
-- =========================================================

SELECT
  (SELECT count(*) FROM cymbal_products)  AS products,
  (SELECT count(*) FROM cymbal_embedding) AS embeddings;

SELECT uniq_id,
       vector_dims(embedding) AS dims,
       left(embedding::text, 120) AS first_floats
FROM cymbal_embedding
LIMIT 1;

-- Nearest neighbours to a *known* product's vector — no TEI dependency.
WITH q AS (SELECT embedding AS v FROM cymbal_embedding LIMIT 1)
SELECT cp.product_name, cp.sale_price,
       ce.embedding <=> q.v AS distance
FROM cymbal_products cp
JOIN cymbal_embedding ce ON ce.uniq_id = cp.uniq_id
CROSS JOIN q
ORDER BY distance
LIMIT 5;
