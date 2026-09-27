#!/usr/bin/env bash
# Neovim (latest stable) + LazyVim for the ros1 container (Ubuntu 20.04).
#
# Run INSIDE the container, as your user (not with sudo):
#     bash /opt/ros-setup/lazyvim-setup.sh
#
# 1. Removes any earlier Neovim setup (apt neovim, old config/plugins/data)
#    unless it is already a LazyVim setup.
# 2. Installs Neovim from neovim-releases (built for older glibc; the main
#    Neovim release may need a newer glibc than Ubuntu 20.04 has).
# 3. Installs what LazyVim needs: git, C compiler, ripgrep, fd, fzf >= 0.25.1,
#    lazygit, tree-sitter CLI, Node.js (for Mason), clipboard tools.
# 4. Installs the LazyVim starter and pre-installs its plugins.
#
# Safe to re-run: it updates tools and keeps an existing LazyVim config.
# Afterwards, on the HOST: sudo systemctl reload ros1   (saves it to the image)
set -euo pipefail

NODE_MAJOR=22
NVIM_DIR=/opt/nvim-linux-x86_64
LOCAL_BIN="$HOME/.local/bin"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mfail\033[0m  %s\n' "$*"; exit 1; }

[ "${CONTAINER_NAME:-}" = ros1 ] || die "run this inside the ros1 container (type 1 first)"
[ "${EUID}" -ne 0 ] || die "run as your user, not root (the script uses sudo itself)"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${LOCAL_BIN}"

# --- 1. remove the earlier Neovim setup -------------------------------------
info "Removing earlier Neovim setup"
sudo apt-get purge -y neovim neovim-runtime >/dev/null 2>&1 || true
if grep -qs 'LazyVim/LazyVim' "$HOME/.config/nvim/lua/config/lazy.lua"; then
    ok "existing LazyVim config found, keeping it"
else
    rm -rf "$HOME/.config/nvim" "$HOME/.local/share/nvim" \
           "$HOME/.local/state/nvim" "$HOME/.cache/nvim"
    ok "old config, plugins and data removed"
fi

# --- 2. system packages -----------------------------------------------------
info "Installing packages (apt)"
sudo apt-get update -qq
sudo apt-get install -y -qq \
    git build-essential curl wget unzip gzip tar xz-utils \
    ripgrep fd-find python3-venv python3-pip wl-clipboard xclip >/dev/null
ln -sf /usr/bin/fdfind "${LOCAL_BIN}/fd"          # Ubuntu calls it fdfind
ok "git $(git --version | cut -d' ' -f3), ripgrep, fd, compiler, clipboard"

# --- 3. Neovim --------------------------------------------------------------
info "Installing Neovim (latest stable)"
curl -fsSL -o "${tmp}/nvim.tar.gz" \
    https://github.com/neovim/neovim-releases/releases/latest/download/nvim-linux-x86_64.tar.gz
sudo rm -rf "${NVIM_DIR}"
sudo tar -xzf "${tmp}/nvim.tar.gz" -C /opt
for name in nvim vim vi; do
    sudo ln -sf "${NVIM_DIR}/bin/nvim" "/usr/local/bin/${name}"
done
nvim --version | grep -q LuaJIT || die "this Neovim build has no LuaJIT (LazyVim needs it)"
ok "$(nvim --version | head -1)  (also as vim and vi)"

# --- 4. fzf (apt's 0.20 is too old) -------------------------------------------
info "Installing fzf"
if [ -d "$HOME/.fzf/.git" ]; then
    git -C "$HOME/.fzf" pull -q --ff-only
else
    rm -rf "$HOME/.fzf"
    git clone -q --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
fi
"$HOME/.fzf/install" --bin >/dev/null
ln -sf "$HOME/.fzf/bin/fzf" "${LOCAL_BIN}/fzf"
ok "fzf $("${LOCAL_BIN}/fzf" --version | cut -d' ' -f1)"

# --- 5. lazygit ---------------------------------------------------------------
info "Installing lazygit"
lg_version="$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
              | grep -Po '"tag_name": *"v\K[^"]*')" || true
