#!/usr/bin/env python3
"""Unit tests for the PreToolUse path guard (.claude/hooks/guard_path.py) — both the
Write/Edit target check and the Bash defence-in-depth guard added in this change.

The guard's whole job is that a passing gate can never mean "the agent edited the
oracle" (ADR-0001/0004). The Bash guard is a heuristic bar-raiser, so these tests pin
exactly which shapes it catches and which it must NOT catch (reads, generated/ writes,
dotnet builds) — a guard that blocks legitimate work is as broken as one that lets the
oracle be rewritten.

Stdlib unittest only:
    python -m unittest discover -s .claude/hooks -v
"""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gp = _load("guard_path", os.path.join(HERE, "guard_path.py"))

BLOCK, ALLOW = 2, 0


class TestBashGuardBlocks(unittest.TestCase):
    def test_redirect_into_corpus_golden(self):
        self.assertEqual(gp._guard_bash("echo '[]' > corpus/golden/Foo__base.json"), BLOCK)

    def test_append_redirect_into_gates(self):
        self.assertEqual(gp._guard_bash("printf x >> gates/differential.sh"), BLOCK)

    def test_cp_over_golden(self):
        self.assertEqual(gp._guard_bash("cp /tmp/x.json corpus/golden/Foo__base.json"), BLOCK)

    def test_mv_into_docs(self):
        self.assertEqual(gp._guard_bash("mv a.md docs/adr/0001-non-circular-gate.md"), BLOCK)

    def test_rm_seed(self):
        self.assertEqual(gp._guard_bash("rm -f corpus/seed/relational.json"), BLOCK)

    def test_sed_inplace_gate(self):
        self.assertEqual(gp._guard_bash("sed -i 's/a/b/' gates/verify.sh"), BLOCK)

    def test_perl_inplace_agent(self):
        self.assertEqual(gp._guard_bash("perl -i -pe 's/x/y/' .claude/agents/reviewer.md"), BLOCK)

    def test_git_checkout_oracle(self):
        self.assertEqual(gp._guard_bash("git checkout -- corpus/seed/relational.json"), BLOCK)

    def test_git_restore_oracle(self):
        self.assertEqual(gp._guard_bash("git restore corpus/golden/Foo__base.json"), BLOCK)

    def test_tee_into_evals(self):
        self.assertEqual(gp._guard_bash("echo x | tee evals/PREREGISTRATION.md"), BLOCK)


class TestBashGuardAllows(unittest.TestCase):
    def test_read_corpus(self):
        self.assertEqual(gp._guard_bash("cat corpus/golden/Foo__base.json"), ALLOW)

    def test_grep_gates(self):
        self.assertEqual(gp._guard_bash("grep -n foo gates/differential.sh"), ALLOW)

    def test_write_into_generated(self):
        self.assertEqual(gp._guard_bash("echo x > generated/Foo/FooService.cs"), ALLOW)

    def test_dotnet_build(self):
        self.assertEqual(gp._guard_bash("dotnet build -c Release generated/Foo/Foo.csproj"), ALLOW)

    def test_rm_generated_bin(self):
        self.assertEqual(gp._guard_bash("rm -rf generated/bin"), ALLOW)

    def test_run_gate_script(self):
        self.assertEqual(gp._guard_bash("bash gates/differential.sh Website.SearchForCustomers"), ALLOW)

    def test_empty_command(self):
        self.assertEqual(gp._guard_bash(""), ALLOW)


class TestWriteGuard(unittest.TestCase):
    def setUp(self):
        self.root = os.path.abspath(os.path.join(HERE, "..", ".."))

    def _check(self, tool, file_path):
        import io
        import json as _json
        payload = {"tool_name": tool, "tool_input": {"file_path": file_path}}
        # exercise main() via stdin round-trip
        import sys
        old = sys.stdin
        sys.stdin = io.StringIO(_json.dumps(payload))
        try:
            sys.argv = ["guard_path", self.root]
            return gp.main()
        finally:
            sys.stdin = old

    def test_write_into_generated_allowed(self):
        self.assertEqual(self._check("Write", os.path.join(self.root, "generated", "x.cs")), ALLOW)

    def test_write_into_corpus_blocked(self):
        self.assertEqual(self._check("Write", os.path.join(self.root, "corpus", "golden", "x.json")), BLOCK)

    def test_edit_gate_blocked(self):
        self.assertEqual(self._check("Edit", os.path.join(self.root, "gates", "verify.sh")), BLOCK)

    def test_non_write_tool_allowed(self):
        self.assertEqual(self._check("Read", os.path.join(self.root, "corpus", "golden", "x.json")), ALLOW)


if __name__ == "__main__":
    unittest.main()
