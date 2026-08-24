#!/usr/bin/env bash
#
# NeuroMed-AI installer - builds the latest linebot branch HEAD.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/neurowatt-dev/NeuroMed-AI/linebot/static/scripts/install.sh | bash
#
set -euo pipefail

REPO_URL="https://github.com/neurowatt-dev/NeuroMed-AI.git"
BRANCH="linebot"
INSTALL_URL="https://raw.githubusercontent.com/neurowatt-dev/NeuroMed-AI/linebot/static/scripts/install.sh"
GO_INSTALL_DIR="${HOME}/.local/go"
REQUIRED_GO_MAJOR=1
REQUIRED_GO_MINOR=26

PKG_MGR=""
SUDO=""

SRC_DIR=""
GO_TMP_DIR=""
INSTALLED_REV=""
SWAP_FILE=""
LOW_MEM=0
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

if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_RST=''
fi

log()  { printf "%s==>%s %s\n" "$C_BLU" "$C_RST" "$*"; }
ok()   { printf "%s ok%s %s\n"  "$C_GRN" "$C_RST" "$*"; }
warn() { printf "%s !!%s %s\n"  "$C_YLW" "$C_RST" "$*"; }
die()  { printf "%s xx%s %s\n"  "$C_RED" "$C_RST" "$*" >&2; exit 1; }

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

# Homebrew collapses three distinct failures into "needs to be an Administrator".
# Report which one actually applies so the user can act on it.
sudo_unavailable_reason() {
  if ! command -v sudo >/dev/null 2>&1; then
    printf '%s' "sudo is not installed. Run this installer as root, or install sudo first."
    return 0
  fi
  if ! is_admin_user; then
    printf '%s' "User '$(whoami)' is not in the admin group, so root access cannot be obtained. Re-run as an administrator account."
    return 0
  fi
  printf '%s' "No terminal is available to prompt for your sudo password, and the sudo timestamp is cold. This is NOT a permissions problem — '$(whoami)' is an administrator. Either run 'sudo -v' first in this same terminal (macOS ties the timestamp to the tty), or download the script and run it directly: curl -fsSL ${INSTALL_URL} -o install.sh && bash install.sh"
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1${2:+ ($2)}"
}

ensure_homebrew_darwin() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  command -v brew >/dev/null 2>&1 && { ok "Homebrew already installed"; return 0; }

  case "$(uname -m)" in
    arm64|aarch64) ;;
    *) die "Homebrew not found. Install it from https://brew.sh, then re-run this installer." ;;
  esac

  warn "Homebrew not found, installing"

  # Homebrew's installer needs root. Under `curl … | bash` our stdin is the curl
  # pipe, so a plain `/bin/bash -c "$(…)"` child inherits a non-TTY stdin,
  # Homebrew switches to NONINTERACTIVE, its have_sudo_access() falls back to
  # `sudo -n`, and a cold sudo timestamp aborts with a misleading
  # "needs to be an Administrator". Warm the timestamp ourselves and hand the
  # child the real terminal.
  local brew_script
  brew_script="$(curl -fsSL --retry 3 --retry-delay 2 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || die "Failed to download the Homebrew installer. Check network access to raw.githubusercontent.com, then re-run."
  [ -n "$brew_script" ] || die "Downloaded Homebrew installer was empty; refusing to execute."

  ensure_sudo || true

  if have_tty; then
    if ! /bin/bash -c "$brew_script" </dev/tty; then
      die "Homebrew installation failed (see output above). Install it manually from https://brew.sh, then re-run this installer."
    fi
  else
    # No controlling terminal at all (CI, MDM, remote provisioning).
    # Homebrew cannot prompt, so root access must already be available.
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
      die "$(sudo_unavailable_reason)"
    fi
    if ! NONINTERACTIVE=1 /bin/bash -c "$brew_script"; then
      die "Homebrew installation failed in non-interactive mode (see output above)."
    fi
  fi

  [ -x /opt/homebrew/bin/brew ] || die "Homebrew install completed but brew binary not found in /opt/homebrew/bin"
  eval "$(/opt/homebrew/bin/brew shellenv)"
  command -v brew >/dev/null 2>&1 || die "brew still not on PATH after eval shellenv"
  ok "Homebrew installed: $(brew --version | head -n 1)"
}

