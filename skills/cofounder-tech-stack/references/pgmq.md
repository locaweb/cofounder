# pgmq — Lightweight Message Queue

PostgreSQL extension that provides a durable, ACID-compliant message queue inside the database. Messages are stored in regular tables (prefixed `q_`) and archived messages in tables prefixed `a_`.

## Setup

```sql
CREATE EXTENSION pgmq;
```

## Create a Queue

```sql
SELECT pgmq.create('my_queue');
```

## Send Messages

Single message:

```sql
SELECT * FROM pgmq.send(
  queue_name => 'my_queue',
  msg => '{"foo": "bar"}'
);
-- Returns the message ID
```

With delay (invisible for N seconds):

```sql
SELECT * FROM pgmq.send(
  queue_name => 'my_queue',
  msg => '{"foo": "bar"}',
  delay => 5
);
```

Batch send:

```sql
SELECT pgmq.send_batch(
  queue_name => 'my_queue',
  msgs => ARRAY['{"a": 1}', '{"b": 2}', '{"c": 3}']::jsonb[]
);
```

## Read Messages

Read without removing. The visibility timeout (`vt`) hides messages from other consumers for the specified seconds, providing at-most-once delivery within that window. If the consumer doesn't delete/archive before the timeout, the message becomes visible again.

```sql
SELECT * FROM pgmq.read(
  queue_name => 'my_queue',
  vt => 30,
  qty => 2
);
```

Returns empty result if the queue is empty or all messages are currently invisible.

## Pop (Read + Delete)

Read and immediately delete in one atomic operation:

```sql
SELECT * FROM pgmq.pop('my_queue');
```

## Archive Messages

Move messages to the archive table instead of deleting them:

```sql
-- Single message
SELECT pgmq.archive(queue_name => 'my_queue', msg_id => 2);

-- Multiple messages
SELECT pgmq.archive(queue_name => 'my_queue', msg_ids => ARRAY[3, 4, 5]);
```

Query archived messages:

```sql
SELECT * FROM pgmq.a_my_queue;
```

## Delete Messages

Permanently remove a message (no archive):

```sql
SELECT pgmq.delete('my_queue', 6);
```

## Drop a Queue

Remove the queue and all its messages:

```sql
SELECT pgmq.drop_queue('my_queue');
```

## Typical Consumer Pattern

```sql
-- 1. Read a batch with visibility timeout
SELECT * FROM pgmq.read('tasks', vt => 60, qty => 1);

-- 2. Process the message in application code

-- 3a. On success: archive (or delete)
SELECT pgmq.archive('tasks', msg_id => 42);

-- 3b. On failure: message automatically becomes visible again after VT expires
```

Source: <https://github.com/pgmq/pgmq>
