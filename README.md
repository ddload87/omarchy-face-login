# Face Login (Howdy) — Omarchy plugin

Windows Hello-style face authentication for Omarchy, powered by
[howdy-next](https://codeberg.org/nathawat/howdy-next) (the maintained C++
rewrite of Howdy with a native `pam_howdy.so`).

One look at the camera can authenticate:

| Surface | Mechanism |
|---|---|
| `sudo` | `pam_howdy.so` inserted at the top of the stack |
| polkit prompts | same, via `/etc/pam.d/polkit-1` |
| SDDM greeter login | same, via `/etc/pam.d/sddm` |
| Omarchy lock screen | the shell's biometric slot (`omarchy-lock-fingerprint` PAM service) backed by face recognition |
| Omarchy menu | Setup → Security → **Face Recognition** management entry |

**Password authentication is never removed.** Face failure or timeout always
falls back to the password prompt. With the laptop lid shut (reader
unreachable), a clamshell gate skips face auth entirely.

## Requirements

- Omarchy (Quattro) on Arch Linux, with the Quickshell shell lock
  (any recent Omarchy install)
- A V4L2 camera:
  - any UVC webcam works out of the box
  - Apple T2 MacBooks: the FaceTime HD camera works via the t2linux stack
  - pre-T2 Apple MacBooks (Broadcom `14e4:1570`): the installer sets up
    `facetimehd-dkms` automatically when no video device exists
- An AUR-capable toolchain (the installer handles `base-devel` itself)
- Root access during install (the installer self-elevates with `sudo`)

Note: Touch ID on T2 MacBooks has no Linux driver (the sensor is wired to the
T2 Secure Enclave); this plugin uses the camera instead.

## Install

```bash
# 1. Add the plugin
omarchy plugin add https://github.com/ddload87/omarchy-face-login.git

# 2. Run the system installer once (idempotent; PAM originals are backed up)
~/.config/omarchy/plugins/io.github.ddload87.face-login/install.sh

# 3. Enroll your face (needs you physically at the machine)
sudo howdy add
```

The Omarchy menu then gains **Setup → Security → Face Recognition**, opening
the management TUI (add/remove models, live camera test, enable/disable
toggle, clear).

## Verify

```bash
sudo howdy test        # live camera preview with recognition overlay
sudo -k && sudo true   # should authenticate by face
```

Lock the screen and look at the camera — the lock's parallel biometric
prompt unlocks you. If the display has already blanked, press any key first:
the screen lighting your face makes recognition instant.

## Manage

```bash
sudo howdy list        # enrolled models
sudo howdy add         # add another angle/lighting condition (best accuracy win)
sudo howdy remove <ID>
sudo howdy disable true|false
```

or use the TUI: omarchy menu → Setup → Security → Face Recognition.

## Security notes

- Face recognition is a convenience factor and **weaker than a password**;
  similar faces or photos may pass. This is an RGB camera setup without IR,
  so accuracy drops in the dark. Keep your password safe — it stays fully
  functional.
- Face models live in `/etc/howdy/models` (root-only `0750`/`0600`). PAM
  clients running as a regular user (lock screen, sddm greeter) get mediated
  access through howdy-next's setuid `howdy-auth-helper`; nothing is made
  world-readable.
- Every modified PAM file is backed up with a timestamp under
  `/var/lib/face-login-howdy/pam-backups/`.
- The lock-screen probe shim (`/usr/local/bin/fprintd-list`) only answers the
  shell's "is a biometric configured?" check and forwards to a real
  `fprintd-list` if one is ever installed.

## Uninstall

```bash
~/.config/omarchy/plugins/io.github.ddload87.face-login/uninstall.sh
omarchy plugin remove io.github.ddload87.face-login
```

Restores PAM files (our lines are stripped; originals remain in the backup
directory), removes the lock-screen slot, probe shim, menu row and TUI.
Optionally removes the howdy-next package and enrolled models.

## How it works

The Omarchy lock screen already ships a parallel biometric authentication
slot: when a probe succeeds (`/etc/pam.d/omarchy-lock-fingerprint` exists and
`fprintd-list` reports an enrolled finger), it starts that PAM service next to
the password field and unlocks on success. This plugin points that slot at
`pam_howdy.so` and answers the probe based on enrolled face models — no shell
code is modified, so Omarchy updates cannot conflict with it.

## Credits

- [howdy-next](https://codeberg.org/nathawat/howdy-next) (GPL-3.0) — recognition engine and PAM module
- [Howdy](https://github.com/boltgolt/howdy) — original concept
- [facetimehd](https://github.com/patjak/facetimehd) — pre-T2 Apple camera driver

## License

MIT (this plugin's scripts and QML). Dependencies carry their own licenses.
