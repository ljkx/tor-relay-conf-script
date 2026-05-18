#!/usr/bin/env python3
"""Render README terminal screenshots from a captured script transcript."""

from __future__ import annotations

import argparse
import html
from pathlib import Path


def color_for(line: str) -> str:
    if "[OK]" in line:
        return "#50fa7b"
    if "[WARN]" in line:
        return "#f1fa8c"
    if "[ERROR]" in line:
        return "#ff6e6e"
    if "+--" in line or line.startswith("Tor Relay Setup"):
        return "#23d6c8"
    return "#d8edf3"


def render_svg(path: Path, title: str, lines: list[str]) -> None:
    width = 1180
    line_height = 22
    top = 64
    height = top + line_height * len(lines) + 34

    output = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-label="{html.escape(title)}">',
        '<rect width="100%" height="100%" rx="16" fill="#071923"/>',
        '<rect width="100%" height="42" rx="16" fill="#0d2b38"/>',
        '<circle cx="26" cy="21" r="7" fill="#ff5f57"/>'
        '<circle cx="50" cy="21" r="7" fill="#ffbd2e"/>'
        '<circle cx="74" cy="21" r="7" fill="#28c840"/>',
        f'<text x="104" y="27" font-family="DejaVu Sans Mono, Consolas, monospace" '
        f'font-size="15" fill="#a8d8e8">{html.escape(title)}</text>',
    ]

    y = top
    for raw in lines:
        escaped = html.escape(raw[:136])
        output.append(
            f'<text x="28" y="{y}" font-family="DejaVu Sans Mono, Consolas, monospace" '
            f'font-size="15" fill="{color_for(raw)}">{escaped}</text>'
        )
        y += line_height

    output.append("</svg>")
    path.write_text("\n".join(output) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("transcript", type=Path)
    parser.add_argument("--out-dir", type=Path, default=Path("docs/assets"))
    args = parser.parse_args()

    lines = args.transcript.read_text(encoding="utf-8", errors="replace").splitlines()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    render_svg(
        args.out_dir / "tor-relay-setup-first-run.svg",
        "WSL Ubuntu dry-run: guided setup",
        lines[:42],
    )

    review_start = next(
        (index for index, line in enumerate(lines) if "Review Before Applying" in line),
        50,
    )
    render_svg(
        args.out_dir / "tor-relay-setup-review.svg",
        "WSL Ubuntu dry-run: final review",
        lines[review_start : review_start + 52],
    )


if __name__ == "__main__":
    main()
