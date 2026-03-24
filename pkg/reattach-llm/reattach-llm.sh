set -euo pipefail

readonly SESSION_NAME="llm"
readonly INITIAL_WINDOW_NAME="shell"
USER_NAME="$(id -un)"
readonly USER_NAME

declare -A session_tty_set=()
declare -A attached_pid_set=()
declare -a candidate_rows=()
declare -a attached_rows=()

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

ensure_session() {
  if ! tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
    tmux new-session -d -s "${SESSION_NAME}" -n "${INITIAL_WINDOW_NAME}"
  fi
}

load_session_state() {
  session_tty_set=()
  attached_pid_set=()

  while IFS= read -r pane_tty; do
    if [[ -z "${pane_tty}" ]]; then
      continue
    fi

    session_tty_set["${pane_tty}"]=1

    while IFS= read -r attached_pid; do
      if [[ -z "${attached_pid}" ]]; then
        continue
      fi

      attached_pid_set["${attached_pid}"]=1
    done < <(
      ps -t "${pane_tty#/dev/}" -o args= \
        | awk '
            match($0, /(^|[[:space:]])reptyr[[:space:]]+(-T[[:space:]]+)?([0-9]+)($|[[:space:]])/, groups) {
              print groups[3]
            }
          '
    )
  done < <(tmux list-panes -t "${SESSION_NAME}" -F '#{pane_tty}')
}

collect_candidates_for_tty() {
  local tty="$1"

  local -a tty_rows=()
  local row

  while IFS= read -r row; do
    if [[ -z "${row}" ]]; then
      continue
    fi

    tty_rows+=("${row}")
  done < <(
    ps -t "${tty#/dev/}" -o pid=,ppid=,comm=,args= --no-headers --sort pid | awk '
      {
        pid = $1
        ppid = $2
        comm = $3
        sub(/^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", $0)
        print pid "\t" ppid "\t" comm "\t" $0
      }
    '
  )

  if [[ "${#tty_rows[@]}" -eq 0 ]]; then
    return
  fi

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

  if [[ "${#related_pid_set[@]}" -eq 0 ]]; then
    return
  fi

  local root_pid=""
  local root_comm=""
  local root_args=""

  for row in "${tty_rows[@]}"; do
    local pid
    local ppid
    local comm
    local args
    IFS=$'\t' read -r pid ppid comm args <<<"${row}"

    if [[ -z "${related_pid_set["${pid}"]+x}" ]]; then
      continue
    fi

    if [[ -n "${related_pid_set["${ppid}"]+x}" ]]; then
      continue
    fi

    root_pid="${pid}"
    root_comm="${comm}"
    root_args="${args}"
    break
  done

  if [[ -z "${root_pid}" ]]; then
    echo "Failed to determine sandbox root for tty ${tty}." >&2
    exit 1
  fi

  if [[ -n "${attached_pid_set["${root_pid}"]+x}" ]]; then
    return
  fi

  candidate_rows+=("${root_pid}"$'\t'"${tool_name}"$'\t'"${tty}"$'\t'"${root_comm}"$'\t'"${root_args}")
}

collect_candidates() {
  candidate_rows=()

  while IFS=$'\t' read -r tty; do
    if [[ -z "${tty}" ]]; then
      continue
    fi

    if [[ -n "${session_tty_set["${tty}"]+x}" ]]; then
      continue
    fi

    collect_candidates_for_tty "${tty}"
  done < <(ps -u "${USER_NAME}" -o tty= --no-headers | awk '
      {
        if ($1 == "?") {
          next
        }

        print "/dev/" $1
      }
    ' | sort -u)
}

attach_candidates() {
  local row

  for row in "${candidate_rows[@]}"; do
    local pid
    local tool_name
    local tty
    local root_comm
    local root_args
    IFS=$'\t' read -r pid tool_name tty root_comm root_args <<<"${row}"

    local window_name="${tool_name}-${pid}"
    tmux new-window -d -t "${SESSION_NAME}:" -n "${window_name}" \
      "bash -lc 'sudo reptyr -s -T ${pid}; exit_code=\$?; if [[ \$exit_code -ne 0 ]]; then echo; echo \"reptyr failed for pid ${pid} with exit code \$exit_code\"; echo \"Press Enter to close this pane.\"; read -r _; exit \$exit_code; fi'"

    attached_rows+=("${pid}"$'\t'"${tool_name}"$'\t'"${tty}"$'\t'"${root_comm}")
  done
}

print_summary() {
  if [[ "${#attached_rows[@]}" -eq 0 ]]; then
    echo "No unattached Claude/Codex/Gemini processes found for tmux session '${SESSION_NAME}'."
    return
  fi

  echo "Attached processes to tmux session '${SESSION_NAME}':"

  local row
  for row in "${attached_rows[@]}"; do
    local pid
    local tool_name
    local tty
    local root_comm
    IFS=$'\t' read -r pid tool_name tty root_comm <<<"${row}"
    printf '  %s pid=%s from %s (%s)\n' "${tool_name}" "${pid}" "${tty}" "${root_comm}"
  done
}

ensure_session
load_session_state
collect_candidates
attach_candidates
print_summary
