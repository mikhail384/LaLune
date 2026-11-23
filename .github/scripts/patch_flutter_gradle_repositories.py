#!/usr/bin/env python3
"""Make Flutter's included Gradle build resilient to Maven Central outages.

Flutter 3.47.x builds packages/flutter_tools/gradle as an included Gradle build.
That build needs Kotlin artifacts (notably 2.0.21 and 2.2.20) before the app
project is configured.  A transient/blocked repo.maven.apache.org endpoint can
therefore fail the build at `dev.flutter.flutter-plugin-loader` resolution.

This helper:
  1. probes a small list of Maven Central-compatible endpoints using the exact
     Kotlin POMs required by Flutter 3.47.x;
  2. exports the selected endpoint through GITHUB_ENV when requested;
  3. rewrites Flutter's included-build settings.gradle.kts so both plugin and
     normal dependency resolution use the selected endpoint before the default
     Maven Central URL.

The operation is deterministic and idempotent.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_CANDIDATES = (
    # Public Google Cloud Storage mirror of Maven Central.  Put it first so CI
    # does not depend on repo.maven.apache.org being reachable from the runner.
    "https://maven-central.storage-download.googleapis.com/maven2",
    "https://maven-central-eu.storage-download.googleapis.com/maven2",
    "https://repo.maven.apache.org/maven2",
    "https://repo1.maven.org/maven2",
    "https://cache-redirector.jetbrains.com/repo1.maven.org/maven2",
)

# These are the artifacts visible in the Flutter 3.47.x failure path:
# Gradle Kotlin DSL 5.2.0 uses Kotlin 2.0.21, while Flutter's Gradle build uses
# Kotlin JVM plugin 2.2.20.
PROBE_PATHS = (
    "org/jetbrains/kotlin/kotlin-stdlib/2.0.21/kotlin-stdlib-2.0.21.pom",
    "org/jetbrains/kotlin/kotlin-gradle-plugin-api/2.0.21/kotlin-gradle-plugin-api-2.0.21.pom",
    "org/jetbrains/kotlin/kotlin-gradle-plugin/2.2.20/kotlin-gradle-plugin-2.2.20.pom",
    "org/jetbrains/kotlin/kotlin-gradle-plugins-bom/2.2.20/kotlin-gradle-plugins-bom-2.2.20.pom",
)


def normalize_repo(url: str) -> str:
    return url.strip().rstrip("/")


def probe(url: str, timeout: float = 12.0) -> tuple[bool, str]:
    """Return (ok, detail) after checking all required Kotlin POMs."""
    base = normalize_repo(url)
    for rel in PROBE_PATHS:
        target = f"{base}/{rel}"
        req = Request(
            target,
            headers={
                "User-Agent": "LaLune-GitHub-Actions/1.0",
                "Accept": "application/xml,text/xml,text/plain,*/*",
            },
        )
        last_error = "unknown error"
        for attempt in range(1, 3):
            try:
                with urlopen(req, timeout=timeout) as response:
                    status = getattr(response, "status", None) or 200
                    body = response.read(4096)
                if status == 200 and b"<project" in body:
                    last_error = ""
                    break
                last_error = f"HTTP {status} or invalid POM"
            except HTTPError as exc:
                last_error = f"HTTP {exc.code}"
            except URLError as exc:
                last_error = f"URL error: {exc.reason}"
            except TimeoutError:
                last_error = "timeout"
            except Exception as exc:  # diagnostics only; try next mirror
                last_error = f"{type(exc).__name__}: {exc}"
            if attempt < 2:
                time.sleep(0.5)
        if last_error:
            return False, f"{rel}: {last_error}"
    return True, "all required Kotlin POMs are reachable"


def choose_repository(forced: str | None) -> str:
    if forced:
        selected = normalize_repo(forced)
        ok, detail = probe(selected)
        if not ok:
            raise RuntimeError(f"Forced Maven repository failed probe: {selected}: {detail}")
        print(f"Selected forced Maven Central endpoint: {selected}")
        return selected

    env_override = os.environ.get("LALUNE_MAVEN_CENTRAL_URL", "").strip()
    candidates: list[str] = []
    if env_override:
        candidates.append(env_override)
    candidates.extend(DEFAULT_CANDIDATES)

    seen: set[str] = set()
    failures: list[str] = []
    for candidate in candidates:
        candidate = normalize_repo(candidate)
        if not candidate or candidate in seen:
            continue
        seen.add(candidate)
        ok, detail = probe(candidate)
        if ok:
            print(f"Selected Maven Central endpoint: {candidate} ({detail})")
            return candidate
        failures.append(f"  - {candidate}: {detail}")
        print(f"Maven endpoint unavailable: {candidate}: {detail}", file=sys.stderr)

    raise RuntimeError(
        "None of the Maven Central endpoints can serve Flutter's required Kotlin artifacts:\n"
        + "\n".join(failures)
    )


def flutter_settings(repo_url: str) -> str:
    escaped = repo_url.replace("\\", "\\\\").replace('"', '\\"')
    return f'''// Patched by LaLune CI. See .github/scripts/patch_flutter_gradle_repositories.py.
pluginManagement {{
    repositories {{
        google()
        maven {{
            name = "LaLuneMavenCentralMirror"
            url = uri("{escaped}")
        }}
        // Keep canonical Central and Plugin Portal only as fallbacks.
        mavenCentral()
        gradlePluginPortal()
    }}
}}

dependencyResolutionManagement {{
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {{
        google()
        maven {{
            name = "LaLuneMavenCentralMirror"
            url = uri("{escaped}")
        }}
        mavenCentral()
    }}
}}
'''


def write_github_env(path: Path, repo_url: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="\n") as f:
        f.write(f"LALUNE_MAVEN_CENTRAL_URL={repo_url}\n")
    print(f"Exported LALUNE_MAVEN_CENTRAL_URL via {path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("flutter_root", type=Path, help="Path to the Flutter SDK root")
    parser.add_argument(
        "--github-env",
        type=Path,
        help="Optional GITHUB_ENV file; selected mirror is appended for later Gradle invocations",
    )
    parser.add_argument(
        "--repository-url",
        help="Force one Maven Central-compatible endpoint (still validated before use)",
    )
    args = parser.parse_args()

    settings = args.flutter_root / "packages" / "flutter_tools" / "gradle" / "settings.gradle.kts"
    if not settings.is_file():
        print(f"Flutter Gradle settings not found: {settings}", file=sys.stderr)
        return 2

    source = settings.read_text(encoding="utf-8")
    if (
        "dependencyResolutionManagement" not in source
        and "Patched by LaLune CI" not in source
    ):
        print(
            "Unexpected Flutter Gradle settings layout; refusing to overwrite an unknown file:\n"
            f"{settings}\n{source}",
            file=sys.stderr,
        )
        return 3

    try:
        repo_url = choose_repository(args.repository_url)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 4

    if args.github_env:
        write_github_env(args.github_env, repo_url)

    updated = flutter_settings(repo_url)
    settings.write_text(updated, encoding="utf-8", newline="\n")
    print(f"Patched Flutter included-build repositories: {settings}")
    print(updated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
