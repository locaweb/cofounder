#!/usr/bin/env bash
# Generate the cofounder plugin PDF.
# Creates a venv automatically if needed, installs deps, and runs the script.
# Portable: works on macOS, Linux, and GitHub Actions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

# Find a working Python 3 (skip shims that may hang)
find_python() {
    # Prefer PYTHON env var if set
    if [ -n "${PYTHON:-}" ] && command -v "$PYTHON" &>/dev/null; then
        echo "$PYTHON"; return
    fi
    # Try common locations, avoiding shims
    for p in \
        /usr/bin/python3 \
        /opt/homebrew/bin/python3 \
        /usr/local/bin/python3 \
        "$(command -v python3 2>/dev/null)"; do
        if [ -x "$p" ] 2>/dev/null; then
            echo "$p"; return
        fi
    done
    echo "python3"  # fallback
}

# Create venv if it doesn't exist
if [ ! -d "$VENV_DIR" ]; then
    PYTHON_BIN="$(find_python)"
    echo "Creating virtual environment with $PYTHON_BIN..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

# Install/upgrade deps
echo "Installing dependencies..."
"$VENV_DIR/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt"

# Run the generator
echo "Generating PDF..."
"$VENV_DIR/bin/python" "$SCRIPT_DIR/generate_pdf.py"
