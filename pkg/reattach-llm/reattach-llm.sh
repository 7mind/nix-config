set -euo pipefail

readonly SUDO_BIN="/run/wrappers/bin/sudo"
readonly SELF_BIN="$0"
USER_NAME="$(id -un)"
readonly USER_NAME

declare -A tmux_tty_set=()
declare -A attached_pid_set=()
declare -a candidate_rows=()
declare -a process_rows=()

fail() {
  echo "$1" >&2
  exit 1
}

ensure_tmux() {
  [[ -n "${TMUX-}" ]] || fail "reattach-llm must be run from inside tmux."
  [[ -u "${SUDO_BIN}" ]] || fail "Expected setuid sudo wrapper at ${SUDO_BIN}."
}

llm_label_from_text() {
  local text="$1"

  case "${text}" in
    *claude*)
      printf '%s\n' "claude"
      return 0
      ;;
    *codex*)
      printf '%s\n' "codex"
      return 0
      ;;
    *gemini*)
      printf '%s\n' "gemini"
      return 0
      ;;
  esac

  return 1
}

load_tmux_state() {
  tmux_tty_set=()
  attached_pid_set=()

  while IFS= read -r pane_tty; do
    [[ -n "${pane_tty}" ]] || continue

    tmux_tty_set["${pane_tty}"]=1

    while IFS= read -r attached_pid; do
      [[ -n "${attached_pid}" ]] || continue
      attached_pid_set["${attached_pid}"]=1
    done < <(
      ps -t "${pane_tty#/dev/}" -o args= \
        | awk '
            match($0, /(^|[[:space:]])reptyr[[:space:]]+(-s[[:space:]]+)?(-T[[:space:]]+)?([0-9]+)($|[[:space:]])/, groups) {
              print groups[4]
            }
          '
    )
  done < <(tmux list-panes -a -F '#{pane_tty}')
}

load_process_rows() {
  process_rows=()

  local row
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    process_rows+=("${row}")
  done < <(
    ps -u "${USER_NAME}" -o pid=,ppid=,tty=,comm=,args= --no-headers --sort tty,pid | awk '
      {
        pid = $1
        ppid = $2
        tty = $3
        comm = $4
        sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", $0)
        print pid "\t" ppid "\t" tty "\t" comm "\t" $0
      }
    '
  )
}

collect_candidates_for_tty() {
  local tty="$1"

  local -a tty_rows=()
  local row

  for row in "${process_rows[@]}"; do
    local pid
    local ppid
    local process_tty
    local comm
    local args
    IFS=$'\t' read -r pid ppid process_tty comm args <<<"${row}"

    if [[ "/dev/${process_tty}" != "${tty}" ]]; then
      continue
    fi

    tty_rows+=("${pid}"$'\t'"${ppid}"$'\t'"${comm}"$'\t'"${args}")
  done

  [[ "${#tty_rows[@]}" -gt 0 ]] || return 0

  local -A related_pid_set=()
  local tool_name=""

  for row in "${tty_rows[@]}"; do
    local pid
    local ppid
    local comm
    local args
    IFS=$'\t' read -r pid ppid comm args <<<"${row}"

    local label=""
    if label="$(llm_label_from_text "${comm}")"; then
      :
    elif label="$(llm_label_from_text "${args}")"; then
      :
    else
      continue
    fi

    related_pid_set["${pid}"]=1
    if [[ -z "${tool_name}" ]]; then
      tool_name="${label}"
    fi
  done

  [[ "${#related_pid_set[@]}" -gt 0 ]] || return 0

  local root_pid=""
  local root_comm=""
  local root_args=""

  for row in "${tty_rows[@]}"; do
    local pid
    local ppid
    local comm
    local args
    IFS=$'\t' read -r pid ppid comm args <<<"${row}"

    [[ -n "${related_pid_set["${pid}"]+x}" ]] || continue
    [[ -z "${related_pid_set["${ppid}"]+x}" ]] || continue

    root_pid="${pid}"
    root_comm="${comm}"
    root_args="${args}"
    break
  done

  [[ -n "${root_pid}" ]] || fail "Failed to determine sandbox root for tty ${tty}."
  [[ -z "${tmux_tty_set["${tty}"]+x}" ]] || return 0
  [[ -z "${attached_pid_set["${root_pid}"]+x}" ]] || return 0

  candidate_rows+=("${root_pid}"$'\t'"${tool_name}"$'\t'"${tty}"$'\t'"${root_comm}"$'\t'"${root_args}")
}

collect_candidates() {
  candidate_rows=()
  load_process_rows

  local -A seen_tty_set=()
  local row
  for row in "${process_rows[@]}"; do
    local pid
    local ppid
    local process_tty
    local comm
    local args
    IFS=$'\t' read -r pid ppid process_tty comm args <<<"${row}"

    if [[ "${process_tty}" == "?" ]]; then
      continue
    fi

    local tty="/dev/${process_tty}"
    if [[ -n "${seen_tty_set["${tty}"]+x}" ]]; then
      continue
    fi

    seen_tty_set["${tty}"]=1
    collect_candidates_for_tty "${tty}"
  done
}

attach_pid() {
  local selected_pid="$1"
  local target_session="$2"

  load_tmux_state
  collect_candidates

  local row
  for row in "${candidate_rows[@]}"; do
    local pid
    local tool_name
    local tty
    local root_comm
    local root_args
    IFS=$'\t' read -r pid tool_name tty root_comm root_args <<<"${row}"

    if [[ "${pid}" != "${selected_pid}" ]]; then
      continue
    fi

    local window_name="${tool_name}-${pid}"
    tmux new-window -d -t "${target_session}:" -n "${window_name}" \
      "bash -lc '${SUDO_BIN} reptyr -s -T ${pid}; exit_code=\$?; if [[ \$exit_code -ne 0 ]]; then echo; echo \"reptyr failed for pid ${pid} with exit code \$exit_code\"; echo \"Press Enter to close this pane.\"; read -r _; exit \$exit_code; fi'"
    return
  done

  tmux display-message "LLM process ${selected_pid} is no longer available."
}

show_menu() {
  load_tmux_state
  collect_candidates

  if [[ "${#candidate_rows[@]}" -eq 0 ]]; then
    tmux display-message "No unattached Claude/Codex/Gemini processes found."
    return
  fi

  local current_session
  current_session="$(tmux display-message -p '#{session_name}')"

  local -a menu_args=()
  menu_args+=(-T "Reattach LLM")

  local row
  for row in "${candidate_rows[@]}"; do
    local pid
    local tool_name
    local tty
    local root_comm
    local root_args
    IFS=$'\t' read -r pid tool_name tty root_comm root_args <<<"${row}"

    local item_name="${tool_name} pid=${pid} ${tty}"
    local command
    printf -v command "run-shell %q" "${SELF_BIN} --attach ${pid} ${current_session}"
    menu_args+=("${item_name}" "" "${command}")
  done

  tmux display-menu "${menu_args[@]}"
}

main() {
  ensure_tmux

  case "${1-}" in
    --attach)
      [[ $# -eq 3 ]] || fail "Usage: reattach-llm --attach PID TARGET_SESSION"
      attach_pid "$2" "$3"
      ;;
    "")
      [[ $# -eq 0 ]] || fail "Usage: reattach-llm [--attach PID TARGET_SESSION]"
      show_menu
      ;;
    *)
      fail "Usage: reattach-llm [--attach PID TARGET_SESSION]"
      ;;
  esac
}

main "$@"
