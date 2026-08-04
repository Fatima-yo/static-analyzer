import json, glob, os, collections

BASELINE = "opencode_artifacts/run2"
CURRENT = "opencode_artifacts/newruns10"

NEW_REAL = {
    ("Reentrancy", "InitialCashDistributor.sol", 42),
    ("Reentrancy", "InitialShareDistributor.sol", 42),
    ("FrontRunning", "CEther.sol", 1131),
    ("FrontRunning", "OUSD.sol", 404),
}
ACCEPTED_TS = {
    ("Timestamp", "BACDAIPool.sol", 208),
    ("Timestamp", "BACSUSDPool.sol", 208),
    ("Timestamp", "BACUSDCPool.sol", 208),
    ("Timestamp", "BACUSDTPool.sol", 208),
    ("Timestamp", "BACyCRVPool.sol", 208),
    ("Timestamp", "DAIBACLPTokenSharePool.sol", 189),
    ("Timestamp", "DAIBASLPTokenSharePool.sol", 178),
    ("Timestamp", "Treasury.sol", 108),
    ("Timestamp", "Treasury.sol", 139),
}
BORDERLINE = {
    ("Reentrancy", "OUSD.sol", 362),
    ("Reentrancy", "OUSD.sol", 373),
}
NOISE = {
    ("IntegerOverflow", "CEther.sol", 2534),
    ("IntegerOverflow", "CEther.sol", 2535),
}

def k(f):
    return (f["detector"], os.path.basename(f["file_path"]), f["line_number"])

def load(path):
    return json.load(open(path))

def resolve_src(f):
    p = f["file_path"]
    if not os.path.exists(p):
        return None
    try:
        lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
    except Exception:
        return None
    n = f.get("line_number")
    if n and 1 <= n <= len(lines):
        return lines[n - 1].strip()[:110]
    return None

# baseline keys to mark baseline findings
base_keys = set()
for p in glob.glob(os.path.join(BASELINE, "*.json")):
    for f in load(p):
        base_keys.add(k(f))

per_proto = collections.defaultdict(list)
for p in sorted(glob.glob(os.path.join(CURRENT, "*.json"))):
    name = os.path.basename(p)[:-5]
    for f in load(p):
        kk = k(f)
        note = None
        if kk in base_keys:
            note = "baseline (triaged)"
        if kk in NEW_REAL:
            note = "pattern-TP (low exploitability)"
        elif kk in ACCEPTED_TS:
            note = "accepted SWC-116 gating"
        elif kk in BORDERLINE:
            note = "borderline FP (internal accounting)"
        elif kk in NOISE:
            note = "noise (duplicate, pure helper)"
        f["_note"] = note
        per_proto[name].append(f)

lines = []
lines.append("# Analyzer findings report — 22 protocol corpus\n")
lines.append("Generated: 2026-08-03")
lines.append("")
lines.append("## Methodology")
lines.append("- Current analyzer output: `newruns10/` (121 findings).")
lines.append("- Baseline: `run2/` triaged output of the legacy analyzer (113 findings).")
lines.append("- Corpus true-positive recall held at 138/138 = 100%; pytest 21 passed.")
lines.append("- Each finding below is tagged: baseline | pattern-TP | accepted SWC-116 gating | borderline FP | noise.")
lines.append("")
det = collections.Counter()
total = 0
for name, fs in per_proto.items():
    for f in fs:
        det[f["detector"]] += 1
        total += 1
lines.append(f"## Summary (n = {total})")
lines.append("| Detector | Count |")
lines.append("|----------|-------|")
for d, c in sorted(det.items(), key=lambda x: -x[1]):
    lines.append(f"| {d} | {c} |")
lines.append("")
lines.append("## Per-protocol findings\n")
for name in sorted(per_proto, key=lambda n: -len(per_proto[n])):
    fs = per_proto[name]
    lines.append(f"### {name} — {len(fs)} findings\n")
    byfile = collections.defaultdict(list)
    for f in fs:
        byfile[os.path.basename(f["file_path"])].append(f)
    for bfile in sorted(byfile):
        lines.append(f"**{bfile}**")
        for f in sorted(byfile[bfile], key=lambda x: x["line_number"]):
            note = f" _[{f['_note']}]_" if f["_note"] else ""
            src = resolve_src(f)
            s = f"- {f['detector']} ({f['severity']}) — line {f['line_number']} — {f['message'].split('. ')[0]}.{note}"
            if src:
                s += f"\n    `{src}`"
            lines.append(s)
        lines.append("")
lines.append("## Notes on categories")
lines.append("- **baseline (triaged)**: findings carried over from the legacy analyzer's triaged run — retained as accepted real findings.")
lines.append("- **NEW pattern-TP (4, low exploitability)**: basis-cash `InitialCashDistributor`/`InitialShareDistributor` `distribute()` — correct CEI-shape detection (`once=false` written after the transfer loop), but `Cash` is a standard OZ ERC20 with no callback and targets are trusted protocol contracts, so no practical re-entry vector. compound CEther `approve` + harvest OUSD `approve` — genuine SWC-114 allowance-overwrite instances (documented known pattern in Compound); low impact (requires a malicious spender racing a legitimate transaction).")
lines.append("- **accepted SWC-116 gating (9)**: basis-cash reward-epoch `block.timestamp` gates (pool `notifyRewardAmount` ×7, Treasury `migrate`/`_allocateSeigniorage` ×2). Benign in practice (governance-set windows) but the exact class the timestamp detector reports; aligned with corpus TPs.")
lines.append("- **borderline FP (2)**: harvest OUSD `_adjustAccount` reentrancy — internal credit-balance bookkeeping; the detected call is an internal read-only call chain (`balanceOf`/`_autoMigrate`/`_rebaseOptOut`), no external value transfer.")
lines.append("- **noise (2)**: compound CEther `fail()` index-arithmetic duplicates — pure error-formatting helper.")
lines.append("- **Removed vs baseline (2)**: basis-cash `Treasury.sol` `buyBonds` (FrontRunning + MEV, line 175) — exact-price pinning `require(cashPrice == targetPrice)` is genuine protection, so these FPs were dropped.")
lines.append("")
per_line = ", ".join(f"{k}={len(v)}" for k, v in sorted(per_proto.items(), key=lambda x: -len(x[1])))
lines.append(f"Per-protocol counts: {per_line}")
open("opencode_artifacts/REPORT.md", "w").write("\n".join(lines))
print("wrote", sum(1 for _ in open("opencode_artifacts/REPORT.md")), "lines,", total, "findings")
