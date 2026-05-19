#!/usr/bin/env bash
# Matrix test: llama-cli / llama-bench from pkg.llama-cpp-sycl
# (already on PATH after `nixos-rebuild switch`) against the ollama
# model store on L0.
#
# Goal: prove qwen3.5 / qwen3.6 / glm-4.7-flash / gpt-oss / gemma4 /
# ministral-3 load and generate coherent tokens under
# ONEAPI_DEVICE_SELECTOR=level_zero:0 on the Intel Arc Pro B70
# (Battlemage). qwen3.5 (qwen35 arch) is the original motivator —
# previously broken on the deployed ollama-sycl + OpenCL combo.
#
# Run from a yolo-sandboxed claude session — /var/lib/ollama is now
# bind-mounted read-only into the sandbox. Falls back to
# /tmp/exchange/<name>.gguf if a model's blob isn't readable.
#
# Output:
#   /tmp/exchange/llama-cli-l0-matrix.tsv  (one-line-per-model table)
#   /tmp/exchange/llama-cli-l0-matrix.out  (full log)

set -uo pipefail

OUT=/tmp/exchange/llama-cli-l0-matrix.out
TSV=/tmp/exchange/llama-cli-l0-matrix.tsv

# Models to test, paired with the ollama-store ref. The script resolves
# each into a GGUF blob path via the model's manifest. All confirmed
# present in /var/lib/ollama on the vm host as of 2026-05-19.
# Architectures exercised:
#   - qwen3        (Mamba-2 hybrid; SSM_SCAN)           : qwen3:4b
#   - qwen35       (dense)                              : qwen3.5:9b, qwen3.6:27b
#   - qwen35moe    (MoE)                                : qwen3.6:latest
#   - glm4moelite  (MoE; needs MLA-FA)                  : glm-4.7-flash:latest
#   - gptoss       (MXFP4 + bf16 mix)                   : gpt-oss:20b
#   - gemma4       (dense)                              : gemma4:e4b
#   - mistral3     (uses GATED_DELTA_NET)               : ministral-3:14b
declare -a MODELS=(
  "qwen3:4b"
  "qwen3.5:9b"
  "qwen3.6:27b"
  "qwen3.6:latest"
  "glm-4.7-flash:latest"
  "gpt-oss:20b"
  "gemma4:e4b"
  "ministral-3:14b"
)

OLLAMA_STORE=/var/lib/ollama/models
PROMPT="Reply with one short sentence: what is the capital of France?"

# Common L0 env. SYCL_CACHE_PERSISTENT=0 works around the libsycl
# getSortedImages NULL-deref (intel-llvm@unstable-2025-11-14); see
# debug/20260508-1718-intel-llvm-getsortedimages-null-strcmp.md.
# ZES_ENABLE_SYSMAN=1 gives accurate VRAM stats on B70.
# `env -u OCL_ICD_VENDORS` is critical: any leaked OCL_ICD_VENDORS from
# the parent env (the deployed ollama-sycl wrapper sets it) makes SYCL
# prefer the OpenCL ICD even when level_zero:0 is requested.
L0_ENV=(
  env -u OCL_ICD_VENDORS
  ONEAPI_DEVICE_SELECTOR=level_zero:0
  SYCL_CACHE_PERSISTENT=0
  ZES_ENABLE_SYSMAN=1
  LD_LIBRARY_PATH=/run/opengl-driver/lib
)

# ============================================================
# Setup
# ============================================================

bat --paging=never "$0" 2>/dev/null || cat "$0"
read -r -p "Press Enter to run, Ctrl+C to abort..."
exec > >(tee "$OUT") 2>&1

# Bumped llama-cpp-sycl is in the system closure already
# (`nixos-rebuild switch`'d in via /run/current-system/sw/bin). Use
# the system-installed binaries; no `nix build` needed.
LLAMA_CLI=$(command -v llama-cli)
LLAMA_BENCH=$(command -v llama-bench)
echo "llama-cli   : $LLAMA_CLI"
echo "llama-bench : $LLAMA_BENCH"
if [ -z "$LLAMA_CLI" ] || [ -z "$LLAMA_BENCH" ]; then
  echo "FATAL: llama-cli/llama-bench not on PATH; is llama-cpp-sycl in the host config?"
  exit 1
fi
# Pin the libggml-sycl.so directory so cached store paths from earlier
# experiments don't accidentally win.
LCS_DIR=$(dirname "$(readlink -f "$LLAMA_CLI")")
echo "lcs dir     : $LCS_DIR"
ls "$LCS_DIR"/libggml-sycl.so 2>&1 | head -1

echo
echo "=== L0 device discovery ==="
"${L0_ENV[@]}" "$LLAMA_CLI" --list-devices 2>&1 | head -20

# ============================================================
# Helpers
# ============================================================

