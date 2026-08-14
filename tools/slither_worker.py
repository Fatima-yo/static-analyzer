#!/usr/bin/env python3
"""Analyze one address-dir of the TVL corpus with Slither.

Usage:
    slither_worker.py <address_dir> <out_json>

Resolves the entry .sol (contract_name match, else first .sol), the exact solc
version from contract_info.json, and import remaps for nested source trees,
then runs Slither. Prints a tab-separated status line to stdout:
    <status>\t<rel_path>\t<dur_s>\t<findings>\t<solc_ver>\t<note>
"""
import json
import os
import re
import subprocess
import sys
import time

SLITHER = os.environ.get(
    "SLITHER_BIN", "/home/fatima/Downloads/static-analyzer/slither_env/bin/slither"
)
SOLC_ROOT = os.path.expanduser("~/.solc-select/artifacts")
TIMEOUT = int(os.environ.get("SLITHER_TIMEOUT", "300"))
EXTRA_ARGS = ["--fail-none"]


DEP_DIRS = ("/lib/", "/node_modules/", "/dependencies/", "/_dependency/",
            "/forge-std/", "/solmate/")


def is_dep_path(path):
    return any(d in path for d in DEP_DIRS)


def find_entry(root, name):
    if name:
        name_sol = name + ".sol"
        for r, _, fs in os.walk(root):
            if name_sol in fs:
                p = os.path.join(r, name_sol)
                if not is_dep_path(p):
                    return p
        for r, _, fs in os.walk(root):
            if name_sol in fs:
                return os.path.join(r, name_sol)
    best = None
    for r, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(".sol") and not f.endswith(".t.sol"):
                p = os.path.join(r, f)
                if best is None or (is_dep_path(best) and not is_dep_path(p)):
                    best = p
    return best


def extract_json_blob(path, out_dir):
    """Etherscan multi-file JSON stored in a .sol: {file.sol: {content: str}}.
    Writes each embedded file under out_dir and returns the path of the file
    whose name matches the outer file, or None."""
    try:
        data = json.load(open(path))
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    files = {k: v for k, v in data.items()
             if isinstance(k, str) and k.endswith(".sol")
             and isinstance(v, dict) and isinstance(v.get("content"), str)}
    if not files:
        return None
    base = os.path.basename(path)
    target = os.path.join(out_dir, base)
    for k, v in files.items():
        fp = os.path.join(out_dir, k)
        os.makedirs(os.path.dirname(fp), exist_ok=True)
        with open(fp, "w") as f:
            f.write(v["content"])
    return target if os.path.exists(target) else files and os.path.join(out_dir, sorted(files)[0])


def collect_imports(root):
    imps = set()
    for r, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(".sol"):
                try:
                    txt = open(os.path.join(r, f), encoding="utf-8", errors="ignore").read()
                except Exception:
                    continue
                for imp in re.findall(r'import\s+(?:[^;]*?\s+from\s+)?["\']([^"\']+)["\']', txt):
                    imps.add(imp)
    return imps


def build_remaps(root, imps):
    """Resolve every non-relative import against the on-disk tree.

    Emits one full-path remap per import ('imp=/abs/target'). Full-path keys
    are the longest possible remap prefixes, so solc maps each import exactly
    to its resolved file, regardless of renamed/versioned/srcd directories."""
    rel_index = []
    for r, _, fs in os.walk(root):
        for f in fs:
            if f.endswith(".sol"):
                rel_index.append(os.path.relpath(os.path.join(r, f), root).replace(os.sep, "/"))

    def norm(p):
        return re.sub(r"@", "", p)

    remaps = {}
    seen = set()
    for imp in sorted(imps):
        tail = imp
        while tail.startswith("./"):
            tail = tail[2:]
        if tail == imp and imp.startswith("."):
            continue  # bare '../' relative import; handled by solc's own resolution
        parts = [p for p in tail.split("/") if p not in ("", ".", "..")]
        key = "/".join(parts)
        if not key or key in seen:
            continue
        seen.add(key)
        target = resolve_import(root, key, rel_index, norm)
        if target and key != imp:
            remaps[key] = target
        elif target:
            remaps[imp] = target
    return [f"{k}={v}" for k, v in remaps.items()]


