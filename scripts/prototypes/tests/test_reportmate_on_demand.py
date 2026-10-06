"""Offline prototype tests. All device names, serials, and IDs are synthetic."""

import contextlib
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("on_demand", str(Path(__file__).parents[1] / "reportmate-on-demand"))
spec = importlib.util.spec_from_loader(loader.name, loader)
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)

REQUEST = "11111111-1111-4111-8111-111111111111"
DEVICE = "22222222-2222-4222-8222-222222222222"
GROUP = "33333333-3333-4333-8333-333333333333"
SCRIPT = "44444444-4444-4444-8444-444444444444"
OBJECT = "55555555-5555-4555-8555-555555555555"


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = patch.object(cli, "STATE", Path(self.temp.name))
        self.state.start()
        self.addCleanup(self.state.stop)
        self.stdout = contextlib.redirect_stdout(io.StringIO())
        self.stdout.__enter__()
        self.addCleanup(self.stdout.__exit__, None, None, None)
        self.device = {"id": DEVICE, "objectId": OBJECT, "serialNumber": "TESTSERIAL", "deviceName": "Test Mac"}

    def test_duplicate_serial_fails_before_mutation(self):
        with patch.object(cli, "collection", return_value=[{}, {}]), patch.object(cli, "graph") as graph:
            with self.assertRaises(cli.Error):
                cli.resolve("TESTSERIAL")
            graph.assert_not_called()

    def test_windows_rejected(self):
        with patch.object(cli, "collection", return_value=[{"serialNumber": "TESTSERIAL", "operatingSystem": "Windows"}]):
            with self.assertRaises(cli.Error):
                cli.resolve("TESTSERIAL")

    def test_dry_run_never_creates_objects_or_state(self):
        with patch.object(cli, "resolve", return_value=self.device), patch.object(cli, "graph") as graph:
            cli.queue("TESTSERIAL", True)
            graph.assert_not_called()
        self.assertEqual(list(Path(self.temp.name).iterdir()), [])

    def test_extra_group_member_prevents_assignment(self):
        with patch.object(cli, "owned"), patch.object(cli, "resolve", return_value=self.device), patch.object(cli, "graph", return_value={"id": GROUP}) as graph, patch.object(cli, "collection", return_value=[{"id": OBJECT}, {"id": DEVICE}]), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(cli.Error):
                cli.queue("TESTSERIAL", False)
            self.assertEqual(graph.call_count, 1)
            record = cli.json.loads(next(Path(self.temp.name).glob("*.json")).read_text())
            self.assertEqual(record["groupId"], GROUP)

    def test_root_once_assignment_and_durable_request(self):
        with patch.object(cli, "owned"), patch.object(cli, "resolve", return_value=self.device), patch.object(cli, "graph", side_effect=[{"id": GROUP}, {"id": SCRIPT}, {}]) as graph, patch.object(cli, "collection", return_value=[{"id": OBJECT}]):
            cli.queue("TESTSERIAL", False)
            body = graph.call_args_list[1].args[3]
            self.assertEqual(body["runAsAccount"], "system")
            self.assertNotIn("executionFrequency", body)
            self.assertEqual(graph.call_args_list[2].args[3]["deviceManagementScriptAssignments"][0]["target"]["groupId"], GROUP)
            record = cli.json.loads(next(Path(self.temp.name).glob("*.json")).read_text())
            self.assertEqual(record["phase"], "queued")

    def test_cleanup_recovers_create_response_loss_and_absent_objects(self):
        record = {"owner": cli.OWNER, "requestId": REQUEST, "name": cli.PREFIX + REQUEST, "phase": "creating"}
        resource = {"id": SCRIPT, "displayName": record["name"], "description": f"{cli.OWNER}; request={REQUEST}"}
        with patch.object(cli, "collection", side_effect=[[resource], []]), patch.object(cli, "graph", side_effect=[resource, {}]) as graph:
            cli.cleanup(record)
            self.assertEqual(graph.call_args_list[1].args[1], "delete")
            self.assertEqual(record["phase"], "cleaned")

    def test_cleanup_refuses_changed_ownership(self):
        record = {"owner": cli.OWNER, "requestId": REQUEST, "name": cli.PREFIX + REQUEST}
        with patch.object(cli, "collection", return_value=[{"id": SCRIPT}]), patch.object(cli, "graph", return_value={"description": "someone else"}) as graph:
            with self.assertRaises(cli.Error):
                cli.cleanup(record)
            self.assertEqual(graph.call_count, 1)

    def test_directory_propagation_retries_without_creating_another_group(self):
        record = {"groupId": GROUP, "device": self.device}
        with patch.object(cli, "collection", side_effect=[cli.Error("Request_ResourceNotFound"), [], [{"id": OBJECT}]]), patch.object(cli.time, "sleep") as sleep:
            cli.wait_for_members(record)
            self.assertEqual(sleep.call_count, 2)

    def test_resume_refuses_ambiguous_script_creation(self):
        with patch.object(cli, "graph") as graph:
            with self.assertRaises(cli.Error):
                cli.finish_request({"phase": "creating_script"})
            graph.assert_not_called()

    def test_payload_is_valid_bash_and_refuses_wrong_device_before_runner(self):
        script = cli.payload("TESTSERIAL", REQUEST, 2000000000)
        result = subprocess.run(["/bin/bash", "-n"], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(script.index("Serial mismatch"), script.index('"$runner" --force'))
        self.assertLess(script.index("Request expired"), script.index('"$runner" --force'))
        self.assertLess(script.index('"$runner" --force'), script.index('/usr/bin/touch "$marker"'))


if __name__ == "__main__":
    unittest.main()
