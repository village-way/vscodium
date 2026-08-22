#!/usr/bin/env python3
"""Safely prepare and trigger Zhanlu IDE release builds."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Callable, Iterable, Mapping, Sequence, TextIO
from urllib.parse import urlparse


COMPONENT_REPOS = (
    "zhanlu-cloud",
    "zhanlu-code",
    "zhanlu-core",
    "zhanlu-loc",
    "zhanlu-vs",
)
REQUIRED_COMPONENT_REPOS = COMPONENT_REPOS[:-1]  # zhanlu_change - native Agent no longer requires zhanlu-vs
WORKFLOWS = {
    "macos": "stable-macos.yml",
    "linux": "stable-linux.yml",
    "windows": "stable-windows.yml",
}
VERSION_RE = re.compile(r"^(?:v)?([0-9]+)\.([0-9]+)\.([0-9]+)$")
TIME_PATCH_RE = re.compile(r"^[0-9]{1,4}$")
TERMINAL_STATUS = "completed"


class BuildError(RuntimeError):
    """Raised for an expected, user-actionable build error."""


@dataclass(frozen=True)
class Config:
    workspace: Path
    kind: str
    version: str
    time_patch: str | None
    workflow_ref: str  # zhanlu_change
    source_branch: str
    delivery_profile: str
    zhanlu_core_ref: str
    zhanlu_vs_ref: str
    bundle_codex_runtime: str
    platform: str
    apply: bool
    trigger_only: bool
    no_gitlab: bool
    publish: bool
    no_wait: bool
    poll_interval: float
    discovery_timeout: float
    output_format: str = "text"
    request_id: str | None = None
    generate_only: bool = False
    selected_source_sync: bool = False
    portal_source_sync: bool = False
    confirmed_source_plan: Path | None = None
    source_commit: str | None = None
    zhanlu_core_commit: str | None = None
    zhanlu_vs_commit: str | None = None


@dataclass(frozen=True)
class ReleasePlan:
    config: Config
    release_repo: Path
    release_version: str
    version_time_patch: str
    release_date: str
    gitlab_sync: bool
    workflows: tuple[str, ...]

    @property
    def release_draft(self) -> bool:
        return not self.config.publish

    @property
    def source_sync_all_refs(self) -> bool:
        return not (self.config.selected_source_sync or self.config.portal_source_sync) and any(
            ref and ref != "develop"  # zhanlu_change
            for ref in (
                self.config.source_branch,
                self.config.zhanlu_core_ref,
                self.config.zhanlu_vs_ref,
            )
        )


def component_repositories(plan: ReleasePlan) -> tuple[str, ...]:
    """Return the component set required by the selected Agent architecture."""
    return COMPONENT_REPOS if plan.config.zhanlu_vs_ref else REQUIRED_COMPONENT_REPOS  # zhanlu_change


@dataclass(frozen=True)
class CommandResult:
    stdout: str = ""
    stderr: str = ""
    returncode: int = 0


@dataclass(frozen=True)
class ResolvedSourceRef:
    repository: str
    ref_type: str
    requested_ref: str
    source_ref: str
    destination_ref: str
    source_object_sha: str
    source_commit_sha: str
    destination_sha: str
    action: str


class CommandRunner:
    """Run commands without a shell so refs and tokens cannot be re-evaluated."""

    def run(
        self,
        args: Sequence[str],
        *,
        cwd: Path | None = None,
        env: Mapping[str, str] | None = None,
        capture: bool = True,
    ) -> CommandResult:
        completed = subprocess.run(
            list(args),
            cwd=str(cwd) if cwd else None,
            env=dict(env) if env is not None else None,
            check=True,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
        return CommandResult(
            stdout=completed.stdout or "",
            stderr=completed.stderr or "",
            returncode=completed.returncode,
        )


def default_workspace() -> Path:
    # The skill is stored in the standalone vscodium project, while releases
    # intentionally run from the current Zhanlu multi-repository workspace.
    configured = os.environ.get("ZHANLU_WORKSPACE_ROOT", "/Volumes/Files/zhanlu-ide")
    return Path(configured).expanduser().resolve()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Prepare and trigger a Zhanlu development or formal release."
    )
    result.add_argument("--kind", choices=("development", "formal"), required=True)
    result.add_argument("--version", required=True, help="Base/exact Zhanlu version")
    result.add_argument("--time-patch", help="Explicit internal patch, 1-4 digits")
    result.add_argument("--workspace", type=Path, default=default_workspace())
    result.add_argument("--workflow-ref", default="master", help="VSCodium workflow branch")  # zhanlu_change
    result.add_argument("--source-branch", default="develop")
    result.add_argument("--delivery-profile", default="default")
    result.add_argument("--zhanlu-core-ref", default="develop")
    result.add_argument("--zhanlu-vs-ref", default="")  # zhanlu_change - optional legacy VSIX source
    result.add_argument(
        "--bundle-codex-runtime", choices=("0", "1"), default="0",
        help="Bundle the optional Codex CLI runtime (default: 0)",
    )
    result.add_argument(
        "--platform", choices=("all", "macos", "linux", "windows"), default="all"
    )
    result.add_argument("--trigger-only", action="store_true")
    result.add_argument("--no-gitlab", action="store_true")
    result.add_argument("--publish", action="store_true")
    result.add_argument("--no-wait", action="store_true")
    result.add_argument("--apply", action="store_true")
    result.add_argument("--poll-interval", type=float, default=30.0)
    result.add_argument("--run-discovery-timeout", type=float, default=300.0)
    result.add_argument("--output", choices=("text", "json"), default="text")
    result.add_argument(
        "--request-id",
        help="Stable portal request UUID propagated to workflow run names",
    )
    result.add_argument(
        "--generate-only",
        action="store_true",
        help="Generate workflow artifacts without uploading to a Release",
    )
    result.add_argument(
        "--selected-source-sync",
        action="store_true",
        help="Synchronize only the explicitly selected component refs",  # zhanlu_change
    )
    result.add_argument(
        "--portal-source-sync",
        action="store_true",
        help="Apply a confirmed required-develop plus selected-ref portal plan",  # zhanlu_change
    )
    result.add_argument("--confirmed-source-plan", type=Path, help=argparse.SUPPRESS)
    result.add_argument("--source-commit", help=argparse.SUPPRESS)
    result.add_argument("--zhanlu-core-commit", help=argparse.SUPPRESS)
    result.add_argument("--zhanlu-vs-commit", help=argparse.SUPPRESS)
    return result


def parse_config(argv: Sequence[str] | None = None) -> Config:
    args = parser().parse_args(argv)
    if args.selected_source_sync and args.portal_source_sync:
        raise BuildError("selected and portal source synchronization are mutually exclusive")
    if args.portal_source_sync != bool(args.confirmed_source_plan):
        raise BuildError("--portal-source-sync requires --confirmed-source-plan")
    if args.poll_interval <= 0:
        raise BuildError("--poll-interval must be greater than zero")
    if args.run_discovery_timeout < 0:
        raise BuildError("--run-discovery-timeout cannot be negative")
    for name, value in (
        ("--source-commit", args.source_commit),
        ("--zhanlu-core-commit", args.zhanlu_core_commit),
        ("--zhanlu-vs-commit", args.zhanlu_vs_commit),
    ):
        if value is not None and not re.fullmatch(r"[0-9a-f]{40}", value):
            raise BuildError(f"{name} must be an exact lowercase 40-character Git SHA")
    return Config(
        workspace=args.workspace.resolve(),
        kind=args.kind,
        version=args.version,
        time_patch=args.time_patch,
        workflow_ref=args.workflow_ref,
        source_branch=args.source_branch,
        delivery_profile=args.delivery_profile,
        zhanlu_core_ref=args.zhanlu_core_ref,
        zhanlu_vs_ref=args.zhanlu_vs_ref,
        bundle_codex_runtime=args.bundle_codex_runtime,
        platform=args.platform,
        apply=args.apply,
        trigger_only=args.trigger_only,
        no_gitlab=args.no_gitlab,
        publish=args.publish,
        no_wait=args.no_wait,
        poll_interval=args.poll_interval,
        discovery_timeout=args.run_discovery_timeout,
        output_format=args.output,
        request_id=args.request_id,
        generate_only=args.generate_only,
        selected_source_sync=args.selected_source_sync,
        portal_source_sync=args.portal_source_sync,
        confirmed_source_plan=args.confirmed_source_plan.resolve() if args.confirmed_source_plan else None,
        source_commit=args.source_commit,
        zhanlu_core_commit=args.zhanlu_core_commit,
        zhanlu_vs_commit=args.zhanlu_vs_commit,
    )


def normalize_time_patch(value: str) -> str:
    if not TIME_PATCH_RE.fullmatch(value):
        raise BuildError(f"invalid time patch: {value!r}; expected 1-4 digits")
    return f"{int(value):04d}"


def generated_time_patch(now: dt.datetime) -> str:
    return f"{now.timetuple().tm_yday * 24 + now.hour:04d}"


def resolve_version(
    kind: str,
    requested: str,
    explicit_patch: str | None,
    now: dt.datetime,
) -> tuple[str, str]:
    match = VERSION_RE.fullmatch(requested)
    if not match:
        raise BuildError(
            f"invalid version: {requested!r}; expected X.Y.Z, optionally prefixed by v"
        )

    major, minor, public_patch = match.groups()
    normalized = f"{major}.{minor}.{public_patch}"
    supplied_patch = normalize_time_patch(explicit_patch) if explicit_patch else None

    if kind == "formal":
        return normalized, supplied_patch or generated_time_patch(now)

    if len(public_patch) > 4:
        inferred_patch = public_patch[-4:]
        if supplied_patch and supplied_patch != inferred_patch:
            raise BuildError(
                "explicit time patch does not match the exact development version "
                f"suffix: {supplied_patch} != {inferred_patch}"
            )
        return normalized, inferred_patch

    time_patch = supplied_patch or generated_time_patch(now)
    return f"{normalized}{time_patch}", time_patch


def selected_workflows(platform: str) -> tuple[str, ...]:
    if platform == "all":
        return tuple(WORKFLOWS.values())
    return (WORKFLOWS[platform],)


def make_plan(config: Config, now: dt.datetime | None = None) -> ReleasePlan:
    if config.generate_only and config.kind != "development":
        raise BuildError("--generate-only is only valid for development builds")
    if config.generate_only and config.trigger_only:
        raise BuildError("--generate-only cannot be combined with --trigger-only")
    current = now or dt.datetime.now().astimezone()
    release_version, version_time_patch = resolve_version(
        config.kind, config.version, config.time_patch, current
    )
    return ReleasePlan(
        config=config,
        release_repo=config.workspace / "vscodium",
        release_version=release_version,
        version_time_patch=version_time_patch,
        release_date=current.strftime("%Y%m%d"),
        gitlab_sync=(
            config.kind == "formal" and not config.no_gitlab and not config.trigger_only
        ),
        workflows=selected_workflows(config.platform),
    )


def validate_native_scripts(plan: ReleasePlan) -> None:
    expected_repo = (plan.config.workspace / "vscodium").resolve()
    if plan.release_repo.resolve() != expected_repo:
        raise BuildError(f"release checkout must be {expected_repo}")

    create_script = plan.release_repo / "create-release.sh"
    trigger_script = plan.release_repo / "scripts" / "trigger-stable-release.sh"
    sync_script = plan.release_repo / "scripts" / "sync-zhanlu-gitlab-to-github.sh"
    selected_sync_script = (
        plan.release_repo / "scripts" / "sync-zhanlu-selected-refs.sh"
    )
    sync_config = plan.release_repo / "scripts" / "sync-zhanlu-gitlab-to-github.repos"
    if (
        not create_script.is_file()
        or not trigger_script.is_file()
        or not sync_script.is_file()
        or not sync_config.is_file()
        or ((plan.config.selected_source_sync or plan.config.portal_source_sync) and not selected_sync_script.is_file())
    ):
        raise BuildError(
            f"missing native release scripts under canonical checkout: {plan.release_repo}"
        )

    create_text = create_script.read_text(encoding="utf-8")
    trigger_text = trigger_script.read_text(encoding="utf-8")
    sync_text = sync_script.read_text(encoding="utf-8")
    for token in ("-g)", "--delivery-profile)"):
        if token not in create_text:
            raise BuildError(f"create-release.sh lacks required capability: {token}")
    for token in (
        "--delivery-profile)",
        "--workflow-ref)",  # zhanlu_change
        "--zhanlu-vs-ref)",
        "--bundle-codex-runtime)",
        "--version-time-patch)",
    ):
        if token not in trigger_text:
            raise BuildError(
                f"trigger-stable-release.sh lacks required capability: {token}"
            )
    for token in ("--dry-run", "--all-refs"):
        if token not in sync_text:
            raise BuildError(
                f"sync-zhanlu-gitlab-to-github.sh lacks required capability: {token}"
            )
    if plan.config.selected_source_sync or plan.config.portal_source_sync:
        selected_text = selected_sync_script.read_text(encoding="utf-8")
        for token in ("--ref", "--output-plan", "--apply-plan"):
            if token not in selected_text:
                raise BuildError(
                    f"sync-zhanlu-selected-refs.sh lacks required capability: {token}"
                )


def source_sync_command(plan: ReleasePlan, *, dry_run: bool) -> list[str]:
    command = ["bash", "./scripts/sync-zhanlu-gitlab-to-github.sh"]
    if dry_run:
        command.append("--dry-run")
    if plan.source_sync_all_refs:
        command.append("--all-refs")
    return command


def selected_source_sync_command(
    plan: ReleasePlan, *, dry_run: bool, plan_file: Path
) -> list[str]:
    command = ["bash", "./scripts/sync-zhanlu-selected-refs.sh"]
    if dry_run:
        command.extend(["--dry-run", "--ref", f"zhanlu-code={plan.config.source_branch}", "--ref", f"zhanlu-core={plan.config.zhanlu_core_ref}"])
        if plan.config.zhanlu_vs_ref:  # zhanlu_change
            command.extend(["--ref", f"zhanlu-vs={plan.config.zhanlu_vs_ref}"])
        command.extend(["--output-plan", str(plan_file)])
    else:
        command.extend(["--apply-plan", str(plan_file)])
    return command


def create_command(plan: ReleasePlan) -> list[str]:
    command = ["bash", "create-release.sh"]
    if plan.gitlab_sync:
        command.append("-g")
    command.extend(
        [
            "--source-branch",
            plan.config.source_branch,
            "--delivery-profile",
            plan.config.delivery_profile,
        ]
    )
    return command


def trigger_command(
    plan: ReleasePlan,
    resolved_sources: Mapping[str, ResolvedSourceRef] | None = None,
) -> list[str]:
    core_ref = (
        resolved_sources["zhanlu-core"].source_commit_sha
        if resolved_sources and "zhanlu-core" in resolved_sources
        else plan.config.zhanlu_core_commit or plan.config.zhanlu_core_ref
    )
    vs_ref = (
        resolved_sources["zhanlu-vs"].source_commit_sha
        if resolved_sources and "zhanlu-vs" in resolved_sources
        else plan.config.zhanlu_vs_commit or plan.config.zhanlu_vs_ref
    )
    command = [
        "bash",
        "./scripts/trigger-stable-release.sh",
        "--workflow",
        "--workflow-ref",
        plan.config.workflow_ref,
        "--source-branch",
        plan.config.source_branch,
        "--delivery-profile",
        plan.config.delivery_profile,
        "--zhanlu-core-ref",
        core_ref,
        "--bundle-codex-runtime",
        plan.config.bundle_codex_runtime,
        "--platform",
        plan.config.platform,
        "--release-version",
        plan.release_version,
        "--version-time-patch",
        plan.version_time_patch,
    ]
    if vs_ref:  # zhanlu_change
        command.extend(["--zhanlu-vs-ref", vs_ref])
    if plan.config.generate_only:
        command.append("--generate")
    if plan.config.request_id:
        command.extend(["--request-id", plan.config.request_id])
    if plan.config.output_format == "json":
        command.extend(["--output", "json"])
    return command


def source_refs_document(
    resolved_sources: Mapping[str, ResolvedSourceRef],
) -> dict[str, dict[str, str]]:
    return {
        repository: {
            "repository": item.repository,
            "refType": item.ref_type,
            "requestedRef": item.requested_ref,
            "sourceRef": item.source_ref,
            "destinationRef": item.destination_ref,
            "gitlabSha": item.source_commit_sha,
            "gitlabObjectSha": item.source_object_sha,
            "previousGithubSha": item.destination_sha,
            "action": item.action,
        }
        for repository, item in sorted(resolved_sources.items())
    }


def source_plan_document(
    rows: Sequence[ResolvedSourceRef],
) -> list[dict[str, str]]:
    return [
        {
            "repository": item.repository,
            "refType": item.ref_type,
            "requestedRef": item.requested_ref,
            "sourceRef": item.source_ref,
            "destinationRef": item.destination_ref,
            "gitlabSha": item.source_commit_sha,
            "gitlabObjectSha": item.source_object_sha,
            "previousGithubSha": item.destination_sha,
            "action": item.action,
        }
        for item in rows
    ]


def plan_document(
    plan: ReleasePlan,
    resolved_sources: Mapping[str, ResolvedSourceRef] | None = None,
) -> dict[str, object]:
    document: dict[str, object] = {
        "schemaVersion": "v1",
        "requestId": plan.config.request_id,
        "mode": "apply" if plan.config.apply else "preview",
        "kind": plan.config.kind,
        "releaseVersion": plan.release_version,
        "versionTimePatch": plan.version_time_patch,
        "sourceBranch": plan.config.source_branch,
        "vscodiumRef": plan.config.workflow_ref,  # zhanlu_change
        "deliveryProfile": plan.config.delivery_profile,
        "zhanluCoreRef": plan.config.zhanlu_core_ref,
        "zhanluVsRef": plan.config.zhanlu_vs_ref,
        "bundleCodexRuntime": plan.config.bundle_codex_runtime == "1",
        "platform": plan.config.platform,
        "generateOnly": plan.config.generate_only,
        "triggerOnly": plan.config.trigger_only,
        "syncGitLab": plan.gitlab_sync,
        "publish": plan.config.publish,
        "sourceSyncAllRefs": plan.source_sync_all_refs,
        "sourceSyncSelectedRefs": plan.config.selected_source_sync,
        "sourceSyncPortalPlan": plan.config.portal_source_sync,
        "workflows": list(plan.workflows),
    }
    if resolved_sources:
        document["sourceRefs"] = source_refs_document(resolved_sources)
    return document


def safe_environment(
    plan: ReleasePlan,
    resolved_sources: Mapping[str, ResolvedSourceRef] | None = None,
) -> dict[str, str]:
    result = dict(os.environ)
    result.update(
        {
            "RELEASE_VERSION": plan.release_version,
            "VERSION_TIME_PATCH": plan.version_time_patch,
            "RELEASE_DRAFT": "false" if plan.config.publish else "true",
            "SOURCE_BRANCH": plan.config.source_branch,
            "ZHANLU_DELIVERY_PROFILE": plan.config.delivery_profile,
            "ZHANLU_IDE_ROOT": str(plan.config.workspace),
            "RELEASE_DATE": plan.release_date,
            "GITLAB_FORCE_TAG_UPDATE": "false",
            "ZHANLU_BUNDLE_CODEX_RUNTIME": plan.config.bundle_codex_runtime,
            "WORKFLOW_REF": plan.config.workflow_ref,  # zhanlu_change
            "GITLAB_RELEASE_REPOS": " ".join(component_repositories(plan)),  # zhanlu_change
        }
    )
    source_commit = (
        resolved_sources["zhanlu-code"].source_commit_sha
        if resolved_sources and "zhanlu-code" in resolved_sources
        else plan.config.source_commit
    )
    if source_commit:
        result["ZHANLU_DELIVERY_SOURCE_COMMIT"] = source_commit
    return result


def read_env_value(env_file: Path, key: str) -> str | None:
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*(.*?)\s*$")
    for raw_line in env_file.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        match = pattern.match(raw_line)
        if not match:
            continue
        value = match.group(1)
        if " #" in value:
            value = value.split(" #", 1)[0].rstrip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        return value or None
    return None


def gitlab_cli_host(environment: Mapping[str, str]) -> tuple[str, str]:
    raw = environment.get("GITLAB_HOST", "").strip()
    api_host = environment.get("GITLAB_API_HOST", "").strip()
    protocol = environment.get("GITLAB_API_PROTOCOL", "").strip()
    if raw.startswith("http://") or raw.startswith("https://"):
        parsed = urlparse(raw)
        return raw.rstrip("/"), parsed.hostname or api_host
    host = api_host or raw
    if not host:
        return raw, ""
    return f"{(protocol or 'https')}://{host}", host


def prepare_gitlab_cli_environment(workspace: Path, environment: dict[str, str]) -> None:
    url, host = gitlab_cli_host(environment)
    if url:
        environment["GITLAB_HOST"] = url
    token = environment.get("GITLAB_TOKEN") or environment.get("GITLAB_ACCESS_TOKEN")
    if not token or not host:
        return
    config_home = workspace / ".zhanlu-cli" / "config"
    cache_home = workspace / ".zhanlu-cli" / "cache"
    config_dir = config_home / "glab-cli"
    config_dir.mkdir(parents=True, exist_ok=True)
    cache_home.mkdir(parents=True, exist_ok=True)
    config_path = config_dir / "config.yml"
    protocol = "http" if url.startswith("http://") else "https"
    config_path.write_text(
        f"hosts:\n    {host}:\n        token: {token}\n"
        f"        api_host: {host}\n        api_protocol: {protocol}\n",
        encoding="utf-8",
    )
    config_path.chmod(0o600)
    environment["XDG_CONFIG_HOME"] = str(config_home)
    environment["XDG_CACHE_HOME"] = str(cache_home)


def load_gitlab_environment(workspace: Path, environment: dict[str, str]) -> None:
    env_file = workspace / ".env"
    if env_file.is_file() and not (
        environment.get("GITLAB_TOKEN") or environment.get("GITLAB_ACCESS_TOKEN")
    ):
        for key in (
            "GITLAB_TOKEN",
            "GITLAB_ACCESS_TOKEN",
            "OAUTH_TOKEN",
            "GLAB_TOKEN",
            "ZHANLU_GITLAB_TOKEN",
            "ZHANLU_GITHUB_TOKEN",
        ):
            value = read_env_value(env_file, key)
            if value:
                environment["GITLAB_TOKEN"] = value
                break
    if env_file.is_file() and not environment.get("GITLAB_HOST"):
        host = read_env_value(env_file, "GITLAB_HOST") or read_env_value(
            env_file, "CI_SERVER_HOST"
        )
        if host:
            environment["GITLAB_HOST"] = host
    prepare_gitlab_cli_environment(workspace, environment)


def command_text(args: Iterable[str]) -> str:
    return shlex.join(list(args))


def local_repo_snapshot(
    runner: CommandRunner, repo: Path, expected_branch: str
) -> tuple[str, str, str]:
    if not repo.exists():
        return "missing", "-", "-"
    try:
        branch = runner.run(
            ["git", "-C", str(repo), "branch", "--show-current"]
        ).stdout.strip()
        sha = runner.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"]
        ).stdout.strip()
        dirty = runner.run(
            ["git", "-C", str(repo), "status", "--porcelain"]
        ).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return "invalid", "-", "-"
    state = "clean" if not dirty else "dirty"
    if branch != expected_branch:
        state = f"{state}, expected {expected_branch}"
    return state, branch or "detached", sha or "-"


def print_plan(
    plan: ReleasePlan, runner: CommandRunner, output: TextIO = sys.stdout
) -> None:
    if plan.config.output_format == "json":
        print(json.dumps(plan_document(plan), sort_keys=True), file=output)
        return
    mode = "APPLY" if plan.config.apply else "DRY RUN"
    print("Zhanlu build plan", file=output)
    print(f"  mode: {mode}", file=output)
    print(f"  workspace: {plan.config.workspace}", file=output)
    print(f"  release checkout: {plan.release_repo}", file=output)
    print(f"  kind: {plan.config.kind}", file=output)
    print(f"  release version: {plan.release_version}", file=output)
    print(f"  internal time patch: {plan.version_time_patch}", file=output)
    print(f"  source branch: {plan.config.source_branch}", file=output)
    print(f"  vscodium workflow branch: {plan.config.workflow_ref}", file=output)  # zhanlu_change
    print(f"  zhanlu-core ref: {plan.config.zhanlu_core_ref}", file=output)
    print(f"  zhanlu-vs ref: {plan.config.zhanlu_vs_ref}", file=output)
    print(f"  bundle Codex runtime: {plan.config.bundle_codex_runtime}", file=output)
    print(f"  delivery profile: {plan.config.delivery_profile}", file=output)
    print(f"  platform: {plan.config.platform}", file=output)
    print(
        "  GitLab -> GitHub source sync: "
        + (
            "confirmed portal plan"
            if plan.config.portal_source_sync
            else
            "selected refs only"
            if plan.config.selected_source_sync
            else "all branches and tags"
            if plan.source_sync_all_refs
            else "default branches"
        ),
        file=output,
    )
    print(f"  GitHub visibility: {'draft' if plan.release_draft else 'published'}", file=output)
    print(f"  create/update release: {'no' if plan.config.trigger_only or plan.config.generate_only else 'yes'}", file=output)
    print(f"  component GitLab sync: {'yes' if plan.gitlab_sync else 'no'}", file=output)
    if plan.gitlab_sync:
        print(
            "  component GitLab tag: "
            f"release_zhanlu-ide_v{plan.release_version}_{plan.release_date}",
            file=output,
        )
    print(f"  wait for workflows: {'no' if plan.config.no_wait else 'yes'}", file=output)

    state, branch, sha = local_repo_snapshot(runner, plan.release_repo, plan.config.workflow_ref)  # zhanlu_change
    print("Local repository snapshot (no fetch):", file=output)
    print(f"  vscodium: state={state} branch={branch} sha={sha}", file=output)
    if plan.gitlab_sync:
        for name in component_repositories(plan):  # zhanlu_change
            state, branch, sha = local_repo_snapshot(
                runner, plan.config.workspace / name, "develop"
            )
            print(f"  {name}: state={state} branch={branch} sha={sha}", file=output)

    print("Native commands:", file=output)
    if plan.config.portal_source_sync:
        assert plan.config.confirmed_source_plan is not None
        print(
            "  " + command_text(selected_source_sync_command(
                plan, dry_run=False, plan_file=plan.config.confirmed_source_plan
            )),
            file=output,
        )
    elif plan.config.selected_source_sync:
        placeholder = Path("<selected-ref-plan>")
        print(
            "  " + command_text(selected_source_sync_command(plan, dry_run=True, plan_file=placeholder)),
            file=output,
        )
        print(
            "  " + command_text(selected_source_sync_command(plan, dry_run=False, plan_file=placeholder)),
            file=output,
        )
    else:
        print("  " + command_text(source_sync_command(plan, dry_run=True)), file=output)
        print("  " + command_text(source_sync_command(plan, dry_run=False)), file=output)
    if not plan.config.trigger_only and not plan.config.generate_only:
        print(
            "  "
            + f"RELEASE_VERSION={shlex.quote(plan.release_version)} "
            + f"VERSION_TIME_PATCH={shlex.quote(plan.version_time_patch)} "
            + f"RELEASE_DRAFT={'true' if plan.release_draft else 'false'} "
            + command_text(create_command(plan)),
            file=output,
        )
    print("  " + command_text(trigger_command(plan)), file=output)
    if not plan.config.apply:
        print("Dry run only: no remote command was executed. Add --apply only after confirmation.", file=output)


def require_tool(name: str) -> None:
    if shutil.which(name) is None:
        raise BuildError(f"required command not found in PATH: {name}")


def require_synced_repo(
    runner: CommandRunner,
    repo: Path,
    expected_branch: str,
) -> str:
    if not repo.exists():
        raise BuildError(f"repository does not exist: {repo}")
    dirty = runner.run(
        ["git", "-C", str(repo), "status", "--porcelain"]
    ).stdout.strip()
    if dirty:
        raise BuildError(f"repository must be clean before release: {repo}")
    branch = runner.run(
        ["git", "-C", str(repo), "branch", "--show-current"]
    ).stdout.strip()
    if branch != expected_branch:
        raise BuildError(
            f"repository {repo} must be on {expected_branch}, found {branch or 'detached'}"
        )
    runner.run(
        ["git", "-C", str(repo), "fetch", "--quiet", "origin", expected_branch]
    )
    head = runner.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"]
    ).stdout.strip()
    remote = runner.run(
        ["git", "-C", str(repo), "rev-parse", f"origin/{expected_branch}"]
    ).stdout.strip()
    if head != remote:
        raise BuildError(
            f"repository {repo} is not synchronized with origin/{expected_branch}: "
            f"HEAD={head}, remote={remote}"
        )
    return head


def preflight_apply(
    plan: ReleasePlan,
    runner: CommandRunner,
    environment: dict[str, str],
    output: TextIO,
) -> tuple[str, str]:
    for tool in ("git", "gh", "bash"):
        require_tool(tool)
    if plan.gitlab_sync:
        require_tool("glab")

    release_sha = require_synced_repo(runner, plan.release_repo, plan.config.workflow_ref)  # zhanlu_change
    print(f"Preflight vscodium: {release_sha}", file=output)

    if plan.gitlab_sync:
        load_gitlab_environment(plan.config.workspace, environment)
        if not (
            environment.get("GITLAB_TOKEN")
            or environment.get("GITLAB_ACCESS_TOKEN")
        ):
            raise BuildError(
                "formal GitLab sync requires GITLAB_TOKEN or GITLAB_ACCESS_TOKEN "
                "in the process or workspace .env"
            )
        for name in component_repositories(plan):  # zhanlu_change
            sha = require_synced_repo(
                runner, plan.config.workspace / name, "develop"
            )
            print(f"Preflight {name}: {sha}", file=output)

    runner.run(["gh", "auth", "status"], cwd=plan.release_repo, env=environment)
    repo_slug = runner.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        cwd=plan.release_repo,
        env=environment,
    ).stdout.strip()
    if not repo_slug:
        raise BuildError("could not resolve the GitHub repository")
    if plan.gitlab_sync:
        runner.run(["glab", "auth", "status"], cwd=plan.release_repo, env=environment)
    return release_sha, repo_slug


def synchronize_sources(
    plan: ReleasePlan,
    runner: CommandRunner,
    environment: Mapping[str, str],
    output: TextIO,
) -> dict[str, ResolvedSourceRef]:
    for tool in ("git", "bash"):
        require_tool(tool)
    if plan.config.portal_source_sync:
        plan_file = plan.config.confirmed_source_plan
        if not plan_file or not plan_file.is_file():
            raise BuildError("confirmed portal source plan is not readable")
        rows, resolved = portal_source_plan(plan, plan_file)
        print("Applying confirmed portal GitLab -> GitHub source plan...", file=output)
        runner.run(
            selected_source_sync_command(
                plan, dry_run=False, plan_file=plan_file
            ),
            cwd=plan.release_repo,
            env=environment,
            capture=False,
        )
        event = {
            "schemaVersion": "v1",
            "event": "source_refs_resolved",
            "sourceRefs": source_refs_document(resolved),
            "mirrorPlan": source_plan_document(rows),
        }
        print(json.dumps(event, sort_keys=True), file=output)
        print(
            "GitLab -> GitHub source synchronization completed "
            "(confirmed portal plan).",
            file=output,
        )
        return resolved
    if plan.config.selected_source_sync:
        print("Previewing selected GitLab -> GitHub refs...", file=output)
        with tempfile.TemporaryDirectory(prefix="zhanlu-selected-ref-plan.") as directory:
            plan_file = Path(directory) / "selected-refs.tsv"
            runner.run(
                selected_source_sync_command(
                    plan, dry_run=True, plan_file=plan_file
                ),
                cwd=plan.release_repo,
                env=environment,
                capture=False,
            )
            resolved = parse_selected_ref_plan(plan_file)
            expected = {"zhanlu-code", "zhanlu-core", "zhanlu-vs"}
            if set(resolved) != expected:
                raise BuildError(
                    "selected-ref synchronization did not resolve exactly "
                    "zhanlu-code, zhanlu-core, and zhanlu-vs"
                )
            print("Synchronizing selected GitLab refs to GitHub...", file=output)
            runner.run(
                selected_source_sync_command(
                    plan, dry_run=False, plan_file=plan_file
                ),
                cwd=plan.release_repo,
                env=environment,
                capture=False,
            )
        event = {
            "schemaVersion": "v1",
            "event": "source_refs_resolved",
            "sourceRefs": source_refs_document(resolved),
        }
        print(json.dumps(event, sort_keys=True), file=output)
        print(
            "GitLab -> GitHub source synchronization completed (selected refs).",
            file=output,
        )
        return resolved
    print("Previewing GitLab -> GitHub source synchronization...", file=output)
    runner.run(
        source_sync_command(plan, dry_run=True),
        cwd=plan.release_repo,
        env=environment,
        capture=False,
    )
    print("Synchronizing GitLab sources to GitHub...", file=output)
    runner.run(
        source_sync_command(plan, dry_run=False),
        cwd=plan.release_repo,
        env=environment,
        capture=False,
    )
    scope = "all refs" if plan.source_sync_all_refs else "default branches"
    print(f"GitLab -> GitHub source synchronization completed ({scope}).", file=output)
    return {}


def parse_selected_ref_plan_rows(path: Path) -> list[ResolvedSourceRef]:
    result: list[ResolvedSourceRef] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise BuildError(f"could not read selected-ref plan: {error}") from error
    for number, line in enumerate(lines, start=1):
        fields = line.split("\t")
        if len(fields) != 9:
            raise BuildError(f"invalid selected-ref plan row {number}")
        (
            repository,
            ref_type,
            requested_ref,
            source_ref,
            destination_ref,
            source_object_sha,
            source_commit_sha,
            destination_sha,
            action,
        ) = fields
        if not re.fullmatch(r"[0-9a-f]{40}", source_object_sha) or not re.fullmatch(
            r"[0-9a-f]{40}", source_commit_sha
        ):
            raise BuildError(f"invalid selected-ref SHA for {repository}")
        if destination_sha == "-":
            destination_sha = ""
        elif not re.fullmatch(r"[0-9a-f]{40}", destination_sha):
            raise BuildError(f"invalid previous GitHub SHA for {repository}")
        result.append(ResolvedSourceRef(
            repository=repository,
            ref_type=ref_type,
            requested_ref=requested_ref,
            source_ref=source_ref,
            destination_ref=destination_ref,
            source_object_sha=source_object_sha,
            source_commit_sha=source_commit_sha,
            destination_sha=destination_sha,
            action=action,
        ))
    return result


def parse_selected_ref_plan(path: Path) -> dict[str, ResolvedSourceRef]:
    result: dict[str, ResolvedSourceRef] = {}
    for item in parse_selected_ref_plan_rows(path):
        if item.repository in result:
            raise BuildError(
                f"duplicate selected-ref plan repository: {item.repository}"
            )
        result[item.repository] = item
    return result


def portal_source_plan(
    plan: ReleasePlan, path: Path
) -> tuple[list[ResolvedSourceRef], dict[str, ResolvedSourceRef]]:
    rows = parse_selected_ref_plan_rows(path)
    expected_repositories = set(component_repositories(plan))  # zhanlu_change
    develop_rows = {
        item.repository: item
        for item in rows
        if item.destination_ref == "refs/heads/develop"
    }
    if set(develop_rows) != expected_repositories:
        raise BuildError(
            f"portal source plan must contain develop for all {len(expected_repositories)} selected components"
        )
    selected_requests = {
        "zhanlu-code": plan.config.source_branch,
        "zhanlu-core": plan.config.zhanlu_core_ref,
        **({"zhanlu-vs": plan.config.zhanlu_vs_ref} if plan.config.zhanlu_vs_ref else {}),  # zhanlu_change
    }
    selected: dict[str, ResolvedSourceRef] = {}
    for repository, requested in selected_requests.items():
        matches = [
            item for item in rows
            if item.repository == repository and item.requested_ref == requested
        ]
        if len(matches) != 1:
            raise BuildError(
                f"portal source plan must resolve exactly one {repository}={requested}"
            )
        selected[repository] = matches[0]
    destinations = [(item.repository, item.destination_ref) for item in rows]
    if len(set(destinations)) != len(destinations):
        raise BuildError("portal source plan contains duplicate destination refs")
    expected_count = len(expected_repositories) + sum(  # zhanlu_change
        requested not in ("develop", "refs/heads/develop")
        for requested in selected_requests.values()
    )
    if len(rows) != expected_count:
        raise BuildError(
            f"portal source plan has {len(rows)} rows; expected {expected_count}"
        )
    return rows, selected


def parse_json_list(raw: str, context: str) -> list[dict[str, object]]:
    try:
        value = json.loads(raw or "[]")
    except json.JSONDecodeError as error:
        raise BuildError(f"invalid JSON from {context}: {error}") from error
    if not isinstance(value, list):
        raise BuildError(f"expected a JSON list from {context}")
    return [item for item in value if isinstance(item, dict)]


def release_assets_repository(plan: ReleasePlan, default_repo: str) -> str:
    metadata = plan.release_repo / ".zhanlu" / "release-delivery.json"
    if not metadata.is_file():
        return default_repo
    try:
        value = json.loads(metadata.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default_repo
    if not isinstance(value, dict):
        return default_repo
    if value.get("releaseVersion") not in (None, "", plan.release_version):
        return default_repo
    repository = value.get("assetsRepository")
    return repository if isinstance(repository, str) and repository else default_repo


def report_github_release(
    plan: ReleasePlan,
    runner: CommandRunner,
    repo_slug: str,
    environment: Mapping[str, str],
    output: TextIO,
) -> str:
    assets_repository = release_assets_repository(plan, repo_slug)
    result = runner.run(
        [
            "gh",
            "release",
            "view",
            plan.release_version,
            "--repo",
            assets_repository,
            "--json",
            "url,isDraft",
        ],
        cwd=plan.release_repo,
        env=environment,
    )
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise BuildError(f"invalid JSON from gh release view: {error}") from error
    if not isinstance(value, dict) or not value.get("url"):
        raise BuildError("GitHub Release exists but its URL could not be resolved")
    visibility = "draft" if value.get("isDraft") else "published"
    print(f"GitHub Release ({visibility}): {value['url']}", file=output)
    return assets_repository


def list_workflow_runs(
    runner: CommandRunner,
    repo_slug: str,
    workflow: str,
    environment: Mapping[str, str],
    cwd: Path,
) -> list[dict[str, object]]:
    result = runner.run(
        [
            "gh",
            "run",
            "list",
            "--repo",
            repo_slug,
            "--workflow",
            workflow,
            "--event",
            "workflow_dispatch",
            "--limit",
            "20",
            "--json",
            "databaseId,createdAt,headBranch,status,conclusion,url",
        ],
        cwd=cwd,
        env=environment,
    )
    return parse_json_list(result.stdout, f"gh run list {workflow}")


def capture_run_baseline(
    plan: ReleasePlan,
    runner: CommandRunner,
    repo_slug: str,
    environment: Mapping[str, str],
) -> dict[str, set[int]]:
    baseline: dict[str, set[int]] = {}
    for workflow in plan.workflows:
        baseline[workflow] = {
            int(item["databaseId"])
            for item in list_workflow_runs(
                runner, repo_slug, workflow, environment, plan.release_repo
            )
            if isinstance(item.get("databaseId"), int)
        }
    return baseline


def discover_new_runs(
    plan: ReleasePlan,
    runner: CommandRunner,
    repo_slug: str,
    environment: Mapping[str, str],
    baseline: Mapping[str, set[int]],
    output: TextIO,
    monotonic: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> dict[str, dict[str, object]]:
    deadline = monotonic() + plan.config.discovery_timeout
    found: dict[str, dict[str, object]] = {}
    while len(found) < len(plan.workflows):
        for workflow in plan.workflows:
            if workflow in found:
                continue
            candidates = [
                item
                for item in list_workflow_runs(
                    runner, repo_slug, workflow, environment, plan.release_repo
                )
                if isinstance(item.get("databaseId"), int)
                and int(item["databaseId"]) not in baseline.get(workflow, set())
                and item.get("headBranch") in (None, "", "master")
            ]
            if len(candidates) > 1:
                ids = ", ".join(str(item["databaseId"]) for item in candidates)
                raise BuildError(
                    f"ambiguous new runs for {workflow}: {ids}; refusing to attribute one"
                )
            if len(candidates) == 1:
                found[workflow] = candidates[0]
                print(
                    f"Discovered {workflow}: {candidates[0].get('url', candidates[0]['databaseId'])}",
                    file=output,
                )
        if len(found) == len(plan.workflows):
            break
        if monotonic() >= deadline:
            missing = ", ".join(w for w in plan.workflows if w not in found)
            raise BuildError(f"timed out discovering workflow runs: {missing}")
        sleep(plan.config.poll_interval)
    return found


def view_run(
    runner: CommandRunner,
    repo_slug: str,
    run_id: int,
    environment: Mapping[str, str],
    cwd: Path,
) -> dict[str, object]:
    result = runner.run(
        [
            "gh",
            "run",
            "view",
            str(run_id),
            "--repo",
            repo_slug,
            "--json",
            "status,conclusion,url,workflowName,jobs",
        ],
        cwd=cwd,
        env=environment,
    )
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise BuildError(f"invalid JSON from gh run view {run_id}: {error}") from error
    if not isinstance(value, dict):
        raise BuildError(f"expected a JSON object from gh run view {run_id}")
    return value


def monitor_runs(
    plan: ReleasePlan,
    runner: CommandRunner,
    repo_slug: str,
    environment: Mapping[str, str],
    runs: Mapping[str, Mapping[str, object]],
    output: TextIO,
    sleep: Callable[[float], None] = time.sleep,
) -> bool:
    pending = dict(runs)
    successful = True
    last_status: dict[str, str] = {}
    while pending:
        for workflow, run in list(pending.items()):
            run_id = int(run["databaseId"])
            detail = view_run(
                runner, repo_slug, run_id, environment, plan.release_repo
            )
            status = str(detail.get("status") or "unknown")
            if last_status.get(workflow) != status:
                print(f"{workflow}: {status}", file=output)
                last_status[workflow] = status
            if status != TERMINAL_STATUS:
                continue
            conclusion = str(detail.get("conclusion") or "unknown")
            url = str(detail.get("url") or run.get("url") or run_id)
            print(f"{workflow}: {conclusion} {url}", file=output)
            if conclusion != "success":
                successful = False
                jobs = detail.get("jobs")
                if isinstance(jobs, list):
                    failed = [
                        str(job.get("name"))
                        for job in jobs
                        if isinstance(job, dict)
                        and job.get("conclusion") not in ("success", "skipped", None)
                    ]
                    if failed:
                        print(f"  failed jobs: {', '.join(failed)}", file=output)
            del pending[workflow]
        if pending:
            sleep(plan.config.poll_interval)
    return successful


def execute(
    plan: ReleasePlan,
    runner: CommandRunner | None = None,
    output: TextIO = sys.stdout,
    monotonic: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> int:
    active_runner = runner or CommandRunner()
    validate_native_scripts(plan)
    print_plan(plan, active_runner, output)
    if not plan.config.apply:
        return 0

    resolved_sources: dict[str, ResolvedSourceRef] = {}
    environment = safe_environment(plan)
    # A failed-platform retry must not repeat source synchronization.  The
    # existing Release is the immutable anchor for trigger-only recovery;
    # preflight and the dispatch script still validate the checkout/Release.
    if not plan.config.trigger_only:
        resolved_sources = synchronize_sources(
            plan, active_runner, environment, output
        )
        environment = safe_environment(plan, resolved_sources)
    _, repo_slug = preflight_apply(
        plan, active_runner, environment, output
    )

    if not plan.config.trigger_only and not plan.config.generate_only:
        print("Creating/updating the release before workflow fan-out...", file=output)
        active_runner.run(
            create_command(plan),
            cwd=plan.release_repo,
            env=environment,
            capture=False,
        )
        if plan.gitlab_sync:
            print(
                "Component GitLab synchronization completed: "
                f"release_zhanlu-ide_v{plan.release_version}_{plan.release_date}",
                file=output,
            )

    if not plan.config.generate_only:
        report_github_release(plan, active_runner, repo_slug, environment, output)

    baseline: dict[str, set[int]] = {}
    if not plan.config.no_wait:
        baseline = capture_run_baseline(plan, active_runner, repo_slug, environment)

    print("Dispatching stable workflow(s)...", file=output)
    trigger_result = active_runner.run(
        trigger_command(plan, resolved_sources),
        cwd=plan.release_repo,
        env=environment,
        capture=plan.config.output_format == "json",
    )

    dispatched_runs: list[dict[str, object]] = []
    if plan.config.output_format == "json":
        for line in trigger_result.stdout.splitlines():
            try:
                candidate = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(candidate, dict) and candidate.get("schemaVersion") == "v1":
                raw_runs = candidate.get("runs")
                if isinstance(raw_runs, list):
                    dispatched_runs = [item for item in raw_runs if isinstance(item, dict)]
        print(
            json.dumps(
                {
                    **plan_document(plan, resolved_sources),
                    "runs": dispatched_runs,
                },
                sort_keys=True,
            ),
            file=output,
        )

    if plan.config.no_wait:
        print(f"Workflows dispatched: https://github.com/{repo_slug}/actions", file=output)
        return 0

    runs = discover_new_runs(
        plan,
        active_runner,
        repo_slug,
        environment,
        baseline,
        output,
        monotonic=monotonic,
        sleep=sleep,
    )
    return 0 if monitor_runs(
        plan, active_runner, repo_slug, environment, runs, output, sleep=sleep
    ) else 1


def main(argv: Sequence[str] | None = None) -> int:
    try:
        config = parse_config(argv)
        return execute(make_plan(config))
    except BuildError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as error:
        print(
            f"ERROR: command failed ({error.returncode}): {command_text(error.cmd)}",
            file=sys.stderr,
        )
        return error.returncode or 1
    except KeyboardInterrupt:
        print("ERROR: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
