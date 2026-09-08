#!/usr/bin/env bash
# Face Login (Howdy) — uninstaller.
#
# Reverses install.sh: restores PAM backups (or strips our lines), removes
# the lock-screen slot, probe shim, menu row and management TUI. Never touches
# the password stacks. Optionally removes howdy-next and face models.
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR=/var/lib/face-login-howdy/pam-backups
GATE_RE='omarchy-hw-laptop-closed'
HOWDY_RE='pam_howdy\.so'

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi
REAL_USER="${SUDO_USER:-}"
[[ -z $REAL_USER || $REAL_USER == root ]] && REAL_USER="$(stat -c %U "$PLUGIN_DIR")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

# 1. PAM: remove our lines (gate + pam_howdy). pam_unix stacks were never
# modified, so services keep working after removal.
strip_pam() { # $1 = service file
  local f="$1"
  [[ -f $f ]] || return 0
  if grep -qE "$HOWDY_RE|$GATE_RE" "$f"; then
    cp -a "$f" "$BACKUP_DIR/pre-uninstall.$(basename "$f").$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    sed -i "/$HOWDY_RE/d;/$GATE_RE/d" "$f"
    echo "stripped: $f"
  fi
}
strip_pam /etc/pam.d/sudo
strip_pam /etc/pam.d/sddm

# polkit-1 was created by us only when absent; remove only if it is still
# exactly our content (gate+howdy+unix), otherwise strip.
if [[ -f /etc/pam.d/polkit-1 ]]; then
  if ! grep -qvE '^(#%PAM-1.0|auth|account|password|session|\s*$)' /etc/pam.d/polkit-1 \
     && ! grep -q 'system-auth' /etc/pam.d/polkit-1; then
    rm -f /etc/pam.d/polkit-1
    echo "removed: /etc/pam.d/polkit-1"
  else
    strip_pam /etc/pam.d/polkit-1
  fi
fi

# 2. Lock-screen biometric slot + probe shim
rm -f /etc/pam.d/omarchy-lock-fingerprint && echo "removed: omarchy-lock-fingerprint"
if [[ -f /usr/local/bin/fprintd-list ]] && grep -q 'face-login-howdy' /usr/local/bin/fprintd-list 2>/dev/null; then
  rm -f /usr/local/bin/fprintd-list && echo "removed: fprintd-list shim"
fi

# 3. Menu row + TUI
MENU="$REAL_HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [[ -f $MENU ]] && grep -q 'setup\.security\.face' "$MENU"; then
  cp -a "$MENU" "$BACKUP_DIR/pre-uninstall.omarchy-menu.jsonc.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  sed -i '/face-login-howdy/d;/"setup\.security\.face"/d' "$MENU"
  echo "stripped: $MENU"
fi
rm -f "$REAL_HOME/.local/bin/face-login-manage" && echo "removed: face-login-manage"

# 4. Optional: package + models
if command -v gum >/dev/null 2>&1; then
  if gum confirm "Also remove the howdy-next package? (keeps models otherwise)"; then
    pacman -R --noconfirm howdy-next 2>/dev/null || true
  fi
  if gum confirm "Delete all enrolled face models?"; then
    rm -rf /etc/howdy/models
    echo "removed: /etc/howdy/models"
  fi
else
  echo "kept: howdy-next package and /etc/howdy/models (remove manually if wanted)"
fi

echo "done. PAM originals (pre-install) remain under $BACKUP_DIR"
