#!/usr/bin/env python3
"""Generate a caller deploy workflow with two jobs: infra + deploy.

Writes .github/workflows/deploy-{env_name}.yml with deterministic content.
The infra job calls deploy.yml@v1 for infrastructure provisioning.
The deploy job installs Kamal and deploys the application using the outputs.

Usage:
    python3 generate_deploy_workflow.py --env-name preview --trigger push-main --accessories db --secrets POSTGRES_PASSWORD,DATABASE_URL
    python3 generate_deploy_workflow.py --env-name production --trigger push-tags --accessories db --secrets POSTGRES_PASSWORD,DATABASE_URL
    python3 generate_deploy_workflow.py --env-name production --trigger workflow_dispatch --accessories db,redis --workers 2 --secrets POSTGRES_PASSWORD,DATABASE_URL,REDIS_URL
"""
import argparse
import json
import os
import sys


def _suffix(env_name):
    """Return the secret suffix for an environment (empty for preview)."""
    if env_name == "preview":
        return ""
    return f"_{env_name.upper()}"


def _secret_ref(name, env_name):
    """Return the GitHub Secret reference for a secret name.

    Preview: POSTGRES_PASSWORD -> ${{ secrets.POSTGRES_PASSWORD }}
    Production: POSTGRES_PASSWORD -> ${{ secrets.POSTGRES_PASSWORD_PRODUCTION }}
    """
    sfx = _suffix(env_name)
    return f"${{{{ secrets.{name}{sfx} }}}}"


def _env_var_name(name, env_name):
    """Return the env var name (= GitHub Secret name) for a secret.

    Preview: POSTGRES_PASSWORD -> POSTGRES_PASSWORD
    Production: POSTGRES_PASSWORD -> POSTGRES_PASSWORD_PRODUCTION
    """
    sfx = _suffix(env_name)
    return f"{name}{sfx}"


