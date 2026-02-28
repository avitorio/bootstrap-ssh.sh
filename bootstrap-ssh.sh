#!/usr/bin/env bash
set -euo pipefail

# One-shot bootstrap (Ubuntu):
# - user + SSH keys + locked password + passwordless sudo
# - Tailscale install + interactive login URL flow (waits for approval)
# - bind sshd to Tailscale IP only + UFW tailnet-only inbound
# - disable root ssh + disable ssh password auth

NEW_USER="${1:-}"
if [[ -z "${NEW_USER}" ]]; then
  echo "Usage: sudo $0 <username>"
  exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (use sudo)."
  exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script needs apt-get (Ubuntu/Debian)."
  exit 1
fi

ROOT_AUTH="/root/.ssh/authorized_keys"
TS_WAIT_SECONDS="${TS_WAIT_SECONDS:-600}"   # 10 minutes
TS_POLL_SECONDS="${TS_POLL_SECONDS:-3}"

log() { printf "\n==> %s\n" "$*"; }

detect_admin_group() {
  if getent group sudo >/dev/null 2>&1; then echo "sudo"
  elif getent group wheel >/dev/null 2>&1; then echo "wheel"
  else echo ""
  fi
}

ensure_user() {
  if id "${NEW_USER}" >/dev/null 2>&1; then
    log "User '${NEW_USER}' already exists"
  else
    log "Creating user '${NEW_USER}'"
    useradd -m -s /bin/bash "${NEW_USER}"
  fi
}

ensure_admin_group() {
  local grp
  grp="$(detect_admin_group)"
  if [[ -z "${grp}" ]]; then
    echo "Could not find sudo/wheel group."
    exit 1
  fi
  log "Adding '${NEW_USER}' to admin group '${grp}'"
  usermod -aG "${grp}" "${NEW_USER}"
}

copy_ssh_keys() {
  if [[ ! -f "${ROOT_AUTH}" ]]; then
    log "No ${ROOT_AUTH} found. Skipping SSH key copy."
    return
  fi
  local home_dir ssh_dir user_auth
  home_dir="$(eval echo "~${NEW_USER}")"
  ssh_dir="${home_dir}/.ssh"
  user_auth="${ssh_dir}/authorized_keys"

  log "Copying root SSH authorized_keys to ${NEW_USER}"
  install -d -m 700 -o "${NEW_USER}" -g "${NEW_USER}" "${ssh_dir}"
  install -m 600 -o "${NEW_USER}" -g "${NEW_USER}" "${ROOT_AUTH}" "${user_auth}"
}

lock_user_password() {
  log "Locking password for '${NEW_USER}' (SSH keys only)"
  passwd -l "${NEW_USER}" >/dev/null 2>&1 || true
}

enable_nopasswd_sudo() {
  local file="/etc/sudoers.d/90-${NEW_USER}-nopasswd"
  log "Enabling passwordless sudo for '${NEW_USER}' via ${file}"
  cat > "${file}" <<EOF
${NEW_USER} ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 440 "${file}"
  visudo -cf "${file}" >/dev/null
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    log "Tailscale already installed"
    return
  fi
  log "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
}

tailscale_is_up() {
  command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1
}

tailscale_up_interactive_and_wait() {
  log "Starting Tailscale (interactive login)"
  # This prints the login URL. It returns non-zero until authenticated on many systems, so don't fail the script.
  set +e
  tailscale up
  set -e

  log "Waiting for Tailscale to become authenticated (up to ${TS_WAIT_SECONDS}s)"
  local waited=0
  until tailscale_is_up; do
    sleep "${TS_POLL_SECONDS}"
    waited=$((waited + TS_POLL_SECONDS))
    if (( waited >= TS_WAIT_SECONDS )); then
      echo "Timed out waiting for Tailscale login."
      echo "Complete the login URL and then re-run the script (it is idempotent)."
      exit 1
    fi
  done

  tailscale status || true
}

