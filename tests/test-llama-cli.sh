#!/usr/bin/env bash
# Matrix test: llama-cli / llama-bench from pkg.llama-cpp-sycl
# (already on PATH after `nixos-rebuild switch`) against HuggingFace
# GGUFs on Level Zero (Intel Arc Pro B70 / Battlemage).
#
# Earlier rev tried ollama-store blobs from /var/lib/ollama; failed
# on every arch except qwen3 because ollama emits GGUFs through its
# own Go engine using arch-name spellings (`glm4moelite`, `gptoss`,
# `mistral3`) and metadata layouts that don't match upstream stock
# llama.cpp@ad09224's expectations. HF GGUFs published by community
# quantizers track upstream arch names, so they exercise the SYCL
# backend end-to-end without the ollama-format drift.
#
# Run from a yolo-sandboxed claude session. Downloads land in
# /tmp/exchange/hf-ggufs/ and are reused across runs.
#
# Output:
#   /tmp/exchange/llama-cli-l0-matrix.tsv  (one-line-per-model table)
#   /tmp/exchange/llama-cli-l0-matrix.out  (full log)

set -uo pipefail

OUT=/tmp/exchange/llama-cli-l0-matrix.out
TSV=/tmp/exchange/llama-cli-l0-matrix.tsv
# GGUFs land under ./debug/hf-ggufs/ (gitignored) so they survive
# reboots — /tmp/exchange is tmpfs and loses them. Tested files are
# 45 GB total; redownloading from HF every time is wasteful.
GGUF_DIR="$(dirname "$0")/../debug/hf-ggufs"

# Each row: <label>|<HF repo>|<filename>. Filenames verified live on
# 2026-05-19 via /api/models/<repo>/tree/main — all are single-file
# GGUFs, public, no auth required. Total ≈ 50 GB if all fresh.
#
# Architectures targeted (per llama.cpp@ad09224 src/llama-arch.cpp):
#   qwen2          — long-standing dense Transformer; control
#   qwen3          — dense, post-Qwen2; ad09224's Qwen3-Next adds SSM_SCAN
#                    but base Qwen3 dense is plain GQA Transformer
#   qwen35         — qwen3.5 family dense; rope.dimension_sections
#                    was the ollama-format mismatch in earlier rev
#   gemma3         — Google Gemma 3; tied embeddings
#   glm4           — THUDM GLM-4 dense Chat (not glm4moe — different arch)
#   gpt-oss        — OpenAI 20B MoE; MXFP4 + bf16 norms
#   llama          — control
#   ministral      — Mistral's 8B dense; uses sliding-window attn
declare -a MODELS=(
  # qwen2 arch — control case
  "qwen2.5_7b_q4|bartowski/Qwen2.5-7B-Instruct-GGUF|Qwen2.5-7B-Instruct-Q4_K_M.gguf"
  # qwen3 arch dense, small/fast smoke (1.83 GB Q8_0)
  "qwen3_1.7b_q8|Qwen/Qwen3-1.7B-GGUF|Qwen3-1.7B-Q8_0.gguf"
  # qwen3 arch dense larger
  "qwen3_8b_q4|unsloth/Qwen3-8B-GGUF|Qwen3-8B-Q4_K_M.gguf"
  # qwen35 arch — the one ollama-store version failed with
  # `rope.dimension_sections has wrong array length`. HF unsloth
  # quant should have the upstream-expected metadata layout.
  "qwen3.5_9b_q4|unsloth/Qwen3.5-9B-GGUF|Qwen3.5-9B-Q4_K_M.gguf"
  # gemma3 arch
  "gemma3_4b_q4|ggml-org/gemma-3-4b-it-GGUF|gemma-3-4b-it-Q4_K_M.gguf"
  # glm4 arch (THUDM GLM-4-9B-Chat). The original THUDM repo is gated;
  # bartowski's quant is public.
  "glm4_9b_q4|bartowski/glm-4-9b-chat-GGUF|glm-4-9b-chat-Q4_K_M.gguf"
  # gpt-oss arch — OpenAI 20B MoE, MXFP4 weights + bf16 norms.
  # Exercises the bf16 IMF-bypass postPatch in pkg/llama-cpp-sycl
  # AND the mxfp4 dequant memcpy fix.
  "gpt-oss_20b_mxfp4|ggml-org/gpt-oss-20b-GGUF|gpt-oss-20b-mxfp4.gguf"
  # llama arch — control
  "llama3.1_8b_q4|bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
  # mistral arch (Ministral, Mistral's 8B with sliding-window attn)
  "ministral_8b_q4|bartowski/Ministral-8B-Instruct-2410-GGUF|Ministral-8B-Instruct-2410-Q4_K_M.gguf"
)
PROMPT="Reply with one short sentence: what is the capital of France?"

mkdir -p "$GGUF_DIR"

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
# HF download helper
# ============================================================

# Download <repo>/<filename> to <dst>. Resumes if partial. Returns 0
# on success, non-zero otherwise.
download_gguf () {
  local repo="$1"
  local fname="$2"
  local dst="$3"
  local url="https://huggingface.co/${repo}/resolve/main/${fname}"

  if [ -f "$dst" ]; then
    # Quick check: is it a valid GGUF (starts with "GGUF" magic)?
    if [ "$(head -c 4 "$dst" 2>/dev/null)" = "GGUF" ]; then
      echo "  HAVE: $(basename "$dst") ($(stat -c%s "$dst" | numfmt --to=iec))"
      return 0
    else
      echo "  CORRUPT: $(basename "$dst") doesn't start with GGUF magic; redownloading"
      rm -f "$dst"
    fi
  fi

  echo "  DOWNLOAD: $url"
  if ! curl -L -C - --fail --progress-bar -o "$dst" "$url"; then
    echo "  FAIL: curl exit non-zero"
    rm -f "$dst"
    return 1
  fi
  if [ "$(head -c 4 "$dst" 2>/dev/null)" != "GGUF" ]; then
    echo "  FAIL: downloaded file is not a GGUF (probably 404/HTML error page)"
    head -c 200 "$dst" | sed 's/^/  >> /'
    rm -f "$dst"
    return 1
  fi
  echo "  OK: $(stat -c%s "$dst" | numfmt --to=iec)"
  return 0
}

# ============================================================
# Test runner
# ============================================================

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
# Main: download + test loop
# ============================================================

echo
echo "============================================================"
echo "=== fetching missing GGUFs to $GGUF_DIR"
echo "============================================================"
declare -A RESOLVED
for row in "${MODELS[@]}"; do
  IFS='|' read -r label repo fname <<< "$row"
  echo
  echo "[$label] $repo / $fname"
  dst="$GGUF_DIR/${label}.gguf"
  if download_gguf "$repo" "$fname" "$dst"; then
    RESOLVED["$label"]="$dst"
  fi
done

echo
echo "============================================================"
echo "=== running L0 matrix"
echo "============================================================"
printf 'model\tpp_t_s\ttg_t_s\tbench_exit\tcli_exit\tcli_tg_t_s\tfirst_words\n' > "$TSV"

for row in "${MODELS[@]}"; do
  IFS='|' read -r label _ _ <<< "$row"
  gguf="${RESOLVED[$label]:-}"
  if [ -z "$gguf" ]; then
    echo
    echo "=== SKIP $label (download failed)"
    printf '%s\tSKIP\tSKIP\t-\t-\t-\tdownload failed\n' "$label" >> "$TSV"
    continue
  fi
  run_one "$label" "$gguf"
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
echo "ggufs: $GGUF_DIR ($(du -sh "$GGUF_DIR" 2>/dev/null | cut -f1) total)"
