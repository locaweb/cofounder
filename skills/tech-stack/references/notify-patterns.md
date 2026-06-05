# LISTEN/NOTIFY + Persistence Patterns

Native `LISTEN`/`NOTIFY` delivers real-time notifications but is **not durable** — if no listener is connected, the message is lost. When durability matters, combine it with a persistence layer so consumers can recover missed events.

## Core idea

| Layer | Role |
|---|---|
| `NOTIFY` | Real-time push — instant wake-up for connected listeners |
| Persistence (pgmq, regular table, etc.) | Durable record — survives missed notifications |
| Polling | Fallback — catches anything the listener missed |

`NOTIFY` is an **optimization**, not a delivery guarantee. The persistence layer is the source of truth.

## Pattern 1: pgmq + NOTIFY

Use when consumers need to **process jobs** reliably (task queues, background work).

### Producer

```sql
BEGIN;

SELECT pgmq.send(
    queue_name => 'jobs',
    msg        => '{"job_id": 123}'
);

NOTIFY jobs_channel;

COMMIT;
```

Both the enqueue and the notification are in the same transaction — if it rolls back, neither happens.

### Consumer

1. `LISTEN jobs_channel`
2. When notified → read the queue
3. If no notification arrives → periodic polling fallback (e.g., every 30 s)

```sql
SELECT *
FROM pgmq.read(
    queue_name => 'jobs',
    vt         => 30,
    qty        => 10
);
```

After processing, archive or delete:

```sql
SELECT pgmq.archive('jobs', msg_id => 42);
```

## Pattern 2: Table update + NOTIFY

Use when the consumer just needs **fresh data** (live dashboards, page updates, cache invalidation).

### Producer

```sql
BEGIN;

UPDATE orders SET status = 'shipped' WHERE id = 456;

NOTIFY orders_channel, '456';

COMMIT;
```

### Consumer

- Connected listener receives the notification and refreshes instantly.
- If the notification is missed (disconnect, deploy, etc.), the next page load or periodic refresh reads the updated row — no data is lost because the table **is** the persistence layer.

No queue needed here — the regular table already holds the durable state.

## When to use which

| Scenario | Persistence layer | Why |
|---|---|---|
| Background jobs, task processing | pgmq | Need reliable delivery, visibility timeout, retry semantics |
| Live UI updates, dashboards | Regular table | Data is already persisted; notification is just an optimization for instant push |
| Cache invalidation | None (NOTIFY only may suffice) | Stale cache is tolerable; next read rebuilds it anyway |
