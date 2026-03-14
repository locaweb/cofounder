---
name: webapp-testing
description: Toolkit for interacting with and testing local web applications using Playwright. Supports verifying frontend functionality, debugging UI behavior, capturing browser screenshots, and viewing browser logs.
---

# Web Application Testing

> **Windows:** Do NOT use Claude Desktop Preview servers based on `launch.json` file on Windows. Always use Playwright scripts (described below) for visual verification and testing instead.

Test local web applications by writing native Python Playwright scripts.

## Prerequisites

Before running tests, ensure all services are running — database containers, Go backend, and Vite dev server. Start them using the **tech-stack** skill's **Local Development** section (steps 1–3).

## Writing Playwright Scripts

Every script follows the same lifecycle: start Playwright → launch a headless browser → open a page → navigate → wait for the app to load → perform actions → close the browser. Example:

```python
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    page.goto('http://localhost:5173')
    page.wait_for_load_state('networkidle')  # Wait for JS to finish
    # ... test logic here
    browser.close()
```

## Reconnaissance-Then-Action Pattern

Never assume what's on the page — always inspect first, then act.

1. **Inspect the rendered DOM** using one or more of these techniques:
   ```python
   page.screenshot(path='/tmp/inspect.png', full_page=True)  # Visual snapshot
   content = page.content()                                    # Raw HTML
   page.locator('button').all()                                # List matching elements
   ```

2. **Identify selectors** from the inspection results

3. **Execute actions** using the discovered selectors

## Common Pitfalls

- **Don't** inspect the DOM before waiting for `networkidle` on dynamic apps
- **Do** wait for `page.wait_for_load_state('networkidle')` before inspection
- **Don't** assume the default Vite port (5173) is available. If another dev server is already using the port, Vite silently picks the next one (5174, 5175, …). Always check the Vite startup output for the actual `Local:` URL before writing test scripts.

## Installing Playwright

Create a virtualenv first, then install Playwright inside it:

```bash
# macOS/Linux:
mise x -- python -m venv .venv
.venv/bin/pip install playwright
.venv/bin/python -m playwright install chromium
```

Run Playwright scripts using the venv python:

```bash
# macOS/Linux:
.venv/bin/python your_test.py
```

**Windows note:** Use `.venv\Scripts\` paths instead:

```powershell
mise x -- python -m venv .venv
.venv\Scripts\pip.exe install playwright
.venv\Scripts\python.exe -m playwright install chromium
.venv\Scripts\python.exe your_test.py
```

## Authenticating in Tests

Many app features are behind a login wall. Magic link and Google Auth flows cannot be completed in automated tests, so the backend provides a **dev-only login endpoint** (`POST /api/dev/login`) when running locally with `DEV_MODE=1`. See the **tech-stack** skill for the backend design.

In Playwright scripts, call the dev login endpoint using `page.request.post()` before navigating to authenticated pages. Because this method shares the browser context's cookie jar, the session cookie is automatically available for all subsequent navigations.

In Claude Desktop Preview, use `preview_click` to submit the login form through the UI — either a dev-mode login shortcut (if the app renders one when `DEV_MODE=1`) or the regular login form with the test user credentials.

## Persistent Test Suite

E2E tests are not throwaway scripts — they accumulate into a regression suite that runs before every commit. This prevents features from breaking as the app evolves.

### Structure

Organize tests in `tests/e2e/`, one file per user flow:

```
tests/
└── e2e/
    ├── conftest.py          # Shared fixtures (browser, auth, base URL)
    ├── test_login.py        # Login / authentication flow
    ├── test_create_todo.py  # Creating a todo item
    ├── test_dashboard.py    # Dashboard loads with correct data
    └── ...
```

### Shared fixtures

Create a shared module (`conftest.py`) with reusable helpers to avoid duplication across test files. It should encapsulate:

- **Browser lifecycle** — start/stop Playwright and the browser in one place (e.g., a context manager or setup/teardown pair).
- **Dev login helper** — call the `POST /api/dev/login` endpoint to authenticate (see "Authenticating in Tests" above).
- **Navigation helper** — go to a path and wait for the page to load.

Every test file imports from this module rather than repeating setup logic.

### Writing test files

Each test file covers one user flow. Tests should be independent — they must not depend on state left by other test files. The pattern for each test is: authenticate → navigate to the relevant page → perform actions → assert on visible results.

### Running the full suite

Run all E2E test files sequentially before committing a completed feature. Stop on the first failure and fix it before proceeding.

### When to add new tests

- **Every new user-facing feature** gets a corresponding test file.
- **Bug fixes** get a test that reproduces the bug (and now passes).
- **Never delete old tests** when adding new features — the suite is cumulative.
- **Keep tests fast** — each file should complete in under 10 seconds. If a test is slow, check for unnecessary waits.

## Best Practices

- Always close the browser when done — use a context manager or try/finally.
- Prefer descriptive selectors: visible text, ARIA roles, or `data-testid` attributes. Avoid fragile selectors tied to CSS class names or DOM structure.
- Add `data-testid` attributes to key interactive elements in React components to make selectors stable across UI changes.
- Add appropriate waits before asserting — wait for specific elements to appear rather than using fixed timeouts.

## Reference Files

- **examples/** - Examples showing common patterns:
  - `element_discovery.py` - Discovering buttons, links, and inputs on a page
  - `static_html_automation.py` - Using file:// URLs for local HTML
  - `console_logging.py` - Capturing console logs during automation
