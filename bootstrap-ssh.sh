#!/usr/bin/env bash
set -euo pipefail

# bootstrap-ssh-tailscale-ufw.sh (Ubuntu-focused)
#
# One-shot bootstrap for a fresh server:
# - Create user
# - Copy root SSH authorized_keys to that user
# - Lock user password (no password login)
# - Configure passwordless sudo for that user (sudo won't ask)
# - Install + bring up Tailscale (auth key recommended for non-interactive)
# - Bind sshd to the Tailscale IP only (plus 127.0.0.1)
# - Configure UFW to allow inbound ONLY from Tailscale interface (tailscale0)
#   and allow UDP 41641 for Tailscale direct connections
# - Disable root SSH login and disable SSH password authentication
#
# Usage (recommended, non-interactive, one-shot):
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<branch>/bootstrap.sh \
#     | sudo TAILSCALE_AUTHKEY="tskey-auth-XXXX" bash -s -- deploy
#
# Optional env vars:
#   TAILSCALE_HOSTNAME        Hostname in Tailscale (default: current hostname)
#   TAILSCALE_EXTRA_UP_ARGS   Extra args to tailscale up (example: --advertise-tags=tag:server)
#
# IMPORTANT:
# - This will cut off public inbound access (including public SSH) once firewall + ListenAddress apply.
# - Ensure you can reach the server via Tailscale from another device before you close your current session.
# - Keep your root session open until you've tested: ssh <user>@<tailscale-ip>

NEW_USER="${1:-}"
if [[ -z "${NEW_USER}" ]]; then
  echo "Usage: sudo $0 <username>"
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (use sudo)."
  exit 1
fi

ROOT_AUTH="/root/.ssh/authorized_keys"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}"
TAILSCALE_EXTRA_UP_ARGS="${TAILSCALE_EXTRA_UP_ARGS:-}"

log() { printf "\n==> %s\n" "$*"; }

require_ubuntu_tools() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script is Ubuntu/Debian oriented (needs apt-get)."
    exit 1
  fi
}

detect_admin_group() {
  if getent group sudo >/dev/null 2>&1; then
    echo "sudo"
  elif getent group wheel >/dev/null 2>&1; then
    echo "wheel"
  else
    echo ""
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
    echo "Could not find 'sudo' (or 'wheel') group on this system."
    echo "Add '${NEW_USER}' to the correct admin group manually."
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

  if command -v visudo >/dev/null 2>&1; then
    visudo -cf "${file}" >/dev/null
  fi
}

smoke_test_sudo() {
  log "Smoke test: sudo as '${NEW_USER}' (no password prompt expected)"
  if sudo -u "${NEW_USER}" -H bash -lc 'sudo -n true' >/dev/null 2>&1; then
    echo "sudo works for ${NEW_USER} without a password"
  else
    echo "Warning: sudo test failed for ${NEW_USER}. Check sudoers and group membership."
  fi
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    log "Tailscale already installed"
    return
  fi

  log "Installing Tailscale (official install script)"
  curl -fsSL https://tailscale.com/install.sh | sh
}

tailscale_is_up() {
  command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1
}

tailscale_up() {
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "tailscale not found, skipping tailscale up."
    return 1
  fi

  local hn
  hn="${TAILSCALE_HOSTNAME:-$(hostname)}"

  log "Bringing up Tailscale"
  if [[ -n "${TAILSCALE_AUTHKEY}" ]]; then
    tailscale up --authkey "${TAILSCALE_AUTHKEY}" --hostname "${hn}" ${TAILSCALE_EXTRA_UP_ARGS}
  else
    echo "TAILSCALE_AUTHKEY not provided."
    echo "This script is intended to be one-shot, so provide an auth key."
    echo "Otherwise Tailscale will print a login URL and you must rerun after approving."
    tailscale up || true
    return 1
  fi

  tailscale status || true
  return 0
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
  if [[ -f /etc/ssh/sshd_config ]]; then
    echo "/etc/ssh/sshd_config"
  elif [[ -f /etc/sshd_config ]]; then
    echo "/etc/sshd_config"
  else
    echo ""
  fi
}

