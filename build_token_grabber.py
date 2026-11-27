#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 luminescq
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# build_token_grabber.py — сборка LaLuneTokenFetcher (Go + playwright-go).
#
# Раньше здесь собирался .NET-проект. Теперь фетчер — один Go-бинарник на
# платформу; он же встраивается в desktop-бэкенды (см. Backend/Desktop/build.rs
# и Core/TokenFetcher/build.sh).
#
# Использование:
#   python build_token_grabber.py                 # linux + windows
#   python build_token_grabber.py --platform=Linux
#   python build_token_grabber.py --platform=Windows
#   python build_token_grabber.py --clean
#
# Требования:
#   - Python 3.8+
#   - Go 1.22+ в PATH (или GOROOT/go в PATH)
#
# Что делает:
#   1. Проверяет наличие go.
#   2. Запускает `go vet ./...` и `go test ./...` в Core/TokenFetcher.
#   3. Запускает Core/TokenFetcher/build.sh — он собирает оба бинарника и
#      кладёт gzip в Backend/Desktop/assets/.

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent
FETCHER_ROOT = PROJECT_ROOT / "Core" / "TokenFetcher"
BUILD_SCRIPT = FETCHER_ROOT / "build.sh"


def die(message: str) -> "None":
    print(f"[ERROR] {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the LaLune VK token fetcher (Go).")
    parser.add_argument(
        "--platform",
        choices=["Linux", "Windows", "All"],
        default="All",
        help="Какие бинарники собирать (по умолчанию оба).",
    )
    parser.add_argument("--clean", action="store_true", help="Удалить прошлые артефакты.")
    args = parser.parse_args()

    if shutil.which("go") is None:
        die("Go не найден в PATH. Установите Go 1.22+ и повторите.")
    if not BUILD_SCRIPT.exists():
        die(f"Не найден {BUILD_SCRIPT}")

    if args.clean:
        for path in [
            FETCHER_ROOT / "output",
            PROJECT_ROOT / "Backend" / "Desktop" / "assets",
        ]:
            if path.exists():
                shutil.rmtree(path)
                print(f"[INFO] removed {path}")

    print(f"[INFO] go: {subprocess.run(['go', 'version'], capture_output=True, text=True).stdout.strip()}")
    for command in (["go", "vet", "./..."], ["go", "test", "./..."]):
        print(f"[INFO] {' '.join(command)}")
        result = subprocess.run(command, cwd=FETCHER_ROOT)
        if result.returncode != 0:
            die(f"{' '.join(command)} failed with {result.returncode}")

    print("[INFO] Core/TokenFetcher/build.sh")
    result = subprocess.run(["sh", str(BUILD_SCRIPT)], cwd=FETCHER_ROOT)
    if result.returncode != 0:
        die(f"build.sh failed with {result.returncode}")

    assets = PROJECT_ROOT / "Backend" / "Desktop" / "assets"
    produced = sorted(assets.glob("*.gz"))
    if not produced:
        die("Не найдено ни одного .gz в Backend/Desktop/assets")
    for path in produced:
        print(f"[OK] {path.relative_to(PROJECT_ROOT)} — {path.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
