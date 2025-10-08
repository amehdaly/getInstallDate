#!/usr/bin/env bash
# arch-install-date.sh
# Show estimated Arch Linux installation date from multiple sources.

set -euo pipefail

bold()  { tput bold 2>/dev/null || true; }
norm()  { tput sgr0 2>/dev/null || true; }
green() { tput setaf 2 2>/dev/null || true; }
blue()  { tput setaf 4 2>/dev/null || true; }
grey()  { tput setaf 8 2>/dev/null || true; }
resetc(){ tput sgr0 2>/dev/null || true; }

fmt_utc_and_local() {
  local raw="$1"
  local iso="$raw"
  local utc locald
  utc="$(date -u -d "$iso" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$raw")"
  locald="$(date -d "$iso"  '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$raw")"
  printf "%s\n      %s\n" "UTC:    $utc" "Local:  $locald"
}

root_src() {
  if command -v findmnt >/dev/null 2>&1; then
    findmnt -no SOURCE /
  else
    df / | awk 'NR==2{print $1}'
  fi
}

root_fstype() {
  if command -v findmnt >/dev/null 2>&1; then
    findmnt -no FSTYPE /
  else
    lsblk -no FSTYPE "$(root_src 2>/dev/null)" 2>/dev/null
  fi
}

first_pacman_entry() {
  [[ -r /var/log/pacman.log ]] && head -n 1 /var/log/pacman.log || true
}

first_filesystem_pkg() {
  [[ -r /var/log/pacman.log ]] && grep -m1 "installed filesystem" /var/log/pacman.log || true
}

first_pkg_dir_time() {
  [[ -d /var/lib/pacman/local ]] || return 0
  find /var/lib/pacman/local -mindepth 1 -maxdepth 1 -type d -printf '%T@ %TY-%Tm-%Td %TH:%TM:%TS %p\n' \
    | sort -n | head -n 1 | awk '{print $2" "$3}' || true
}

root_birth() {
  # handle any spacing before/after "Birth:" and strip fractional seconds
  stat / 2>/dev/null \
    | sed -n 's/.*Birth:[[:space:]]*//p' \
    | sed 's/\.[0-9]\+//; s/[[:space:]]\{2,\}/ /g' \
    || true
}

run_tune2fs() {
  # try sudo non-interactively; fall back to plain; never fail the script
  local dev="$1"
  if command -v tune2fs >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo tune2fs -l "$dev" 2>/dev/null || true
    else
      tune2fs -l "$dev" 2>/dev/null || true
    fi
  fi
}

ext4_fs_created() {
  local dev="$1"
  run_tune2fs "$dev" | awk -F'Filesystem created: *' '/Filesystem created:/ {print $2}' || true
}

resolve_device_if_uuid() {
  local src="$1"
  if [[ "$src" =~ ^UUID= ]]; then
    local uuid="${src#UUID=}"
    blkid -U "$uuid" 2>/dev/null || echo "$src"
  else
    echo "$src"
  fi
}

printf "%sArch Linux installation date estimator%s\n" "$(bold)$(blue)" "$(norm)$(resetc)"
echo

RSRC="$(root_src)"
FSTYPE="$(root_fstype)"
DEV="$(resolve_device_if_uuid "${RSRC#/dev/}")"
DEV="/dev/$DEV"

printf "%sRoot mount:%s %s (%s)\n" "$(bold)" "$(norm)" "$RSRC" "${FSTYPE:-unknown}"
echo

echo "$(bold)1) Filesystem creation time (closest to when installation began):$(norm)"
BIRTH="$(root_birth || true)"
EXT4_CREATED=""
if [[ "${FSTYPE:-}" == "ext4" ]]; then
  EXT4_CREATED="$(ext4_fs_created "$DEV" || true)"
fi

if [[ -n "$EXT4_CREATED" ]]; then
  echo "ext4 superblock:"
  fmt_utc_and_local "$EXT4_CREATED"
elif [[ -n "$BIRTH" ]]; then
  echo "stat / (Birth):"
  fmt_utc_and_local "$BIRTH"
else
  echo "$(grey)No filesystem creation time found. Try: sudo tune2fs -l $RSRC | grep 'Filesystem created'.$(resetc)"
fi
echo

echo "$(bold)2) First pacman log entry (bootstrap time):$(norm)"
FPL="$(first_pacman_entry || true)"
if [[ -n "$FPL" ]]; then
  echo "$FPL"
  TS="$(sed -n 's/^\[\(.*\)\].*/\1/p' <<<"$FPL")"
  [[ -n "$TS" ]] && fmt_utc_and_local "$TS"
else
  echo "$(grey)/var/log/pacman.log not found or unreadable.$(resetc)"
fi
echo

echo "$(bold)3) Oldest package metadata under /var/lib/pacman/local:$(norm)"
PKG_FIRST="$(first_pkg_dir_time || true)"
if [[ -n "$PKG_FIRST" ]]; then
  echo "First package metadata time:"
  fmt_utc_and_local "$PKG_FIRST"
else
  echo "$(grey)No data found (unexpected).$(resetc)"
fi
echo

echo "$(bold)4) First 'filesystem' package install (confirmation):$(norm)"
FS_LINE="$(first_filesystem_pkg || true)"
if [[ -n "$FS_LINE" ]]; then
  echo "$FS_LINE"
  TS2="$(sed -n 's/^\[\(.*\)\].*/\1/p' <<<"$FS_LINE")"
  [[ -n "$TS2" ]] && fmt_utc_and_local "$TS2"
else
  echo "$(grey)Couldn’t find 'installed filesystem' in pacman.log (still OK).$(resetc)"
fi
echo

printf "%sResult:%s These timestamps should cluster within minutes.\n" "$(bold)$(green)" "$(norm)$(resetc)"
echo "Use the pacman bootstrap time (2) as the canonical 'install date', cross-checked by (1) and (3)."
