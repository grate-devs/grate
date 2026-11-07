"""Check the standalone planner through its command line."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
FIRST = "functions/dbo.fnOrderTotals.sql"
VIEW = "views/dbo.vOrders.sql"
REPORT = "functions/dbo.fnReport.sql"


def run(root):
    return subprocess.run(["dotnet", str(PLANNER), str(root)], text=True,
                          capture_output=True, timeout=20)


def view(name, query="SELECT 1 AS Value"):
    return f"CREATE OR ALTER VIEW {name} AS {query};"


class OfflinePlanTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def write(self, scripts):
        for name, sql in scripts.items():
            file = self.root / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(sql, encoding="utf-8")

    def plan(self, root):
        result = run(root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)["scripts"]

    def assert_rejected(self, *diagnostics):
        result = run(self.root)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        for diagnostic in diagnostics:
            self.assertIn(diagnostic, result.stderr)
        return result.stderr

    def test_three_definitions_and_edge_reasons(self):
        fixture = ROOT / "fixtures" / "base"
        plan = self.plan(fixture)
        self.assertEqual([script["path"] for script in plan], [FIRST, VIEW, REPORT])
        self.assertEqual([script["dependencies"] for script in plan], [
            [],
            [{"path": FIRST, "source": "inferred",
              "reference": {"schema": "dbo", "name": "fnOrderTotals"}}],
            [{"path": VIEW, "source": "inferred",
              "reference": {"schema": "dbo", "name": "vOrders"}}],
        ])
        self.assertTrue(all(not script["outsideReferences"] for script in plan))
        self.assertEqual(run(fixture).stdout, run(fixture).stdout)

    def test_outside_reference_is_deduplicated_and_matching_is_exact(self):
        self.write({
            "views/a.sql": view("dbo.Report", "SELECT a.Value FROM dbo.Orders a, [dbo].[Orders] b"),
            "views/z.sql": view("dbo.orders"),
        })
        first, last = self.plan(self.root)
        self.assertEqual((first["path"], last["path"]), ("views/a.sql", "views/z.sql"))
        self.assertEqual(first["dependencies"], [])
        self.assertEqual(first["outsideReferences"], [{"schema": "dbo", "name": "Orders"}])

    def test_declaration_replaces_inference_and_incoming_edges_still_apply(self):
        self.write({
            "views/a.sql": "-- Dependencies: views/m.sql\n"
                           + view("dbo.A", "SELECT Value FROM dbo.Z"),
            "views/b.sql": view("dbo.B", "SELECT Value FROM dbo.A"),
            "views/m.sql": view("dbo.M"),
            "views/z.sql": view("dbo.Z"),
        })
        plan = self.plan(self.root)
        self.assertEqual([script["path"] for script in plan],
                         ["views/m.sql", "views/a.sql", "views/b.sql", "views/z.sql"])
        self.assertEqual(plan[1]["dependencies"],
                         [{"path": "views/m.sql", "source": "declared", "reference": None}])
        self.assertEqual(plan[2]["dependencies"],
                         [{"path": "views/a.sql", "source": "inferred",
                           "reference": {"schema": "dbo", "name": "A"}}])

    def test_missing_declared_path_rejects_whole_plan(self):
        self.write({"views/a.sql": "-- Dependencies: views/missing.sql\n" + view("dbo.A")})
        self.assert_rejected("views/a.sql", "views/missing.sql", "outside the planned group")

    def test_cycle_diagnostic_excludes_waiting_script(self):
        self.write({
            "views/a.sql": view("dbo.A", "SELECT Value FROM dbo.B"),
            "views/b.sql": "-- Dependencies: views/c.sql\n" + view("dbo.B"),
            "views/c.sql": view("dbo.C", "SELECT Value FROM dbo.B"),
        })
        diagnostic = self.assert_rejected("Dependency cycle", "views/b.sql -> views/c.sql -> views/b.sql")
        self.assertNotIn("views/a.sql", diagnostic)

    def test_duplicate_names_include_both_files(self):
        self.write({"views/a.sql": view("dbo.A"), "views/b.sql": view("[dbo].[A]")})
        self.assert_rejected("Duplicate definition", "views/a.sql", "views/b.sql")

    def test_unsupported_scripts_are_rejected(self):
        for file, script, diagnostic in [
            ("views/a.sql", view("dbo.A", "SELECT Value FROM Orders"), "schema-qualified"),
            ("views/a.sql", view("{{schema}}.A"), "token placeholders"),
            ("views/a.sql", view("dbo.A") + "\nGO\nSELECT 2;", "expected one"),
            ("views/a.sql", view("dbo.A", "SELECT Value FROM dbo.X CROSS JOIN dbo.Y"), "unsupported FROM source"),
            ("views/EveryTime.a.sql", view("dbo.A"), "EveryTime scripts"),
            ("views/a.ENV.LOCAL.sql", view("dbo.A"), "environment"),
        ]:
            with self.subTest(file=file, diagnostic=diagnostic):
                self.write({file: script})
                self.assert_rejected(file, diagnostic)
                (self.root / file).unlink()


if __name__ == "__main__":
    PLANNER = Path(sys.argv.pop(1)).resolve()
    unittest.main(verbosity=2)