def generate(env_name, trigger, zone="ZP01", web_plan="small",
             web_disk_size_gb=20, accessories=None, workers=0,
             workers_plan="small", secrets=None):
    """Generate deploy workflow YAML content."""
    lines = []

    # Header
    title = env_name.title()
    lines.append(f"# .github/workflows/deploy-{env_name}.yml")
    lines.append(f"name: Deploy {title}")

    # Trigger
    lines.append("on:")
    if trigger == "push-main":
        lines.append("  push:")
        lines.append('    branches: [main]')
        lines.append('    paths-ignore: [".claude/**"]')
    elif trigger == "push-tags":
        lines.append("  push:")
        lines.append('    tags: ["v*"]')
    elif trigger == "workflow_dispatch":
        lines.append("  workflow_dispatch:")

    lines.append("")

    # Permissions
    lines.append("permissions:")
    lines.append("  contents: read")
    lines.append("  packages: write")
    lines.append("")

    # Jobs
    lines.append("jobs:")

    # --- Infra job ---
    lines.append("  infra:")
    lines.append("    uses: gmautner/locaweb-cloud-deploy/.github/workflows/deploy.yml@v1")
    lines.append("    with:")
    lines.append(f'      env_name: "{env_name}"')

    if zone != "ZP01":
        lines.append(f'      zone: "{zone}"')
    if web_plan != "small":
        lines.append(f'      web_plan: "{web_plan}"')
    if web_disk_size_gb != 20:
        lines.append(f"      web_disk_size_gb: {web_disk_size_gb}")

    if accessories:
        acc_list = [{"name": name, "plan": "medium", "disk_size_gb": 20}
                    for name in accessories]
        acc_json = json.dumps(acc_list, separators=(",", ":"))
        lines.append(f"      accessories: '{acc_json}'")

    if workers > 0:
        lines.append(f"      workers_replicas: {workers}")
        if workers_plan != "small":
            lines.append(f'      workers_plan: "{workers_plan}"')

    lines.append("    secrets:")
    lines.append("      CLOUDSTACK_API_KEY: ${{ secrets.CLOUDSTACK_API_KEY }}")
    lines.append("      CLOUDSTACK_SECRET_KEY: ${{ secrets.CLOUDSTACK_SECRET_KEY }}")
    lines.append(f"      SSH_PRIVATE_KEY: {_secret_ref('SSH_PRIVATE_KEY', env_name)}")

    lines.append("")

    # --- Deploy job ---
    lines.append("  deploy:")
    lines.append("    needs: infra")
    lines.append("    runs-on: ubuntu-latest")

    # Env block for app secrets
    if secrets:
        lines.append("    env:")
        for secret_name in secrets:
            ev = _env_var_name(secret_name, env_name)
            lines.append(f"      {ev}: {_secret_ref(secret_name, env_name)}")

    lines.append("    steps:")

    # Step 1: Checkout
    lines.append("      - name: Checkout application repository")
    lines.append("        uses: actions/checkout@v4")
    lines.append("")

    # Step 2: Load infra env
    lines.append("      - name: Load infrastructure environment")
    lines.append('        run: echo "${{ needs.infra.outputs.infra_env }}" >> "$GITHUB_ENV"')
    lines.append("")

    # Step 3: Set repo identity
    lines.append("      - name: Set repo identity")
    lines.append("        run: |")
    lines.append('          echo "REPO_NAME=${{ github.event.repository.name }}" >> "$GITHUB_ENV"')
    lines.append('          echo "REPO_FULL=${{ github.repository }}" >> "$GITHUB_ENV"')
    lines.append('          echo "REPO_OWNER=${{ github.repository_owner }}" >> "$GITHUB_ENV"')
    lines.append("")

    # Step 4: Configure gem path
    lines.append("      - name: Configure gem path")
    lines.append("        run: |")
    lines.append('          echo "GEM_HOME=$HOME/.gems" >> "$GITHUB_ENV"')
    lines.append('          echo "$HOME/.gems/bin" >> "$GITHUB_PATH"')
    lines.append("")

    # Step 5: Cache Kamal gem
    lines.append("      - name: Cache Kamal gem")
    lines.append("        id: kamal-cache")
    lines.append("        uses: actions/cache@v4")
    lines.append("        with:")
    lines.append("          path: ~/.gems")
    lines.append("          key: kamal-${{ runner.os }}-v1")
    lines.append("")

    # Step 6: Install Kamal
    lines.append("      - name: Install Kamal")
    lines.append("        if: steps.kamal-cache.outputs.cache-hit != 'true'")
    lines.append("        run: gem install kamal --no-document")
    lines.append("")

    # Step 7: Prepare SSH key
    lines.append("      - name: Prepare SSH key for Kamal")
    lines.append("        env:")
    lines.append(f"          SSH_PRIVATE_KEY: {_secret_ref('SSH_PRIVATE_KEY', env_name)}")
    lines.append("        run: |")
    lines.append("          mkdir -p .kamal")
    lines.append("          install -m 600 /dev/null .kamal/ssh_key")
    lines.append("          printf '%s\\n' \"$SSH_PRIVATE_KEY\" > .kamal/ssh_key")
    lines.append("")

    # Step 8: Docker cache
    lines.append("      - name: Expose GitHub Actions runtime for Docker cache")
    lines.append("        uses: actions/github-script@v7")
    lines.append("        with:")
    lines.append("          script: |")
    lines.append("            const vars = [")
    lines.append("              'ACTIONS_CACHE_URL',")
    lines.append("              'ACTIONS_RUNTIME_TOKEN',")
    lines.append("              'ACTIONS_RUNTIME_URL',")
    lines.append("              'ACTIONS_RESULTS_URL',")
    lines.append("              'ACTIONS_CACHE_SERVICE_V2',")
    lines.append("            ];")
    lines.append("            for (const v of vars) {")
    lines.append("              const val = process.env[v];")
    lines.append("              if (val) core.exportVariable(v, val);")
    lines.append("            }")
    lines.append("")

    # Step 9: Deploy with Kamal
    lines.append("      - name: Deploy with Kamal")
    lines.append("        env:")
    lines.append("          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}")
    lines.append("        run: |")
    lines.append(f'          if [ "${{{{ needs.infra.outputs.infrastructure_changed }}}}" = "true" ]; then')
    lines.append(f'            echo "Fresh infrastructure — running kamal setup"')
    lines.append(f'            kamal setup -d {env_name}')
    lines.append("          else")
    lines.append(f'            echo "Infrastructure cached — running kamal deploy"')
    lines.append(f'            kamal deploy -d {env_name}')
    lines.append("          fi")
    lines.append("")

    # Step 10: Reboot scaled accessories
    lines.append("      - name: Reboot scaled accessories")
    lines.append("        env:")
    lines.append("          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}")
    lines.append("        run: |")
    lines.append("          python3 << 'PYEOF'")
    lines.append("          import json, subprocess, sys")
    lines.append("          scaled = json.loads('${{ needs.infra.outputs.scaled_accessories }}')")
    lines.append("          for name in scaled:")
    lines.append('              print(f"Accessory \'{name}\' VM was rescaled, rebooting...")')
    lines.append(f'              subprocess.run(')
    lines.append(f'                  ["kamal", "accessory", "reboot", name, "-d", "{env_name}"],')
    lines.append(f'                  check=True')
    lines.append(f'              )')
    lines.append("          PYEOF")

    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Generate a two-job deploy workflow (infra + deploy)")
    parser.add_argument("--env-name", required=True,
                        help="Environment name (e.g. preview, production)")
    parser.add_argument("--trigger", required=True,
                        choices=["push-main", "push-tags", "workflow_dispatch"],
                        help="Workflow trigger type")
    parser.add_argument("--zone", default="ZP01",
                        help="CloudStack zone (default: ZP01)")
    parser.add_argument("--web-plan", default="small",
                        help="Web VM plan (default: small)")
    parser.add_argument("--web-disk-size-gb", type=int, default=20,
                        help="Web data disk size in GB (default: 20)")
    parser.add_argument("--accessories", default=None,
                        help="Comma-separated accessory names (e.g. db,redis)")
    parser.add_argument("--workers", type=int, default=0,
                        help="Number of worker replicas (default: 0)")
    parser.add_argument("--workers-plan", default="small",
                        help="Worker VM plan (default: small)")
    parser.add_argument("--secrets", default=None,
                        help="Comma-separated app secret names (e.g. POSTGRES_PASSWORD,DATABASE_URL)")
    args = parser.parse_args()

    accessories = []
    if args.accessories:
        accessories = [a.strip() for a in args.accessories.split(",") if a.strip()]

    secrets = []
    if args.secrets:
        secrets = [s.strip() for s in args.secrets.split(",") if s.strip()]

    content = generate(
        args.env_name,
        args.trigger,
        zone=args.zone,
        web_plan=args.web_plan,
        web_disk_size_gb=args.web_disk_size_gb,
        accessories=accessories,
        workers=args.workers,
        workers_plan=args.workers_plan,
        secrets=secrets,
    )

    dest_path = os.path.join(".github", "workflows", f"deploy-{args.env_name}.yml")
    os.makedirs(os.path.join(".github", "workflows"), exist_ok=True)
    with open(dest_path, "w") as f:
        f.write(content)

    print(f"Generated {dest_path}")


if __name__ == "__main__":
    main()
