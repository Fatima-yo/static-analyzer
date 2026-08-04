#!/usr/bin/env python3
"""Phase 1 exploitability ranker for analyzer pattern findings.

Reads the per-protocol finding JSONs (newruns10/*.json), recompiles each
protocol with solc once, resolves every finding to its enclosing function, and
scores exploitability from semantic signals:

  exposure            external/public vs internal/private
  taint              attacker input (params/msg.sender/msg.value) reaches the flag
  call_target        a low/high-level call receiver depends on user input/msg.sender
  value_to_user      value flows to msg.sender or a user-controlled address
  no_guard           the function has no authorization guard
  no_reentrancy      no reentrancy guard modifier
  callback_capable   the receiver can call back (fallback/receive/hooks)

Writes opencode_artifacts/ranked_findings.md and ranked_findings.json.

Usage (from the analyzer root, venv active so `solc` resolves):
  analyzer_env/bin/python tools/rank_findings.py
  analyzer_env/bin/python tools/rank_findings.py --findings-dir ... --out ...
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

# Make `solc` (the venv wrapper) resolvable for subprocess compilation even when
# this script is invoked as `.../bin/python tools/rank_findings.py` un-activated.
_VENV_BIN = Path(sys.executable).resolve().parent
os.environ["PATH"] = str(_VENV_BIN) + os.pathsep + os.environ.get("PATH", "")

from smart_analyzer.context import (  # noqa: E402
    AnalyzerContext,
    block_has_auth,
    call_target,
    function_reentrancy_guarded,
    ident_name,
    index_base,
    low_level_call_member,
    node_is,
    _expr_mentions_msg_sender,
    _transfer_recipient,
    walk_nodes,
)

DEFAULT_FINDINGS_DIR = ROOT / "opencode_artifacts" / "newruns10"
DEFAULT_OUT_MD = ROOT / "opencode_artifacts" / "ranked_findings.md"
DEFAULT_OUT_JSON = ROOT / "opencode_artifacts" / "ranked_findings.json"

SEV_WEIGHT = {"LOW": 0, "MEDIUM": 1, "HIGH": 2, "CRITICAL": 3}

# Full-code root that appears in every finding file_path.
FULL_CODE_RE = re.compile(r"/full_code/([^/]+)/")
FULL_CODE_ROOT = "/home/fatima/Downloads/TVL/output_2026_08_01_22_58_07/full_code"


# ---------------------------------------------------------------------------
# Compilation
# ---------------------------------------------------------------------------

def compile_project(project_root: str) -> dict:
    """Compile every .sol file under project_root (single solc invocation)."""
    all_sol = {}
    for root, _dirs, files in os.walk(project_root):
        for name in files:
            if not name.endswith(".sol"):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, project_root)
            all_sol[rel] = {"content": Path(path).read_text()}
    standard_input = {
        "language": "Solidity",
        "sources": all_sol,
        "settings": {
            "outputSelection": {"*": {"*": ["*"], "": ["ast"]}},
        },
    }
    result = subprocess.run(
        ["solc", "--standard-json"],
        input=json.dumps(standard_input),
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"solc error: {result.stderr[:500]}")
    output = json.loads(result.stdout)
    for err in output.get("errors", []):
        if err.get("severity") == "error":
            raise RuntimeError(f"solc error: {err['formattedMessage'][:500]}")
    return output


# ---------------------------------------------------------------------------
# Node / scope resolution
# ---------------------------------------------------------------------------

def nodes_at_src(ast_root: dict, start: str, length: str) -> list[dict]:
    """AST nodes whose src exactly matches (start, length)."""
    out = []
    for n in walk_nodes(ast_root):
        s = n.get("src")
        if not s:
            continue
        try:
            a, l, _f = s.split(":")
        except ValueError:
            continue
        if a == start and l == length:
            out.append(n)
    return out


def containing_nodes(ast_root: dict, offset: int) -> list[dict]:
    """Nodes whose src range contains offset, shallowest first."""
    out = []
    for n in walk_nodes(ast_root):
        s = n.get("src")
        if not s:
            continue
        try:
            a, l, _f = s.split(":")
        except ValueError:
            continue
        a, l = int(a), int(l)
        if a <= offset < a + l:
            out.append((a + l, n))
    out.sort(key=lambda t: (t[0] - offset, -t[0]))
    return [n for _k, n in out]


def enclosing_scope(ast_root: dict, offset: int) -> dict | None:
    """Innermost FunctionDefinition/ModifierDefinition containing offset."""
    best = None

    def rec(node, scope):
        nonlocal best
        if isinstance(node, dict):
            nt = node.get("nodeType")
            if nt in ("FunctionDefinition", "ModifierDefinition"):
                s = node.get("src")
                if s:
                    try:
                        a, l, _f = s.split(":")
                    except ValueError:
                        a = l = None
                    if a is not None and int(a) <= offset < int(a) + int(l):
                        best = node
            for value in node.values():
                if value is node:
                    continue
                rec(value, node)
        elif isinstance(node, list):
            for item in node:
                rec(item, node)

    rec(ast_root, None)
    return best


# ---------------------------------------------------------------------------
# Signal helpers
# ---------------------------------------------------------------------------

def _collect_base_sources(func: dict) -> set:
    sources = set()
    for p in func.get("parameters", {}).get("parameters", []) or []:
        if p and p.get("name"):
            sources.add(p["name"])
    return sources


def _expr_refs_user(node, tainted: set) -> bool:
    """True if an expression subtree references msg.sender/msg.value/tx.origin
    or any name in the tainted set."""
    if not isinstance(node, dict):
        return False
    nt = node.get("nodeType")
    if nt == "Identifier":
        return node.get("name") in tainted
    if nt == "MemberAccess":
        base = node.get("expression")
        m = node.get("memberName")
        if m in ("sender", "value") and ident_name(base) == "msg":
            return True
        if m == "origin" and ident_name(base) == "tx":
            return True
        if base is not None:
            return _expr_refs_user(base, tainted)
        return False
    if nt in ("FunctionCall", "FunctionCallOptions", "IndexAccess", "TupleExpression"):
        pass
    for key, value in node.items():
        if key in ("src", "id", "typeDescriptions"):
            continue
        if isinstance(value, dict):
            if _expr_refs_user(value, tainted):
                return True
        elif isinstance(value, list):
            if any(isinstance(i, dict) and _expr_refs_user(i, tainted) for i in value):
                return True
    return False


def _write_target_name(node: dict) -> str | None:
    target = node.get("leftHandSide") or node.get("subExpression") or node.get("expression")
    while target and target.get("nodeType") in ("IndexAccess", "MemberAccess"):
        target = index_base(target)
    if target and node_is(target, "Identifier"):
        return target.get("name")
    return None


def _tainted_names(body: dict, base_sources: set) -> set:
    """Def-use taint propagation inside one function body (bounded fixpoint)."""
    tainted = set(base_sources)
    for _ in range(4):
        changed = False
        for n in walk_nodes(body):
            nt = n.get("nodeType")
            if nt == "Assignment":
                rhs = n.get("rightHandSide")
                if _expr_refs_user(rhs, tainted):
                    lhs = _write_target_name(n)
                    if lhs and lhs not in tainted:
                        tainted.add(lhs)
                        changed = True
            elif nt == "VariableDeclarationStatement":
                init = n.get("initialValue")
                if _expr_refs_user(init, tainted):
                    for decl in n.get("declarations") or []:
                        if decl and decl.get("name") and decl["name"] not in tainted:
                            tainted.add(decl["name"])
                            changed = True
            elif nt == "UnaryOperation":
                if n.get("operator") in ("++", "--"):
                    sub = n.get("subExpression")
                    if _expr_refs_user(sub, tainted):
                        name = _write_target_name(n)
                        if name and name not in tainted:
                            tainted.add(name)
                            changed = True
        if not changed:
            break
    return tainted


def _user_controlled_call(func: dict, tainted: set) -> bool:
    """Any external call whose receiver depends on user input / msg.sender."""
    for n in walk_nodes(func.get("body")):
        if not node_is(n, "FunctionCall"):
            continue
        member = low_level_call_member(n)
        if member:
            target = call_target(n)
            if target is not None and _expr_refs_user(target, tainted):
                return True
            continue
        ex = n.get("expression", {})
        if not node_is(ex, "MemberAccess"):
            continue
        if ex.get("memberName") in ("transfer", "transferFrom", "send"):
            continue
        base = ex.get("expression")
        if base is None or _expr_mentions_msg_sender(base):
            continue
        if _expr_refs_user(base, tainted):
            return True
    return False


def _value_to_user(func: dict, tainted: set) -> bool:
    for n in walk_nodes(func.get("body")):
        if not node_is(n, "FunctionCall"):
            continue
        member = low_level_call_member(n)
        if member:
            target = call_target(n)
            if target is not None and _expr_refs_user(target, tainted):
                # value-carrying low-level call
                ex = n.get("expression", {})
                if node_is(ex, "FunctionCallOptions"):
                    return True
                if node_is(ex, "MemberAccess"):
                    return True
            continue
        ex = n.get("expression", {})
        name = (ex.get("memberName") or "").lower()
        if "transfer" in name or name == "send":
            recipient = _transfer_recipient(n)
            if recipient is not None and _expr_refs_user(recipient, tainted):
                return True
    return False


def _contract_has_callback(cinfo) -> bool:
    hooks = {
        "fallback", "receive", "tokensReceived", "tokensToSend",
        "onERC721Received", "onERC1155Received", "onERC1155BatchReceived",
    }
    for f in cinfo.function_nodes:
        if (f.get("name") or "") in hooks:
            return True
    return False


def _resolve_receiver_contract(ctx: AnalyzerContext, recv, cinfo) -> list:
    """In-project contracts matching the receiver expression's type."""
    name = ident_name(recv)
    if not name:
        return []
    target_type = None
    for sv in cinfo.state_vars:
        if sv.get("name") == name:
            target_type = sv.get("typeDescriptions", {}).get("typeString", "")
            break
    m = re.search(r"contract\s+(\w+)", target_type or "")
    if not m:
        return []
    return ctx.contracts_by_name.get(m.group(1), [])


