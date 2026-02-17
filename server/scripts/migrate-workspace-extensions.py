#!/usr/bin/env -S uv run --python 3.14 --script
# /// script
# requires-python = ">=3.14"
# ///
"""Migrate legacy pi-remote workspaces to explicit extension config.

Safe by default:
- DRY RUN unless --apply is provided
- Creates a backup copy for each changed file on apply

Legacy -> explicit mapping used by this script:
- memoryEnabled=true  => include "memory"
- todos extension     => include "todos" (configurable via --include-todos)

Usage examples:
  # Preview all workspace changes
  scripts/migrate-workspace-extensions.py

  # Apply for one user only
  scripts/migrate-workspace-extensions.py --user-id <userId> --apply

  # Apply all users and force include todos
  scripts/migrate-workspace-extensions.py --include-todos always --apply
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

DEFAULT_WORKSPACES_DIR = Path.home() / ".config" / "pi-remote" / "workspaces"
DEFAULT_TODOS_PATH = Path.home() / ".pi" / "agent" / "extensions" / "todos.ts"


@dataclass
class WorkspacePlan:
    path: Path
    user_id: str
    workspace_id: str
    name: str
    changed: bool
    skipped: bool
    reason: str
    before_mode: str | None
    before_extensions: list[str]
    after_mode: str
    after_extensions: list[str]
    error: str | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--workspaces-dir",
        type=Path,
        default=DEFAULT_WORKSPACES_DIR,
        help=f"Workspace directory (default: {DEFAULT_WORKSPACES_DIR})",
    )
    parser.add_argument(
        "--user-id",
        action="append",
        default=[],
        help="Restrict migration to one or more user IDs",
    )
    parser.add_argument(
        "--include-todos",
        choices=["auto", "always", "never"],
        default="auto",
        help=(
            "How to include todos extension: "
            "auto=include if todos.ts exists (default), always=always include, never=never include"
        ),
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Recompute extension list even for already-explicit workspaces",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write changes (default is dry run)",
    )
    parser.add_argument(
        "--backup-dir",
        type=Path,
        help="Backup directory for changed files (auto-generated if omitted)",
    )
    return parser.parse_args()


def normalize_extensions(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []

    seen: set[str] = set()
    out: list[str] = []
    for item in value:
        if not isinstance(item, str):
            continue
        name = item.strip()
        if not name:
            continue
        if name in seen:
            continue
        seen.add(name)
        out.append(name)

    return out


def discover_workspace_files(workspaces_dir: Path, user_ids: list[str]) -> list[Path]:
    if not workspaces_dir.exists():
        return []

    files: list[Path] = []

    if user_ids:
        for user_id in user_ids:
            user_dir = workspaces_dir / user_id
            if not user_dir.exists():
                continue
            files.extend(sorted(user_dir.glob("*.json")))
        return files

    for user_dir in sorted(workspaces_dir.iterdir()):
        if not user_dir.is_dir():
            continue
        files.extend(sorted(user_dir.glob("*.json")))

    return files


def should_include_todos(mode: str, todos_path: Path) -> bool:
    if mode == "always":
        return True
    if mode == "never":
        return False
    return todos_path.exists()


def build_plan(path: Path, include_todos: bool, force: bool) -> WorkspacePlan:
    rel_parts = path.parts
    # Expected: <workspaces_dir>/<userId>/<workspaceId>.json
    user_id = rel_parts[-2] if len(rel_parts) >= 2 else "unknown"
    workspace_id = path.stem

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as err:  # pragma: no cover - defensive path
        return WorkspacePlan(
            path=path,
            user_id=user_id,
            workspace_id=workspace_id,
            name=workspace_id,
            changed=False,
            skipped=True,
            reason="parse-error",
            before_mode=None,
            before_extensions=[],
            after_mode="explicit",
            after_extensions=[],
            error=str(err),
        )

    if not isinstance(data, dict):
        return WorkspacePlan(
            path=path,
            user_id=user_id,
            workspace_id=workspace_id,
            name=workspace_id,
            changed=False,
            skipped=True,
            reason="invalid-json-root",
            before_mode=None,
            before_extensions=[],
            after_mode="explicit",
            after_extensions=[],
            error="workspace file root must be a JSON object",
        )

    name = str(data.get("name") or workspace_id)
    before_mode = data.get("extensionMode") if isinstance(data.get("extensionMode"), str) else None
    before_extensions = normalize_extensions(data.get("extensions"))

    if before_mode == "explicit" and not force:
        return WorkspacePlan(
            path=path,
            user_id=user_id,
            workspace_id=workspace_id,
            name=name,
            changed=False,
            skipped=True,
            reason="already-explicit",
            before_mode=before_mode,
            before_extensions=before_extensions,
            after_mode="explicit",
            after_extensions=before_extensions,
        )

    after_extensions = list(before_extensions if force else [])

    if bool(data.get("memoryEnabled")) and "memory" not in after_extensions:
        after_extensions.append("memory")

    if include_todos and "todos" not in after_extensions:
        after_extensions.append("todos")

    changed = before_mode != "explicit" or before_extensions != after_extensions

    return WorkspacePlan(
        path=path,
        user_id=user_id,
        workspace_id=workspace_id,
        name=name,
        changed=changed,
        skipped=False,
        reason="migrate",
        before_mode=before_mode,
        before_extensions=before_extensions,
        after_mode="explicit",
        after_extensions=after_extensions,
    )


def apply_plan(
    plans: list[WorkspacePlan],
    workspaces_dir: Path,
    backup_dir: Path,
) -> tuple[int, int]:
    changed = 0
    failed = 0

    for plan in plans:
        if not plan.changed or plan.skipped:
            continue

        try:
            raw = json.loads(plan.path.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                raise ValueError("workspace root is not a JSON object")

            rel_path = plan.path.relative_to(workspaces_dir)
            backup_path = backup_dir / rel_path
            backup_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(plan.path, backup_path)

            raw["extensionMode"] = plan.after_mode
            raw["extensions"] = plan.after_extensions

            serialized = json.dumps(raw, indent=2) + "\n"
            tmp_path = plan.path.with_suffix(plan.path.suffix + ".tmp")
            tmp_path.write_text(serialized, encoding="utf-8")
            tmp_path.replace(plan.path)

            changed += 1
        except Exception as err:  # pragma: no cover - defensive path
            failed += 1
            print(f"[error] failed to update {plan.path}: {err}", file=sys.stderr)

    return changed, failed


def print_plan(plans: list[WorkspacePlan], dry_run: bool) -> None:
    mode = "DRY RUN" if dry_run else "APPLY"
    print(f"\n== Workspace Extension Migration ({mode}) ==")

    for plan in plans:
        header = f"- {plan.user_id}/{plan.workspace_id} ({plan.name})"

        if plan.error:
            print(f"{header}  [skip: {plan.reason}]\n    error: {plan.error}")
            continue

        if plan.skipped:
            print(f"{header}  [skip: {plan.reason}]")
            continue

        if plan.changed:
            print(
                f"{header}\n"
                f"    mode: {plan.before_mode!r} -> {plan.after_mode!r}\n"
                f"    extensions: {plan.before_extensions} -> {plan.after_extensions}"
            )
        else:
            print(
                f"{header}  [no-op]\n"
                f"    mode: {plan.before_mode!r}\n"
                f"    extensions: {plan.before_extensions}"
            )


def summarize(plans: list[WorkspacePlan]) -> tuple[int, int, int, int]:
    total = len(plans)
    errors = sum(1 for p in plans if p.error)
    skipped = sum(1 for p in plans if p.skipped and not p.error)
    changed = sum(1 for p in plans if p.changed and not p.skipped and not p.error)
    return total, changed, skipped, errors


def main() -> int:
    args = parse_args()

    workspaces_dir: Path = args.workspaces_dir.expanduser().resolve()
    todos_path = DEFAULT_TODOS_PATH.expanduser().resolve()

    include_todos = should_include_todos(args.include_todos, todos_path)

    workspace_files = discover_workspace_files(workspaces_dir, args.user_id)
    if not workspace_files:
        print(f"No workspace files found under: {workspaces_dir}")
        return 0

    plans = [build_plan(path, include_todos, args.force) for path in workspace_files]
    print_plan(plans, dry_run=not args.apply)

    total, changed, skipped, errors = summarize(plans)
    print(
        "\nSummary: "
        f"total={total}, migrate={changed}, skipped={skipped}, errors={errors}, include_todos={include_todos}"
    )

    if not args.apply:
        print("\nDry run only. Re-run with --apply to write changes.")
        return 0 if errors == 0 else 2

    if changed == 0:
        print("\nNo changes to apply.")
        return 0 if errors == 0 else 2

    backup_dir = args.backup_dir
    if backup_dir is None:
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_dir = workspaces_dir.parent / f"workspaces.backup-{stamp}"

    backup_dir = backup_dir.expanduser().resolve()
    backup_dir.mkdir(parents=True, exist_ok=True)

    applied, failed = apply_plan(plans, workspaces_dir, backup_dir)
    print(f"\nApplied: {applied} workspace file(s)")
    print(f"Backups: {backup_dir}")

    if failed > 0:
        print(f"Failures: {failed}", file=sys.stderr)
        return 2

    if errors > 0:
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
