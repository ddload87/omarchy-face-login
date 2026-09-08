#!/usr/bin/env bash
# Face Login (Howdy) — system installer for Omarchy / Arch Linux.
#
# Sets up Windows Hello-style face authentication with howdy-next:
#   sudo / polkit / sddm   → clamshell gate + `auth sufficient pam_howdy.so`
#                            (password stacks untouched, password stays as fallback)
#   Omarchy lock screen    → the shell's biometric PAM slot
#                            (/etc/pam.d/omarchy-lock-fingerprint) backed by
#                            pam_howdy + a small fprintd-list probe shim
#   Omarchy menu           → Setup → Security → Face Recognition row
#   Management TUI         → ~/.local/bin/face-login-manage
#
# Cameras: any V4L2 camera (uvcvideo). Apple MacBooks with the Broadcom
# 14e4:1570 FaceTime HD camera (pre-T2) get the facetimehd-dkms driver
# installed automatically when no video device exists yet.
#
# Idempotent: re-running is a no-op or a safe re-apply. Roll back with
# uninstall.sh. Never removes password authentication.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR=/var/lib/face-login-howdy/pam-backups
GATE='auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'
HOWDY='auth      sufficient pam_howdy.so'

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi
REAL_USER="${SUDO_USER:-}"
[[ -z $REAL_USER || $REAL_USER == root ]] && REAL_USER="$(stat -c %U "$PLUGIN_DIR")"
echo "==> installing for user: $REAL_USER"

# 1. Repository dependencies (including build tooling)
pacman -S --needed --noconfirm \
  libevdev libinih acl curl openssl opencv qt6-base yyjson pam \
  cmake gettext base-devel git

# 2. AUR helper (builds as the invoking user, never root)
# --nocheck: howdy-next's test suite contains security cases that require
# root-owned fixture paths (upstream CI runs as root); they fail in any
# unprivileged build environment. That is environmental, not a code defect.
aur_install() { # $1 = AUR package name
  local pkg="$1"
  if pacman -Q "$pkg" &>/dev/null; then
    echo "already installed: $pkg"
    return
  fi
  local tmp
  tmp="$(runuser -u "$REAL_USER" -- mktemp -d)"
  runuser -u "$REAL_USER" -- git clone -q "https://aur.archlinux.org/$pkg.git" "$tmp/$pkg"
  (cd "$tmp/$pkg" && runuser -u "$REAL_USER" -- makepkg -f --nocheck --noconfirm)
  pacman -U --noconfirm "$tmp/$pkg/$pkg"-*.pkg.tar.zst
}

# 2a. Pre-T2 Apple FaceTime HD camera (Broadcom 14e4:1570): needs the
# facetimehd driver when no video device exists yet. DKMS build requires
# headers matching the RUNNING kernel.
if ! ls /dev/video* >/dev/null 2>&1 && lspci -nn 2>/dev/null | grep -q '14e4:1570'; then
  echo "==> Broadcom FaceTime HD camera detected, installing facetimehd driver"
  pacman -S --needed --noconfirm linux-headers dkms
  aur_install facetimehd-firmware
  aur_install facetimehd-dkms
  modprobe facetimehd || echo "WARN: modprobe facetimehd failed (a reboot will load it)"
fi

aur_install howdy-next

