#!/usr/bin/env bash
#
# NeuroMed-AI updater - always overwrite to the latest linebot branch.
# Source clone is staged under /tmp and removed on exit / interrupt.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/neurowatt-dev/NeuroMed-AI/linebot/static/scripts/update.sh \
#     -o /tmp/neuromed-update.sh && bash /tmp/neuromed-update.sh; rm -f /tmp/neuromed-update.sh
#   agen update
#
set -euo pipefail

REPO_URL="https://github.com/neurowatt-dev/NeuroMed-AI.git"
BRANCH="linebot"
GO_INSTALL_DIR="${HOME}/.local/go"
REQUIRED_GO_MAJOR=1
REQUIRED_GO_MINOR=26

if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_RST=''
fi

log()  { printf "%s==>%s %s\n" "$C_BLU" "$C_RST" "$*"; }
ok()   { printf "%s ok%s %s\n" "$C_GRN" "$C_RST" "$*"; }
warn() { printf "%s !!%s %s\n" "$C_YLW" "$C_RST" "$*"; }
die()  { printf "%s xx%s %s\n" "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# A controlling terminal exists and is usable for prompting, even when stdin is
# a pipe (the `curl … | bash` case).
have_tty() {
  [ -e /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

is_admin_user() {
  case "$(uname -s)" in
    Darwin) id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin ;;
    *)      id -Gn 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin' ;;
  esac
}

# "no sudo" collapses three distinct failures into one message. Report which
# one actually applies so the user can act on it.
sudo_unavailable_reason() {
  if ! command -v sudo >/dev/null 2>&1; then
    printf '%s' "sudo is not installed. Run this updater as root, or install sudo first."
    return 0
  fi
  if ! is_admin_user; then
    printf '%s' "User '$(whoami)' is not in the admin group, so root access cannot be obtained. Re-run as an administrator account."
    return 0
  fi
  printf '%s' "No terminal is available to prompt for your sudo password, and the sudo timestamp is cold. This is NOT a permissions problem — '$(whoami)' is an administrator. Run 'sudo -v' first in this same terminal, then re-run."
}

print_done() {
  local tag="$1"
  local lines=(
    "NeuroMed-AI ${tag} installed"
    ""
    "Starting agen in 2s..."
  )

  local max=0 line len
  for line in "${lines[@]}"; do
    len=${#line}
    [ "$len" -gt "$max" ] && max=$len
  done

  local pad_each=2
  local inner=$((max + pad_each * 2))

  local border="" rpad=""
  local i=0
  while [ $i -lt $inner ]; do
    border="${border}─"
    i=$((i + 1))
  done

  printf '\n%s╭%s╮%s\n' "$C_GRN" "$border" "$C_RST"
  for line in "${lines[@]}"; do
    rpad=""
    i=0
    while [ $i -lt $((max - ${#line})) ]; do
      rpad="${rpad} "
      i=$((i + 1))
    done
    printf '%s│%s  %s%s  %s│%s\n' "$C_GRN" "$C_RST" "$line" "$rpad" "$C_GRN" "$C_RST"
  done
  printf '%s╰%s╯%s\n\n' "$C_GRN" "$border" "$C_RST"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1${2:+ ($2)}"
}

detect_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux  ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
  printf "%s-%s" "$os" "$arch"
}

# returns 0 if "$1" (e.g. 1.26.0) >= REQUIRED
go_version_ok() {
  local v="$1"
  local major minor
  major="${v%%.*}"; v="${v#*.}"; minor="${v%%.*}"
  case "$minor" in *[!0-9]*) minor="${minor%%[!0-9]*}" ;; esac
  [ -n "$major" ] && [ -n "$minor" ] || return 1
  if [ "$major" -gt "$REQUIRED_GO_MAJOR" ]; then return 0; fi
  if [ "$major" -eq "$REQUIRED_GO_MAJOR" ] && [ "$minor" -ge "$REQUIRED_GO_MINOR" ]; then return 0; fi
  return 1
}

current_go_version() {
  command -v go >/dev/null 2>&1 || return 1
  go version 2>/dev/null | awk '{print $3}' | sed 's/^go//'
}

persist_go_path() {
  local rc="" os
  os="$(uname -s)"
  case "${SHELL##*/}" in
    zsh)  rc="${HOME}/.zshrc" ;;
    bash) [ "$os" = "Darwin" ] && rc="${HOME}/.bash_profile" || rc="${HOME}/.bashrc" ;;
    *)    rc="${HOME}/.profile" ;;
  esac

  local marker_begin="# >>> agenvoy go path >>>"
  local marker_end="# <<< agenvoy go path <<<"
  local export_line="export PATH=\"${GO_INSTALL_DIR}/bin:\$PATH\""

  if [ -f "$rc" ] && grep -Fq "$marker_begin" "$rc"; then
    return 0
  fi

  mkdir -p "$(dirname "$rc")"
  {
    printf '\n%s\n' "$marker_begin"
    printf '%s\n' "$export_line"
    printf '%s\n' "$marker_end"
  } >> "$rc"
  ok "Persisted Go PATH to $rc"
  warn "Open a new shell or run: source $rc"
}

# go-sqlite3 is a cgo binding, and Go silently sets CGO_ENABLED=0 when no C
# compiler is on PATH: the rebuild then succeeds and lands a stub driver that
# fails only at the first OpenDB. Installed rather than merely required, the
# same way this script already installs the go-rod dependencies below.
ensure_toolchain() {
  command -v cc >/dev/null 2>&1 && return 0

  if [ "$(uname -s)" = "Darwin" ]; then
    die "No C compiler found. Run 'xcode-select --install' then re-run this updater."
  fi

  local sudo=""
  [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo="sudo"

  log "No C compiler found; installing one (go-sqlite3 requires cgo)"
  if command -v apt-get >/dev/null 2>&1; then
    $sudo apt-get update -y || warn "apt-get update failed, continuing"
    $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential
  elif command -v dnf >/dev/null 2>&1; then
    $sudo dnf install -y gcc
  elif command -v yum >/dev/null 2>&1; then
    $sudo yum install -y gcc
  elif command -v pacman >/dev/null 2>&1; then
    $sudo pacman -Sy --noconfirm base-devel
  elif command -v apk >/dev/null 2>&1; then
    $sudo apk add --no-cache build-base
  else
    die "No C compiler and no supported package manager. Install gcc manually, then re-run."
  fi

  command -v cc >/dev/null 2>&1 || die "C compiler still missing after install"
  ok "C compiler ready"
}

# An explicit CGO_ENABLED=0 in the caller's environment survives into `make
# build`: go-sqlite3 then compiles as static_mock.go, the build exits 0, and the
# stub only errors at the first OpenDB. Refuse instead of shipping that binary.
ensure_cgo_enabled() {
  case "${CGO_ENABLED:-}" in
    0)
      die "CGO_ENABLED=0 is set in this environment; go-sqlite3 would build as a
     non-functional stub. Run 'unset CGO_ENABLED' (or export CGO_ENABLED=1)
     and re-run this updater."
      ;;
  esac
}

# go-rod launches ~/.cache/rod/browser/.../chrome directly (not apt's chromium
# package), so apt won't pull its shared-lib deps automatically. libasound2 is
# the one rod's chromium needs that a bare Debian/Ubuntu host lacks; minimal
# WSL images additionally ship no CJK fonts, so Chinese renders as tofu boxes.
ensure_chrome_deps() {
  command -v apt-get >/dev/null 2>&1 || return 0
  local sudo=""
  [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo="sudo"

  log "Ensuring libasound2 for go-rod (apt)"
  $sudo apt-get update -y || warn "apt-get update failed, continuing"
  if $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y libasound2 2>/dev/null; then
    ok "libasound2 installed"
  else
    # Newer Ubuntu (24.04+) renamed libasound2 -> libasound2t64; retry with that name.
    warn "libasound2 install failed, retrying with libasound2t64 (newer Ubuntu package name)"
    if $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y libasound2t64; then
      ok "libasound2t64 installed"
    else
      warn "Failed to install libasound2/libasound2t64; go-rod browser automation may not launch"
    fi
  fi

  log "Ensuring CJK fonts for go-rod (apt)"
  if $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y fonts-noto-cjk; then
    ok "fonts-noto-cjk installed"
  else
    warn "Failed to install fonts-noto-cjk; Chinese/Japanese/Korean text may render as tofu boxes"
  fi
}

# go.dev/dl/<file>.sha256 answers 200 with an HTML redirect page, not a
# checksum; the real sidecar is served from dl.google.com.
verify_go_checksum() {
  local dir="$1" tarball="$2"
  local expect actual

  expect="$(curl -fsSL --retry 3 --retry-delay 2 "https://dl.google.com/go/${tarball}.sha256" 2>/dev/null | tr -d '[:space:]')"
  if ! printf '%s' "$expect" | grep -qE '^[0-9a-f]{64}$'; then
    warn "No sha256 published for ${tarball}; skipping integrity check"
    return 0
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${dir}/${tarball}" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "${dir}/${tarball}" | awk '{print $1}')"
  else
    warn "Neither sha256sum nor shasum available; skipping integrity check"
    return 0
  fi

  [ "$actual" = "$expect" ] || die "Checksum mismatch for ${tarball}; refusing to install Go."
  ok "Checksum verified"
}

GO_TMP_DIR=""
install_go() {
  local platform="$1"
  local version url tarball
  log "Resolving latest Go release..."
  version="$(curl -fsSL --retry 3 --retry-delay 2 'https://go.dev/VERSION?m=text' | head -n 1)" \
    || die "Failed to reach go.dev to resolve the latest Go release. Check network access, then re-run."
  case "$version" in go*) ;; *) die "Unexpected Go version response: $version" ;; esac

  tarball="${version}.${platform}.tar.gz"
  url="https://go.dev/dl/${tarball}"
  GO_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agenvoy-go.XXXXXX")"

  log "Downloading $url"
  curl -fSL --retry 3 --retry-delay 2 --progress-bar "$url" -o "${GO_TMP_DIR}/${tarball}" \
    || die "Download failed: $tarball"
  verify_go_checksum "$GO_TMP_DIR" "$tarball"

  log "Installing to ${GO_INSTALL_DIR}"
  rm -rf "$GO_INSTALL_DIR"
  mkdir -p "$(dirname "$GO_INSTALL_DIR")"
  tar -C "$(dirname "$GO_INSTALL_DIR")" -xzf "${GO_TMP_DIR}/${tarball}"

  export PATH="${GO_INSTALL_DIR}/bin:${PATH}"
  ok "Installed $(go version 2>/dev/null || echo "$version")"
  persist_go_path
}

