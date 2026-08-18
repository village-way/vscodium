#!/usr/bin/env python3

from __future__ import annotations

import datetime as dt
import importlib.util
from io import StringIO
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("zhanlu_build.py")
REPOSITORY_ROOT = SCRIPT.parents[4]
SPEC = importlib.util.spec_from_file_location("zhanlu_build", SCRIPT)
assert SPEC and SPEC.loader
zhanlu_build = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = zhanlu_build
SPEC.loader.exec_module(zhanlu_build)


class FakeRunner:
    def __init__(
        self,
        *,
        dirty_repo: str | None = None,
        fail_create: bool = False,
        fail_sync_preview: bool = False,
        fail_sync_apply: bool = False,
    ):
        self.dirty_repo = dirty_repo
        self.fail_create = fail_create
        self.fail_sync_preview = fail_sync_preview
        self.fail_sync_apply = fail_sync_apply
        self.calls: list[tuple[list[str], Path | None, dict[str, str] | None, bool]] = []
        self.run_lists: dict[str, list[dict[str, object]]] = {}
        self.run_views: dict[int, dict[str, object]] = {}

    def run(self, args, *, cwd=None, env=None, capture=True):
        command = list(args)
        saved_env = dict(env) if env is not None else None
        self.calls.append((command, cwd, saved_env, capture))

        if command[0] == "git":
            repo = Path(command[2])
            operation = command[3:]
            if operation == ["status", "--porcelain"]:
                dirty = self.dirty_repo == repo.name
                return zhanlu_build.CommandResult(stdout=" M changed\n" if dirty else "")
            if operation == ["branch", "--show-current"]:
                branch = "master" if repo.name == "vscodium" else "develop"
                return zhanlu_build.CommandResult(stdout=f"{branch}\n")
            if operation == ["rev-parse", "HEAD"]:
                return zhanlu_build.CommandResult(stdout=f"sha-{repo.name}\n")
            if operation[:1] == ["rev-parse"] and operation[1].startswith("origin/"):
                return zhanlu_build.CommandResult(stdout=f"sha-{repo.name}\n")
            if operation[:3] == ["fetch", "--quiet", "origin"]:
                return zhanlu_build.CommandResult()
            raise AssertionError(f"unexpected git command: {command}")

        if command[:3] == ["gh", "auth", "status"]:
            return zhanlu_build.CommandResult()
        if command[:3] == ["gh", "repo", "view"]:
            return zhanlu_build.CommandResult(stdout="village-way/vscodium\n")
        if command[:3] == ["gh", "release", "view"]:
            import json

            return zhanlu_build.CommandResult(
                stdout=json.dumps(
                    {"url": "https://github.com/village-way/vscodium/releases/tag/test", "isDraft": True}
                )
            )
        if command[:3] == ["glab", "auth", "status"]:
            return zhanlu_build.CommandResult()
        if command[:3] == ["gh", "run", "list"]:
            workflow = command[command.index("--workflow") + 1]
            import json

            return zhanlu_build.CommandResult(
                stdout=json.dumps(self.run_lists.get(workflow, []))
            )
        if command[:3] == ["gh", "run", "view"]:
            import json

            run_id = int(command[3])
            return zhanlu_build.CommandResult(
                stdout=json.dumps(self.run_views[run_id])
            )
        if command[:2] == [
            "bash",
            "./scripts/sync-zhanlu-gitlab-to-github.sh",
        ]:
            if "--dry-run" in command and self.fail_sync_preview:
                raise subprocess.CalledProcessError(1, command)
            if "--dry-run" not in command and self.fail_sync_apply:
                raise subprocess.CalledProcessError(2, command)
            return zhanlu_build.CommandResult()
        if command[:2] == ["bash", "./scripts/sync-zhanlu-selected-refs.sh"]:
            if "--dry-run" in command:
                if self.fail_sync_preview:
                    raise subprocess.CalledProcessError(1, command)
                plan_file = Path(command[command.index("--output-plan") + 1])
                selected = [
                    command[index + 1]
                    for index, value in enumerate(command)
                    if value == "--ref"
                ]
                rows = []
                for number, value in enumerate(selected, start=1):
                    repository, requested = value.split("=", 1)
                    source_sha = str(number) * 40
                    previous_sha = str(number + 3) * 40
                    rows.append(
                        "\t".join(
                            [
                                repository,
                                "branch",
                                requested,
                                f"refs/heads/{requested}",
                                f"refs/heads/{requested}",
                                source_sha,
                                source_sha,
                                previous_sha,
                                "update",
                            ]
                        )
                    )
                plan_file.write_text("\n".join(rows) + "\n", encoding="utf-8")
            elif self.fail_sync_apply:
                raise subprocess.CalledProcessError(2, command)
            return zhanlu_build.CommandResult()
        if command[:2] == ["bash", "create-release.sh"]:
            if self.fail_create:
                raise subprocess.CalledProcessError(9, command)
            return zhanlu_build.CommandResult()
        if command[:2] == ["bash", "./scripts/trigger-stable-release.sh"]:
            return zhanlu_build.CommandResult()
        raise AssertionError(f"unexpected command: {command}")


class ZhanluBuildTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.workspace = Path(self.temp.name)
        self.release_repo = self.workspace / "vscodium"
        (self.release_repo / "scripts").mkdir(parents=True)
        (self.release_repo / "create-release.sh").write_text(
            "case x in\n-g) ;;\n--delivery-profile) ;;\nesac\n",
            encoding="utf-8",
        )
        (self.release_repo / "scripts" / "trigger-stable-release.sh").write_text(
            "case x in\n"
            "--delivery-profile) ;;\n"
            "--zhanlu-vs-ref) ;;\n"
            "--bundle-codex-runtime) ;;\n"
            "--version-time-patch) ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        (self.release_repo / "scripts" / "sync-zhanlu-gitlab-to-github.sh").write_text(
            "case x in\n--dry-run) ;;\n--all-refs) ;;\nesac\n",
            encoding="utf-8",
        )
        (self.release_repo / "scripts" / "sync-zhanlu-selected-refs.sh").write_text(
            "case x in\n--ref) ;;\n--output-plan) ;;\n--apply-plan) ;;\nesac\n",
            encoding="utf-8",
        )
        (
            self.release_repo / "scripts" / "sync-zhanlu-gitlab-to-github.repos"
        ).write_text(
            "zhanlu-code\tgitlab\tgithub\tdevelop\n",
            encoding="utf-8",
        )
        for name in zhanlu_build.COMPONENT_REPOS:
            (self.workspace / name).mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def config(self, **overrides):
        values = {
            "workspace": self.workspace,
            "kind": "development",
            "version": "1.4.1",
            "time_patch": "5061",
            "source_branch": "develop",
            "delivery_profile": "default",
            "zhanlu_core_ref": "develop",
            "zhanlu_vs_ref": "develop",
            "bundle_codex_runtime": "0",
            "platform": "all",
            "apply": False,
            "trigger_only": False,
            "no_gitlab": False,
            "publish": False,
            "no_wait": True,
            "poll_interval": 0.01,
            "discovery_timeout": 0.01,
        }
        values.update(overrides)
        return zhanlu_build.Config(**values)

    @staticmethod
    def command_calls(runner: FakeRunner, prefix: list[str]):
        return [call for call in runner.calls if call[0][: len(prefix)] == prefix]

    def execute_apply(self, plan, runner):
        output = StringIO()
        with mock.patch.object(zhanlu_build.shutil, "which", return_value="/fake/tool"):
            result = zhanlu_build.execute(plan, runner=runner, output=output)
        return result, output.getvalue()

    def test_development_base_version_appends_one_patch(self):
        release, patch = zhanlu_build.resolve_version(
            "development", "1.4.1", None, dt.datetime(2026, 7, 30, 15)
        )
        expected_patch = f"{dt.datetime(2026, 7, 30, 15).timetuple().tm_yday * 24 + 15:04d}"
        self.assertEqual((release, patch), (f"1.4.1{expected_patch}", expected_patch))

    def test_exact_development_version_reuses_suffix(self):
        release, patch = zhanlu_build.resolve_version(
            "development", "1.4.15061", None, dt.datetime(2026, 1, 1)
        )
        self.assertEqual((release, patch), ("1.4.15061", "5061"))

    def test_exact_development_rejects_mismatched_patch(self):
        with self.assertRaises(zhanlu_build.BuildError):
            zhanlu_build.resolve_version(
                "development", "1.4.15061", "5062", dt.datetime(2026, 1, 1)
            )

    def test_formal_version_keeps_public_semver_and_pins_patch(self):
        release, patch = zhanlu_build.resolve_version(
            "formal", "v1.4.1", "61", dt.datetime(2026, 1, 1)
        )
        self.assertEqual((release, patch), ("1.4.1", "0061"))

    def test_formal_plan_uses_gitlab_and_full_default_parameters(self):
        plan = zhanlu_build.make_plan(
            self.config(kind="formal", version="1.4.1")
        )
        self.assertIn("-g", zhanlu_build.create_command(plan))
        trigger = zhanlu_build.trigger_command(plan)
        self.assertEqual(trigger[trigger.index("--platform") + 1], "all")
        self.assertEqual(trigger[trigger.index("--zhanlu-core-ref") + 1], "develop")
        self.assertEqual(trigger[trigger.index("--zhanlu-vs-ref") + 1], "develop")
        self.assertEqual(trigger[trigger.index("--bundle-codex-runtime") + 1], "0")
        self.assertEqual(trigger[trigger.index("--release-version") + 1], "1.4.1")
        self.assertEqual(trigger[trigger.index("--version-time-patch") + 1], "5061")
        self.assertFalse(plan.source_sync_all_refs)
        self.assertNotIn(
            "--all-refs", zhanlu_build.source_sync_command(plan, dry_run=False)
        )

    def test_codex_runtime_bundle_is_explicitly_forwarded(self):
        plan = zhanlu_build.make_plan(self.config(bundle_codex_runtime="1"))
        trigger = zhanlu_build.trigger_command(plan)
        self.assertEqual(trigger[trigger.index("--bundle-codex-runtime") + 1], "1")
        self.assertEqual(
            zhanlu_build.safe_environment(plan)["ZHANLU_BUNDLE_CODEX_RUNTIME"], "1"
        )

    def test_custom_build_ref_synchronizes_all_refs(self):
        plan = zhanlu_build.make_plan(
            self.config(zhanlu_vs_ref="feature/test")
        )
        self.assertTrue(plan.source_sync_all_refs)
        self.assertIn(
            "--all-refs", zhanlu_build.source_sync_command(plan, dry_run=True)
        )

    def test_portal_selected_sync_never_uses_all_refs(self):
        plan = zhanlu_build.make_plan(
            self.config(
                selected_source_sync=True,
                source_branch="feature/code",
                zhanlu_core_ref="develop",
                zhanlu_vs_ref="refs/tags/v2",
            )
        )
        self.assertFalse(plan.source_sync_all_refs)
        command = zhanlu_build.selected_source_sync_command(
            plan, dry_run=True, plan_file=Path("plan.tsv")
        )
        self.assertNotIn("--all-refs", command)
        self.assertIn("zhanlu-code=feature/code", command)
        self.assertIn("zhanlu-core=develop", command)
        self.assertIn("zhanlu-vs=refs/tags/v2", command)

    def test_selected_sync_pins_workflow_refs_and_emits_source_refs(self):
        plan = zhanlu_build.make_plan(
            self.config(
                apply=True,
                selected_source_sync=True,
                source_branch="feature/code",
                zhanlu_core_ref="feature/core",
                zhanlu_vs_ref="feature/vs",
                output_format="json",
            )
        )
        runner = FakeRunner()
        result, output = self.execute_apply(plan, runner)
        self.assertEqual(result, 0)
        selected_calls = self.command_calls(
            runner, ["bash", "./scripts/sync-zhanlu-selected-refs.sh"]
        )
        self.assertEqual(len(selected_calls), 2)
        self.assertNotIn("--all-refs", " ".join(selected_calls[0][0]))
        trigger = self.command_calls(
            runner, ["bash", "./scripts/trigger-stable-release.sh"]
        )[0]
        self.assertEqual(trigger[0][trigger[0].index("--zhanlu-core-ref") + 1], "2" * 40)
        self.assertEqual(trigger[0][trigger[0].index("--zhanlu-vs-ref") + 1], "3" * 40)
        self.assertEqual(trigger[2]["ZHANLU_DELIVERY_SOURCE_COMMIT"], "1" * 40)
        self.assertIn('"event": "source_refs_resolved"', output)
        self.assertIn('"sourceRefs"', output)

    def test_portal_applies_only_the_confirmed_five_develop_plan(self):
        plan_file = self.workspace / "confirmed.tsv"
        rows = []
        for number, repository in enumerate(zhanlu_build.COMPONENT_REPOS, start=1):
            source_sha = format(number, "x") * 40
            rows.append("\t".join([
                repository, "branch", "develop", "refs/heads/develop",
                "refs/heads/develop", source_sha, source_sha, "f" * 40,
                "update",
            ]))
        plan_file.write_text("\n".join(rows) + "\n", encoding="utf-8")
        plan = zhanlu_build.make_plan(self.config(
            apply=True,
            portal_source_sync=True,
            confirmed_source_plan=plan_file,
        ))
        runner = FakeRunner()
        result, output = self.execute_apply(plan, runner)
        self.assertEqual(result, 0)
        selected_calls = self.command_calls(
            runner, ["bash", "./scripts/sync-zhanlu-selected-refs.sh"]
        )
        self.assertEqual(len(selected_calls), 1)
        self.assertEqual(selected_calls[0][0], [
            "bash", "./scripts/sync-zhanlu-selected-refs.sh",
            "--apply-plan", str(plan_file),
        ])
        self.assertIn('"mirrorPlan"', output)
        self.assertNotIn("--all-refs", " ".join(selected_calls[0][0]))

    def test_trigger_only_reuses_persisted_source_commits(self):
        plan = zhanlu_build.make_plan(
            self.config(
                apply=True,
                trigger_only=True,
                platform="linux",
                selected_source_sync=True,
                source_branch="feature/code",
                source_commit="a" * 40,
                zhanlu_core_commit="b" * 40,
                zhanlu_vs_commit="c" * 40,
            )
        )
        runner = FakeRunner()
        result, _ = self.execute_apply(plan, runner)
        self.assertEqual(result, 0)
        self.assertFalse(
            self.command_calls(runner, ["bash", "./scripts/sync-zhanlu-selected-refs.sh"])
        )
        trigger = self.command_calls(
            runner, ["bash", "./scripts/trigger-stable-release.sh"]
        )[0]
        self.assertEqual(trigger[0][trigger[0].index("--zhanlu-core-ref") + 1], "b" * 40)
        self.assertEqual(trigger[0][trigger[0].index("--zhanlu-vs-ref") + 1], "c" * 40)
        self.assertEqual(trigger[2]["ZHANLU_DELIVERY_SOURCE_COMMIT"], "a" * 40)

    def test_cli_defaults_codex_runtime_bundle_to_zero(self):
        config = zhanlu_build.parse_config(
            ["--kind", "development", "--version", "1.4.1"]
        )
        self.assertEqual(config.bundle_codex_runtime, "0")

    def test_portal_contract_propagates_request_id_and_generate_only(self):
        config = zhanlu_build.parse_config(
            [
                "--kind", "development", "--version", "1.4.1",
                "--request-id", "portal-request-1", "--output", "json",
                "--generate-only",
            ]
        )
        plan = zhanlu_build.make_plan(config)
        trigger = zhanlu_build.trigger_command(plan)
        self.assertEqual(trigger[trigger.index("--request-id") + 1], "portal-request-1")
        self.assertIn("--generate", trigger)
        self.assertEqual(trigger[trigger.index("--output") + 1], "json")
        self.assertEqual(zhanlu_build.plan_document(plan)["schemaVersion"], "v1")

    def test_generate_only_never_creates_or_reads_a_release(self):
        plan = zhanlu_build.make_plan(self.config(generate_only=True, apply=True))
        runner = FakeRunner()
        result, _ = self.execute_apply(plan, runner)
        self.assertEqual(result, 0)
        self.assertFalse(self.command_calls(runner, ["bash", "create-release.sh"]))
        self.assertFalse(self.command_calls(runner, ["gh", "release", "view"]))

    def test_native_script_ignores_stale_local_release_metadata(self):
        native_script = REPOSITORY_ROOT / "scripts" / "trigger-stable-release.sh"
        scripts = self.release_repo / "scripts"
        (scripts / "trigger-stable-release.sh").write_text(
            native_script.read_text(encoding="utf-8"), encoding="utf-8"
        )
        (scripts / "resolve-release-delivery-profile.sh").write_text(
            "resolve_release_delivery_profile() {\n"
            "  ZHANLU_DELIVERY_SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
            "  ZHANLU_DELIVERY_PROFILE_DIGEST=test-digest\n"
            "  ZHANLU_DELIVERY_ASSETS_REPOSITORY=village-way/vscodium\n"
            "  export ZHANLU_DELIVERY_SOURCE_COMMIT ZHANLU_DELIVERY_PROFILE_DIGEST ZHANLU_DELIVERY_ASSETS_REPOSITORY\n"
            "}\n"
            "prepare_release_delivery_profile() {\n"
            "  resolve_release_delivery_profile\n"
            "}\n",
            encoding="utf-8",
        )
        metadata = self.release_repo / ".zhanlu" / "release-delivery.json"
        metadata.parent.mkdir()
        metadata.write_text(
            '{"releaseVersion":"1.4.15198","deliveryProfile":"default",'
            '"sourceRef":"fix_CMSSAIYSYFXFS-400_codex",'
            '"assetsRepository":"village-way/vscodium"}\n',
            encoding="utf-8",
        )
        binaries = self.workspace / "bin"
        binaries.mkdir()
        gh_calls = self.workspace / "gh-calls"
        (binaries / "gh").write_text(
            "#!/usr/bin/env sh\n"
            "printf '%s\\n' \"$*\" >> \"$GH_CALL_LOG\"\n"
            "case \"$*\" in\n"
            "  'auth status') exit 0 ;;\n"
            "  'repo view --json nameWithOwner -q .nameWithOwner') echo village-way/vscodium ;;\n"
            "  release\\ download*) exit 1 ;;\n"
            "  *) echo \"unexpected gh call: $*\" >&2; exit 97 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        (binaries / "git").write_text(
            "#!/usr/bin/env sh\n"
            "if [ \"$*\" = 'branch --show-current' ]; then echo master; else exit 98; fi\n",
            encoding="utf-8",
        )
        (binaries / "gh").chmod(0o755)
        (binaries / "git").chmod(0o755)
        environment = {
            "PATH": f"{binaries}:{os.environ['PATH']}",
            "GH_CALL_LOG": str(gh_calls),
        }
        result = subprocess.run(
            [
                "bash", "./scripts/trigger-stable-release.sh", "--workflow",
                "--generate", "--dry-run", "--source-branch", "develop",
                "--delivery-profile", "default", "--platform", "linux",
                "--release-version", "1.4.25202", "--version-time-patch", "5202",
            ],
            cwd=self.release_repo,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertNotIn("unexpected gh call", result.stderr)
        self.assertNotIn("release download", gh_calls.read_text(encoding="utf-8"))

        gh_calls.write_text("", encoding="utf-8")
        result = subprocess.run(
            [
                "bash", "./scripts/trigger-stable-release.sh", "--workflow",
                "--dry-run", "--source-branch", "develop",
                "--delivery-profile", "default", "--platform", "linux",
                "--release-version", "1.4.25202", "--version-time-patch", "5202",
            ],
            cwd=self.release_repo,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertNotIn("已固定为", result.stdout + result.stderr)

    def test_no_gitlab_removes_g_and_component_preflight(self):
        plan = zhanlu_build.make_plan(
            self.config(
                kind="formal", version="1.4.1", no_gitlab=True, apply=True
            )
        )
        runner = FakeRunner()
        result, _ = self.execute_apply(plan, runner)
        self.assertEqual(result, 0)
        self.assertNotIn("-g", self.command_calls(runner, ["bash", "create-release.sh"])[0][0])
        self.assertFalse(self.command_calls(runner, ["glab"]))
        fetched = [
            call[0][2]
            for call in self.command_calls(runner, ["git"])
            if "fetch" in call[0]
        ]
        self.assertEqual(fetched, [str(self.release_repo)])
        sync_calls = self.command_calls(
            runner, ["bash", "./scripts/sync-zhanlu-gitlab-to-github.sh"]
        )
        self.assertEqual(len(sync_calls), 2)
        self.assertIn("--dry-run", sync_calls[0][0])
        self.assertNotIn("--dry-run", sync_calls[1][0])

    def test_trigger_only_skips_release_creation(self):
        plan = zhanlu_build.make_plan(
            self.config(
                kind="formal",
                version="1.4.1",
                trigger_only=True,
                platform="windows",
                apply=True,
            )
        )
        runner = FakeRunner()
        result, _ = self.execute_apply(plan, runner)
        self.assertEqual(result, 0)
        self.assertFalse(self.command_calls(runner, ["bash", "create-release.sh"]))
        trigger = self.command_calls(
            runner, ["bash", "./scripts/trigger-stable-release.sh"]
        )[0][0]
        self.assertEqual(trigger[trigger.index("--platform") + 1], "windows")
        self.assertEqual(plan.workflows, ("stable-windows.yml",))

    def test_publish_override_sets_published_visibility(self):
        plan = zhanlu_build.make_plan(self.config(publish=True))
        self.assertFalse(plan.release_draft)
        self.assertEqual(zhanlu_build.safe_environment(plan)["RELEASE_DRAFT"], "false")

    def test_create_failure_prevents_workflow_dispatch(self):
        plan = zhanlu_build.make_plan(
            self.config(kind="formal", version="1.4.1", apply=True)
        )
        (self.workspace / ".env").write_text(
            "GITLAB_TOKEN=top-secret-value\n", encoding="utf-8"
        )
        runner = FakeRunner(fail_create=True)
        with mock.patch.object(zhanlu_build.shutil, "which", return_value="/fake/tool"):
            with self.assertRaises(subprocess.CalledProcessError):
                zhanlu_build.execute(plan, runner=runner, output=StringIO())
        self.assertFalse(
            self.command_calls(runner, ["bash", "./scripts/trigger-stable-release.sh"])
        )

    def test_sync_preview_failure_prevents_sync_release_and_dispatch(self):
        plan = zhanlu_build.make_plan(self.config(apply=True))
        runner = FakeRunner(fail_sync_preview=True)
        with mock.patch.object(zhanlu_build.shutil, "which", return_value="/fake/tool"):
            with self.assertRaises(subprocess.CalledProcessError):
                zhanlu_build.execute(plan, runner=runner, output=StringIO())
        sync_calls = self.command_calls(
            runner, ["bash", "./scripts/sync-zhanlu-gitlab-to-github.sh"]
        )
        self.assertEqual(len(sync_calls), 1)
        self.assertIn("--dry-run", sync_calls[0][0])
        self.assertFalse(self.command_calls(runner, ["bash", "create-release.sh"]))
        self.assertFalse(
            self.command_calls(runner, ["bash", "./scripts/trigger-stable-release.sh"])
        )

    def test_sync_apply_failure_prevents_release_and_dispatch(self):
        plan = zhanlu_build.make_plan(self.config(apply=True))
        runner = FakeRunner(fail_sync_apply=True)
        with mock.patch.object(zhanlu_build.shutil, "which", return_value="/fake/tool"):
            with self.assertRaises(subprocess.CalledProcessError):
                zhanlu_build.execute(plan, runner=runner, output=StringIO())
        sync_calls = self.command_calls(
            runner, ["bash", "./scripts/sync-zhanlu-gitlab-to-github.sh"]
        )
        self.assertEqual(len(sync_calls), 2)
        self.assertFalse(self.command_calls(runner, ["bash", "create-release.sh"]))
        self.assertFalse(
            self.command_calls(runner, ["bash", "./scripts/trigger-stable-release.sh"])
        )

    def test_dirty_release_checkout_is_rejected(self):
        plan = zhanlu_build.make_plan(self.config(apply=True))
        runner = FakeRunner(dirty_repo="vscodium")
        with mock.patch.object(zhanlu_build.shutil, "which", return_value="/fake/tool"):
            with self.assertRaisesRegex(zhanlu_build.BuildError, "must be clean"):
                zhanlu_build.execute(plan, runner=runner, output=StringIO())
        self.assertFalse(self.command_calls(runner, ["bash", "create-release.sh"]))
        self.assertFalse(
            self.command_calls(runner, ["bash", "./scripts/trigger-stable-release.sh"])
        )

    def test_dirty_component_checkout_is_rejected_before_release(self):
        (self.workspace / ".env").write_text(
            "GITLAB_TOKEN=top-secret-value\n", encoding="utf-8"
        )
        plan = zhanlu_build.make_plan(
            self.config(kind="formal", version="1.4.1", apply=True)
        )
        runner = FakeRunner(dirty_repo="zhanlu-code")
        with mock.patch.object(zhanlu_build.shutil, "which", return_value="/fake/tool"):
            with self.assertRaisesRegex(zhanlu_build.BuildError, "must be clean"):
                zhanlu_build.execute(plan, runner=runner, output=StringIO())
        self.assertFalse(self.command_calls(runner, ["bash", "create-release.sh"]))
        self.assertFalse(
            self.command_calls(runner, ["bash", "./scripts/trigger-stable-release.sh"])
        )

    def test_formal_sync_requires_gitlab_auth_without_leaking_token(self):
        plan = zhanlu_build.make_plan(
            self.config(kind="formal", version="1.4.1", apply=True)
        )
        runner = FakeRunner()
        with mock.patch.dict(
            zhanlu_build.os.environ,
            {"PATH": zhanlu_build.os.environ.get("PATH", "")},
            clear=True,
        ):
            with mock.patch.object(zhanlu_build.shutil, "which", return_value="/fake/tool"):
                with self.assertRaisesRegex(zhanlu_build.BuildError, "requires GITLAB_TOKEN"):
                    zhanlu_build.execute(plan, runner=runner, output=StringIO())

    def test_env_token_is_used_but_never_printed(self):
        secret = "never-print-this-token"
        (self.workspace / ".env").write_text(
            f"GITLAB_TOKEN={secret}\n", encoding="utf-8"
        )
        plan = zhanlu_build.make_plan(
            self.config(kind="formal", version="1.4.1", apply=True)
        )
        runner = FakeRunner()
        with mock.patch.dict(
            zhanlu_build.os.environ,
            {"PATH": zhanlu_build.os.environ.get("PATH", "")},
            clear=True,
        ):
            result, output = self.execute_apply(plan, runner)
        self.assertEqual(result, 0)
        self.assertNotIn(secret, output)
        create_call = self.command_calls(runner, ["bash", "create-release.sh"])[0]
        self.assertEqual(create_call[2]["GITLAB_TOKEN"], secret)
        self.assertEqual(create_call[2]["GITLAB_FORCE_TAG_UPDATE"], "false")

    def test_portal_http_gitlab_host_is_normalized_for_glab(self):
        secret = "never-print-this-token"
        plan = zhanlu_build.make_plan(
            self.config(kind="formal", version="1.4.1", apply=True)
        )
        runner = FakeRunner()
        with mock.patch.dict(
            zhanlu_build.os.environ,
            {
                "PATH": zhanlu_build.os.environ.get("PATH", ""),
                "GITLAB_TOKEN": secret,
                "GITLAB_HOST": "gitlab.cmss.com",
                "GITLAB_API_HOST": "gitlab.cmss.com",
                "GITLAB_API_PROTOCOL": "http",
            },
            clear=True,
        ):
            result, output = self.execute_apply(plan, runner)
        self.assertEqual(result, 0)
        self.assertNotIn(secret, output)
        create_env = self.command_calls(runner, ["bash", "create-release.sh"])[0][2]
        self.assertEqual(create_env["GITLAB_HOST"], "http://gitlab.cmss.com")
        glab_env = self.command_calls(runner, ["glab", "auth", "status"])[0][2]
        self.assertEqual(glab_env["GITLAB_HOST"], "http://gitlab.cmss.com")
        config_path = (
            self.workspace / ".zhanlu-cli" / "config" / "glab-cli" / "config.yml"
        )
        self.assertTrue(config_path.is_file())
        self.assertEqual(config_path.stat().st_mode & 0o777, 0o600)
        self.assertIn("api_protocol: http", config_path.read_text(encoding="utf-8"))

    def test_gitlab_cli_host_preserves_explicit_urls(self):
        self.assertEqual(
            zhanlu_build.gitlab_cli_host({"GITLAB_HOST": "http://gitlab.cmss.com/"}),
            ("http://gitlab.cmss.com", "gitlab.cmss.com"),
        )

    def test_dry_run_never_calls_remote_tools_or_native_scripts(self):
        plan = zhanlu_build.make_plan(self.config())
        runner = FakeRunner()
        output = StringIO()
        result = zhanlu_build.execute(plan, runner=runner, output=output)
        self.assertEqual(result, 0)
        self.assertIn("Dry run only", output.getvalue())
        self.assertIn("sync-zhanlu-gitlab-to-github.sh --dry-run", output.getvalue())
        self.assertTrue(runner.calls)
        self.assertTrue(all(call[0][0] == "git" for call in runner.calls))

    def test_ambiguous_new_workflow_runs_are_rejected(self):
        plan = zhanlu_build.make_plan(
            self.config(platform="macos", discovery_timeout=0)
        )
        runner = FakeRunner()
        runner.run_lists["stable-macos.yml"] = [
            {"databaseId": 10, "headBranch": "master", "url": "https://example/10"},
            {"databaseId": 11, "headBranch": "master", "url": "https://example/11"},
        ]
        with self.assertRaisesRegex(zhanlu_build.BuildError, "ambiguous new runs"):
            zhanlu_build.discover_new_runs(
                plan,
                runner,
                "village-way/vscodium",
                {},
                {"stable-macos.yml": set()},
                StringIO(),
                monotonic=lambda: 0,
                sleep=lambda _: None,
            )

    def test_monitor_reports_failed_jobs(self):
        plan = zhanlu_build.make_plan(self.config(platform="linux"))
        runner = FakeRunner()
        runner.run_views[22] = {
            "status": "completed",
            "conclusion": "failure",
            "url": "https://example/22",
            "jobs": [
                {"name": "build x64", "conclusion": "failure"},
                {"name": "build arm64", "conclusion": "success"},
            ],
        }
        output = StringIO()
        success = zhanlu_build.monitor_runs(
            plan,
            runner,
            "village-way/vscodium",
            {},
            {"stable-linux.yml": {"databaseId": 22}},
            output,
            sleep=lambda _: None,
        )
        self.assertFalse(success)
        self.assertIn("failed jobs: build x64", output.getvalue())


if __name__ == "__main__":
    unittest.main()
