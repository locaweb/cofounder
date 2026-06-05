# PGroonga — Full-Text Search for All Languages

PostgreSQL extension that provides fast full-text search using the Groonga engine. Unlike PostgreSQL's built-in `tsvector`/`tsquery` (which requires language-specific dictionaries), PGroonga supports all languages including CJK (Chinese, Japanese, Korean) out of the box with no configuration.

## Setup

```sql
CREATE EXTENSION IF NOT EXISTS pgroonga;
```

## Create a Search Index

```sql
CREATE INDEX idx_memos_content ON memos USING pgroonga (content);
```

Multiple columns can be indexed:

```sql
CREATE INDEX idx_memos_search ON memos USING pgroonga (title, content);
```

## Search Operators

### `&@` — Single Keyword Match

```sql
SELECT * FROM memos WHERE content &@ 'database';
```

### `&@~` — Query Syntax (Boolean Logic)

```sql
-- OR search
SELECT * FROM memos WHERE content &@~ 'PGroonga OR PostgreSQL';

-- AND search (default when space-separated)
SELECT * FROM memos WHERE content &@~ 'full text search';

-- NOT
SELECT * FROM memos WHERE content &@~ 'PostgreSQL -MySQL';
```

### `LIKE` Compatibility

PGroonga accelerates existing `LIKE` queries — no query changes needed:

```sql
SELECT * FROM memos WHERE content LIKE '%engine%';
```

Note: `LIKE` through PGroonga is slower than native operators due to recheck overhead. Prefer `&@` or `&@~` for new code.

## Relevance Ranking

```sql
SELECT *, pgroonga_score(tableoid, ctid) AS score
FROM memos
WHERE content &@ 'keyword'
ORDER BY score DESC;
```

## Highlighting Search Terms

```sql
SELECT pgroonga_highlight_html(content, pgroonga_query_extract_keywords('search term'))
FROM memos
WHERE content &@~ 'search term';
```

## Snippets (KWIC — Keyword in Context)

```sql
SELECT pgroonga_snippet_html(content, pgroonga_query_extract_keywords('search term'))
FROM memos
WHERE content &@~ 'search term';
```

## JSONB Search

PGroonga can index and search inside JSONB columns:

```sql
CREATE INDEX idx_docs_metadata ON docs USING pgroonga (metadata);

-- Containment
SELECT * FROM docs WHERE metadata @> '{"category": "tech"}'::jsonb;

-- Full-text search inside JSONB
SELECT * FROM docs WHERE metadata &@ 'keyword';
```

## When to Use PGroonga vs tsvector/tsquery

| Feature | `tsvector`/`tsquery` | PGroonga |
|---|---|---|
| Language support | Needs dictionaries per language | All languages, including CJK |
| Query syntax | Custom (`& | !`) | Familiar (`AND OR NOT`) |
| Relevance ranking | `ts_rank()` | `pgroonga_score()` |
| Highlighting | `ts_headline()` | `pgroonga_highlight_html()` |
| JSONB search | No | Yes |

PGroonga works well for all languages. It adds particularly strong support for CJK and other languages where `tsvector`/`tsquery` requires manual dictionary configuration or produces poor results.

## sqlc Integration

All SQL lives in `backend/internal/database/queries/*.sql` and is generated via `sqlc generate`. PGroonga operators (`&@`, `&@~`) work in sqlc query files like any other operator.

```sql
-- name: SearchMemos :many
SELECT id, title, content, pgroonga_score(tableoid, ctid) AS score
FROM memos
WHERE content &@~ @query
ORDER BY score DESC
LIMIT @max_results;
```

```sql
-- name: SearchMemosWithHighlight :many
SELECT id, title,
       pgroonga_highlight_html(content, pgroonga_query_extract_keywords(@query)) AS content_highlighted,
       pgroonga_score(tableoid, ctid) AS score
FROM memos
WHERE content &@~ @query
ORDER BY score DESC
LIMIT @max_results;
```

The migration that creates the PGroonga index goes in `backend/internal/database/migrations/` alongside other migration files:

```sql
-- NNN_add_search_index.sql
CREATE EXTENSION IF NOT EXISTS pgroonga;
CREATE INDEX IF NOT EXISTS idx_memos_search ON memos USING pgroonga (title, content);
```

Source: <https://pgroonga.github.io/>