def _callback_capable(ctx: AnalyzerContext, cinfo, func: dict, tainted: set) -> bool:
    """True if the function makes a call that can re-enter the contract.

    `.transfer`/`.send` are excluded: they forward only 2300 gas, so the
    receiver cannot run a callback (a known over-approximation fixed here).
    High-level calls to user-controlled receivers and all-gas low-level calls
    (call{value:..}(..)) remain callback-capable."""
    for n in walk_nodes(func.get("body")):
        if not node_is(n, "FunctionCall"):
            continue
        member = low_level_call_member(n)
        if member:
            target = call_target(n)
            if target is None:
                continue
        else:
            ex = n.get("expression", {})
            name = (ex.get("memberName") or "").lower()
            if "transfer" in name or name == "send":
                continue  # 2300-gas stipend: no callback possible
            target = _transfer_recipient(n)
            if target is None:
                continue
        if _expr_mentions_msg_sender(target):
            return True
        if _expr_refs_user(target, tainted):
            return True
        for c in _resolve_receiver_contract(ctx, target, cinfo):
            if _contract_has_callback(c):
                return True
    return False


def _find_function(ctx: AnalyzerContext, cinfo, name: str) -> dict | None:
    """Resolve an in-contract function by name (self + inherited)."""
    if not name:
        return None
    for c in [cinfo] + ctx.bases(cinfo):
        for f in c.function_nodes:
            if f.get("name") == name:
                return f
    return None


