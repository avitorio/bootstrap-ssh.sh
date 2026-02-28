#!/usr/bin/env bash
set -euo pipefail

# bootstrap-ssh.sh
#
# What it does:
#  1) Creates a new user (if missing) with /bin/bash + home dir
#  2) Adds user to sudo (Debian/Ubuntu) or wheel (RHEL/CentOS/Amazon Linux)
#  3) Copies /root/.ssh/authorized_keys to the new user (secure perms/ownership)
#  4) Locks the user's password (no password login)
#  5) Enables passwordless sudo for the new user (sudo won't ask for a password)
#  6) Updates sshd_config to disable root SSH login and password authentication
#  7) Validates sshd config (if possible) and reloads ssh/sshd
#
# Usage:
#   sudo ./bootstrap-ssh.sh <username>
#
# Remote usage:
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<branch>/bootstrap-ssh.sh | sudo bash -s -- <username>
#
# Notes:
# - Keep your current root session open.
# - After running, test: ssh <username>@<server> in a NEW terminal.

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

log() { printf "\n==> %s\n" "$*"; }

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
    echo "Could not find 'sudo' or 'wheel' group on this system."
    echo "Add '${NEW_USER}' to the correct admin group manually."
    return
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

  # SELinux contexts (if present)
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -Rv "${ssh_dir}" >/dev/null 2>&1 || true
  fi
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

backup_file() {
  local f="$1"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "${f}.bak.${ts}"
  echo "${f}.bak.${ts}"
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

harden_sshd() {
  local cfg
  cfg="$(find_sshd_config)"
  if [[ -z "${cfg}" ]]; then
    echo "Could not find sshd_config."
    exit 1
  fi

  log "Backing up SSH config: ${cfg}"
  local backup
  backup="$(backup_file "${cfg}")"
  echo "Backup saved to: ${backup}"

  log "Updating SSH daemon settings"
  set_sshd_option "${cfg}" "PermitRootLogin" "no"
  set_sshd_option "${cfg}" "PasswordAuthentication" "no"

  # These vary by distro/version; safe to set if supported
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
    elif systemctl list-units --type=service --all | grep -qE '^ssh\.service'; then
      systemctl reload ssh || systemctl restart ssh
    else
      systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
      systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    fi
  else
    service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || \
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
  fi
}

smoke_test_sudo() {
  log "Smoke test: sudo as '${NEW_USER}'"
  if sudo -u "${NEW_USER}" -H bash -lc 'sudo -n true' >/dev/null 2>&1; then
    echo "sudo works for ${NEW_USER} without a password"
  else
    echo "Warning: sudo test failed for ${NEW_USER}. Check group membership and sudoers."
  fi
}

main() {
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

  log "Hardening SSH daemon config"
  harden_sshd

  reload_sshd

  log "Done"
  echo
  echo "Test in a NEW terminal before closing this one:"
  echo "  ssh ${NEW_USER}@<server>"
  echo
  echo "If you get locked out, restore the sshd_config backup printed above and restart sshd."
}

main