get_tailscale_ipv4() {
  tailscale ip -4 2>/dev/null | head -n1 || true
}

backup_file() {
  local f="$1"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "${f}.bak.${ts}"
  echo "${f}.bak.${ts}"
}

find_sshd_config() {
  [[ -f /etc/ssh/sshd_config ]] && echo "/etc/ssh/sshd_config" && return
  [[ -f /etc/sshd_config ]] && echo "/etc/sshd_config" && return
  echo ""
}

validate_sshd_config() {
  command -v sshd >/dev/null 2>&1 && sshd -t >/dev/null 2>&1
}

set_sshd_option() {
  local file="$1" key="$2" value="$3"
  if grep -qiE "^[[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i -E "s|^[[:space:]]*(${key})[[:space:]]+.*|\1 ${value}|I" "$file"
  elif grep -qiE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*(${key})[[:space:]]+.*|\1 ${value}|I" "$file"
  else
    printf "\n%s %s\n" "$key" "$value" >>"$file"
  fi
}

bind_sshd_to_tailscale_ip() {
  local cfg ts_ip backup
  cfg="$(find_sshd_config)"
  [[ -z "${cfg}" ]] && echo "No sshd_config found" && exit 1

  ts_ip="$(get_tailscale_ipv4)"
  [[ -z "${ts_ip}" ]] && echo "No Tailscale IP found" && exit 1

  log "Binding SSHD to Tailscale IP: ${ts_ip} (plus 127.0.0.1)"
  backup="$(backup_file "${cfg}")"
  echo "Backup saved to: ${backup}"

  sed -i -E '/^[[:space:]]*#?[[:space:]]*ListenAddress[[:space:]]+/Id' "${cfg}"
  cat >> "${cfg}" <<EOF

# Bound by bootstrap script on $(date -Is)
ListenAddress ${ts_ip}
ListenAddress 127.0.0.1
EOF

  if ! validate_sshd_config; then
    echo "sshd config invalid after binding. Restoring."
    cp -a "${backup}" "${cfg}"
    exit 1
  fi
}

enable_ufw_tailscale_only() {
  log "Configuring UFW: inbound only from tailscale0"
  apt-get update -y
  apt-get install -y ufw

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow in on lo
  ufw allow in on tailscale0
  ufw allow 41641/udp

  ufw --force enable
  ufw status verbose
}

harden_sshd() {
  local cfg backup
  cfg="$(find_sshd_config)"
  [[ -z "${cfg}" ]] && echo "No sshd_config found" && exit 1

  log "Hardening SSH (disable root SSH, disable password auth)"
  backup="$(backup_file "${cfg}")"
  echo "Backup saved to: ${backup}"

  set_sshd_option "${cfg}" "PermitRootLogin" "no"
  set_sshd_option "${cfg}" "PasswordAuthentication" "no"
  set_sshd_option "${cfg}" "KbdInteractiveAuthentication" "no" || true
  set_sshd_option "${cfg}" "ChallengeResponseAuthentication" "no" || true

  if ! validate_sshd_config; then
    echo "sshd config invalid after hardening. Restoring."
    cp -a "${backup}" "${cfg}"
    exit 1
  fi
}

reload_sshd() {
  log "Reloading SSH daemon"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || \
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
  else
    service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || \
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
  fi
}

main() {
  ensure_user
  ensure_admin_group
  copy_ssh_keys
  lock_user_password
  enable_nopasswd_sudo

  install_tailscale
  tailscale_up_interactive_and_wait

  bind_sshd_to_tailscale_ip
  enable_ufw_tailscale_only

  harden_sshd
  reload_sshd

  local ts_ip
  ts_ip="$(get_tailscale_ipv4)"
  log "Done"
  echo
  echo "Test from a Tailscale-connected device:"
  echo "  ssh ${NEW_USER}@${ts_ip}"
  echo
  echo "Public inbound access should now be blocked."
  echo "Keep this session open until you've confirmed the Tailscale SSH works."
}

main