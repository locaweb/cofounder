#!/usr/bin/env python3
"""Generate the proxy configuration block for deploy.yml.

Outputs YAML proxy block with platform constraints to stdout.
The agent inserts this into the base deploy.yml.

Usage:
    python3 generate_proxy_config.py
"""


def generate():
    """Generate proxy YAML block."""
    return """\
proxy:
  app_port: 80
  ssl: true
  forward_headers: false
  healthcheck:
    path: /up
    interval: 3
    timeout: 5"""


def main():
    print(generate())


if __name__ == "__main__":
    main()