# Resolve a model:tag into an absolute path of its GGUF blob via the
# ollama manifest.
resolve_blob () {
  local model="$1"
  local ns="${model%%:*}"
  local tag="${model#*:}"
  [ "$ns" = "$tag" ] && tag=latest
  local mf="$OLLAMA_STORE/manifests/registry.ollama.ai/library/$ns/$tag"
  [ -r "$mf" ] || return 1
  python3 - "$mf" "$OLLAMA_STORE" <<'PYEOF'
import json, os, sys
mf, store = sys.argv[1], sys.argv[2]
with open(mf) as f:
    m = json.load(f)
for layer in m.get("layers", []):
    mt = layer.get("mediaType", "")
    if "model" in mt and "projector" not in mt:
        digest = layer["digest"].replace(":", "-")
        path = os.path.join(store, "blobs", digest)
        if os.path.exists(path):
            print(path)
            sys.exit(0)
sys.exit(2)
PYEOF
}

# Fallback for non-ollama-store GGUFs (e.g. /tmp/exchange/qwen3-4b.gguf
# from earlier testing).
fallback_blob () {
  local model="$1"
  local sanitized="${model//[:\/]/_}"
  for cand in \
    "/tmp/exchange/${sanitized}.gguf" \
    "/tmp/exchange/${model%%:*}-${model#*:}.gguf"; do
    if [ -r "$cand" ]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

# Run llama-bench + llama-cli --single-turn for one model. Captures
# pp/tg throughput and the first few generated words.
run_one () {
  local model="$1"
  local gguf="$2"

  echo
  echo "============================================================"
  echo "=== $model"
  echo "=== gguf : $gguf"
  echo "=== size : $(stat -c %s "$gguf" 2>/dev/null || echo '?') bytes"
  echo "============================================================"

  local bench_out cli_out pp tg bench_rc cli_rc cli_tg snippet
  bench_out=$(timeout 300 "${L0_ENV[@]}" \
      "$LLAMA_BENCH" -m "$gguf" -p 32 -n 16 -t "$(nproc)" -r 1 -ngl 99 2>&1)
  bench_rc=$?
  echo "$bench_out" | tail -20
  echo "bench exit=$bench_rc"

  pp=$(echo "$bench_out" | awk -F'[|±]' '/\| *pp32 *\|/ {gsub(/ /,"",$8); print $8; exit}')
  tg=$(echo "$bench_out" | awk -F'[|±]' '/\| *tg16 *\|/ {gsub(/ /,"",$8); print $8; exit}')

  echo
  echo "--- llama-cli --single-turn ---"
  cli_out=$(timeout 180 "${L0_ENV[@]}" \
      "$LLAMA_CLI" -m "$gguf" -ngl 99 -n 32 \
        --single-turn -p "$PROMPT" -t "$(nproc)" 2>&1 </dev/null)
  cli_rc=$?
  echo "$cli_out" | tail -30
  echo "cli exit=$cli_rc"

  cli_tg=$(echo "$cli_out" | grep -oE 'Generation:[^|]*t/s' | grep -oE '[0-9.]+' | head -1)
  # Pull a coherence snippet — first 20 words after the prompt line.
  snippet=$(echo "$cli_out" \
    | sed -n "/$(echo "$PROMPT" | head -c 40)/,/Exiting/p" \
    | tr -s ' \n\t' ' ' \
    | awk '{for(i=1;i<=NF && i<=20;i++) printf "%s ", $i; print ""}' \
    | head -1)

  printf '%s\t%s\t%s\t%d\t%d\t%s\t%s\n' \
    "$model" "${pp:-?}" "${tg:-?}" "$bench_rc" "$cli_rc" "${cli_tg:-?}" "${snippet:-?}" >> "$TSV"
}

# ============================================================
# Main loop
# ============================================================

printf 'model\tpp_t_s\ttg_t_s\tbench_exit\tcli_exit\tcli_tg_t_s\tfirst_words\n' > "$TSV"

for model in "${MODELS[@]}"; do
  blob=$(resolve_blob "$model" 2>/dev/null) || true
  if [ -z "$blob" ]; then
    blob=$(fallback_blob "$model" 2>/dev/null) || true
  fi
  if [ -z "$blob" ]; then
    echo
    echo "============================================================"
    echo "=== SKIP $model (no blob found in $OLLAMA_STORE or /tmp/exchange)"
    echo "============================================================"
    printf '%s\tSKIP\tSKIP\t-\t-\t-\tno blob resolved\n' "$model" >> "$TSV"
    continue
  fi
  run_one "$model" "$blob"
done

# ============================================================
# Summary
# ============================================================

echo
echo "============================================================"
echo "=== L0 MATRIX SUMMARY ==="
echo "============================================================"
column -t -s $'\t' "$TSV"
echo
echo "logs : $OUT"
echo "table: $TSV"