ensure_go() {
  local platform; platform="$(detect_platform)"
  local current

  # Probe canonical install dir if go isn't on PATH (install.sh writes here
  # but the caller's shell rc may not have been sourced in this subprocess).
  if ! command -v go >/dev/null 2>&1 && [ -x "${GO_INSTALL_DIR}/bin/go" ]; then
    export PATH="${GO_INSTALL_DIR}/bin:${PATH}"
  fi

  if current="$(current_go_version)" && [ -n "$current" ]; then
    if go_version_ok "$current"; then
      ok "Go $current already meets >= ${REQUIRED_GO_MAJOR}.${REQUIRED_GO_MINOR}"
      if [ "$(command -v go)" = "${GO_INSTALL_DIR}/bin/go" ]; then
        persist_go_path
      fi
      return 0
    fi
    warn "Go $current < ${REQUIRED_GO_MAJOR}.${REQUIRED_GO_MINOR}, upgrading"
  else
    warn "Go not found, bootstrapping"
  fi
  install_go "$platform"
}

SRC_DIR=""
SWAP_FILE=""
LOW_MEM=0
SUDO_KEEPALIVE_PID=""

stop_sudo_keepalive() {
  if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi
}

# Keep sudo timestamp warm during long builds (so swap + install don't re-prompt).
start_sudo_keepalive() {
  command -v sudo >/dev/null 2>&1 || return 0
  sudo -n true 2>/dev/null || return 0
  (
    while true; do
      sudo -n true 2>/dev/null || exit 0
      sleep 30
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
}

cleanup() {
  stop_sudo_keepalive 2>/dev/null || true
  if [ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ]; then
    rm -rf "$SRC_DIR"
  fi
  if [ -n "$GO_TMP_DIR" ] && [ -d "$GO_TMP_DIR" ]; then
    rm -rf "$GO_TMP_DIR"
  fi
  if [ -n "$SWAP_FILE" ] && [ -f "$SWAP_FILE" ]; then
    if [ "$(id -u)" -eq 0 ]; then
      swapoff "$SWAP_FILE" 2>/dev/null || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo swapoff "$SWAP_FILE" 2>/dev/null || true
    fi
    rm -f "$SWAP_FILE" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Acquire root for temporary swap + later /usr/local/bin install.
# Works under `curl | bash` by prompting on /dev/tty when needed.
ensure_sudo() {
  [ "$(id -u)" -eq 0 ] && return 0
  command -v sudo >/dev/null 2>&1 || return 1
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  if have_tty; then
    warn "Need sudo for temporary swap (and /usr/local/bin install)"
    # -v refreshes timestamp; talk to the real terminal even if stdin is a pipe
    if sudo -v </dev/tty >/dev/tty 2>/dev/tty; then
      return 0
    fi
  fi
  return 1
}

path_fstype() {
  # df -T: Filesystem Type Available ... ; portable enough on Linux
  local dir="$1"
  df -T "$dir" 2>/dev/null | awk 'NR==2 { print $2 }'
}

path_avail_kb() {
  local dir="$1"
  df -Pk "$dir" 2>/dev/null | awk 'NR==2 { print $4 }'
}

print_host_status() {
  [ "$(uname -s)" = "Linux" ] || return 0
  log "Host memory / disk (low-RAM build prep)"
  if command -v free >/dev/null 2>&1; then
    free -h 2>/dev/null || true
  elif [ -r /proc/meminfo ]; then
    awk '/MemTotal:|MemAvailable:|SwapTotal:|SwapFree:/ {printf "  %s %s %s\n", $1, $2, $3}' /proc/meminfo 2>/dev/null || true
  fi
  if command -v swapon >/dev/null 2>&1; then
    swapon --show 2>/dev/null || true
  fi
  df -h / 2>/dev/null || true
}

# Low-RAM hosts (e.g. free-tier VMs) OOM-kill go compile with:
#   .../compile: signal: killed
# Cap package parallelism, create temporary swap, and pre-build heavy packages
# one-by-one so a single large compile does not peak with others.
ensure_build_swap() {
  [ "$(uname -s)" = "Linux" ] || return 0
  [ -r /proc/meminfo ] || return 0

  local swap_kb
  swap_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
  # Already have >= 1 GiB swap — nothing to do.
  if [ -n "$swap_kb" ] && [ "$swap_kb" -ge 1048576 ] 2>/dev/null; then
    ok "Existing swap: ${swap_kb} kB"
    return 0
  fi

  # Prefer classic /swapfile on the root disk first, then $HOME, then /var/tmp.
  # Never use tmpfs/ramfs (swap on RAM makes OOM worse).
  # Try smaller sizes if free disk is tight (2G → 1G; 3G is often too large for free VMs).
  local sizes_mb=(2048 1024)
  local candidates=(
    "/swapfile"
    "$HOME/neuromed-build.swap"
    "/var/tmp/neuromed-build.swap"
  )
  local size_mb need_kb path dir fstype avail last_err=""

  if ! ensure_sudo; then
    warn "Cannot create temporary swap automatically: $(sudo_unavailable_reason)"
    # Interactive: walk the user through the exact steps on this host.
    if have_tty; then
      warn "Interactive swap setup required (passwordless sudo missing)."
      printf "\n" >/dev/tty
      printf "Run these on this host (another terminal is fine), then press Enter here:\n" >/dev/tty
      printf "  sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress\n" >/dev/tty
      printf "  sudo chmod 600 /swapfile\n" >/dev/tty
      printf "  sudo mkswap /swapfile\n" >/dev/tty
      printf "  sudo swapon /swapfile\n" >/dev/tty
      printf "  free -h\n" >/dev/tty
      printf "\nPress Enter after swap is active (or Ctrl-C to abort)... " >/dev/tty
      IFS= read -r _ </dev/tty || true
      swap_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
      if [ -n "$swap_kb" ] && [ "$swap_kb" -ge 524288 ] 2>/dev/null; then
        ok "Detected swap after manual setup: ${swap_kb} kB"
        return 0
      fi
    fi
    warn "Still no usable swap."
    return 1
  fi
  start_sudo_keepalive

  # Helper: create + activate one swap file. Echoes reason on failure via last_err.
  try_one_swap() {
    path="$1"
    size_mb="$2"
    dir="$(dirname "$path")"
    last_err=""

    if [ ! -d "$dir" ]; then
      if ! mkdir -p "$dir" 2>/dev/null && ! sudo mkdir -p "$dir" 2>/dev/null; then
        last_err="$path: cannot create dir $dir"
        return 1
      fi
    fi

    fstype="$(path_fstype "$dir")"
    case "$fstype" in
      tmpfs|ramfs|devtmpfs)
        last_err="$path: filesystem is $fstype (RAM-backed; skipped)"
        return 1
        ;;
    esac

    avail="$(path_avail_kb "$dir")"
    need_kb=$((size_mb * 1024 + 102400))
    if [ -z "$avail" ]; then
      last_err="$path: cannot measure free space on $dir"
      return 1
    fi
    if [ "$avail" -lt "$need_kb" ] 2>/dev/null; then
      last_err="$path: need ~${size_mb}MiB free, only ${avail} kB available on $dir"
      return 1
    fi

    # Remove any leftover file first.
    sudo rm -f "$path" 2>/dev/null || rm -f "$path" 2>/dev/null || true

    # btrfs: disable CoW before allocating (swapfiles cannot live on CoW extents).
    if [ "$fstype" = "btrfs" ]; then
      if ! sudo touch "$path" 2>/dev/null; then
        last_err="$path: touch failed (btrfs)"
        return 1
      fi
      sudo chattr +C "$path" 2>/dev/null || true
    fi

    # Prefer fully-written file (dd) on low-mem hosts — fallocate can leave
    # holes that swapon rejects on some filesystems.
    local allocated=0
    if [ "${LOW_MEM:-0}" -eq 1 ] 2>/dev/null; then
      log "Allocating ${size_mb} MiB swap at $path (dd; may take a minute)"
      if sudo dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=progress 2>/dev/tty \
        || sudo dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=none 2>/dev/null \
        || dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=none 2>/dev/null; then
        allocated=1
      fi
    fi
    if [ "$allocated" -eq 0 ] && command -v fallocate >/dev/null 2>&1; then
      if sudo fallocate -l "${size_mb}M" "$path" 2>/dev/null || fallocate -l "${size_mb}M" "$path" 2>/dev/null; then
        allocated=1
      fi
    fi
    if [ "$allocated" -eq 0 ]; then
      log "Allocating ${size_mb} MiB swap at $path (dd)"
      if sudo dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=none 2>/dev/null \
        || dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=none 2>/dev/null; then
        allocated=1
      fi
    fi
    if [ "$allocated" -eq 0 ]; then
      last_err="$path: fallocate/dd failed for ${size_mb}MiB"
      sudo rm -f "$path" 2>/dev/null || rm -f "$path" 2>/dev/null || true
      return 1
    fi

    if ! sudo chmod 600 "$path" 2>/dev/null && ! chmod 600 "$path" 2>/dev/null; then
      last_err="$path: chmod 600 failed"
      sudo rm -f "$path" 2>/dev/null || rm -f "$path" 2>/dev/null || true
      return 1
    fi

    local mkswap_out
    if ! mkswap_out="$(sudo mkswap "$path" 2>&1)"; then
      if ! mkswap_out="$(mkswap "$path" 2>&1)"; then
        last_err="$path: mkswap failed: $mkswap_out"
        sudo rm -f "$path" 2>/dev/null || rm -f "$path" 2>/dev/null || true
        return 1
      fi
    fi

    local swapon_out
    if swapon_out="$(sudo swapon "$path" 2>&1)"; then
      SWAP_FILE="$path"
      warn "Created temporary ${size_mb} MiB swap at $path (removed after update)"
      return 0
    fi
    # fallocate sparse / CoW / missing CAP_SYS_ADMIN often land here
    last_err="$path: swapon failed: ${swapon_out:-unknown (no CAP_SYS_ADMIN / CoW fs / sparse file?)}"

    # Retry once with dd if we used fallocate (fills holes).
    if command -v fallocate >/dev/null 2>&1; then
      sudo swapoff "$path" 2>/dev/null || true
      sudo rm -f "$path" 2>/dev/null || rm -f "$path" 2>/dev/null || true
      if [ "$fstype" = "btrfs" ]; then
        sudo touch "$path" 2>/dev/null || true
        sudo chattr +C "$path" 2>/dev/null || true
      fi
      log "Retrying ${size_mb} MiB swap at $path with full dd write"
      if sudo dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=none 2>/dev/null \
        || dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=none 2>/dev/null; then
        sudo chmod 600 "$path" 2>/dev/null || chmod 600 "$path" 2>/dev/null || true
        sudo mkswap "$path" >/dev/null 2>&1 || mkswap "$path" >/dev/null 2>&1 || true
        if swapon_out="$(sudo swapon "$path" 2>&1)"; then
          SWAP_FILE="$path"
          warn "Created temporary ${size_mb} MiB swap at $path via dd (removed after update)"
          return 0
        fi
        last_err="$path: swapon failed after dd: ${swapon_out:-unknown}"
      fi
    fi
    sudo rm -f "$path" 2>/dev/null || rm -f "$path" 2>/dev/null || true
    return 1
  }

  local c
  for size_mb in "${sizes_mb[@]}"; do
    for c in "${candidates[@]}"; do
      if try_one_swap "$c" "$size_mb"; then
        return 0
      fi
      [ -n "$last_err" ] && warn "swap attempt: $last_err"
    done
  done

  # Auto path failed — offer interactive manual walkthrough before dying.
  warn "Could not create temporary swap automatically."
  if have_tty; then
    printf "\n" >/dev/tty
    printf "Automatic swap setup failed. Create swap manually, then press Enter:\n" >/dev/tty
    printf "  sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress\n" >/dev/tty
    printf "  sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile\n" >/dev/tty
    printf "  free -h\n" >/dev/tty
    printf "\nPress Enter after swap is active (or Ctrl-C to abort)... " >/dev/tty
    IFS= read -r _ </dev/tty || true
    swap_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
    if [ -n "$swap_kb" ] && [ "$swap_kb" -ge 524288 ] 2>/dev/null; then
      ok "Detected swap after manual setup: ${swap_kb} kB"
      return 0
    fi
  fi

  warn "Still no usable swap. Build would OOM on large packages (e.g. ugorji/go/codec)."
  return 1
}

# Apply low-memory compile env (also used by staged prebuild).
# Do NOT force CGO_ENABLED=0 — makefile / mattn/go-sqlite3 + fts5 need cgo.
apply_low_mem_env() {
  export GOMAXPROCS=1
  # -p=1 caps concurrent package compiles; do not append -tags here
  # (makefile owns build tags for the final binary).
  export GOFLAGS="-p=1"
  export GOGC="${GOGC:-25}"
  export GOMEMLIMIT="${GOMEMLIMIT:-1000MiB}"
}

configure_build_env() {
  local mem_kb=""
  if [ -r /proc/meminfo ]; then
    mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
  fi

  # Default: leave host alone. Only throttle when we can measure low RAM.
  # Threshold 5 GiB: ~4 GiB free-tier boxes still OOM on large packages.
  if [ -n "$mem_kb" ] && [ "$mem_kb" -lt 5242880 ] 2>/dev/null; then
    LOW_MEM=1
    warn "Low memory detected (${mem_kb} kB < 5 GiB)"
    print_host_status
    apply_low_mem_env
    log "Step 1/3: ensure swap (auto, else interactive instructions on this host)"
    if ! ensure_build_swap; then
      die "Low-memory host has no usable swap. Add >=1-2 GiB swap, then re-run. Refusing to build (would OOM)."
    fi
    print_host_status
  fi
}

# Pure-Go heavy packages that peak high during compile. Built one-by-one first
# so the final `make build` mostly reuses the build cache.
# Order: most painful first. (Skip cgo packages — those belong to make build.)
HEAVY_PKGS=(
  "github.com/ugorji/go/codec"
  "github.com/bytedance/sonic"
  "github.com/quic-go/quic-go"
  "golang.org/x/net"
  "golang.org/x/sys"
  "github.com/gin-gonic/gin"
  "github.com/go-rod/rod"
  "github.com/cloudwego/base64x"
)

staged_prebuild() {
  [ "${LOW_MEM:-0}" -eq 1 ] || return 0
  [ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] || return 0

  log "Step 2/3: staged prebuild (one heavy package at a time)"
  apply_low_mem_env

  (
    cd "$SRC_DIR" || exit 1
    export GOMAXPROCS=1
    export GOFLAGS="-p=1"
    export GOGC="${GOGC:-25}"
    export GOMEMLIMIT="${GOMEMLIMIT:-1000MiB}"

    log "  2a) go mod download"
    go mod download || warn "go mod download failed; continuing"

    log "  2b) pre-build heavy packages one-by-one"
    local p i=0 n=${#HEAVY_PKGS[@]}
    for p in "${HEAVY_PKGS[@]}"; do
      i=$((i + 1))
      # Skip packages not in this module graph (older/newer branch state).
      if ! go list -f '{{.ImportPath}}' "$p" >/dev/null 2>&1; then
        log "  [${i}/${n}] skip $p (not in module graph)"
        continue
      fi
      log "  [${i}/${n}] go build -p=1 $p"
      local memlimit="${GOMEMLIMIT:-1000MiB}"
      if [ "$p" = "github.com/ugorji/go/codec" ]; then
        memlimit="800MiB"
      fi
      if GOMEMLIMIT="$memlimit" go build -p=1 "$p"; then
        ok "  cached: $p"
      else
        warn "  pre-compile failed for $p (will retry in make build)"
      fi
      # Let kernel reclaim compiler RSS / page cache before next peak.
      sleep 1
    done
  )
}

# `command -v agen` succeeding proves nothing: a stale copy earlier on PATH
# (~/.local/bin, brew) answers the same way and the user keeps running the old
# binary while the updater reports success.
verify_path_resolution() {
  hash -r 2>/dev/null || true
  local resolved
  resolved="$(command -v agen 2>/dev/null || true)"
  if [ -z "$resolved" ]; then
    warn "/usr/local/bin is not on PATH; run /usr/local/bin/agen directly or add it to PATH"
  elif [ "$resolved" != "/usr/local/bin/agen" ]; then
    warn "Another agen shadows the new install: $resolved (new binary is at /usr/local/bin/agen)"
  fi
}

run_make_build() {
  (
    cd "$SRC_DIR" || exit 1
    export GOMAXPROCS="${GOMAXPROCS:-1}"
    export GOFLAGS="${GOFLAGS:--p=1}"
    export GOGC="${GOGC:-25}"
    export GOMEMLIMIT="${GOMEMLIMIT:-1000MiB}"
    make build
  )
}

main() {
  log "NeuroMed-AI updater (linebot branch)"

  require_cmd curl
  require_cmd git
  require_cmd make
  require_cmd tar
  ensure_cgo_enabled
  ensure_toolchain
  ensure_chrome_deps
  ensure_go

  SRC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/neuromed-update.XXXXXX")"
  log "Cloning ${BRANCH} branch -> ${SRC_DIR}"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"

  local rev
  rev="$(cd "$SRC_DIR" && git rev-parse --short HEAD)"
  log "HEAD: ${rev}"

  configure_build_env
  staged_prebuild

  log "Step 3/3: Building (sudo prompt expected for /usr/local/bin install)"
  local build_log
  build_log="$(mktemp "${TMPDIR:-/tmp}/neuromed-build.XXXXXX")"
  set +e
  run_make_build >"$build_log" 2>&1
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    cat "$build_log" >&2
    # Retry once: re-assert single-package + try swap if missing, then staged rebuild.
    if grep -qE 'signal: killed|cannot allocate memory|out of memory' "$build_log"; then
      warn "Build OOM-killed; re-staging heavy packages then retry once"
      LOW_MEM=1
      apply_low_mem_env
      export GOMEMLIMIT=800MiB
      print_host_status
      ensure_build_swap || true
      staged_prebuild || true
      if ! run_make_build; then
        rm -f "$build_log"
        die "Build failed after low-memory retry. Free RAM, ensure >=1-2 GiB swap, or use a larger VM."
      fi
    else
      rm -f "$build_log"
      die "Build failed (see output above)"
    fi
  else
    # Surface successful build output for transparency
    cat "$build_log"
  fi
  rm -f "$build_log"

  [ -x /usr/local/bin/agen ] || die "Build reported success but /usr/local/bin/agen is missing"
  verify_path_resolution
  ok "Updated to ${BRANCH}@${rev} at /usr/local/bin/agen"

  log "Stopping old daemon (if any) so the new binary takes effect"
  /usr/local/bin/agen stop || true

  print_done "${BRANCH}@${rev}"

  cleanup
  trap - EXIT INT TERM

  sleep 2
  exec /usr/local/bin/agen
}

main "$@"