# 2b. Recognition models (YuNet detector + SFace recognizer, downloaded to the
# unpackaged /usr/share/howdy/models)
if ! ls /usr/share/howdy/models/*.onnx >/dev/null 2>&1; then
  howdy download-models
fi

# 3. PAM: sudo / sddm / polkit-1 (same insertion pattern as omarchy's own
# fingerprint setup; password stacks are never modified)
mkdir -p "$BACKUP_DIR"

insert_gate_howdy() { # $1 = pam service file
  local f="$1"
  if ! grep -q 'pam_howdy\.so' "$f"; then
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").$(date +%Y%m%d-%H%M%S)"
    sed -i "1a $HOWDY" "$f"
    echo "patched: $f (+pam_howdy)"
  fi
  if ! grep -q 'omarchy-hw-laptop-closed' "$f"; then
    sed -i "/pam_howdy\.so/i $GATE" "$f"
    echo "patched: $f (+clamshell gate)"
  fi
}

insert_gate_howdy /etc/pam.d/sudo
[[ -f /etc/pam.d/sddm ]] && insert_gate_howdy /etc/pam.d/sddm

if [[ ! -f /etc/pam.d/polkit-1 ]]; then
  cat > /etc/pam.d/polkit-1 <<EOF
#%PAM-1.0
$GATE
$HOWDY
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
EOF
  echo "created: /etc/pam.d/polkit-1"
else
  insert_gate_howdy /etc/pam.d/polkit-1
fi

# 4. Lock screen: ride the Omarchy shell's biometric slot. The shell arms the
# omarchy-lock-fingerprint PAM service in parallel at lock time when its probe
# passes (file exists + fprintd-list reports a "finger"). No clamshell gate
# here: with the lid shut howdy simply times out, matching fingerprint
# semantics.
cat > /etc/pam.d/omarchy-lock-fingerprint <<'EOF'
#%PAM-1.0
# face-login-howdy: no Linux fingerprint driver on this machine, so the
# biometric slot is backed by howdy-next face recognition. Started in parallel
# when the lock engages; password entry stays available the whole time.
auth      sufficient pam_howdy.so
auth      required   pam_deny.so

account   include    system-local-login
EOF
echo "written: /etc/pam.d/omarchy-lock-fingerprint"

# 5. Probe shim: reports a configured biometric when a howdy face model exists.
# Uses howdy-next's setuid helper (models are root-only); forwards to a real
# fprintd-list if one ever appears.
install -Dm755 "$PLUGIN_DIR/fprintd-list" /usr/local/bin/fprintd-list
echo "installed: /usr/local/bin/fprintd-list"

# 6. The sddm greeter runs as the sddm user and needs camera access
# (model/config reads are mediated by the setuid howdy-auth-helper)
if id sddm &>/dev/null && ! id -nG sddm | tr ' ' '\n' | grep -qx video; then
  usermod -aG video sddm
  echo "sddm added to video group"
fi

# 7. Camera: pin the stable by-path path (/dev/videoN drifts; the config
# schema rejects by-id paths). Skip with a warning when no camera is visible.
CONF=/etc/howdy/config.ini
CAMERA="$(ls /dev/v4l/by-path/*-video-index0 2>/dev/null | head -1 || true)"
if [[ -z $CAMERA ]]; then
  echo "WARN: no camera found. After connecting one, set it with:"
  echo "      sudo howdy config   # [video] device_path = /dev/v4l/by-path/..."
elif ! grep -qE '^\s*device_path\s*=\s*/dev/' "$CONF"; then
  cp -a "$CONF" "$BACKUP_DIR/config.ini.$(date +%Y%m%d-%H%M%S)"
  sed -i "s|^\s*device_path\s*=.*|device_path = $CAMERA|" "$CONF"
  echo "patched: $CONF (device_path=$CAMERA)"
fi

# 8. User-level: management TUI + Omarchy menu row (hot-reloads)
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
install -D -o "$REAL_USER" -g "$REAL_USER" -m755 \
  "$PLUGIN_DIR/face-login-manage" "$REAL_HOME/.local/bin/face-login-manage"
echo "installed: $REAL_HOME/.local/bin/face-login-manage"

MENU="$REAL_HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
if [[ -f $MENU ]] && ! grep -q 'setup\.security\.face' "$MENU"; then
  cp -a "$MENU" "$BACKUP_DIR/omarchy-menu.jsonc.$(date +%Y%m%d-%H%M%S)"
  sed -i '0,/^}$/s|^}$|\n  // face-login-howdy: face model management (hidden when howdy absent)\n  "setup.security.face": {"icon":"󰗽","label":"Face Recognition","when":"command -v howdy >/dev/null","action":"omarchy-launch-floating-terminal-with-presentation face-login-manage"},\n}|' "$MENU"
  echo "patched: $MENU (Setup → Security → Face Recognition)"
fi

# 9. Verification
[[ -f /usr/lib/security/pam_howdy.so ]] && echo "OK: pam_howdy.so" || { echo "FAIL: pam_howdy.so missing"; exit 1; }
[[ -x /usr/lib/howdy/howdy-auth-helper && -u /usr/lib/howdy/howdy-auth-helper ]] \
  && echo "OK: auth-helper setuid" || { echo "FAIL: auth-helper not setuid"; exit 1; }
bash -n /usr/local/bin/fprintd-list && echo "OK: shim syntax"
for f in /etc/pam.d/sudo /etc/pam.d/polkit-1 /etc/pam.d/omarchy-lock-fingerprint; do
  grep -q 'pam_howdy\.so' "$f" && echo "OK: $f" || { echo "FAIL: $f"; exit 1; }
done
howdy version 2>&1 | head -1 || true

cat <<'MSG'

Done. Next step (cannot be automated — needs your face):
  sudo howdy add          # look into the camera to enroll a face model
Verify:
  sudo howdy test         # live camera preview
  sudo -k && sudo true    # should authenticate by face
  lock the screen and look at the camera
Remove: uninstall.sh in this plugin directory.
MSG
