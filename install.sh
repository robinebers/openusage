#!/usr/bin/env bash
set -euo pipefail

INSTALL_BIN="${INSTALL_BIN:-$HOME/.local/bin}"
INSTALL_PLUGINS="${INSTALL_PLUGINS:-$HOME/.local/share/openusage/plugins}"
AUTO_YES=false

usage() {
    echo "Usage: $0 [-y] [-b BINDIR] [-p PLUGINSDIR]"
    echo ""
    echo "  -y    Auto-confirm all prompts"
    echo "  -b    Binary install directory (default: ~/.local/bin)"
    echo "  -p    Plugins install directory (default: ~/.local/share/openusage/plugins)"
    exit 0
}

while getopts "yhb:p:" opt; do
    case "$opt" in
        y) AUTO_YES=true ;;
        b) INSTALL_BIN="$OPTARG" ;;
        p) INSTALL_PLUGINS="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

confirm() {
    if $AUTO_YES; then return 0; fi
    read -rp "$1 [Y/n] " answer
    case "$answer" in
        [nN]*) return 1 ;;
        *) return 0 ;;
    esac
}

info()  { echo "  [*] $*"; }
ok()    { echo "  [+] $*"; }
warn()  { echo "  [!] $*"; }
fail()  { echo "  [-] $*"; exit 1; }

echo ""
echo "  OpenUsage CLI Installer"
echo "  ======================="
echo ""

# ── Detect OS / package manager ──────────────────────────────────────

PKG_MGR=""
INSTALL_CMD=""

if command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
    INSTALL_CMD="sudo apt-get install -y"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    INSTALL_CMD="sudo dnf install -y"
elif command -v pacman &>/dev/null; then
    PKG_MGR="pacman"
    INSTALL_CMD="sudo pacman -S --noconfirm"
elif command -v brew &>/dev/null; then
    PKG_MGR="brew"
    INSTALL_CMD="brew install"
else
    warn "No supported package manager found (apt, dnf, pacman, brew)"
    warn "You will need to install missing dependencies manually"
fi

# ── Dependency checks ────────────────────────────────────────────────

MISSING_CMDS=()
MISSING_PKGS=()

check_cmd() {
    local cmd="$1"
    local pkg_apt="${2:-$1}"
    local pkg_dnf="${3:-$1}"
    local pkg_pac="${4:-$1}"
    local pkg_brew="${5:-$1}"

    if command -v "$cmd" &>/dev/null; then
        ok "$cmd found: $(command -v "$cmd")"
    else
        warn "$cmd not found"
        MISSING_CMDS+=("$cmd")
        case "$PKG_MGR" in
            apt)    MISSING_PKGS+=("$pkg_apt") ;;
            dnf)    MISSING_PKGS+=("$pkg_dnf") ;;
            pacman) MISSING_PKGS+=("$pkg_pac") ;;
            brew)   MISSING_PKGS+=("$pkg_brew") ;;
        esac
    fi
}

check_lib() {
    local name="$1"
    local check_cmd="$2"
    local pkg_apt="$3"
    local pkg_dnf="$4"
    local pkg_pac="$5"
    local pkg_brew="$6"

    if eval "$check_cmd" &>/dev/null; then
        ok "$name found"
    else
        warn "$name not found"
        MISSING_CMDS+=("$name")
        case "$PKG_MGR" in
            apt)    MISSING_PKGS+=("$pkg_apt") ;;
            dnf)    MISSING_PKGS+=("$pkg_dnf") ;;
            pacman) MISSING_PKGS+=("$pkg_pac") ;;
            brew)   MISSING_PKGS+=("$pkg_brew") ;;
        esac
    fi
}

info "Checking dependencies..."
echo ""

# git
check_cmd "git" "git" "git" "git" "git"

# C compiler
check_cmd "cc" "build-essential" "gcc" "base-devel" "gcc"

# pkg-config
check_cmd "pkg-config" "pkg-config" "pkgconf" "pkgconf" "pkg-config"

# clang (needed by rquickjs bindgen)
check_cmd "clang" "clang" "clang" "clang" "llvm"

# libclang (bindgen needs libclang.so)
check_lib "libclang" \
    "test -n \"\$(find /usr/lib* /usr/local/lib* -name 'libclang*' 2>/dev/null | head -1)\" || llvm-config --libdir 2>/dev/null" \
    "libclang-dev" "clang-devel" "clang" "llvm"

# OpenSSL dev (reqwest)
check_lib "libssl-dev" \
    "pkg-config --exists openssl 2>/dev/null || test -f /usr/include/openssl/ssl.h" \
    "libssl-dev" "openssl-devel" "openssl" "openssl"

# Rust toolchain
if command -v cargo &>/dev/null; then
    RUST_VER="$(rustc --version 2>/dev/null || echo 'unknown')"
    ok "cargo found: $RUST_VER"

    # edition 2024 requires Rust 1.85+
    RUST_MINOR="$(echo "$RUST_VER" | grep -oP '\d+\.(\d+)' | head -1 | cut -d. -f2)"
    if [ -n "$RUST_MINOR" ] && [ "$RUST_MINOR" -lt 85 ]; then
        warn "Rust 1.85+ required (edition 2024), you have $RUST_VER"
        MISSING_CMDS+=("rust-1.85+")
    fi
