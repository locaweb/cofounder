#!/usr/bin/env python3
"""Generate the PostgreSQL cmd string tuned for a given VM plan.

Encodes the plan-to-RAM mapping and tuning algorithm from ADR-025.
Outputs the complete postgres command string for use in accessories.db.cmd.

Usage:
    python3 generate_pg_cmd.py --plan medium
    # Output: postgres -D /etc/postgresql -c shared_buffers=1GB ...
"""
import argparse
import sys

# Plan-to-RAM mapping (MiB)
PLAN_RAM_MIB = {
    "micro": 1024,
    "small": 2048,
    "medium": 4096,
    "large": 8192,
    "xlarge": 16384,
    "2xlarge": 32768,
    "4xlarge": 65536,
}


def compute_pg_params(plan):
    """Compute PostgreSQL tuning parameters for a given plan."""
    ram_mib = PLAN_RAM_MIB.get(plan)
    if ram_mib is None:
        raise ValueError(f"Unknown plan: {plan}. "
                         f"Valid plans: {', '.join(PLAN_RAM_MIB.keys())}")

    # max_connections: 100 (<=4GB), 200 (<=16GB), 400 (>16GB)
    if ram_mib <= 4096:
        max_connections = 100
    elif ram_mib <= 16384:
        max_connections = 200
    else:
        max_connections = 400

    # shared_buffers: RAM / 4
    shared_buffers_mib = ram_mib // 4

    # effective_cache_size: RAM * 3 / 4
    effective_cache_size_mib = ram_mib * 3 // 4

    # work_mem: max(RAM / max_conn / 4, 2MB)
    work_mem_mib = max(ram_mib // max_connections // 4, 2)

    # maintenance_work_mem: min(RAM / 16, 2GB)
    maintenance_work_mem_mib = min(ram_mib // 16, 2048)

    return {
        "shared_buffers": format_mib(shared_buffers_mib),
        "effective_cache_size": format_mib(effective_cache_size_mib),
        "work_mem": format_mib(work_mem_mib),
        "maintenance_work_mem": format_mib(maintenance_work_mem_mib),
        "max_connections": str(max_connections),
    }


def format_mib(mib):
    """Format MiB value as PostgreSQL-friendly string (e.g. 1GB, 512MB)."""
    if mib >= 1024 and mib % 1024 == 0:
        return f"{mib // 1024}GB"
    return f"{mib}MB"


def generate_cmd(plan):
    """Generate the complete postgres command string."""
    params = compute_pg_params(plan)
    parts = ["postgres", "-D", "/etc/postgresql"]
    for key in ("shared_buffers", "effective_cache_size", "work_mem",
                "maintenance_work_mem", "max_connections"):
        parts.extend(["-c", f"{key}={params[key]}"])
    return " ".join(parts)


def main():
    parser = argparse.ArgumentParser(
        description="Generate PostgreSQL cmd string tuned for a VM plan")
    parser.add_argument("--plan", required=True,
                        choices=list(PLAN_RAM_MIB.keys()),
                        help="VM plan name")
    args = parser.parse_args()
    print(generate_cmd(args.plan))


if __name__ == "__main__":
    main()