if [ -n "${lg_version}" ] && curl -fsSL -o "${tmp}/lazygit.tar.gz" \
    "https://github.com/jesseduffield/lazygit/releases/download/v${lg_version}/lazygit_${lg_version}_Linux_x86_64.tar.gz"; then
    tar -xzf "${tmp}/lazygit.tar.gz" -C "${tmp}" lazygit
    sudo install -m 0755 "${tmp}/lazygit" /usr/local/bin/lazygit
    ok "lazygit ${lg_version}"
else
    warn "lazygit download failed (optional; re-run the script later)"
fi

# --- 6. tree-sitter CLI -----------------------------------------------------------
info "Installing tree-sitter CLI"
curl -fsSL -o "${tmp}/ts.gz" \
    https://github.com/tree-sitter/tree-sitter/releases/latest/download/tree-sitter-linux-x64.gz
gunzip -c "${tmp}/ts.gz" > "${LOCAL_BIN}/tree-sitter"
chmod +x "${LOCAL_BIN}/tree-sitter"
if "${LOCAL_BIN}/tree-sitter" --version >/dev/null 2>&1; then
    ok "$("${LOCAL_BIN}/tree-sitter" --version) (prebuilt)"
else
    warn "prebuilt tree-sitter needs a newer glibc; building it from source (5-10 min)"
    rm -f "${LOCAL_BIN}/tree-sitter"
    export RUSTUP_HOME="${tmp}/rustup" CARGO_HOME="${tmp}/cargo"   # temporary, deleted at the end
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path >/dev/null
    "${CARGO_HOME}/bin/cargo" install --locked --quiet tree-sitter-cli --root "${tmp}/ts"
    install -m 0755 "${tmp}/ts/bin/tree-sitter" "${LOCAL_BIN}/tree-sitter"
    unset RUSTUP_HOME CARGO_HOME
    ok "$("${LOCAL_BIN}/tree-sitter" --version) (built; Rust toolchain removed again)"
fi

# --- 7. Node.js (Mason installs many language servers with npm) ------------------
info "Installing Node.js ${NODE_MAJOR} LTS"
node_dist="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"
node_tar="$(curl -fsSL "${node_dist}/SHASUMS256.txt" | awk '/linux-x64\.tar\.xz$/ {print $2}')"
[ -n "${node_tar}" ] || die "could not find the Node.js ${NODE_MAJOR} download"
curl -fsSL -o "${tmp}/${node_tar}" "${node_dist}/${node_tar}"
sudo rm -rf /opt/node
sudo mkdir -p /opt/node
sudo tar -xJf "${tmp}/${node_tar}" -C /opt/node --strip-components=1
for name in node npm npx; do
    sudo ln -sf "/opt/node/bin/${name}" "/usr/local/bin/${name}"
done
ok "node $(node --version), npm $(npm --version)"

# --- 8. shell setup (container's own ~/.bashrc) ---------------------------------
info "Updating ~/.bashrc"
add_line() { grep -qxF "$1" "$HOME/.bashrc" || echo "$1" >> "$HOME/.bashrc"; }
add_line 'export PATH="$HOME/.local/bin:$PATH"'
add_line 'export EDITOR=nvim VISUAL=nvim'
export PATH="${LOCAL_BIN}:${PATH}"
ok "PATH and EDITOR set"

# --- 9. LazyVim -----------------------------------------------------------------
info "Installing LazyVim"
if [ ! -d "$HOME/.config/nvim" ]; then
    git clone -q https://github.com/LazyVim/starter "$HOME/.config/nvim"
    rm -rf "$HOME/.config/nvim/.git"
    ok "LazyVim starter installed"
fi
info "Downloading plugins (1-2 min)"
if nvim --headless "+Lazy! sync" +qa >/dev/null 2>&1; then
    ok "plugins installed"
else
    warn "plugin sync reported problems; open nvim, it retries automatically"
fi

echo
info "Done. Next:"
echo "  1. Open a new shell (exit, then 1) and run: nvim   then  :LazyHealth"
echo "     Syntax parsers compile on first use; language servers install via :Mason"
echo "  2. On the HOST: sudo systemctl reload ros1   (saves everything into the image)"
echo "  3. On the HOST, once: install JetBrainsMono Nerd Font and pick it in Konsole"
