---
name: testing
description: Three-layer automated testing strategy for web applications. Defines coverage expectations for backend unit/integration tests, frontend component tests, and end-to-end browser tests. Use this skill after the first successful deployment to introduce systematic testing.
---

# Automated Testing

Introduce automated tests after the first successful deploy. This skill defines a three-layer testing strategy that catches bugs before they reach production.

## The Three Layers

| Layer | What it tests | Requires running services? |
|-------|--------------|---------------------------|
| 1. Backend unit/integration | Handlers, database queries, business logic | Database only |
| 2. Frontend components | UI logic, rendering, user interactions | Nothing — runs in simulated DOM |
| 3. E2E (browser) | Full user flows across frontend + backend | All services |

Each layer catches different classes of bugs. They complement each other — none replaces the others. Layers 1 and 2 run in seconds; layer 3 takes longer but tests what the user actually experiences.

## Running commands

All tool invocations must use `mise x --` so that the correct versions from `mise.toml` are used. This applies to every command in every layer — `mise x -- go test`, `mise x -- npx vitest`, `mise x -- npm run test`, etc. Never invoke `go`, `node`, `npm`, or `npx` directly.

## Setup Sequence

When the user agrees to add tests, set up all three layers in order. For each layer, look up the current recommended test runner and libraries for the project's language and framework, then configure accordingly. The sections below describe **what** to test and **how much** — not which specific library to use.

---

## Layer 1: Backend unit and integration tests

Go has a built-in test runner. Backend tests may already exist from the development phase. If not, set them up now.

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

Use the **webapp-testing** skill for Playwright setup, installation, and the persistent test suite structure. That skill covers installation, writing test scripts, shared fixtures with login helpers, the persistent test suite directory, and running the full suite.

### Coverage expectations

- **Every user-facing feature** gets a corresponding E2E test file.
- **Bug fixes** get a test that reproduces the bug (and now passes with the fix).
- **Tests accumulate** — old tests are never deleted when new features are added. The suite is a regression safety net.

### Cadence

E2E tests run on **feature completion**, not on every micro-edit. Between E2E runs, use Preview quick checks or manual browser checks to verify visual changes.

---

## Enforced Workflow

Once all three layers are set up, the development feedback loop changes. Tests become mandatory gates before every commit:

```
Write / Edit Code (including tests)
       │
       ▼
Layer 1: Backend Tests ──Fail──► Fix & repeat
       │
      Pass
       │
       ▼
Layer 2: Component Tests ──Fail──► Fix & repeat
       │
      Pass
       │
       ▼
Layer 3: E2E Tests ──Fail──► Fix & repeat
  (on feature completion)
       │
      Pass
       │
       ▼
Commit & push
```

- **Layers 1 + 2** run in seconds and gate every commit.
- **Layer 3** gates the commit that delivers a completed feature.
- Write tests as part of building the feature, not as an afterthought.
