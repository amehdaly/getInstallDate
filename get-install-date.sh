#!/usr/bin/env bash
# get-install-date.sh — Estimate Linux install date across Arch/Debian/Ubuntu/Mint/Fedora/etc.

set -euo pipefail

bold()  { tput bold 2>/dev/null || true; }
norm()  { tput sgr0 2>/dev/null || true; }
green() { tput setaf 2 2>/dev/null || true; }
blue()  { tput setaf 4 2>/dev/null || true; }
grey()  { tput setaf 8 2>/dev/null || true; }
resetc(){ tput sgr0 2>/dev/null || true; }

fmt_utc_and_local() {
  local raw="$1"; local utc locald
  utc="$(date -u -d "$raw" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$raw")"
  locald="$(date -d "$raw"  '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$raw")"
  printf "%s\n      %s\n" "UTC:    $utc" "Local:  $locald"
}

root_src() { command -v findmnt >/dev/null && findmnt -no SOURCE / || df / | awk 'NR==2{print $1}'; }
root_fstype(){ command -v findmnt >/dev/null && findmnt -no FSTYPE / || lsblk -no FSTYPE "$(root_src 2>/dev/null)" 2>/dev/null; }

# Filesystem timing
root_birth() {
  stat / 2>/dev/null | sed -n 's/.*Birth:[[:space:]]*//p' | sed 's/\.[0-9]\+//; s/[[:space:]]\{2,\}/ /g' || true
}
run_tune2fs() {
  local dev="$1"
  command -v tune2fs >/dev/null || return 0
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then sudo tune2fs -l "$dev" 2>/dev/null || true
  else tune2fs -l "$dev" 2>/dev/null || true
  fi
}
ext4_fs_created() { run_tune2fs "$1" | awk -F'Filesystem created: *' '/Filesystem created:/ {print $2}' || true; }
resolve_dev() {
  local src="$1"
  [[ "$src" =~ ^UUID= ]] && { blkid -U "${src#UUID=}" 2>/dev/null || echo "$src"; } || echo "$src"
}

# ---------- Package-manager specific readers ----------
first_pacman_entry() { [[ -r /var/log/pacman.log ]] && head -n1 /var/log/pacman.log || true; }
first_arch_filesystem_pkg(){ [[ -r /var/log/pacman.log ]] && grep -m1 "installed filesystem" /var/log/pacman.log || true; }

# Debian/Ubuntu/Mint
first_apt_history() { command -v zgrep >/dev/null && zgrep -h "^Start-Date:" /var/log/apt/history.log* 2>/dev/null | sort | head -n1 || true; }
first_dpkg_install_time() {
  command -v zgrep >/dev/null || return 0
  # dpkg.log lines start with "YYYY-MM-DD HH:MM:SS"
  zgrep -h " install " /var/log/dpkg.log* 2>/dev/null \
    | awk '{print $1" "$2}' | sort | head -n1 || true
}

# Fedora/RHEL family
first_dnf_install_line() {
  # dnf logs often in /var/log/dnf.log, /var/log/dnf.librepo.log, etc.
  command -v zgrep >/dev/null || return 0
  zgrep -h " installed " /var/log/dnf*.log* 2>/dev/null | sort | head -n1 || true
}
first_rpm_qa_oldest() {
  command -v rpm >/dev/null || return 0
  # rpm -qa --last prints "pkg  Mon DD HH:MM:SS YYYY"; last line ~= oldest
  rpm -qa --last 2>/dev/null | tail -n1 | sed 's/^[^ ]\+  *//' || true
}

# ---------- Detect distro ----------
read_os_release() {
  [[ -r /etc/os-release ]] && . /etc/os-release
  echo "${ID:-}:${ID_LIKE:-}"
}

# ---------- MAIN ----------
printf "%sLinux installation date estimator%s\n\n" "$(bold)$(blue)" "$(norm)$(resetc)"

