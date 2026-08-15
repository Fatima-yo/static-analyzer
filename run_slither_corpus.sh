#!/usr/bin/env bash
#
# Run Slither over the full TVL protocol corpus.
#
# Usage:
#   ./run_slither_corpus.sh [CORPUS_DIR] [OUTPUT_DIR] [WORKERS]
#
#   CORPUS_DIR  (default) /home/fatima/Downloads/TVL/output/full_code
#               Each protocol dir: <corpus>/<proto>/<chain>_<chainid>/<address>/
#   OUTPUT_DIR  (default) opencode_artifacts/slither_YYYYMMDD_HHMMSS/
#   WORKERS     (default) 4  number of slither processes in parallel
#
# Per-address results land in OUTPUT_DIR/results/ as <proto>__<address>.json
# (Slither's own schema). A summary TSV is written to OUTPUT_DIR/results.tsv and
# an aggregated top-findings report to OUTPUT_DIR/top_findings.tsv.
#
set -uo pipefail

ANALYZER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS_DIR="${1:-/home/fatima/Downloads/TVL/output/full_code}"
OUTPUT_DIR="${2:-$ANALYZER_ROOT/opencode_artifacts/slither_$(date +%Y%m%d_%H%M%S)}"
WORKERS="${3:-4}"

SLITHER_BIN="$ANALYZER_ROOT/slither_env/bin/slither"
WORKER="$ANALYZER_ROOT/tools/slither_worker.py"
PYTHON_BIN="${SLITHER_BIN%/bin/slither}/bin/python"

if [ ! -x "$SLITHER_BIN" ]; then
    echo "ERROR: Slither not found at $SLITHER_BIN (install into slither_env first)" >&2
    exit 1
fi
if [ ! -d "$CORPUS_DIR" ]; then
    echo "ERROR: corpus dir not found: $CORPUS_DIR" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR/results"
echo "corpus : $CORPUS_DIR"
echo "output : $OUTPUT_DIR"
echo "workers: $WORKERS"

# Collect all address dirs (<proto>/<chain>/<address>/), 3 levels below corpus root.
mapfile -t DIRS < <(find "$CORPUS_DIR" -mindepth 3 -maxdepth 3 -type d ! -name "*.sanitized" ! -name ".extracted" ! -name ".sanitized" | sort)

echo "address dirs found: ${#DIRS[@]}"
printf "%s\n" "${DIRS[@]}" > "$OUTPUT_DIR/address_dirs.txt"

if [ "${#DIRS[@]}" -eq 0 ]; then
    echo "no address dirs found; exiting"
    exit 1
fi

# Parallel dispatch: one slither worker per address dir.
export SLITHER_BIN
PROGRESS_LOG="$OUTPUT_DIR/progress.log"
printf "%s\n" "${DIRS[@]}" | xargs -P "$WORKERS" -n 1 -I{} bash -c '
    dir="{}"
    rel="${dir#"'"$CORPUS_DIR"'"/}"
    proto="${rel%%/*}"
    addr="$(basename "$dir")"
    out="'"$OUTPUT_DIR"'/results/${proto}__${addr}.json"
    "'"$PYTHON_BIN"'" "'"$WORKER"'" "$dir" "$out" "'"$CORPUS_DIR"'" >> "'"$PROGRESS_LOG"'"
    echo "done: $rel" >> "'"$PROGRESS_LOG"'"
'
echo "workers finished; collating..."

# Collate results from the worker status lines (single pass).
RESULTS_TSV="$OUTPUT_DIR/results.tsv"
grep -P "^OK\t|^FAIL\t|^TIMEOUT\t|^EMPTY\t|^VYPER\t" "$PROGRESS_LOG" > "$RESULTS_TSV" || true

# Aggregate top findings by detector/impact for a quick triage view.
"$PYTHON_BIN" -c '
import json, glob, os, sys
from collections import Counter
out = sys.argv[1]
rows = []
for j in glob.glob(os.path.join(out, "results", "*.json")):
    try:
        d = json.load(open(j))
    except Exception:
        continue
    if not d.get("success", False):
        continue
    proto = os.path.basename(j).removesuffix(".json").split("__")[0]
    for det in d.get("results", {}).get("detectors", []):
        rows.append((proto, det.get("check", ""), det.get("impact", ""), det.get("confidence", "")))
cnt = Counter((c, i) for _, c, i, _ in rows)
with open(os.path.join(out, "top_findings.tsv"), "w") as f:
    f.write("detector\timpact\tcount\n")
    for (c, i), n in cnt.most_common():
        f.write(f"{c}\t{i}\t{n}\n")
print(f"total findings: {len(rows)}")
print(f"top detectors written to {out}/top_findings.tsv")
' "$OUTPUT_DIR"

echo
echo "=== SUMMARY ==="
awk -F'\t' '{c[$1]++} END {for (k in c) print k, c[k]}' "$RESULTS_TSV" | sort
echo
echo "done. results in: $OUTPUT_DIR"