detect_pkg_mgr() {
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
  if   command -v apt-get >/dev/null 2>&1; then PKG_MGR=apt
  elif command -v dnf     >/dev/null 2>&1; then PKG_MGR=dnf
  elif command -v yum     >/dev/null 2>&1; then PKG_MGR=yum
  elif command -v pacman  >/dev/null 2>&1; then PKG_MGR=pacman
  elif command -v apk     >/dev/null 2>&1; then PKG_MGR=apk
  elif command -v brew    >/dev/null 2>&1; then PKG_MGR=brew
  fi
  # An AND-list as the last statement returns 1 under `set -e` when no package
  # manager is found, which would kill the installer with no message.
  if [ -n "$PKG_MGR" ]; then
    log "Package manager: $PKG_MGR"
  else
    warn "No supported package manager detected; dependencies must be installed manually"
  fi
}

# Map logical package name -> distro-specific package
resolve_pkg() {
  case "$1:$PKG_MGR" in
    poppler:pacman|poppler:brew) printf "poppler" ;;
    poppler:*)                   printf "poppler-utils" ;;
    python3:pacman)              printf "python" ;;
    python3:*)                   printf "python3" ;;
    nodejs:brew)                 printf "node" ;;
    nodejs:*)                    printf "nodejs" ;;
    bubblewrap:*)                printf "bubblewrap" ;;
    libsecret:apt)               printf "libsecret-tools" ;;
    libsecret:*)                 printf "libsecret" ;;
    build-essential:apt)         printf "build-essential" ;;
    build-essential:pacman)      printf "base-devel" ;;
    build-essential:apk)         printf "build-base" ;;
    build-essential:*)           printf "gcc" ;;
    *)                           printf "%s" "$1" ;;
  esac
}

pkg_install() {
  local logical pkgs=()
  for logical in "$@"; do pkgs+=("$(resolve_pkg "$logical")"); done
  log "Installing: ${pkgs[*]} (via $PKG_MGR)"
  case "$PKG_MGR" in
    apt)
      $SUDO apt-get update -y || warn "apt-get update failed, continuing"
      $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    dnf)    $SUDO dnf install -y "${pkgs[@]}" ;;
    yum)    $SUDO yum install -y "${pkgs[@]}" ;;
    pacman) $SUDO pacman -Sy --noconfirm "${pkgs[@]}" ;;
    apk)    $SUDO apk add --no-cache "${pkgs[@]}" ;;
    brew)
      local prefix; prefix="$(brew --prefix)"
      if [ ! -w "$prefix" ]; then
        warn "$prefix not writable, fixing ownership (sudo prompt expected)"
        sudo chown -R "$(whoami)" "$prefix"
      fi
      brew install "${pkgs[@]}"
      ;;
    *) return 1 ;;
  esac
}

confirm_overwrite_agen() {
  command -v agen >/dev/null 2>&1 || return 0

  local existing
  existing="$(command -v agen)"
  log "agen already installed at: $existing"

  # stdin is the piped script, so read the answer from the terminal
  if ! have_tty; then
    log "Non-interactive shell; keeping existing agen"
    exit 0
  fi

  printf "Overwrite existing agen? [y/N] " >/dev/tty
  local ans=""
  IFS= read -r ans </dev/tty || ans=""
  case "$ans" in
    y|Y|yes|YES|Yes) ok "Proceeding with reinstall" ;;
    *)
      ok "Keeping existing agen"
      exit 0
      ;;
  esac
}

ensure_cmd() {
  local cmd="$1" logical="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return 0

  if [ "$(uname -s)" = "Darwin" ]; then
    case "$cmd" in
      make|git|cc|clang|gcc)
        die "$cmd not found on macOS. Run 'xcode-select --install' then re-run this installer."
        ;;
    esac
  fi

  [ -n "$PKG_MGR" ] || die "$cmd not found and no supported package manager detected. Install '$logical' manually."

  warn "$cmd missing, installing $logical"
  pkg_install "$logical" || die "Failed to install $logical"
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd still missing after installing $logical"
}

# An explicit CGO_ENABLED=0 in the caller's environment survives into `make
# build`: go-sqlite3 then compiles as static_mock.go, the build exits 0, and the
# stub only errors at the first OpenDB. Refuse instead of shipping that binary.
ensure_cgo_enabled() {
  case "${CGO_ENABLED:-}" in
    0)
      die "CGO_ENABLED=0 is set in this environment; go-sqlite3 would build as a
     non-functional stub. Run 'unset CGO_ENABLED' (or export CGO_ENABLED=1)
     and re-run this installer."
      ;;
  esac
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
    ok "Go PATH already persisted in $rc"
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