RSRC="$(root_src)"; FSTYPE="$(root_fstype)"
DEV="/dev/$(resolve_dev "${RSRC#/dev/}")"
printf "%sRoot mount:%s %s (%s)\n\n" "$(bold)" "$(norm)" "$RSRC" "${FSTYPE:-unknown}"

echo "$(bold)1) Filesystem creation time (closest to when installation began):$(norm)"
BIRTH="$(root_birth || true)"
EXT4_CREATED=""
[[ "${FSTYPE:-}" == "ext4" ]] && EXT4_CREATED="$(ext4_fs_created "$DEV" || true)"

if [[ -n "$EXT4_CREATED" ]]; then
  echo "ext4 superblock:"; fmt_utc_and_local "$EXT4_CREATED"
elif [[ -n "$BIRTH" ]]; then
  echo "stat / (Birth):"; fmt_utc_and_local "$BIRTH"
else
  echo "$(grey)No filesystem creation time available on this FS/kernel.$(resetc)"
fi
echo

osid_like="$(read_os_release)"

case "$osid_like" in
  arch*:*|*:arch*|arch*:*)
    echo "$(bold)2) Package manager evidence (Arch family):$(norm)"
    FPL="$(first_pacman_entry || true)"
    [[ -n "$FPL" ]] && { echo "$FPL"; TS="$(sed -n 's/^\[\(.*\)\].*/\1/p' <<<"$FPL")"; [[ -n "$TS" ]] && fmt_utc_and_local "$TS"; } \
                     || echo "$(grey)pacman.log not readable.$(resetc)"
    echo
    echo "$(bold)3) Oldest package metadata under /var/lib/pacman/local:$(norm)"
    PKG_FIRST="$(find /var/lib/pacman/local -mindepth 1 -maxdepth 1 -type d -printf '%T@ %TY-%Tm-%Td %TH:%TM:%TS %p\n' 2>/dev/null | sort -n | head -n1 | awk '{print $2" "$3}')"
    [[ -n "$PKG_FIRST" ]] && { echo "First package metadata time:"; fmt_utc_and_local "$PKG_FIRST"; } \
                           || echo "$(grey)No data found.$(resetc)"
    echo
    FS_LINE="$(first_arch_filesystem_pkg || true)"
    [[ -n "$FS_LINE" ]] && { echo "$(bold)4) 'filesystem' package install (confirmation):$(norm)"; echo "$FS_LINE"; TS2="$(sed -n 's/^\[\(.*\)\].*/\1/p' <<<"$FS_LINE")"; [[ -n "$TS2" ]] && fmt_utc_and_local "$TS2"; echo; }
    ;;
  *debian*|*ubuntu*|*linuxmint*|*elementary*)
    echo "$(bold)2) Package manager evidence (Debian/Ubuntu/Mint family):$(norm)"
    H1="$(first_apt_history || true)"; D1="$(first_dpkg_install_time || true)"
    if [[ -n "$H1" ]]; then
      echo "$H1"
      # line format: Start-Date: 2025-07-06 15:52:09
      TS="$(sed -n 's/^Start-Date:[[:space:]]*//p' <<<"$H1")"; [[ -n "$TS" ]] && fmt_utc_and_local "$TS"
    fi
    if [[ -n "$D1" ]]; then
      echo "First dpkg install timestamp: $D1"
      fmt_utc_and_local "$D1"
    fi
    [[ -z "$H1$D1" ]] && echo "$(grey)Couldn’t read apt/dpkg history (rotated logs missing?).$(resetc)"
    echo
    # Bonus: installer logs if present
    if [[ -r /var/log/installer/syslog ]]; then
      FIRST_IL="$(head -n1 /var/log/installer/syslog)"
      echo "$(bold)3) /var/log/installer/syslog first line (if present):$(norm)"
      echo "$FIRST_IL"
      # Often starts with "Jul  6 18:51:59" — not always ISO; leave as-is.
      echo
    fi
    ;;
  *rhel*|*fedora*|*centos*|*rocky*|*alma*)
    echo "$(bold)2) Package manager evidence (Fedora/RHEL family):$(norm)"
    DNF1="$(first_dnf_install_line || true)"; RPM1="$(first_rpm_qa_oldest || true)"
    if [[ -n "$DNF1" ]]; then
      echo "$DNF1"
      # dnf lines usually begin with ISO8601; try to pull the timestamp prefix
      TS="$(sed -n 's/^\([0-9-:T+]\{10,25\}\).*/\1/p' <<<"$DNF1")"; [[ -n "$TS" ]] && fmt_utc_and_local "$TS"
    fi
    if [[ -n "$RPM1" ]]; then
      echo "Oldest rpm entry (from \`rpm -qa --last\`): $RPM1"
      fmt_utc_and_local "$RPM1" || true
    fi
    [[ -z "$DNF1$RPM1" ]] && echo "$(grey)Couldn’t read dnf/rpm history.$(resetc)"
    echo
    ;;
  *)
    echo "$(bold)2) Package manager evidence:$(norm)"
    echo "$(grey)Unknown distro family (ID/ID_LIKE not matched). Falling back to filesystem time only.$(resetc)"
    echo
    ;;
esac

printf "%sResult:%s Use the earliest package-manager timestamp (section 2) cross-checked with (1).\n" "$(bold)$(green)" "$(norm)$(resetc)"