elif command -v "$HOME/.cargo/bin/cargo" &>/dev/null; then
    RUST_VER="$("$HOME/.cargo/bin/rustc" --version 2>/dev/null || echo 'unknown')"
    ok "cargo found (not on PATH): $RUST_VER"
    export PATH="$HOME/.cargo/bin:$PATH"
else
    warn "cargo not found"
    MISSING_CMDS+=("cargo")
fi

echo ""

# ── Install missing dependencies ─────────────────────────────────────

if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
    # Handle Rust separately
    NEED_RUST=false
    for cmd in "${MISSING_CMDS[@]}"; do
        if [ "$cmd" = "cargo" ]; then NEED_RUST=true; fi
    done

    # System packages
    # Deduplicate MISSING_PKGS
    UNIQUE_PKGS=($(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u))

    if [ ${#UNIQUE_PKGS[@]} -gt 0 ]; then
        if [ -z "$PKG_MGR" ]; then
            fail "Missing: ${UNIQUE_PKGS[*]} — install them manually and re-run"
        fi

        info "Missing system packages: ${UNIQUE_PKGS[*]}"
        if confirm "Install with '$INSTALL_CMD ${UNIQUE_PKGS[*]}'?"; then
            $INSTALL_CMD "${UNIQUE_PKGS[@]}"
            ok "System packages installed"
        else
            fail "Cannot continue without: ${UNIQUE_PKGS[*]}"
        fi
    fi

    if $NEED_RUST; then
        info "Rust toolchain not found"
        if confirm "Install Rust via rustup?"; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            export PATH="$HOME/.cargo/bin:$PATH"
            ok "Rust installed: $(rustc --version)"
        else
            fail "Cannot continue without Rust"
        fi
    fi

    # Handle outdated Rust
    for cmd in "${MISSING_CMDS[@]}"; do
        if [ "$cmd" = "rust-1.85+" ]; then
            info "Rust needs updating to 1.85+"
            if confirm "Run 'rustup update stable'?"; then
                rustup update stable
                ok "Rust updated: $(rustc --version)"
            else
                fail "Rust 1.85+ is required for edition 2024"
            fi
        fi
    done

    echo ""
fi

# ── Locate repo root ─────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/Cargo.toml" ]; then
    fail "install.sh must be run from the openusage repo root"
fi

cd "$SCRIPT_DIR"
info "Building from: $SCRIPT_DIR"

# ── Build ─────────────────────────────────────────────────────────────

info "Building release binary..."
cargo build -p openusage-cli --release

BINARY="$SCRIPT_DIR/target/release/openusage"
if [ ! -f "$BINARY" ]; then
    fail "Build succeeded but binary not found at $BINARY"
fi

ok "Built: $BINARY"

# ── Run tests ─────────────────────────────────────────────────────────

info "Running tests..."
if cargo test -p openusage-plugin-engine -p openusage-cli --release; then
    ok "All tests passed"
else
    warn "Some tests failed — installing anyway"
fi

# ── Install binary ────────────────────────────────────────────────────

echo ""
info "Install binary to: $INSTALL_BIN/openusage"
info "Install plugins to: $INSTALL_PLUGINS/"

if ! confirm "Proceed with install?"; then
    info "Skipped. Binary is at: $BINARY"
    exit 0
fi

mkdir -p "$INSTALL_BIN"
# Remove before copy to handle "Text file busy" when binary is running
if [ -f "$INSTALL_BIN/openusage" ]; then
    rm -f "$INSTALL_BIN/openusage"
fi
cp "$BINARY" "$INSTALL_BIN/openusage"
chmod +x "$INSTALL_BIN/openusage"
ok "Installed binary: $INSTALL_BIN/openusage"

# ── Install plugins ──────────────────────────────────────────────────

mkdir -p "$INSTALL_PLUGINS"
# Copy each plugin directory (skip mock)
for plugin_dir in "$SCRIPT_DIR/plugins"/*/; do
    plugin_name="$(basename "$plugin_dir")"
    if [ "$plugin_name" = "mock" ]; then continue; fi
    rm -rf "${INSTALL_PLUGINS:?}/$plugin_name"
    cp -r "$plugin_dir" "$INSTALL_PLUGINS/$plugin_name"
done
ok "Installed plugins: $INSTALL_PLUGINS/"

# ── Verify PATH ──────────────────────────────────────────────────────

echo ""
if echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_BIN"; then
    ok "$INSTALL_BIN is on PATH"
    info "Verify: openusage --help"
else
    warn "$INSTALL_BIN is not on your PATH"
    info "Add it:  echo 'export PATH=\"$INSTALL_BIN:\$PATH\"' >> ~/.bashrc"
fi

echo ""
info "Usage:"
info "  openusage --plugins-dir $INSTALL_PLUGINS"
info "  openusage --plugins-dir $INSTALL_PLUGINS --json"
info "  openusage --plugins-dir $INSTALL_PLUGINS --verbose"
echo ""
ok "Done!"
