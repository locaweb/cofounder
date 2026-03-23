---
name: testing
description: Two-layer automated testing strategy for Go + React web applications. Covers backend unit/integration tests (Go) and frontend component tests (Vitest). Tests are written in tandem with application code — every handler gets a test file, every interactive component gets a test file. Use this skill whenever the user asks to test, run tests, add tests, or verify the application.
---

# Automated Testing

Tests are written **in tandem with the code they verify** — not as an afterthought, not deferred to a later milestone. When you create a handler, create its test file. When you create an interactive component, create its test file. This keeps tests and code in sync and prevents coverage drift.

## The Two Layers

| Layer | What it tests | Requires running services? |
|-------|--------------|---------------------------|
| 1. Backend unit/integration | Handlers, database queries, business logic | Database only |
| 2. Frontend components | UI logic, rendering, user interactions | Nothing — runs in simulated DOM |

Layer 1 tests the API contract against a real database. Layer 2 tests UI logic, rendering, and user interactions with mocked API calls. Together they cover the full stack — backend correctness and frontend behavior — while running in seconds.

## Running commands

All tool invocations must use `mise x --` so that the correct versions from `mise.toml` are used. This applies to every command in every layer — `mise x -- go test`, `mise x -- npx vitest`, etc. Never invoke `go`, `node`, `npm`, or `npx` directly.

## Setup Sequence

When starting a new project, set up both layers as the first features are being built. For each layer, look up the current recommended test runner and libraries for the project's language and framework, then configure accordingly. The sections below describe **what** to test and **how much** — not which specific library to use.

---

## Layer 1: Backend unit and integration tests

Go has a built-in test runner.

### Coverage expectations

- **Every handler** gets at least one test covering the happy path.
- **Database-touching code** gets integration tests that run against the real local database — not mocks. Use a test helper that runs migrations and wraps each test in a transaction that rolls back.
- **HTTP handlers** are tested by sending real HTTP requests to a test server and asserting on status codes and response bodies.
- Use table-driven tests. Each test case gets a descriptive name.

### Colocated test files

Test files live next to the code they test. For example, `handler/todo_test.go` tests `handler/todo.go`. When creating a new handler file, immediately create the corresponding test file.

### Retrofitting tests to an existing codebase

1. List all handler files that don't have a corresponding test file.
2. Create a test file for each, starting with handlers that touch the database or have complex logic.
3. Simple pass-through handlers (e.g., health check returning 200) can be skipped.

---

## Layer 2: Frontend component tests

Component tests render individual React components in a simulated DOM, simulate user interactions, and assert on visible output. They catch UI logic bugs — conditional rendering, form validation, state management — without needing a running backend.

### Coverage expectations

- **Components with non-trivial logic** (conditional rendering, form handling, computed state, event handlers) get tests.
- **Pure presentational components** that just render props without logic do not need tests.
- **Pages that are layout wrappers** or only compose other already-tested components do not need their own tests.

### Principles

- **Test behavior, not implementation.** Render the component → simulate what a user would do (click, type, submit) → assert on what the user would see. Don't assert on internal state or implementation details.
- **Mock external dependencies.** API calls, router context, and other services should be mocked so component tests run without a backend.
- **Colocated test files.** Test files live next to the component they test (e.g., `TodoList.test.tsx` next to `TodoList.tsx`).

Example — the kind of test to write for a component with interactive logic:

```typescript
// Render with props → simulate a click → assert visible result changed
test('marks a todo as complete when clicked', async () => {
  render(<TodoList items={[{ id: 1, text: 'Buy milk', done: false }]} />)
  await user.click(screen.getByText('Buy milk'))
  expect(screen.getByText('Buy milk')).toHaveClass('completed')
})
```

The specific API depends on the test runner and testing library in use. The pattern — render, act, assert on visible output — is universal.

### Setup

Choose a test runner compatible with the frontend framework (e.g., Vitest for Vite-based projects) and a DOM testing library that encourages testing from the user's perspective. Configure a simulated DOM environment (jsdom or similar) and add a `test` script to `package.json`. Look up the current recommended setup for the project's toolchain.

### Retrofitting tests to existing components

1. Identify components with non-trivial logic.
2. Create test files for those components first.
3. Add `data-testid` attributes to key interactive elements for stable selectors.

### TypeScript type check — required before every commit

Vite's dev server skips type checking for speed, but the production build (`tsc -b && vite build`) does not — so errors like unused imports, type mismatches, or config file issues will only surface at deploy time unless caught locally. **Always run the TypeScript compiler before committing:**

```bash
bash -c 'cd frontend && mise x -- npx tsc -b'
```

---

## Coverage Catch-Up

Features may have been added in previous sessions without corresponding tests. After running the full test suite, scan for coverage gaps:

1. **Backend:** List all handler files in `backend/` and check each one has a corresponding `_test.go` file. Flag any handler without tests (except trivial ones like health checks).
2. **Frontend:** List all components with non-trivial logic (conditional rendering, form handling, event handlers) and check each one has a corresponding `.test.tsx` file.

If gaps are found, report them to the user and offer to add the missing tests. Do not silently skip untested features — the whole point of the test suite is to be a regression safety net, and gaps undermine that.

