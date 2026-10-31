"""验证 Codex 配置更新的键名兼容性；运行需要 Python 3.11+。"""

import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "scripts/installers/install-ai-tools.sh"
CONFIG_ENV = {
    "CODEX_MODEL": "regression-main",
    "CODEX_REASONING": "high",
    "CODEX_SERVICE_TIER": "default",
    "CODEX_APPROVAL": "on-request",
    "CODEX_SANDBOX": "workspace-write",
    "CODEX_NETWORK": "enabled",
    "CODEX_MULTI_AGENT": "enabled",
    "CODEX_MEMORIES": "enabled",
    "CODEX_AGENTS_ENABLED": "enabled",
    "CODEX_AGENTS_MAX_THREADS": "4",
    "CODEX_SUBAGENT_MODEL": "regression-subagent",
    "CODEX_SUBAGENT_REASONING": "medium",
    "CODEX_AGENTS_INTERRUPT_MESSAGE": "enabled",
    "CODEX_EXTRACT_MODEL": "regression-extract",
    "CODEX_CONSOLIDATION_MODEL": "regression-consolidation",
}


class CodexConfigTest(unittest.TestCase):
    def _check_config(self, original: str) -> None:
        tomllib.loads(original)
        with tempfile.TemporaryDirectory(prefix="ai-tools-config-test-") as directory:
            config = Path(directory) / "config.toml"
            config.write_text(original, encoding="utf-8")
            env = {**os.environ, **CONFIG_ENV, "CODEX_HOME": directory}
            command = ["bash", "-c", 'source "$1"; configure_codex_base', "test", str(INSTALLER)]
            first = subprocess.run(command, env=env, capture_output=True, text=True, check=True)
            updated = config.read_text(encoding="utf-8")
            data = tomllib.loads(updated)
            self.assertEqual(data["model"], "regression-main")
            self.assertEqual(data["model_reasoning_effort"], "high")
            self.assertEqual(data["service_tier"], "default")
            self.assertEqual(data["approval_policy"], "on-request")
            self.assertEqual(data["sandbox_mode"], "workspace-write")
            self.assertNotIn("network_access", data)
            self.assertIs(data["sandbox_workspace_write"]["network_access"], True)
            self.assertIs(data["features"]["multi_agent"], True)
            self.assertIs(data["features"]["memories"], True)
            agents = data["agents"]
            self.assertIs(agents["enabled"], True)
            self.assertEqual(agents["max_concurrent_threads_per_session"], 4)
            self.assertNotIn("max_threads", agents)
            self.assertEqual(agents["default_subagent_model"], "regression-subagent")
            self.assertEqual(agents["default_subagent_reasoning_effort"], "medium")
            self.assertIs(agents["interrupt_message"], True)
            self.assertEqual(data["memories"]["extract_model"], "regression-extract")
            self.assertEqual(data["memories"]["consolidation_model"], "regression-consolidation")
            if original:
                self.assertNotIn("added top-level", first.stdout)
                self.assertEqual(data["custom"], "keep-root")
                self.assertEqual(agents["review"], {"description": "keep-role"})
                self.assertEqual(data["memories"]["max_rollout_age_days"], 15)
                self.assertEqual(data["mcp_servers"]["example"]["url"], "https://example.com/mcp")
                self.assertIn("# keep-comment\n", updated)
                self.assertEqual(config.with_suffix(".toml.bak").read_text(), original)
            subprocess.run(command, env=env, capture_output=True, text=True, check=True)
            self.assertEqual(config.read_text(encoding="utf-8"), updated)

    def test_empty_config(self) -> None:
        """空配置仍能生成有效且可重复更新的 TOML。"""
        self._check_config("")

    def test_key_spellings(self) -> None:
        """三种键名写法和并发数旧别名均能原位更新。"""
        for quote in ("", '"', "'"):
            for thread_key in ("max_threads", "max_concurrent_threads_per_session"):
                with self.subTest(quote=quote, thread_key=thread_key):
                    q = quote
                    self._check_config(f"""# keep-comment
{q}model{q} = "old-model"
{q}model_reasoning_effort{q} = "low"
{q}service_tier{q} = "fast"
{q}approval_policy{q} = "never"
{q}sandbox_mode{q} = "read-only"
{q}network_access{q} = "disabled"
custom = "keep-root"

[{q}features{q}]
{q}multi_agent{q} = false
{q}memories{q} = false

[{q}agents{q}]
{q}enabled{q} = false
{q}{thread_key}{q} = 1
{q}default_subagent_model{q} = "old-subagent"
{q}default_subagent_reasoning_effort{q} = "low"
{q}interrupt_message{q} = false

[agents.review]
description = "keep-role"

[{q}memories{q}]
{q}extract_model{q} = "old-extract"
{q}consolidation_model{q} = "old-consolidation"
max_rollout_age_days = 15

[{q}sandbox_workspace_write{q}]
{q}network_access{q} = false

[mcp_servers.example]
url = "https://example.com/mcp"
""")


if __name__ == "__main__":
    unittest.main()
