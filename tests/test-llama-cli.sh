#!/usr/bin/env bash
# Matrix test: llama-cli (and llama-bench) from pkg.llama-cpp-sycl
# (bumped to llama.cpp@ad09224) against ollama-store models on L0.
#
# Goal: prove qwen3.5 / qwen3.6 / glm-4.7-flash / gpt-oss load and
# generate coherent tokens under ONEAPI_DEVICE_SELECTOR=level_zero:0
# on the Intel Arc Pro B70 (Battlemage). qwen3.5 is the original
# motivator — its qwen35 arch has been broken on the deployed
# ollama-sycl + OpenCL combo and is the immediate blocker for the
# unvendoring effort.
#
# Run from a yolo-sandboxed claude session after /var/lib/ollama is
# bind-mounted (--ro). Falls back to /tmp/exchange/<name>.gguf for
# any model whose ollama-store blob is unreadable from this session.
#
# Output: /tmp/exchange/llama-cli-l0-matrix.tsv + .out

set -uo pipefail

OUT=/tmp/exchange/llama-cli-l0-matrix.out
TSV=/tmp/exchange/llama-cli-l0-matrix.tsv
LCS_FLAKE='/home/pavel/work/safe/nix-config?submodules=1#nixosConfigurations.vm.pkgs.llama-cpp-sycl'

# Models to test, paired with the ollama-store ref. The script resolves
# each into a GGUF blob path via the model's manifest. Tags chosen to
# exercise the architectures that matter for the L0 push:
#   - qwen35  (qwen3.5 dense)             : qwen3.5:9b
#   - qwen35  (qwen3.5 MoE)               : qwen3.5:35b-a3b
#   - qwen35  (qwen3.6 dense — same arch) : qwen3.6:27b
#   - qwen35moe                           : qwen3.6:latest  (36B-a-something MoE)
#   - glm4moelite                         : glm-4.7-flash:latest
#   - gptoss  (MXFP4 + bf16)              : gpt-oss:20b
# Add/remove rows here as desired.
declare -a MODELS=(
  "qwen3.5:9b"
  "qwen3.5:35b-a3b"
  "qwen3.6:27b"
  "qwen3.6:latest"
  "glm-4.7-flash:latest"
  "gpt-oss:20b"
)

OLLAMA_STORE=/var/lib/ollama/models
PROMPT="Reply with one short sentence: what is the capital of France?"

# ============================================================
# Setup
# ============================================================

bat --paging=never "$0" 2>/dev/null || cat "$0"
read -r -p "Press Enter to run, Ctrl+C to abort..."
exec > >(tee "$OUT") 2>&1

echo "=== building llama-cpp-sycl ==="
LCS=$(nix build --no-link --print-out-paths "$LCS_FLAKE" 2>/dev/null)
if [ -z "$LCS" ]; then
  echo "FATAL: llama-cpp-sycl build failed"
  exit 1
fi
echo "LCS=$LCS"
ls "$LCS/bin/llama-bench" "$LCS/bin/llama-cli" "$LCS/bin/libggml-sycl.so" 2>&1 | head -3

# Sanity: L0 device must be visible. If this fails, intel-compute-runtime
# isn't seeing the GPU from inside the sandbox.
echo
echo "=== llama-cli --list-devices on L0 ==="
env -u OCL_ICD_VENDORS ONEAPI_DEVICE_SELECTOR=level_zero:0 \
  SYCL_CACHE_PERSISTENT=0 ZES_ENABLE_SYSMAN=1 \
  LD_LIBRARY_PATH=/run/opengl-driver/lib \
  "$LCS/bin/llama-cli" --list-devices 2>&1 | head -15

# ============================================================
# Helpers
# ============================================================

# Resolve a model:tag into an absolute path of its GGUF blob via the
# ollama manifest. Echoes the path (or empty string on failure).
resolve_blob () {
  local model="$1"
  local ns="${model%%:*}"
  local tag="${model#*:}"
  [ "$ns" = "$tag" ] && tag=latest
  local mf="$OLLAMA_STORE/manifests/registry.ollama.ai/library/$ns/$tag"
  if [ ! -r "$mf" ]; then
    return 1
  fi
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
# pp/tg throughput and the first 6 generated words.
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
  bench_out=$(timeout 300 env -u OCL_ICD_VENDORS \
      ONEAPI_DEVICE_SELECTOR=level_zero:0 \
      SYCL_CACHE_PERSISTENT=0 ZES_ENABLE_SYSMAN=1 \
      LD_LIBRARY_PATH=/run/opengl-driver/lib \
      "$LCS/bin/llama-bench" -m "$gguf" -p 32 -n 16 -t "$(nproc)" -r 1 -ngl 99 2>&1)
  bench_rc=$?
  echo "$bench_out" | tail -20
  echo "bench exit=$bench_rc"

  pp=$(echo "$bench_out" | awk -F'[|±]' '/\| *pp32 *\|/ {gsub(/ /,"",$8); print $8; exit}')
  tg=$(echo "$bench_out" | awk -F'[|±]' '/\| *tg16 *\|/ {gsub(/ /,"",$8); print $8; exit}')

  echo
  echo "--- llama-cli --single-turn ---"
  cli_out=$(timeout 180 env -u OCL_ICD_VENDORS \
      ONEAPI_DEVICE_SELECTOR=level_zero:0 \
      SYCL_CACHE_PERSISTENT=0 ZES_ENABLE_SYSMAN=1 \
      LD_LIBRARY_PATH=/run/opengl-driver/lib \
      "$LCS/bin/llama-cli" -m "$gguf" -ngl 99 -n 32 \
        --single-turn -p "$PROMPT" -t "$(nproc)" 2>&1 </dev/null)
  cli_rc=$?
  echo "$cli_out" | tail -30
  echo "cli exit=$cli_rc"

  cli_tg=$(echo "$cli_out" | grep -oE 'Generation:[^|]*t/s' | grep -oE '[0-9.]+' | head -1)
  # Pull the first 8 words emitted after the prompt as a coherence signal.
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
