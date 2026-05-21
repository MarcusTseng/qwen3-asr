#!/usr/bin/env python3
import importlib.util
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "clean_transcript.py"
spec = importlib.util.spec_from_file_location("clean_transcript", SCRIPT)
assert spec is not None and spec.loader is not None
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)


def test_drop_filler_only_lines():
    assert mod.drop_filler_only_lines("嗯。\n今天開會\n，") == "今天開會"


def test_remove_sentence_leading_fillers_only():
    assert mod.remove_leading_fillers("嗯那個我覺得可以。就是明天開始") == "我覺得可以。明天開始"
    assert mod.remove_leading_fillers("我覺得那個方案可以") == "我覺得那個方案可以"


def test_collapse_duplicates_but_keep_emphasis():
    assert mod.collapse_immediate_duplicates("我我我覺得 then then go 對對對 好好好") == "我覺得 then go 對對對 好好好"


def test_dictionary_longest_first_non_cascading_casefold():
    entries = [mod.Entry("Cloud code", "Claude Code"), mod.Entry("code", "CODE")]
    entries = sorted(entries, key=lambda e: len(e.source), reverse=True)
    assert mod.apply_dictionary("cloud code and code", entries) == "Claude Code and CODE"


def test_parse_tsv_and_arrow_entries():
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "corrections.txt"
        p.write_text("# comment\n骨癌\t股癌\nCloud code -> Claude Code\nJ.S.O.N → JSON\n", encoding="utf-8")
        entries = mod.parse_entries(p)
        assert [(e.source, e.target) for e in entries] == [
            ("Cloud code", "Claude Code"),
            ("J.S.O.N", "JSON"),
            ("骨癌", "股癌"),
        ]
