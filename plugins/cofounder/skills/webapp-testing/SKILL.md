---
name: webapp-testing
description: Toolkit for interacting with and testing local web applications using Playwright. Supports verifying frontend functionality, debugging UI behavior, capturing browser screenshots, and viewing browser logs.
---

# Web Application Testing

> **Windows:** Do not use the Preview tool on Windows. Always use Playwright scripts (described below) for visual verification and testing instead.

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

## Best Practices

- Use `sync_playwright()` for synchronous scripts
- Always close the browser when done
- Use descriptive selectors: `text=`, `role=`, CSS selectors, or IDs
- Add appropriate waits: `page.wait_for_selector()` or `page.wait_for_timeout()`

## Reference Files

- **examples/** - Examples showing common patterns:
  - `element_discovery.py` - Discovering buttons, links, and inputs on a page
  - `static_html_automation.py` - Using file:// URLs for local HTML
  - `console_logging.py` - Capturing console logs during automation
