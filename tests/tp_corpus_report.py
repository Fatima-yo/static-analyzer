#!/usr/bin/env python3
"""Baseline recall measurement over the SmartBugs-curated true-positive corpus.

Runs every security detector over each labeled vulnerable contract and reports
which expected detector(s) fired per case, per SmartBugs category.

Usage:
    analyzer_env/bin/python tests/tp_corpus_report.py [--json out.json]
"""

import collections
import json
import os
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from smart_analyzer.analyzer import Analyzer
from smart_analyzer.utils import (
    generate_ast, get_solidity_version, UncheckedContext, walk_ast_generator,
)
from smart_analyzer.context import AnalyzerContext, set_analysis_context

CORPUS = Path(__file__).parent / "tp_corpus"

# SmartBugs-curated category -> analyzer detector names accepted as detection.
CATEGORY_EXPECTED = {
    "access_control": ["access_control", "tx_origin", "delegate_call"],
    "arithmetic": ["integer_overflow"],
    "bad_randomness": ["bad_randomness", "timestamp", "mev", "front_running", "oracle_manipulation"],
    "denial_of_service": ["access_control", "unchecked_call", "denial_of_service"],
    "front_running": ["front_running", "mev", "bad_randomness"],
    "reentrancy": ["reentrancy", "unchecked_call"],
    "short_addresses": [],
    "time_manipulation": ["timestamp", "oracle_manipulation", "bad_randomness"],
    "unchecked_low_level_calls": ["unchecked_call"],
    "other": [],
}

PRAGMA_RE = re.compile(r"pragma\s+solidity\s+[^;]*;")


def patch_pragma(content: str, new: str = "^0.4.24") -> str:
    if PRAGMA_RE.search(content):
        return PRAGMA_RE.sub(f"pragma solidity {new};", content, count=1)
    return f"pragma solidity {new};\n" + content


def _analyze_file(sol_file: str, analyzer: Analyzer) -> dict:
    ast_data = generate_ast(sol_file, None)
    ast_root = ast_data["sources"]["input.sol"]["ast"]
    version = get_solidity_version(sol_file)
    context = AnalyzerContext(ast_data)
    set_analysis_context(context)
    results = collections.defaultdict(list)
    unchecked = UncheckedContext()
    try:
        for node in walk_ast_generator(ast_root):
            unchecked.enter(node)
            for dname, dfunc in analyzer._detectors.items():
                temp = []
                try:
                    if dname == "integer_overflow":
                        dfunc(node, temp, sol_file, version, unchecked)
                    else:
                        dfunc(node, temp, sol_file)
                except Exception:
                    pass
                if temp:
                    results[dname].extend(temp)
            unchecked.exit(node)
    finally:
        set_analysis_context(None)
    return dict(results)


def analyze_file(sol_file: str) -> dict:
    """Return {detector_name: [findings]} for one sol file, or None if the
    original pragma cannot be satisfied (caller retries with a patched copy)."""
    analyzer = Analyzer(categories=["security"])
    try:
        return _analyze_file(sol_file, analyzer)
    except Exception:
        return None


def main() -> int:
    out_path = None
    if "--json" in sys.argv:
        out_path = sys.argv[sys.argv.index("--json") + 1]

    labels = json.load(open(CORPUS / "vulnerabilities.json"))
    summary = collections.Counter()
    rows = []
    per_cat_fire = collections.defaultdict(collections.Counter)

    for entry in labels:
        path = CORPUS / entry["path"]
        cats = [v["category"] for v in entry["vulnerabilities"]]
        expected = set()
        for c in cats:
            expected |= set(CATEGORY_EXPECTED.get(c, []))
        if not expected:
            summary["excluded"] += 1
            rows.append(dict(file=entry["path"], cats=cats, mode="excluded",
                             expected=[], fired=[], hit=False))
            continue

        result = analyze_file(str(path))
        mode = "ok"
        if result is None:
            with tempfile.NamedTemporaryFile("w", suffix=".sol", delete=False) as tf:
                tf.write(patch_pragma(path.read_text()))
                patched = tf.name
            try:
                result = analyze_file(patched)
                if result is None:
                    mode = "unparseable: patched pragma still fails to compile"
                else:
                    mode = "patched"
            except Exception as e:
                result = None
                mode = f"unparseable: {str(e)[:60]}"
            finally:
                os.unlink(patched)

        fired = set(result) if result else set()
        hit = bool(expected & fired)
        summary[mode] += 1
        if mode.startswith("unparseable"):
            summary["expected_but_unparseable"] += 1
        else:
            summary["hit" if hit else "miss"] += 1
            for c in cats:
                for d in CATEGORY_EXPECTED.get(c, []):
                    per_cat_fire[c][d] += d in fired

        rows.append(dict(file=entry["path"], cats=cats, mode=mode,
                         expected=sorted(expected), fired=sorted(fired),
                         hit=hit))

    total = len(rows)
    hits = sum(1 for r in rows if r["hit"])
    denom = sum(1 for r in rows if not r["mode"].startswith(("excluded", "unparseable")))

    print("\n=== Per-file report ===")
    print(f"{'status':16s} {'hit':4s}  categories / expected -> fired")
    for r in rows:
        tag = "HIT " if r["hit"] else "miss"
        cats = ",".join(set(r["cats"]))
        exp = ",".join(r["expected"])
        fire = ",".join(r["fired"]) or "-"
        line = f"{r['mode']:16s} {tag:4s} [{cats}] exp<{exp}> fire<{fire}>"
        print(line)

    print("\n=== Per-category detector firing (files where expected detector fired / files) ===")
    for c in sorted(per_cat_fire):
        total_c = sum(1 for r in rows if c in r["cats"] and r["hit"] is not None
                      and not r["mode"].startswith("unparseable"))
        print(f"  {c}: {total_c} files")
        for d, n in per_cat_fire[c].most_common():
            print(f"      {d:22s} {n}/{total_c}")

    print("\n=== Summary ===")
    print(f"  files:            {total}")
    print(f"  expected (usable): {denom}")
    print(f"  hits:             {hits}")
    print(f"  misses:           {denom - hits}")
    print(f"  recall:           {hits}/{denom} = {hits / max(1, denom):.1%}")
    print(f"  unparseable:      {summary['expected_but_unparseable']}")
    print(f"  excluded (no detector): {summary['excluded']}")
    print(f"  modes:            {dict(summary)}")

    if out_path:
        json.dump(dict(recall=hits / max(1, denom), hits=hits, denom=denom,
                       rows=rows), open(out_path, "w"), indent=1)
        print(f"  wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
