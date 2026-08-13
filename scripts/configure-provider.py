#!/usr/bin/env python3
"""Configure catalog-spawn provider records from the provider manifest."""

import argparse
from pathlib import Path
import tomllib


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "catalog" / "providers.toml"
DEFAULTS = {
    "initial": "_memory_image_provider",
    "prepare": "_composite_prepare_spi",
    "read": "_composite_external_spi_read",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("provider")
    args = parser.parse_args()

    providers = tomllib.loads(MANIFEST.read_text())["providers"]
    if args.provider not in providers:
        choices = ", ".join(sorted(providers))
        parser.error(f"unknown provider {args.provider!r}; choose {choices}")
    selected = providers[args.provider]
    text = args.source.read_text()
    for field, default_symbol in DEFAULTS.items():
        configured_symbol = selected[field]
        needle = f"        .word   {default_symbol}"
        replacement = f"        .word   {configured_symbol}"
        count = text.count(needle)
        if count != 1:
            raise SystemExit(
                f"expected one default {field} record {default_symbol}, found {count}"
            )
        text = text.replace(needle, replacement, 1)
    args.source.write_text(text)
    print(f"Configured provider {args.provider} -> {args.source}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
