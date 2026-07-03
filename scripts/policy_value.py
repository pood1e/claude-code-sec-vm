#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from policy import load_policy  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description="Read a value from egress.policy.yaml")
    parser.add_argument("--policy", default="config/egress.policy.yaml")
    parser.add_argument("path", help="dot path, for example timezone.foreign_clean")
    args = parser.parse_args()

    value = load_policy(args.policy)
    for segment in args.path.split("."):
        if not isinstance(value, dict) or segment not in value:
            raise SystemExit(f"missing policy value: {args.path}")
        value = value[segment]
    if isinstance(value, (dict, list)):
        raise SystemExit(f"policy value is not scalar: {args.path}")
    print(value)


if __name__ == "__main__":
    main()
