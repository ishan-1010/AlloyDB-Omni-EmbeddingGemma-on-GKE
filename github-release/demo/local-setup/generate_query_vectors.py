#!/usr/bin/env python3
"""
Pre-computes embeddings for the natural-language queries you'll run on stage.
Appends INSERTs to seed.sql (or writes a small query_vectors.sql you load after).

Add new queries here before the session — students can't come up with surprises
live because your shadow demo depends on pre-baked query vectors.
"""

import sys
from pathlib import Path

try:
    from sentence_transformers import SentenceTransformer
except ImportError:
    sys.exit("pip install sentence-transformers first")

HERE = Path(__file__).parent
OUT_PATH = HERE / "query_vectors.sql"
MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"

# Edit this list to add/remove stage queries:
QUERIES = [
    "fruit trees for hot weather",
    "low maintenance plant for a small balcony",
    "plants that survive Delhi pollution",
    "something colourful for a monsoon garden",
    "easy indoor plant for a beginner",
    "medicinal plant for the home",
    "flowers for a temple or festival",
    "plant that needs very little water",
]


def vec_literal(values):
    return "[" + ",".join(f"{v:.6f}" for v in values) + "]"


def main():
    print(f"loading model {MODEL_NAME}…")
    model = SentenceTransformer(MODEL_NAME)

    print(f"encoding {len(QUERIES)} query phrases…")
    vectors = model.encode(QUERIES, show_progress_bar=False, normalize_embeddings=True)

    print(f"writing {OUT_PATH}…")
    with OUT_PATH.open("w") as out:
        out.write("-- Pre-computed embeddings for stage queries.\n")
        out.write("-- Load after seed.sql:  psql … -f query_vectors.sql\n\n")
        out.write("BEGIN;\n")
        out.write("TRUNCATE TABLE query_vectors;\n\n")
        for text, vec in zip(QUERIES, vectors):
            esc = text.replace("'", "''")
            out.write(
                "INSERT INTO query_vectors (query_text, embedding) VALUES ("
                f"'{esc}', '{vec_literal(vec)}');\n"
            )
        out.write("\nCOMMIT;\n")

    print(f"done. {len(QUERIES)} queries written.")
    print("apply with:  docker exec -i cymbal-pgvector "
          "psql -U cymbal -d cymbal < query_vectors.sql")


if __name__ == "__main__":
    main()
