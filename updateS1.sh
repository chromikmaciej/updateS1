#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

CONFIG="config.cnf"
HOSTS="hosts.txt"
LOG="updateS1.log"

if [[ ! -f "$CONFIG" ]]; then echo "Brak $CONFIG" >&2; exit 1; fi
if [[ ! -f "$HOSTS" ]]; then echo "Brak $HOSTS" >&2; exit 1; fi

# shellcheck source=/dev/null
source "$CONFIG"
: "${USER:?Musisz ustawić USER w $CONFIG}"
: "${PASSWORD:?Musisz ustawić PASSWORD w $CONFIG}"
: "${AGENT_URL:?Musisz ustawić AGENT_URL w $CONFIG}"

mapfile -t LINES < "$HOSTS"

timestamp(){ date '+%F %T'; }

log_line(){
  # timestamp | host | step | status | message
  printf '%s | %s | %s | %s | %s\n' "$(timestamp)" "$1" "$2" "$3" "$4" >> "$LOG"
}

SSH_OPTS="-o BatchMode=no -o ConnectTimeout=8 -o StrictHostKeyChecking=no"

# każda funkcja wykonuje dokładnie jedno ssh podobnie do run_whoami()
run_whoami(){
  local host="$1"
  sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$host" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' whoami" 2>/dev/null || true
}

# ZWRACA 'IS_ORACLE' dla Oracle, 'IS_FEDORA' dla Fedora, inaczej pusty
check_os(){
  local host="$1"
  sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$host" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' bash -lc 'if grep -qi \"oracle\" /etc/os-release; then echo IS_ORACLE; elif grep -qi \"fedora\" /etc/os-release; then echo IS_FEDORA; fi'" 2>/dev/null || true
}

# ZWRACA HAS_DNF lub NO_DNF
check_dnf(){
  local host="$1"
  sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$host" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' bash -lc 'if command -v dnf >/dev/null 2>&1; then echo HAS_DNF; else echo NO_DNF; fi'" 2>/dev/null || true
}

comment_refuse(){
  local host="$1"
  sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$host" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' bash -lc 'if grep -q \"^RefuseManualStop=yes\" /usr/lib/systemd/system/sentinelone.service 2>/dev/null; then sed -i.bak -e \"s/^RefuseManualStop=yes/#RefuseManualStop=yes/\" /usr/lib/systemd/system/sentinelone.service && echo COMMENTED || echo SED_FAILED; else echo NOT_PRESENT; fi'" 2>/dev/null || true
}

daemon_reload(){
  local host="$1"
  sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$host" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' systemctl daemon-reload && echo RELOADED || echo RELOAD_FAILED" 2>/dev/null || true
}

stop_service(){
  local host="$1"
  sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$host" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' bash -lc 'systemctl stop sentinelone >/dev/null 2>&1 && echo STOPPED || echo STOP_FAILED_OR_NOT_RUNNING'" 2>/dev/null || true
}

# funkcja instalująca agenta - zwraca INSTALL_OK lub INSTALL_FAILED + log tail
install_agent(){
  local host="$1"
  local url="${AGENT_URL//\"/\\\"}"
  sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$host" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' bash -lc 'dnf install -y --allowerasing \"${url}\" >/var/log/sentinel_update_install.log 2>&1 && echo INSTALL_OK || (echo INSTALL_FAILED; tail -n 200 /var/log/sentinel_update_install.log)'" 2>/dev/null || true
}

# usuwa plik serwisu (jedno wywołanie SSH)
remove_service_file(){
  local host="$1"
  sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$host" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' bash -lc 'if [ -f /usr/lib/systemd/system/sentinelone.service ]; then rm -f /usr/lib/systemd/system/sentinelone.service && echo REMOVED || echo REMOVE_FAILED; else echo NOT_PRESENT; fi'" 2>/dev/null || true
}

start_service(){
  local host="$1"
  sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$host" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' bash -lc 'systemctl start sentinelone >/dev/null 2>&1 && echo STARTED || echo START_FAILED'" 2>/dev/null || true
}

check_service_active(){
  local host="$1"
  sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$host" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' bash -lc 'if systemctl is-active --quiet sentinelone; then echo ACTIVE; else echo NOT_ACTIVE; fi'" 2>/dev/null || true
}

check_sentinelctl(){
  local host="$1"
  sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$host" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' bash -lc 'if command -v sentinelctl >/dev/null 2>&1; then sentinelctl version || echo SENTINELCTL_FAILED; else echo NO_SENTINELCTL; fi'" 2>/dev/null || true
}

