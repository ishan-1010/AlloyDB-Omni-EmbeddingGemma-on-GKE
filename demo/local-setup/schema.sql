-- Mirrors the AlloyDB Omni codelab schema, but uses pgvector's HNSW
-- index instead of AlloyDB's ScaNN. Same <-> operator, same SQL idioms.

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE cymbal_products (
  product_id     TEXT PRIMARY KEY,
  description    TEXT NOT NULL,
  price          INT,
  store_location TEXT,
  embedding      vector(384)   -- 384 dims = all-MiniLM-L6-v2, a small CPU-friendly model
);

-- Index for fast nearest-neighbor search.
-- In the GKE codelab, AlloyDB Omni uses ScaNN; here pgvector uses HNSW.
-- Behaviour for a student audience is identical: sub-100ms vector search.
CREATE INDEX cymbal_products_embedding_idx
  ON cymbal_products
  USING hnsw (embedding vector_cosine_ops);

-- A twin table WITHOUT the HNSW index, so the "index matters" demo works:
CREATE TABLE cymbal_products_noindex (
  product_id     TEXT PRIMARY KEY,
  description    TEXT NOT NULL,
  price          INT,
  store_location TEXT,
  embedding      vector(384)
);

-- Pre-computed query embeddings. On GKE, students generate these live via
-- google_ml.embedding(); locally we pre-bake them so shadow demo is instant.
CREATE TABLE query_vectors (
  query_text TEXT PRIMARY KEY,
  embedding  vector(384)
);
