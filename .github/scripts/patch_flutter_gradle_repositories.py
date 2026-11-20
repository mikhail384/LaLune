#!/usr/bin/env python3
"""Ensure Flutter's included Gradle build can resolve Kotlin artifacts from Maven Central.

Flutter 3.47.x ships packages/flutter_tools/gradle/settings.gradle.kts with
only dependencyResolutionManagement repositories. Plugin resolution for that
included build therefore falls back to the Gradle Plugin Portal. If the portal
does not proxy Kotlin's transitive Maven artifacts, Android builds fail before
the app project is configured.

This patch is intentionally idempotent and only prepends pluginManagement to
the Flutter SDK's included Gradle build settings.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

PLUGIN_MANAGEMENT = """pluginManagement {
    repositories {
        // Kotlin/Android plugin implementation artifacts live in Maven Central/Google.
        // Keep the Plugin Portal last for plugin marker artifacts that exist only there.
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("flutter_root", type=Path, help="Path to the Flutter SDK root")
    args = parser.parse_args()

    settings = args.flutter_root / "packages" / "flutter_tools" / "gradle" / "settings.gradle.kts"
    if not settings.is_file():
        print(f"Flutter Gradle settings not found: {settings}", file=sys.stderr)
        return 2

    source = settings.read_text(encoding="utf-8")
    if "pluginManagement" in source:
        print(f"Flutter Gradle pluginManagement already present: {settings}")
        print(source)
        return 0

    if "dependencyResolutionManagement" not in source:
        print(
            "Unexpected Flutter Gradle settings layout; refusing to overwrite an unknown file:\n"
            f"{settings}\n{source}",
            file=sys.stderr,
        )
        return 3

    updated = PLUGIN_MANAGEMENT + source
    settings.write_text(updated, encoding="utf-8")
    print(f"Patched Flutter included-build repositories: {settings}")
    print(updated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