# go-rod launches ~/.cache/rod/browser/.../chrome directly (not apt's chromium
# package), so apt won't pull its shared-lib deps automatically. libasound2 is
# the one rod's chromium needs that a bare Debian/Ubuntu host lacks; minimal
# WSL images additionally ship no CJK fonts, so Chinese renders as tofu boxes.
ensure_chrome_deps() {
  [ "$PKG_MGR" = "apt" ] || return 0

  log "Ensuring libasound2 for go-rod (apt)"
  $SUDO apt-get update -y || warn "apt-get update failed, continuing"
  if $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y libasound2 2>/dev/null; then
    ok "libasound2 installed"
  else
    # Newer Ubuntu (24.04+) renamed libasound2 -> libasound2t64; retry with that name.
    warn "libasound2 install failed, retrying with libasound2t64 (newer Ubuntu package name)"
    if $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y libasound2t64; then
      ok "libasound2t64 installed"
    else
      warn "Failed to install libasound2/libasound2t64; go-rod browser automation may not launch"
    fi
  fi

  log "Ensuring CJK fonts for go-rod (apt)"
  if $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y fonts-noto-cjk; then
    ok "fonts-noto-cjk installed"
  else
    warn "Failed to install fonts-noto-cjk; Chinese/Japanese/Korean text may render as tofu boxes"
  fi
}

ensure_go() {
  local platform="$1"
  local current

  # Prefer existing go on PATH; otherwise probe the canonical install dir
  # so subsequent invocations (and `agen update` subprocesses) can find it
  # even when the user's shell rc was never updated.
  if ! command -v go >/dev/null 2>&1 && [ -x "${GO_INSTALL_DIR}/bin/go" ]; then
    export PATH="${GO_INSTALL_DIR}/bin:${PATH}"
  fi

  if current="$(current_go_version)" && [ -n "$current" ]; then
    if go_version_ok "$current"; then
      ok "Go $current already meets >= ${REQUIRED_GO_MAJOR}.${REQUIRED_GO_MINOR}"
      # Still persist PATH if go was found via probe but rc isn't wired
      if [ "$(command -v go)" = "${GO_INSTALL_DIR}/bin/go" ]; then
        persist_go_path
      fi
      return 0
    fi
    warn "Go $current < ${REQUIRED_GO_MAJOR}.${REQUIRED_GO_MINOR}, upgrading"
  else
    warn "Go not found, installing"
  fi
  install_go "$platform"
}

clone_repo() {
  SRC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/neuromed-install.XXXXXX")"
  log "Cloning ${BRANCH} branch -> ${SRC_DIR}"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
  INSTALLED_REV="$(cd "$SRC_DIR" && git rev-parse --short HEAD)"
  ok "Cloned ${BRANCH}@${INSTALLED_REV}"
}

# Low-RAM hosts (e.g. free-tier VMs) OOM-kill go compile with:
#   .../compile: signal: killed
# Cap package parallelism, create temporary swap, and pre-build heavy packages
# one-by-one so a single large compile does not peak with others.

# Keep sudo timestamp warm during long builds (so swap + install don't re-prompt).
SUDO_KEEPALIVE_PID=""
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

stop_sudo_keepalive() {
  if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi
}

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

# Host readiness report — always run on Linux low-mem path so the installer
# itself does the "df / free / swapon" checklist instead of dumping commands.
report_host_resources() {
  [ "$(uname -s)" = "Linux" ] || return 0
  log "Host resources before build"
  if command -v free >/dev/null 2>&1; then
    free -h 2>/dev/null | sed 's/^/    /' || true
  elif [ -r /proc/meminfo ]; then
    awk '/MemTotal:|MemAvailable:|SwapTotal:|SwapFree:/ { printf "    %s\n", $0 }' /proc/meminfo
  fi
  if command -v df >/dev/null 2>&1; then
    printf "    -- disk --\n"
    df -h / "$HOME" 2>/dev/null | sed 's/^/    /' || true
  fi
  if command -v swapon >/dev/null 2>&1; then
    printf "    -- swap devices --\n"
    local out
    out="$(swapon --show 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf "%s\n" "$out" | sed 's/^/    /'
    else
      printf "    (none)\n"
    fi
  fi
}

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

  report_host_resources

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
    warn "No sudo/root available — cannot create temporary swap automatically."
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
    # Use dd first when we already know memory is tight (more reliable swapon).
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
      warn "Created temporary ${size_mb} MiB swap at $path (removed after install)"
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
          warn "Created temporary ${size_mb} MiB swap at $path via dd (removed after install)"
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
      # Do not track /swapfile for auto-removal if user created it permanently.
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
    report_host_resources
    apply_low_mem_env
    log "Step 1/3: ensure swap (auto, else interactive instructions on this host)"
    if ! ensure_build_swap; then
      die "Low-memory host has no usable swap. Create >=1-2 GiB swap, then re-run."
    fi
    report_host_resources
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

