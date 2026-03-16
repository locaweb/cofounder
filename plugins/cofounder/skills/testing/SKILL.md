---
name: testing
description: Three-layer automated testing strategy for Go + React web applications. Covers backend unit/integration tests (Go), frontend component tests (Vitest), and end-to-end browser tests (Playwright via npx). Tests are written in tandem with application code — every handler gets a test file, every interactive component gets a test file, every completed feature gets an E2E test. Use this skill whenever the user asks to test, run tests, add tests, or verify the application.
---

# Automated Testing

Tests are written **in tandem with the code they verify** — not as an afterthought, not deferred to a later milestone. When you create a handler, create its test file. When you create an interactive component, create its test file. When you complete a feature, write its E2E test. This keeps tests and code in sync and prevents coverage drift.

## The Three Layers

| Layer | What it tests | Requires running services? |
|-------|--------------|---------------------------|
| 1. Backend unit/integration | Handlers, database queries, business logic | Database only |
| 2. Frontend components | UI logic, rendering, user interactions | Nothing — runs in simulated DOM |
| 3. E2E (browser) | Full user flows across frontend + backend | All services |

Each layer catches different classes of bugs. They complement each other — none replaces the others. Layers 1 and 2 run in seconds; layer 3 takes longer but tests what the user actually experiences.

## Running commands

All tool invocations must use `mise x --` so that the correct versions from `mise.toml` are used. This applies to every command in every layer — `mise x -- go test`, `mise x -- npx vitest`, `mise x -- npx playwright test`, etc. Never invoke `go`, `node`, `npm`, or `npx` directly.

## Setup Sequence

When starting a new project, set up all three layers as the first features are being built. For each layer, look up the current recommended test runner and libraries for the project's language and framework, then configure accordingly. The sections below describe **what** to test and **how much** — not which specific library to use.

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
3. Add `data-testid` attributes to key interactive elements for stable selectors (also benefits E2E tests).

---

## Layer 3: E2E tests (browser)

Full end-to-end tests that exercise real user flows through the browser. These require all services running (database, backend, frontend dev server).

### Playwright via npx

Since the frontend is already React/Vite, use Playwright through `npx` (`@playwright/test`) — same JS runtime, same `package.json`, no separate Python virtualenv needed. Install as a dev dependency in the frontend directory, add a config at the project root pointing `testDir` to `tests/e2e/`, and run with `mise x -- npx playwright test`.

### Test suite structure

Organize tests in `tests/e2e/`, one file per user flow (e.g., `login.spec.ts`, `create-todo.spec.ts`, `dashboard.spec.ts`).

### Auth in tests

Create a shared auth setup that calls the `POST /api/dev/login` endpoint and saves browser state for reuse across tests. This avoids repeating login logic in every spec file. Look up Playwright's current recommended pattern for shared authentication state.

### Writing test files

Each test file covers one user flow. Tests must be independent — no shared state between files. The pattern: authenticate → navigate → perform actions → assert on visible results.

### Principles

- Wait for the app to fully load before asserting (SPAs need `networkidle` or equivalent).
- Don't assume the default Vite port (5173) — check the Vite startup output for the actual URL.
- Prefer descriptive selectors: visible text, ARIA roles, or `data-testid` attributes. Avoid fragile selectors tied to CSS class names or DOM structure.
- Add `data-testid` attributes to key interactive elements in React components for stable selectors.

### Coverage expectations

- **Every user-facing feature** gets a corresponding E2E test file.
- **Bug fixes** get a test that reproduces the bug (and now passes with the fix).
- **Tests accumulate** — old tests are not deleted when new features are added. The suite is a regression safety net. Delete a test only when its corresponding handler, component, or feature is removed.

### Cadence

E2E tests run on **feature completion**, not on every micro-edit. Between E2E runs, use Preview quick checks or manual browser checks to verify visual changes.

---

## Coverage Catch-Up

Features may have been added in previous sessions without corresponding tests. After running the full test suite, scan for coverage gaps:

1. **Backend:** List all handler files in `backend/` and check each one has a corresponding `_test.go` file. Flag any handler without tests (except trivial ones like health checks).
2. **Frontend:** List all components with non-trivial logic (conditional rendering, form handling, event handlers) and check each one has a corresponding `.test.tsx` file.
3. **E2E:** Compare the features listed in `docs/PRD.md` against the E2E test files in the `tests/` directory. Flag any user-facing feature without an E2E test.

If gaps are found, report them to the user and offer to add the missing tests. Do not silently skip untested features — the whole point of the test suite is to be a regression safety net, and gaps undermine that.

