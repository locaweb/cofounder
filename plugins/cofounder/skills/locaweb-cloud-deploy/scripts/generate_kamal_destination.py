#!/usr/bin/env python3
"""Generate a Kamal destination file with deterministic infrastructure bindings.

Writes config/deploy.{env_name}.yml with ERB templates for IPs, registry,
builder, SSH, and proxy host.

Usage:
    python3 generate_kamal_destination.py --env-name preview
    python3 generate_kamal_destination.py --env-name production --domain example.com
    python3 generate_kamal_destination.py --env-name preview --accessories db,redis --workers 2
"""
import argparse
import os
import sys


def generate(env_name, domain=None, accessories=None, workers=0):
    """Generate destination file content."""
    lines = []

    # Service identity (ERB from GitHub Actions context)
    lines.append("service: <%= ENV['REPO_NAME'] %>")
    lines.append("image: <%= ENV['REPO_FULL'] %>")
    lines.append("")

    # Servers
    lines.append("servers:")
    lines.append("  web:")
    lines.append("    hosts:")
    lines.append("      - <%= ENV['INFRA_WEB_IP'] %>")

    if workers > 0:
        lines.append("  workers:")
        lines.append("    hosts:")
        for i in range(workers):
            lines.append(f"      - <%= ENV['INFRA_WORKER_IP_{i}'] %>")

    lines.append("")

    # Proxy host
    lines.append("proxy:")
    if domain:
        lines.append(f"  host: {domain}")
    else:
        lines.append("  host: <%= ENV['INFRA_WEB_IP'] %>.nip.io")

    lines.append("")

    # SSH
    lines.append("ssh:")
    lines.append("  user: root")
    lines.append("  keys: [.kamal/ssh_key]")
    lines.append("")

    # Registry
    lines.append("registry:")
    lines.append("  server: ghcr.io")
    lines.append("  username: <%= ENV['REPO_OWNER'] %>")
    lines.append("  password:")
    lines.append("    - KAMAL_REGISTRY_PASSWORD")
    lines.append("")

    # Builder
    lines.append("builder:")
    lines.append("  arch: amd64")
    lines.append("  cache:")
    lines.append("    type: gha")
    lines.append("    options: mode=max")

    # Accessories host assignments
    if accessories:
        lines.append("")
        lines.append("accessories:")
        for name in accessories:
            lines.append(f"  {name}:")
            lines.append(f"    host: <%= ENV['INFRA_{name.upper()}_IP'] %>")

    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Generate a Kamal destination file")
    parser.add_argument("--env-name", required=True,
                        help="Environment name (e.g. preview, production)")
    parser.add_argument("--domain", default=None,
                        help="Custom domain for proxy.host (omit for nip.io)")
    parser.add_argument("--accessories", default=None,
                        help="Comma-separated accessory names (e.g. db,redis)")
    parser.add_argument("--workers", type=int, default=0,
                        help="Number of worker hosts (0 = no workers)")
    args = parser.parse_args()

    accessories = []
    if args.accessories:
        accessories = [a.strip() for a in args.accessories.split(",") if a.strip()]

    content = generate(args.env_name, domain=args.domain,
                       accessories=accessories, workers=args.workers)

    dest_path = os.path.join("config", f"deploy.{args.env_name}.yml")
    os.makedirs("config", exist_ok=True)
    with open(dest_path, "w") as f:
        f.write(content)

    print(f"Generated {dest_path}")


if __name__ == "__main__":
    main()