def _calls_guarded_helper(ctx: AnalyzerContext, cinfo, func: dict,
                          depth: int = 3, seen: set | None = None) -> bool:
    """True if the function (transitively, bounded) calls an internal function
    that itself is guarded.

    Catches guard patterns the modifier/body check misses: helpers like
    ``_requireGroupCurator`` (auth-reverting internal view) and qualified
    calls to guarded initializers (``L2GatewayToken._initialize`` carrying the
    OZ ``initializer`` modifier).
    """
    if func is None or cinfo is None or depth <= 0:
        return False
    if seen is None:
        seen = set()
    fid = func.get("id")
    if fid in seen:
        return False
    seen.add(fid)

    body = func.get("body")
    if not body:
        return False

    self_names = {c.node.get("name") for c in [cinfo] + ctx.bases(cinfo)}

    for n in walk_nodes(body):
        if not node_is(n, "FunctionCall"):
            continue
        ex = n.get("expression", {})
        if node_is(ex, "MemberAccess"):
            base = ex.get("expression")
            base_ok = _expr_mentions_msg_sender(base)
            if node_is(base, "Identifier") and (
                base.get("name") in self_names or base.get("name") == "this"
            ):
                base_ok = True
            if not base_ok:
                continue  # external call to a foreign contract
            name = ex.get("memberName")
        elif node_is(ex, "Identifier"):
            name = ex.get("name")
        else:
            continue
        callee = _find_function(ctx, cinfo, name)
        if callee is None:
            continue
        owner = ctx.contract_for_function(callee) or cinfo
        if ctx.function_has_guard(owner, callee) or block_has_auth(callee.get("body")):
            return True
        if _calls_guarded_helper(ctx, owner, callee, depth - 1, seen):
            return True
    return False


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def score_finding(finding: dict, proto: str, ctx: AnalyzerContext,
                  ast_root: dict) -> dict:
    src = finding.get("source_code", "")
    try:
        start, length, _f = src.split(":")
    except ValueError:
        start = length = None

    scope = enclosing_scope(ast_root, int(start)) if start else None
    cinfo = None
    func = None
    if scope is not None:
        if scope.get("nodeType") == "FunctionDefinition":
            func = scope
            cinfo = ctx.contract_for_function(func)

    flagged = nodes_at_src(ast_root, start, length)
    flagged = flagged[-1] if flagged else None

    signals: dict[str, bool | str] = {}
    score = SEV_WEIGHT.get(finding.get("severity", "MEDIUM"), 1)

    if func is not None:
        exposure = func.get("visibility", "")
        signals["exposure"] = exposure
        if exposure in ("external", "public"):
            score += 3

        tainted = _tainted_names(func.get("body"), _collect_base_sources(func))

        taint_flag = flagged is not None and _expr_refs_user(flagged, tainted)
        signals["taint_reaches_flag"] = taint_flag
        if taint_flag:
            score += 2

        calls = _user_controlled_call(func, tainted)
        signals["user_controlled_call_target"] = calls
        if calls:
            score += 2

        value = _value_to_user(func, tainted)
        signals["value_to_user"] = value
        if value:
            score += 2

        is_constructor = func.get("kind") == "constructor"
        if is_constructor:
            # constructor args are not attacker-callable; the no-guard signal
            # is meaningless there (de-skews ZeroAddress constructor findings)
            has_guard = True
        elif cinfo is not None:
            has_guard = ctx.function_has_guard(cinfo, func)
            if not has_guard:
                has_guard = _calls_guarded_helper(ctx, cinfo, func)
        else:
            has_guard = True
        signals["no_access_control"] = not has_guard
        if not has_guard:
            score += 2

        guarded = (
            function_reentrancy_guarded(ctx, cinfo, func)
            if cinfo is not None
            else True
        )
        signals["no_reentrancy_guard"] = not guarded
        if not guarded:
            score += 1

        cb = _callback_capable(ctx, cinfo, func, tainted)
        signals["callback_capable_receiver"] = cb
        if cb:
            score += 1
    else:
        signals["exposure"] = "unknown"

    signals["bucket"] = "HIGH" if score >= 8 else ("MEDIUM" if score >= 5 else "LOW")

    return {
        "protocol": proto,
        "detector": finding.get("detector"),
        "severity": finding.get("severity"),
        "message": finding.get("message"),
        "line_number": finding.get("line_number"),
        "file_path": finding.get("file_path"),
        "function": func.get("name") if func is not None else None,
        "scope_kind": scope.get("nodeType") if scope is not None else None,
        "score": score,
        "bucket": signals["bucket"],
        "signals": signals,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def protocol_dir(file_path: str) -> str | None:
    m = FULL_CODE_RE.search(file_path)
    return f"{FULL_CODE_ROOT}/{m.group(1)}" if m else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--findings-dir", default=str(DEFAULT_FINDINGS_DIR))
    ap.add_argument("--out", default=str(DEFAULT_OUT_MD))
    ap.add_argument("--out-json", default=str(DEFAULT_OUT_JSON))
    ap.add_argument("--top", type=int, default=15)
    args = ap.parse_args()

    findings_dir = Path(args.findings_dir)
    findings: list[dict] = []
    for f in sorted(findings_dir.glob("*.json")):
        findings.extend(json.loads(f.read_text()))
    print(f"Loaded {len(findings)} findings from {findings_dir}")

    ranked: list[dict] = []
    ast_cache: dict[str, dict] = {}
    skipped = 0
    for finding in findings:
        proto_dir = protocol_dir(finding.get("file_path", ""))
        if proto_dir is None or not os.path.isdir(proto_dir):
            skipped += 1
            continue
        proto = os.path.basename(proto_dir)
        if proto not in ast_cache:
            try:
                print(f"  compiling {proto} ...")
                ast_cache[proto] = compile_project(proto_dir)
            except Exception as e:  # noqa: BLE001
                print(f"  !! compile failed for {proto}: {e}")
                ast_cache[proto] = None
        ast_data = ast_cache[proto]
        if ast_data is None:
            skipped += 1
            continue
        rel = os.path.relpath(finding["file_path"], proto_dir)
        sources = ast_data.get("sources", {})
        ast_root = sources.get(rel, {}).get("ast")
        if ast_root is None:
            skipped += 1
            continue
        ctx = AnalyzerContext(ast_data)
        ranked.append(score_finding(finding, proto, ctx, ast_root))

    print(f"Ranked {len(ranked)} findings ({skipped} skipped: no source/AST)")

    ranked.sort(key=lambda r: (-r["score"], -SEV_WEIGHT.get(r["severity"], 0)))

    # ---- report ----
    out_md = Path(args.out)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    lines.append("# ranked_findings — exploitability ranking")
    lines.append("")
    lines.append(f"Input: {len(findings)} pattern findings from `{findings_dir}`; "
                 f"ranked {len(ranked)}, skipped {skipped}.")
    lines.append("")

    buckets: dict[str, int] = {}
    by_det: dict[str, list[int]] = {}
    for r in ranked:
        buckets[r["bucket"]] = buckets.get(r["bucket"], 0) + 1
        by_det.setdefault(r["detector"], []).append(r["score"])

    lines.append("## Bucket distribution")
    lines.append("")
    lines.append("| bucket | count |")
    lines.append("|--------|-------|")
    for b in ("HIGH", "MEDIUM", "LOW"):
        lines.append(f"| {b} | {buckets.get(b, 0)} |")
    lines.append("")

    lines.append("## By detector (count, min–max score)")
    lines.append("")
    lines.append("| detector | count | score range |")
    lines.append("|----------|-------|-------------|")
    for det, scores in sorted(by_det.items(), key=lambda kv: -len(kv[1])):
        lines.append(f"| {det} | {len(scores)} | {min(scores)}–{max(scores)} |")
    lines.append("")

    lines.append(f"## Top {min(args.top, len(ranked))}")
    lines.append("")
    for i, r in enumerate(ranked[: args.top], 1):
        sig = ", ".join(
            f"{k}" for k, v in r["signals"].items()
            if v is True and k != "bucket"
        )
        fname = Path(r["file_path"]).name
        lines.append(
            f"{i}. **{r['bucket']}** score={r['score']} "
            f"`{r['protocol']}` `{r['detector']}` `{r['severity']}` "
            f"`{fname}:{r['line_number']}` "
            f"`{r['function']}` — {r['message']}"
            + (f"\n   signals: {sig}" if sig else "")
        )
    lines.append("")

    lines.append("## Full ranking")
    lines.append("")
    lines.append("| # | bucket | score | protocol | detector | severity | function | file:line |")
    lines.append("|---|--------|-------|----------|----------|----------|----------|-----------|")
    for i, r in enumerate(ranked, 1):
        fname = Path(r["file_path"]).name
        lines.append(
            f"| {i} | {r['bucket']} | {r['score']} | {r['protocol']} | "
            f"{r['detector']} | {r['severity']} | {r['function']} | "
            f"{fname}:{r['line_number']} |"
        )
    lines.append("")

    lines.append("## Per-protocol summary")
    lines.append("")
    by_proto: dict[str, dict[str, int]] = {}
    for r in ranked:
        d = by_proto.setdefault(r["protocol"], {})
        d[r["bucket"]] = d.get(r["bucket"], 0) + 1
    lines.append("| protocol | HIGH | MEDIUM | LOW |")
    lines.append("|----------|------|--------|-----|")
    for proto, d in sorted(by_proto.items(), key=lambda kv: -kv[1].get("HIGH", 0)):
        lines.append(f"| {proto} | {d.get('HIGH', 0)} | {d.get('MEDIUM', 0)} | {d.get('LOW', 0)} |")
    lines.append("")
    out_md.write_text("\n".join(lines))
    print(f"Wrote {out_md}")

    Path(args.out_json).write_text(json.dumps(ranked, indent=2))
    print(f"Wrote {args.out_json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