def resolve_import(root, imp, rel_index, norm):
    """Find the on-disk file for a non-relative import path, or None."""
    direct = os.path.join(root, imp)
    if os.path.isfile(direct):
        return direct
    nimp = norm(imp)
    parts = nimp.split("/")
    # exact normalized path
    for rp in rel_index:
        if norm(rp) == nimp:
            return os.path.join(root, rp)
    # suffix match on normalized tail (handles versioned/renamed dirs, src/ pkg)
    ntail = norm(parts[-1])
    best = None
    for rp in rel_index:
        nparts = norm(rp).split("/")
        if nparts[-1] == parts[-1] or nparts[-1] == ntail:
            # longest matching suffix (full import path minus first segment onward)
            for k in range(1, min(len(parts), len(nparts)) + 1):
                if nparts[-k:] == parts[-k:]:
                    if best is None or k > best[1]:
                        best = (rp, k)
                    break
    if best:
        return os.path.join(root, best[0])
    return None


def locate_dir(root, prefix):
    """Find a directory under root whose basename matches the import prefix
    (e.g. '@openzeppelin' -> 'lib/openzeppelin-contracts')."""
    stripped = prefix.lstrip("@").lower()
    hits = []
    for r, dirs, _ in os.walk(root):
        for d in dirs:
            if d.lower() == stripped or d.lower().startswith(stripped + "-") or d.lower() == stripped.split("-")[0]:
                hits.append(os.path.join(r, d))
    return hits[0] if hits else None


def count_findings(out_json):
    try:
        with open(out_json) as f:
            d = json.load(f)
        if not d.get("success", False):
            return None, d.get("error", "")
        results = d.get("results", {})
        dets = results.get("detectors", [])
        return len(dets), ""
    except Exception as e:
        return None, str(e)


def find_vyper(root):
    for r, _, fs in os.walk(root):
        for f in fs:
            if f.endswith((".vy", ".Vyper")):
                return os.path.join(r, f)
    return None


def sanitize_tree(root):
    """Some downloaded sources contain a 'slither-disable-end' comment with no
    matching 'slither-disable-start', which crashes Slither. Copy the tree to a
    temp dir stripping unbalanced directives. Returns (tmpdir, entry_map)."""
    import shutil
    tmp = root + ".sanitized"
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.copytree(root, tmp, symlinks=True)
    changed = False
    for r, _, fs in os.walk(tmp):
        for f in fs:
            if f.endswith(".sol"):
                p = os.path.join(r, f)
                try:
                    lines = open(p, encoding="utf-8", errors="ignore").read().splitlines(True)
                except Exception:
                    continue
                out = []
                depth = 0
                dirty = False
                for ln in lines:
                    if "slither-disable-start" in ln:
                        depth += 1
                    elif "slither-disable-end" in ln:
                        if depth > 0:
                            depth -= 1
                        else:
                            dirty = True
                            continue  # unbalanced: drop the line
                    out.append(ln)
                if dirty:
                    with open(p, "w") as fh:
                        fh.writelines(out)
                    changed = True
    return tmp if changed else None