validate_sshd_config() {
  if command -v sshd >/dev/null 2>&1; then
    sshd -t >/dev/null 2>&1
    return $?
  fi
  return 0
}

set_sshd_option() {
  local file="$1"
  local key="$2"
  local value="$3"

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
  if [[ -z "${cfg}" ]]; then
    echo "Could not find sshd_config, skipping ListenAddress binding."
    return
  fi

  ts_ip="$(get_tailscale_ipv4)"
  if [[ -z "${ts_ip}" ]]; then
    echo "Tailscale IPv4 not found, skipping ListenAddress binding."
    return
  fi

  log "Binding SSHD to Tailscale IP only: ${ts_ip} (plus 127.0.0.1)"
  backup="$(backup_file "${cfg}")"
  echo "Backup saved to: ${backup}"

  sed -i -E '/^[[:space:]]*#?[[:space:]]*ListenAddress[[:space:]]+/Id' "${cfg}"

  cat >> "${cfg}" <<EOF

# Bound by bootstrap script on $(date -Is)
ListenAddress ${ts_ip}
ListenAddress 127.0.0.1
EOF

  if ! validate_sshd_config; then
    echo "sshd config validation failed after binding. Restoring backup."
    cp -a "${backup}" "${cfg}"
    exit 1
  fi
}

harden_sshd() {
  local cfg backup
  cfg="$(find_sshd_config)"
  if [[ -z "${cfg}" ]]; then
    echo "Could not find sshd_config."
    exit 1
  fi

  log "Backing up SSH config: ${cfg}"
  backup="$(backup_file "${cfg}")"
  echo "Backup saved to: ${backup}"

  log "Disabling root SSH and SSH password auth"
  set_sshd_option "${cfg}" "PermitRootLogin" "no"
  set_sshd_option "${cfg}" "PasswordAuthentication" "no"
  set_sshd_option "${cfg}" "KbdInteractiveAuthentication" "no" || true
  set_sshd_option "${cfg}" "ChallengeResponseAuthentication" "no" || true

  log "Validating sshd config"
  if ! validate_sshd_config; then
    echo "sshd config test failed. Restoring backup."
    cp -a "${backup}" "${cfg}"
    exit 1
  fi
}

reload_sshd() {
  log "Reloading SSH daemon"
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-units --type=service --all | grep -qE '^sshd\.service'; then
      systemctl reload sshd || systemctl restart sshd
    else
      systemctl reload ssh || systemctl restart ssh
    fi
  else
    service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || \
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
  fi
}

enable_ufw_tailscale_only() {
  log "Configuring firewall (ufw): allow inbound only from tailscale0"
  apt-get update -y
  apt-get install -y ufw

  ufw --force reset

  ufw default deny incoming
  ufw default allow outgoing

  # loopback
  ufw allow in on lo

  # allow all inbound from tailnet (services exposed on tailscale0 only)
  ufw allow in on tailscale0

  # allow Tailscale UDP for direct connections (safe to expose)
  ufw allow 41641/udp

  ufw --force enable
  ufw status verbose
}

main() {
  require_ubuntu_tools

  log "Ensuring user exists"
  ensure_user

  log "Ensuring admin group membership"
  ensure_admin_group

  log "Copying root SSH keys"
  copy_ssh_keys

  log "Locking user password and enabling passwordless sudo"
  lock_user_password
  enable_nopasswd_sudo
  smoke_test_sudo

  log "Installing and bringing up Tailscale"
  install_tailscale

  if ! tailscale_up; then
    echo
    echo "Tailscale is not fully up yet."
    echo "For one-shot setup, run again with:"
    echo "  sudo TAILSCALE_AUTHKEY='tskey-auth-...' bash bootstrap.sh ${NEW_USER}"
    echo
    exit 1
  fi

  # At this point Tailscale should have an IP
  bind_sshd_to_tailscale_ip

  # Firewall after Tailscale is confirmed up
  enable_ufw_tailscale_only

  # Finally, harden SSH and reload
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