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

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)  # Always launch chromium in headless mode
    page = browser.new_page()
    page.goto('http://localhost:5173')  # Server already running and ready
    page.wait_for_load_state('networkidle')  # CRITICAL: Wait for JS to execute
    # ... your test logic
    browser.close()
```

## Reconnaissance-Then-Action Pattern

1. **Inspect rendered DOM**:
   ```python
   page.screenshot(path='/tmp/inspect.png', full_page=True)
   content = page.content()
   page.locator('button').all()
   ```

2. **Identify selectors** from inspection results

3. **Execute actions** using discovered selectors

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

### Shared fixtures (`conftest.py`)

Create a `conftest.py` with reusable helpers to avoid duplication across test files:

```python
from playwright.sync_api import sync_playwright

class AppFixture:
    """Shared test fixture for E2E tests."""

    def __init__(self, base_url='http://localhost:5173'):
        self.base_url = base_url
        self._pw = None
        self._browser = None

    def __enter__(self):
        self._pw = sync_playwright().start()
        self._browser = self._pw.chromium.launch(headless=True)
        self.page = self._browser.new_page()
        return self

    def __exit__(self, *args):
        self._browser.close()
        self._pw.stop()

    def login(self, email='test@example.com'):
        """Authenticate via dev login endpoint."""
        self.page.request.post(
            f'{self.base_url}/api/dev/login',
            data={'email': email}
        )

    def goto(self, path='/'):
        """Navigate to a page and wait for it to load."""
        self.page.goto(f'{self.base_url}{path}')
        self.page.wait_for_load_state('networkidle')
```

### Writing test files

Each test file covers one user flow. Tests should be independent — they must not depend on state left by other test files:

```python
#!/usr/bin/env python3
"""E2E test: creating a todo item."""
import sys
sys.path.insert(0, '.')
from tests.e2e.conftest import AppFixture

def test_create_todo():
    with AppFixture() as app:
        app.login()
        app.goto('/todos')

        app.page.fill('[data-testid="new-todo-input"]', 'Buy milk')
        app.page.click('[data-testid="add-todo-button"]')
        app.page.wait_for_selector('text=Buy milk')

        assert app.page.locator('text=Buy milk').is_visible()
        print('PASS: test_create_todo')

if __name__ == '__main__':
    test_create_todo()
```

### Running the full suite

Run all E2E tests before committing a completed feature:

```bash
bash -c 'for f in tests/e2e/test_*.py; do .venv/bin/python "$f" || exit 1; done'
```

This runs every test file in sequence and stops at the first failure. Fix failures before committing.

### When to add new tests

- **Every new user-facing feature** gets a corresponding `test_*.py` file.
- **Bug fixes** get a test that reproduces the bug (and now passes).
- **Never delete old tests** when adding new features — the suite is cumulative.
- **Keep tests fast** — each file should complete in under 10 seconds. If a test is slow, check for unnecessary waits.

## Best Practices

- Use `sync_playwright()` for synchronous scripts
- Always close the browser when done
- Use descriptive selectors: `text=`, `role=`, CSS selectors, or IDs
- Add appropriate waits: `page.wait_for_selector()` or `page.wait_for_timeout()`
- Add `data-testid` attributes to key interactive elements in React components to make selectors stable

## Reference Files

- **examples/** - Examples showing common patterns:
  - `element_discovery.py` - Discovering buttons, links, and inputs on a page
  - `static_html_automation.py` - Using file:// URLs for local HTML
  - `console_logging.py` - Capturing console logs during automation