def main():
    addr_dir, out_json = sys.argv[1], sys.argv[2]
    rel = os.path.relpath(addr_dir, sys.argv[3] if len(sys.argv) > 3 else "/")
    t0 = time.time()

    ci = os.path.join(addr_dir, "contract_info.json")
    name = ""
    ver = ""
    try:
        d = json.load(open(ci))
        name = d.get("contract_name", "")
        ver = re.search(r"v([\d.]+)", d.get("compiler", "")).group(1)
    except Exception:
        pass

    entry = find_entry(addr_dir, name)
    workdir = addr_dir
    if entry and os.path.isfile(entry) and entry.endswith(".sol"):
        probe = open(entry, encoding="utf-8", errors="ignore").read(256)
        if probe.lstrip().startswith("# @version"):
            dur = time.time() - t0
            print(f"VYPER\t{rel}\t{dur:.0f}\t-\t{ver}\t{os.path.basename(entry)}")
            return 0
        if probe.lstrip().startswith("{"):
            tmp = os.path.join(addr_dir, ".extracted")
            target = extract_json_blob(entry, tmp)
            if target:
                entry = target
                workdir = tmp
    if not entry:
        # maybe a Vyper contract (Slither cannot analyze .vy)
        vy = find_vyper(addr_dir)
        if vy:
            dur = time.time() - t0
            print(f"VYPER\t{rel}\t{dur:.0f}\t-\t{ver}\t{os.path.basename(vy)}")
            return 0
        dur = time.time() - t0
        print(f"FAIL\t{rel}\t{dur:.0f}\t-\t{ver}\tno .sol entry found")
        return 1
    sanitized = sanitize_tree(workdir)
    if sanitized:
        workdir = sanitized
        entry = find_entry(workdir, name) or entry
    if not entry:
        dur = time.time() - t0
        print(f"FAIL\t{rel}\t{dur:.0f}\t-\t{ver}\tno .sol entry found")
        return 1

    cmd = [SLITHER, entry, "--compile-force-framework", "solc"]
    if ver:
        base = os.path.join(SOLC_ROOT, f"solc-{ver}")
        solc = os.path.join(base, f"solc-{ver}")
        if not os.path.isfile(solc) and os.path.isfile(base):
            solc = base  # legacy: artifact installed as a single binary
        elif not os.path.isfile(solc):
            # search artifact dir for an installed binary of this version
            for cand in os.listdir(SOLC_ROOT):
                if cand == f"solc-{ver}":
                    inner = os.path.join(base, cand)
                    if os.path.isfile(inner):
                        solc = inner
                        break
        if os.path.isfile(solc):
            cmd += ["--solc", solc]
        else:
            dur = time.time() - t0
            print(f"FAIL\t{rel}\t{dur:.0f}\t-\t{ver}\tsolc artifact not installed")
            return 1

    imps = collect_imports(workdir)
    remaps = build_remaps(workdir, imps)
    if remaps:
        cmd += ["--solc-remaps", " ".join(remaps)]
    cmd += ["--solc-args", f"--allow-paths {workdir}"]
    cmd += ["--json", out_json] + EXTRA_ARGS

    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        dur = time.time() - t0
        print(f"TIMEOUT\t{rel}\t{dur:.0f}\t-\t{ver}\ttimeout after {TIMEOUT}s")
        return 1

    if p.returncode != 0 and "Stack too deep" in (p.stderr or ""):
        retry = [a for a in cmd]
        retry[retry.index("--solc-args") + 1] += " --via-ir"
        try:
            p2 = subprocess.run(retry, capture_output=True, text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            p2 = None
        if p2 is not None and p2.returncode == 0:
            p = p2

    dur = time.time() - t0
    findings, err = count_findings(out_json)
    if findings is None and p.returncode != 0:
        tail = (p.stderr or "").strip().splitlines()
        tail = tail[-3:] if tail else []
        why = " | ".join(tail)[:160]
        print(f"FAIL\t{rel}\t{dur:.0f}\t-\t{ver}\t{err[:60]} {why}")
        return 1
    if findings is None:
        print(f"EMPTY\t{rel}\t{dur:.0f}\t-\t{ver}\tno json output (rc={p.returncode})")
        return 1
    note = ""
    if p.returncode != 0:
        note = f"rc={p.returncode}"
    print(f"OK\t{rel}\t{dur:.0f}\t{findings}\t{ver}\t{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
