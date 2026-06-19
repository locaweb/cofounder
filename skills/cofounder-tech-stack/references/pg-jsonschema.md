# pg_jsonschema — JSON Schema Validation

PostgreSQL extension that validates `json` and `jsonb` values against JSON Schema documents (draft 2020-12 and earlier).

## Setup

```sql
CREATE EXTENSION pg_jsonschema;
```

## Core Functions

| Function | Description |
|---|---|
| `json_matches_schema(schema json, instance json)` | Validate a `json` value |
| `jsonb_matches_schema(schema json, instance jsonb)` | Validate a `jsonb` value |

Both return `boolean`.

## Basic Validation

```sql
SELECT json_matches_schema(
  '{"type": "object"}',
  '{}'
);
-- true

SELECT json_matches_schema(
  '{"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}',
  '{"age": 30}'
);
-- false (missing required "name")
```

## CHECK Constraint Pattern

The primary use case — enforce a JSON schema at the database level so invalid documents are rejected on insert/update:

```sql
CREATE TABLE customer (
  id SERIAL PRIMARY KEY,
  metadata jsonb,
  CHECK (
    jsonb_matches_schema(
      '{
        "type": "object",
        "properties": {
          "tags": {
            "type": "array",
            "items": {
              "type": "string",
              "maxLength": 16
            }
          }
        }
      }',
      metadata
    )
  )
);
```

Valid:

```sql
INSERT INTO customer (metadata) VALUES ('{"tags": ["vip", "darkmode-ui"]}');
-- OK
```

Invalid:

```sql
INSERT INTO customer (metadata) VALUES ('{"tags": [1, 3]}');
-- ERROR: new row for relation "customer" violates check constraint
```

## Storing Schemas in a Table

For reusable schemas, store them in a dedicated table and reference by name:

```sql
CREATE TABLE json_schemas (
  name TEXT PRIMARY KEY,
  schema JSON NOT NULL
);

INSERT INTO json_schemas (name, schema) VALUES (
  'customer_metadata',
  '{
    "type": "object",
    "properties": {
      "tags": {"type": "array", "items": {"type": "string"}}
    }
  }'
);
```

Then validate against stored schemas in application code or triggers.

Source: <https://github.com/supabase/pg_jsonschema>