# Staged build for low-mem hosts:
#   1) go mod download
#   2) pre-compile heavy packages one-by-one (cache objects)
#   3) final make build (remaining pkgs + cgo + link + install)
staged_low_mem_build() {
  cd "$SRC_DIR" || return 1
  apply_low_mem_env

  log "Step 2/3: staged prebuild"
  log "  2a) go mod download"
  if ! go mod download; then
    warn "go mod download failed; continuing (build may re-fetch)"
  fi

  log "  2b) pre-build heavy packages one-by-one (avoids multi-pkg RSS spike)"
  local pkg i=0 n=${#HEAVY_PKGS[@]}
  for pkg in "${HEAVY_PKGS[@]}"; do
    i=$((i + 1))
    # Skip packages not in this module graph (older/newer branch state).
    if ! go list -f '{{.ImportPath}}' "$pkg" >/dev/null 2>&1; then
      log "  [${i}/${n}] skip $pkg (not in module graph)"
      continue
    fi
    log "  [${i}/${n}] go build -p=1 $pkg"
    local memlimit="${GOMEMLIMIT:-1000MiB}"
    if [ "$pkg" = "github.com/ugorji/go/codec" ]; then
      memlimit="800MiB"
    fi
    if ! GOMEMLIMIT="$memlimit" go build -p=1 "$pkg"; then
      warn "  pre-build failed for $pkg (will retry during final make build)"
    else
      ok "  cached $pkg"
    fi
    # Let kernel reclaim compiler RSS / page cache before next peak.
    sleep 1
  done

  log "Step 3/3: final make build (remaining packages + link + install)"
  make build
}

run_make_build() {
  (
    cd "$SRC_DIR" || exit 1
    export GOMAXPROCS="${GOMAXPROCS:-1}"
    export GOFLAGS="${GOFLAGS:--p=1}"
    export GOGC="${GOGC:-25}"
    export GOMEMLIMIT="${GOMEMLIMIT:-1000MiB}"
    if [ "${LOW_MEM:-0}" -eq 1 ]; then
      staged_low_mem_build
    else
      make build
    fi
  )
}

# `command -v agen` succeeding proves nothing: a stale copy earlier on PATH
# (~/.local/bin, brew) answers the same way and the user keeps running the old
# binary while the installer reports success.
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

build_and_install() {
  configure_build_env
  if [ "${LOW_MEM:-0}" -eq 1 ]; then
    log "Building with low-memory staged pipeline (sudo may prompt for /usr/local/bin)"
  else
    log "Building (sudo prompt expected for /usr/local/bin install)"
  fi

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
      warn "Build OOM-killed; forcing low-mem staged rebuild"
      LOW_MEM=1
      apply_low_mem_env
      export GOMEMLIMIT=800MiB
      report_host_resources
      ensure_build_swap || true
      if ! run_make_build; then
        rm -f "$build_log"
        die "Build failed after low-memory staged retry. Free RAM, ensure >=1 GiB swap is active (free -h), or use a larger VM, then re-run."
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
  ok "agen installed at /usr/local/bin/agen"
}

stop_daemon() {
  log "Stopping existing daemon (if any) so the new binary takes effect"
  /usr/local/bin/agen stop || true
}

print_done() {
  local tag="${1:-installed}"
  local lines=(
    "NeuroMed-AI ${tag} installed"
    ""
    "Next: run 'agen' to attach the new build"
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

main() {
  log "NeuroMed-AI installer (linebot branch)"
  local platform; platform="$(detect_platform)"
  log "Platform: $platform"

  confirm_overwrite_agen

  require_cmd curl
  require_cmd uname

  ensure_cgo_enabled
  ensure_homebrew_darwin
  detect_pkg_mgr
  ensure_cmd tar
  ensure_cmd git
  ensure_cmd make
  # go-sqlite3 is a cgo binding: with no C compiler on PATH, Go silently sets
  # CGO_ENABLED=0, the build still succeeds, and the driver is compiled as a
  # stub that fails only at the first OpenDB — "requires cgo to work".
  ensure_cmd cc build-essential
  ensure_cmd pdftotext poppler
  ensure_cmd python3
  ensure_cmd node nodejs

  # Linux sandbox requires bubblewrap; macOS uses built-in sandbox-exec
  if [ "$(uname -s)" = "Linux" ]; then
    ensure_cmd bwrap bubblewrap
    # keychain: go-pkg/filesystem/keychain shells out to secret-tool on linux
    # and, when it fails, silently writes secrets to a plaintext .secrets file
    ensure_cmd secret-tool libsecret
  fi
  ensure_chrome_deps

  ensure_go "$platform"
  clone_repo
  build_and_install
  stop_daemon
  print_done "${BRANCH}@${INSTALLED_REV}"
}

main "$@"
