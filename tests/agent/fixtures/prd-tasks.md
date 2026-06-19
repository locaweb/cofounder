# PRD — Tarefas (lista de tarefas)

Fixed fixture for the E2E test. Deliberately tiny so the scaffold is reproducible
while still exercising the full stack (migration → sqlc → handler+test → React
component+test).

## O que é

Um app simples de lista de tarefas: o usuário vê suas tarefas, adiciona novas,
marca como concluídas e remove.

## Entidade

**Task**
- `id` — UUID, gerado pelo banco
- `title` — texto, obrigatório, não vazio
- `done` — booleano, padrão `false`
- `created_at` — timestamp, padrão agora

## API (JSON)

- `GET /api/tasks` — lista as tarefas (mais recentes primeiro)
- `POST /api/tasks` — cria uma tarefa a partir de `{ "title": "..." }`
- `PATCH /api/tasks/{id}` — alterna o campo `done`
- `DELETE /api/tasks/{id}` — remove a tarefa
- `GET /up` — health check (já exigido pela plataforma)

## Frontend

Uma única página que:
- lista as tarefas
- tem um campo de texto + botão para adicionar
- permite marcar/desmarcar cada tarefa (checkbox)
- permite remover cada tarefa

Mantenha o escopo exatamente neste conjunto — sem autenticação, sem outras telas.
