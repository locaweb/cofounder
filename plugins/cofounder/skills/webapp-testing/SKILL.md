---
name: webapp-testing
description: Toolkit for interacting with and testing local web applications using Playwright. Supports verifying frontend functionality, debugging UI behavior, capturing browser screenshots, and viewing browser logs.
---

# Web Application Testing

> **Windows:** Do not use the Preview tool on Windows. Always use Playwright scripts (described below) for visual verification and testing instead.

To test local web applications, write native Python Playwright scripts.

**Helper Scripts Available**:
- `scripts/with_server.py` - Manages server lifecycle (supports multiple servers)

**Always run scripts with `--help` first** to see usage. DO NOT read the source until you try running the script first and find that a customized solution is abslutely necessary. These scripts can be very large and thus pollute your context window. They exist to be called directly as black-box scripts rather than ingested into your context window.

## Decision Tree: Choosing Your Approach

```
User task → Is it static HTML?
    ├─ Yes → Read HTML file directly to identify selectors
    │         ├─ Success → Write Playwright script using selectors
    │         └─ Fails/Incomplete → Treat as dynamic (below)
    │
    └─ No (dynamic webapp) → Is the server already running?
        ├─ No → Run: python scripts/with_server.py --help
        │        Then use the helper + write simplified Playwright script
        │
        └─ Yes → Reconnaissance-then-action:
            1. Navigate and wait for networkidle
            2. Take screenshot or inspect DOM
            3. Identify selectors from rendered state
            4. Execute actions with discovered selectors
```

## Example: Using with_server.py

To start a server, run `--help` first, then use the helper:

**Single server:**
```bash
mise x -- python scripts/with_server.py --server "mise x -- npm run dev" --port 5173 -- mise x -- python your_automation.py
```

**Multiple servers (e.g., backend + frontend):**
```bash
mise x -- python scripts/with_server.py \
  --server "cd backend && mise x -- python server.py" --port 3000 \
  --server "cd frontend && mise x -- npm run dev" --port 5173 \
  -- mise x -- python your_automation.py
```

#### Including accessories

If the app depends on accessories beyond the database, start them in the `with_server.py` invocation. Use `podman start` (not `podman run`) — the containers should already exist from the Local Services setup:

```bash
mise x -- python scripts/with_server.py \
  --server "podman start $(basename $(pwd))-db || true" --port 5432 \
  --server "podman start $(basename $(pwd))-redis || true" --port 6379 \
  --server "set -a && . .env && set +a && cd backend && DEV_MODE=1 mise x -- go run ./cmd/server" --port 8080 \
  --server "cd frontend && mise x -- npm run dev" --port 5173 \
  -- mise x -- python test_script.py
```

Note: use `. .env` (dot) instead of `source .env` — `with_server.py` may run commands under `/bin/sh`, where `source` is not available.

**Which accessories to include:** Backend-connected accessories (Redis, Kafka, Meilisearch) must be running for tests to pass — include them. Standalone accessories (n8n, WordPress) are typically not exercised by E2E tests of the main app — omit them unless a test specifically interacts with their API.

To create an automation script, include only Playwright logic (servers are managed automatically):
```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True) # Always launch chromium in headless mode
    page = browser.new_page()
    page.goto('http://localhost:5173') # Server already running and ready
    page.wait_for_load_state('networkidle') # CRITICAL: Wait for JS to execute
    # ... your automation logic
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
bash -c 'source .venv/bin/activate && pip install playwright && python -m playwright install chromium'
```

Activate the virtualenv before running Playwright scripts:

```bash
# macOS/Linux:
bash -c 'source .venv/bin/activate && python your_test.py'
```

**Windows note:** Use `.venv\Scripts\activate` instead of `source .venv/bin/activate`, or call `.venv\Scripts\python.exe` directly:

```powershell
mise x -- python -m venv .venv
.venv\Scripts\python.exe -m pip install playwright
.venv\Scripts\python.exe -m playwright install chromium
.venv\Scripts\python.exe your_test.py
```

## Authenticating in Tests

Many app features are behind a login wall. Magic link and Google Auth flows cannot be completed in automated tests, so the backend provides a **dev-only login endpoint** (`POST /api/dev/login`) when running locally with `DEV_MODE=1`. See the **tech-stack** skill for the backend design.

In Playwright scripts, call the dev login endpoint using `page.request.post()` before navigating to authenticated pages. Because this method shares the browser context's cookie jar, the session cookie is automatically available for all subsequent navigations.

In Claude Desktop Preview, use `preview_click` to submit the login form through the UI — either a dev-mode login shortcut (if the app renders one when `DEV_MODE=1`) or the regular login form with the test user credentials.

## Best Practices

- **Use bundled scripts as black boxes** - To accomplish a task, consider whether one of the scripts available in `scripts/` can help. These scripts handle common, complex workflows reliably without cluttering the context window. Use `--help` to see usage, then invoke directly.
- Use `sync_playwright()` for synchronous scripts
- Always close the browser when done
- Use descriptive selectors: `text=`, `role=`, CSS selectors, or IDs
- Add appropriate waits: `page.wait_for_selector()` or `page.wait_for_timeout()`

## Reference Files

- **examples/** - Examples showing common patterns:
  - `element_discovery.py` - Discovering buttons, links, and inputs on a page
  - `static_html_automation.py` - Using file:// URLs for local HTML
  - `console_logging.py` - Capturing console logs during automation
