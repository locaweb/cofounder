# pg_cron — In-Database Job Scheduling

PostgreSQL extension that runs scheduled SQL commands inside the database using background workers. Jobs run as the user who scheduled them.

## Setup

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
```

For non-superuser roles, grant access:

```sql
GRANT USAGE ON SCHEMA cron TO my_role;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA cron TO my_role;
```

## Schedule a Job

```sql
SELECT cron.schedule(
  'nightly-cleanup',        -- job name (unique identifier)
  '0 3 * * *',              -- cron expression
  $$DELETE FROM logs WHERE created_at < now() - interval '30 days'$$
);
```

## Cron Expression Syntax

Five fields: `minute hour day_of_month month day_of_week`

| Expression | Schedule |
|---|---|
| `* * * * *` | Every minute |
| `*/5 * * * *` | Every 5 minutes |
| `0 * * * *` | Every hour |
| `0 0 * * *` | Daily at midnight |
| `0 2 * * 0` | Weekly on Sunday at 2 AM |
| `0 0 1 * *` | Monthly on the 1st at midnight |

Field ranges: minutes (0–59), hours (0–23), day of month (1–31), month (1–12), day of week (0–6, Sunday = 0).

## Common Patterns

Periodic cleanup:

```sql
SELECT cron.schedule(
  'purge-expired-sessions',
  '*/15 * * * *',
  $$DELETE FROM sessions WHERE expires_at < now()$$
);
```

Materialized view refresh:

```sql
SELECT cron.schedule(
  'refresh-dashboard-stats',
  '0 * * * *',
  $$REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard_stats$$
);
```

Vacuum a table:

```sql
SELECT cron.schedule(
  'vacuum-events',
  '0 4 * * *',
  $$VACUUM (ANALYZE) events$$
);
```

## Triggering Application Code via pg_net

`pg_net` is the recommended way to run scheduled application logic. Instead of container-level cron, schedule `pg_cron` jobs that fire HTTP requests to your app's endpoints using `pg_net`.

Setup:

```sql
CREATE EXTENSION IF NOT EXISTS pg_net;
```

### net.http_post

```sql
net.http_post(
  url text,
  body jsonb default '{}'::jsonb,
  params jsonb default '{}'::jsonb,
  headers jsonb default '{"Content-Type": "application/json"}'::jsonb,
  timeout_milliseconds int default 1000
) returns bigint  -- request ID
```

### net.http_get

```sql
net.http_get(
  url text,
  params jsonb default '{}'::jsonb,
  headers jsonb default '{}'::jsonb,
  timeout_milliseconds int default 1000
) returns bigint  -- request ID
```

Both functions are **asynchronous** — the HTTP request is dispatched by a background worker after the transaction commits. The return value is a request ID. Responses are stored in `net._http_response` for 6 hours.

### pg_cron + pg_net examples

Trigger a cleanup endpoint every 5 minutes:

```sql
SELECT cron.schedule(
  'periodic-cleanup',
  '*/5 * * * *',
  $$SELECT net.http_post('http://localhost/tasks/cleanup', '{}')$$
);
```

Trigger a daily report generation (offloaded to workers via pgmq):

```sql
SELECT cron.schedule(
  'daily-report',
  '0 3 * * *',
  $$SELECT net.http_post('http://localhost/tasks/daily-report', '{}')$$
);
```

Call an external webhook:

```sql
SELECT cron.schedule(
  'webhook-ping',
  '*/5 * * * *',
  $$SELECT net.http_post('https://example.com/webhook', '{"source": "myapp"}')$$
);
```

**Pattern: heavy scheduled work.** For resource-intensive tasks (large data processing, bulk emails, report generation), the pg_cron job should call a lightweight app endpoint that enqueues work to pgmq. Workers then pick up and execute the job, keeping the web VM free for request handling.

### Checking responses

```sql
SELECT * FROM net._http_response ORDER BY created DESC LIMIT 10;
```

Columns: `id`, `status_code`, `headers`, `body`, `timed_out`, `error_msg`, `created`.

## Manage Jobs

List all scheduled jobs:

```sql
SELECT * FROM cron.job;
```

Check execution history:

```sql
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
```

Remove a job:

```sql
SELECT cron.unschedule('nightly-cleanup');
```

## Notes

- Jobs execute using background workers and do not block normal database operations.
- Each job runs in its own transaction.
- Failed jobs are logged in `cron.job_run_details` with the error message.
- pg_cron runs in the database where the extension is installed — it cannot run commands in other databases.

Source: <https://github.com/citusdata/pg_cron>