for raw in "${LINES[@]}"; do
  trimmed="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]]; then continue; fi
  host="$(printf '%s' "$trimmed" | awk '{print $1}')"
  echo "[$(timestamp)] Connecting to $host ..."

  out="$(run_whoami "$host" || true)"
  out_s="$(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -n "$out_s" ]]; then
    echo "[$(timestamp)] $host whoami -> $out_s"
    log_line "$host" "whoami" "OK" "$out_s"
  else
    echo "[$(timestamp)] $host whoami -> ERROR (possible SSH/sudo auth failure)" >&2
    log_line "$host" "whoami" "ERROR" "SSH_AUTH_FAILED_or_no_output"
    continue
  fi

  out="$(check_os "$host" || true)"
  out_s="$(printf '%s' "$out" | tr -d '\r' | head -n1 || true)"
  if [[ "$out_s" == "IS_ORACLE" || "$out_s" == "IS_FEDORA" ]]; then
    echo "[$(timestamp)] $host check_os -> OK ($out_s)"
    log_line "$host" "check_os" "OK" "$out_s"
  else
    echo "[$(timestamp)] $host check_os -> ERROR (unsupported OS or auth failed)" >&2
    log_line "$host" "check_os" "ERROR" "${out_s:-not_supported_or_auth_failed}"
    continue
  fi

  out="$(check_dnf "$host" || true)"
  out_s="$(printf '%s' "$out" | tr -d '\r' | head -n1 || true)"
  if [[ "$out_s" == "HAS_DNF" ]]; then
    echo "[$(timestamp)] $host check_dnf -> OK"
    log_line "$host" "check_dnf" "OK" ""
  else
    echo "[$(timestamp)] $host check_dnf -> ERROR (no dnf or auth failed)" >&2
    log_line "$host" "check_dnf" "ERROR" "${out_s:-no_dnf_or_auth_failed}"
    continue
  fi

  out="$(comment_refuse "$host" || true)"
  out_s="$(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  echo "[$(timestamp)] $host comment_refuse -> ${out_s:-no_output}"
  log_line "$host" "comment_refuse" "OK" "${out_s:-no_output}"

  out="$(daemon_reload "$host" || true)"
  out_s="$(printf '%s' "$out" | tr -d '\r' | head -n1 || true)"
  echo "[$(timestamp)] $host daemon_reload -> ${out_s:-no_output}"
  log_line "$host" "daemon_reload" "OK" "${out_s:-no_output}"

  out="$(stop_service "$host" || true)"
  out_s="$(printf '%s' "$out" | tr -d '\r' | head -n1 || true)"
  echo "[$(timestamp)] $host stop_service -> ${out_s:-no_output}"
  log_line "$host" "stop_service" "OK" "${out_s:-no_output}"

  # install agent; jeśli się nie powiedzie, usuwamy plik serwisu i próbujemy jeszcze raz (max 1 retry)
  out="$(install_agent "$host" || true)"
  out_s="$(printf '%s' "$out" | tr -d '\r' | sed -e 's/[[:space:]]\+/ /g' | head -c 2000 || true)"
  if printf '%s' "$out_s" | grep -qi 'INSTALL_OK'; then
    echo "[$(timestamp)] $host install_agent -> OK"
    log_line "$host" "install_agent" "OK" "INSTALL_OK"
  else
    echo "[$(timestamp)] $host install_agent -> ERROR" >&2
    log_line "$host" "install_agent" "ERROR" "${out_s:-install_failed_or_auth_failed}"

    # dodatkowy krok: usuń /usr/lib/systemd/system/sentinelone.service i spróbuj ponownie tylko raz
    echo "[$(timestamp)] $host remove_service_file -> starting"
    rem_out="$(remove_service_file "$host" || true)"
    rem_out_s="$(printf '%s' "$rem_out" | tr -d '\r' | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    echo "[$(timestamp)] $host remove_service_file -> ${rem_out_s:-no_output}"
    log_line "$host" "remove_service_file" "OK" "${rem_out_s:-no_output}"

    out2="$(install_agent "$host" || true)"
    out2_s="$(printf '%s' "$out2" | tr -d '\r' | sed -e 's/[[:space:]]\+/ /g' | head -c 2000 || true)"
    if printf '%s' "$out2_s" | grep -qi 'INSTALL_OK'; then
      echo "[$(timestamp)] $host install_agent retry -> OK"
      log_line "$host" "install_agent_retry" "OK" "INSTALL_OK"
    else
      echo "[$(timestamp)] $host install_agent retry -> ERROR" >&2
      log_line "$host" "install_agent_retry" "ERROR" "${out2_s:-install_failed_or_auth_failed}"
      continue
    fi
  fi

  out="$(start_service "$host" || true)"
  out_s="$(printf '%s' "$out" | tr -d '\r' | head -n1 || true)"
  echo "[$(timestamp)] $host start_service -> ${out_s:-no_output}"
  log_line "$host" "start_service" "OK" "${out_s:-no_output}"

  out="$(check_service_active "$host" || true)"
  out_s="$(printf '%s' "$out" | tr -d '\r' | head -n1 || true)"
  if [[ "$out_s" == "ACTIVE" ]]; then
    echo "[$(timestamp)] $host check_service_active -> OK"
    log_line "$host" "check_service_active" "OK" "$out_s"
  else
    echo "[$(timestamp)] $host check_service_active -> ERROR" >&2
    log_line "$host" "check_service_active" "ERROR" "${out_s:-not_active_or_auth_failed}"
    continue
  fi

  out="$(check_sentinelctl "$host" || true)"
  out_s="$(printf '%s' "$out" | tr -d '\r' | head -n1 || true)"
  echo "[$(timestamp)] $host check_sentinelctl -> ${out_s:-no_output}"
  log_line "$host" "check_sentinelctl" "OK" "${out_s:-no_output}"

done

echo "Wyniki dopisane do $LOG"
exit 0
