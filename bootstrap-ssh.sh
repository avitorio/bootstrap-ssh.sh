#!/usr/bin/env bash
set -euo pipefail

# create-admin-user-and-disable-root-ssh.sh
#
# What it does:
#  1) Creates a new user (if missing) with /bin/bash + home dir
#  2) Adds user to sudo (Debian/Ubuntu) or wheel (RHEL/CentOS/Amazon Linux)
#  3) Copies /root/.ssh/authorized_keys to the new user (safe perms/ownership)
#  4) Updates sshd_config to disable root login and password auth
#  5) Reloads ssh/sshd
#
# Usage:
#   sudo ./create-admin-user-and-disable-root-ssh.sh <username>
#
# Example:
#   sudo ./create-admin-user-and-disable-root-ssh.sh deploy
#
# Important:
#   Keep your current root session open. Test "ssh <user>@server" before closing it.

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

detect_sudo_group() {
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
    echo "Set a password for '${NEW_USER}' (recommended as a fallback):"
    passwd "${NEW_USER}"
  fi
}

ensure_sudo() {
  local grp
  grp="$(detect_sudo_group)"
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

  # SELinux (if present)
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -Rv "${ssh_dir}" >/dev/null 2>&1 || true
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
  # Ensures a setting exists once (replace if present, else append)
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -qiE "^[[:space:]]*${key}[[:space:]]+" "$file"; then
    # replace uncommented occurrences
    sed -i -E "s|^[[:space:]]*(${key})[[:space:]]+.*|\1 ${value}|I" "$file"
  elif grep -qiE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$file"; then
    # replace commented occurrences
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*(${key})[[:space:]]+.*|\1 ${value}|I" "$file"
  else
    printf "\n%s %s\n" "$key" "$value" >>"$file"
  fi
}

harden_sshd() {
  local cfg=""
  if [[ -f /etc/ssh/sshd_config ]]; then
    cfg="/etc/ssh/sshd_config"
  elif [[ -f /etc/sshd_config ]]; then
    cfg="/etc/sshd_config"
  else
    echo "Could not find sshd_config."
    exit 1
  fi

  log "Backing up SSH config: ${cfg}"
  local backup
  backup="$(backup_file "${cfg}")"
  echo "Backup saved to: ${backup}"

  log "Disabling root SSH login and password authentication"
  set_sshd_option "${cfg}" "PermitRootLogin" "no"
  set_sshd_option "${cfg}" "PasswordAuthentication" "no"

  # This helps avoid unexpected interactive prompts via PAM on some setups
  set_sshd_option "${cfg}" "KbdInteractiveAuthentication" "no" || true
  set_sshd_option "${cfg}" "ChallengeResponseAuthentication" "no" || true

  # Validate config if sshd supports it
  if command -v sshd >/dev/null 2>&1; then
    if ! sshd -t >/dev/null 2>&1; then
      echo "sshd config test failed. Restoring backup."
      cp -a "${backup}" "${cfg}"
      exit 1
    fi
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
      # fallback attempt
      systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
      systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    fi
  else
    service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || \
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
  fi
}

main() {
  log "Ensuring user exists"
  ensure_user

  log "Ensuring user has sudo access"
  ensure_sudo

  log "Copying root SSH keys"
  copy_ssh_keys

  log "Hardening SSH daemon config"
  harden_sshd

  reload_sshd

  log "All done"
  echo
  echo "Now test in a NEW terminal before closing this one:"
  echo "  ssh ${NEW_USER}@<server>"
  echo
  echo "If you get locked out, restore the sshd_config backup printed above and restart sshd."
}

main