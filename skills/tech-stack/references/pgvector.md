# pgvector — Vector Similarity Search

PostgreSQL extension for storing embeddings and performing similarity search. Supports exact and approximate nearest-neighbor queries.

## Setup

```sql
CREATE EXTENSION vector;
```

## Create a Table with Vectors

Specify the number of dimensions (must match your embedding model):

```sql
CREATE TABLE items (
  id BIGSERIAL PRIMARY KEY,
  embedding VECTOR(1536)  -- e.g., OpenAI text-embedding-3-small
);
```

## Insert Vectors

```sql
INSERT INTO items (embedding) VALUES ('[0.1, 0.2, 0.3, ...]');
```

Upsert:

```sql
INSERT INTO items (id, embedding) VALUES (1, '[0.1, 0.2, 0.3]')
  ON CONFLICT (id) DO UPDATE SET embedding = EXCLUDED.embedding;
```

## Distance Operators

| Operator | Distance Metric | Use Case |
|---|---|---|
| `<->` | L2 (Euclidean) | General purpose |
| `<=>` | Cosine | Normalized embeddings |
| `<#>` | Negative inner product | When embeddings are not normalized |
| `<+>` | L1 (Manhattan) | Sparse data |

## Similarity Queries

Nearest neighbors by L2 distance:

```sql
SELECT * FROM items ORDER BY embedding <-> '[0.1, 0.2, 0.3]' LIMIT 5;
```

Cosine similarity (convert distance to similarity):

```sql
SELECT *, 1 - (embedding <=> '[0.1, 0.2, 0.3]') AS similarity
FROM items
ORDER BY embedding <=> '[0.1, 0.2, 0.3]'
LIMIT 5;
```

Filter by distance threshold:

```sql
SELECT * FROM items WHERE embedding <-> '[0.1, 0.2, 0.3]' < 0.5;
```

Find similar to an existing row:

```sql
SELECT * FROM items
WHERE id != 1
ORDER BY embedding <-> (SELECT embedding FROM items WHERE id = 1)
LIMIT 5;
```

## Indexing

Without an index, queries perform exact (brute-force) search. For large datasets, create an approximate nearest-neighbor (ANN) index.

### HNSW (Recommended Default)

Better query performance, no training step, supports concurrent inserts during build:

```sql
CREATE INDEX ON items USING hnsw (embedding vector_l2_ops);
```

Operator classes by distance metric:

| Distance | Operator Class |
|---|---|
| L2 | `vector_l2_ops` |
| Cosine | `vector_cosine_ops` |
| Inner product | `vector_ip_ops` |
| L1 | `vector_l1_ops` |

Tuning parameters:

```sql
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);
```

- `m` — Max connections per layer (default 16). Higher = better recall, more memory.
- `ef_construction` — Candidate list size during build (default 64). Higher = better recall, slower build.

Query-time recall tuning:

```sql
SET hnsw.ef_search = 100;  -- default 40, higher = better recall, slower query
```

### IVFFlat

Faster to build, lower memory, but requires data to already be present (trains on existing rows):

```sql
CREATE INDEX ON items USING ivfflat (embedding vector_l2_ops) WITH (lists = 100);
```

Rule of thumb for `lists`: `rows / 1000` for up to 1M rows, `sqrt(rows)` for more.

Query-time tuning:

```sql
SET ivfflat.probes = 10;  -- default 1, higher = better recall, slower query
```

## Performance Tips

- Set `maintenance_work_mem` high for index builds: `SET maintenance_work_mem = '4 GB';`
- Use parallel workers for faster builds: `SET max_parallel_maintenance_workers = 7;`
- Monitor index build progress: `SELECT phase, round(100.0 * blocks_done / nullif(blocks_total, 0), 1) AS "%" FROM pg_stat_progress_create_index;`
- For filtered queries, add a B-tree index on the filter column too.
- Partial indexes for frequent filter values: `CREATE INDEX ON items USING hnsw (embedding vector_l2_ops) WHERE (category_id = 123);`

## Vector Types

| Type | Description | Max Dimensions |
|---|---|---|
| `vector` | 32-bit float | 2,000 |
| `halfvec` | 16-bit float (less memory) | 4,000 |
| `bit` | Binary (Hamming/Jaccard) | 64,000 |
| `sparsevec` | Sparse (only stores non-zero) | varies |

Source: <https://github.com/pgvector/pgvector>
