set -euo pipefail

readonly SESSION_NAME="llm"
readonly INITIAL_WINDOW_NAME="shell"
USER_NAME="$(id -un)"
readonly USER_NAME

declare -A session_tty_set=()
declare -A attached_pid_set=()
declare -a candidate_rows=()
declare -a attached_rows=()

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

is_llm_process() {
  local comm="$1"
  local argv0="$2"

  case "${comm}" in
    claude|codex|gemini)
      return 0
      ;;
  esac

  case "${argv0}" in
    claude|codex|gemini)
      return 0
      ;;
  esac

  return 1
}

collect_candidates() {
  candidate_rows=()

  while IFS=$'\t' read -r pid comm tty args; do
    if [[ -z "${pid}" ]]; then
      continue
    fi

    if [[ "${tty}" == "?" ]]; then
      continue
    fi

    local argv0
    argv0="$(awk '{ print $1 }' <<<"${args}")"
    argv0="${argv0##*/}"

    if ! is_llm_process "${comm}" "${argv0}"; then
      continue
    fi

    local tty_path="/dev/${tty}"

    if [[ -n "${session_tty_set["${tty_path}"]+x}" ]]; then
      continue
    fi

    if [[ -n "${attached_pid_set["${pid}"]+x}" ]]; then
      continue
    fi

    candidate_rows+=("${pid}"$'\t'"${comm}"$'\t'"${tty_path}"$'\t'"${args}")
  done < <(ps -u "${USER_NAME}" -o pid=,comm=,tty=,args= --no-headers --sort pid | awk '
      {
        pid = $1
        comm = $2
        tty = $3
        sub(/^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", $0)
        print pid "\t" comm "\t" tty "\t" $0
      }
    ')
}

attach_candidates() {
  local row

  for row in "${candidate_rows[@]}"; do
    IFS=$'\t' read -r pid comm tty args <<<"${row}"

    local window_name="${comm}-${pid}"
    tmux new-window -d -t "${SESSION_NAME}:" -n "${window_name}"
    tmux send-keys -t "${SESSION_NAME}:${window_name}" "exec reptyr -T ${pid}" C-m

    attached_rows+=("${pid}"$'\t'"${comm}"$'\t'"${tty}")
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
    IFS=$'\t' read -r pid comm tty <<<"${row}"
    printf '  %s pid=%s from %s\n' "${comm}" "${pid}" "${tty}"
  done
}

ensure_session
load_session_state
collect_candidates
attach_candidates
print_summary
