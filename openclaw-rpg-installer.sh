#!/usr/bin/env bash
###############################################################################
#  Lonely RPG — OpenClaw + Local LLM Installer for Linux
#  Compatible with: Ubuntu/Debian, Fedora/RHEL/CentOS
#
#  What this script does:
#    1. Detects the distro and installs dependencies (Node 22+, curl, git, jq)
#    2. Analyzes hardware (RAM, CPU, GPU NVIDIA/AMD/Intel) and automatically
#       selects the best unrestricted LLM model for your system
#    3. Installs Ollama and downloads the selected Dolphin-series model
#       (fine-tuned for unrestricted creative content — no immersion breaks)
#    4. Installs OpenClaw via npm and creates a systemd service
#    5. Configures a Lonely RPG workspace with:
#         - Mestre (Game Master): narrates the world, controls NPCs, runs rules
#         - 3 AI companions with full RPG character sheets
#         - Player character sheet
#    6. Stores character sheets (fichas) in ~/.openclaw/sheets/
#    7. Applies CPU/RAM limits to prevent server overload
#    8. Installs the 'lonely-rpg-ctl' utility for easy service management
#    9. Opens firewall ports (ufw / firewalld)
#   10. Displays URL + token for immediate browser access
#
#  Usage:
#    chmod +x openclaw-rpg-installer.sh
#    sudo ./openclaw-rpg-installer.sh               # Full install
#    sudo ./openclaw-rpg-installer.sh --reconfigure # Reconfigure party only
#    sudo ./openclaw-rpg-installer.sh --uninstall   # Uninstall everything
#
#  After installation, use 'lonely-rpg-ctl' to manage:
#    lonely-rpg-ctl start    — Start all services
#    lonely-rpg-ctl stop     — Stop everything (free resources)
#    lonely-rpg-ctl status   — Show status of all services
#    lonely-rpg-ctl restart  — Restart everything
#    lonely-rpg-ctl logs     — Tail live logs
#    lonely-rpg-ctl sheets   — List all character sheets
#    lonely-rpg-ctl sheet <name> — Show a character sheet
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ─── Trap for debug: print last executed line if script aborts ──────────────
trap 'err "Script aborted at line $LINENO (last command: $BASH_COMMAND, exit: $?)"' ERR

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
MAGENTA='\033[0;35m'

log()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()    { echo -e "${RED}[ERR]${NC}   $*" >&2; }
info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
ask()    { echo -e "${MAGENTA}[?]${NC}     $*"; }
banner() {
  echo ""
  echo -e "${BOLD}${CYAN}=======================================${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}=======================================${NC}"
  echo ""
}

# ─── Root check ──────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root (sudo)."
  exit 1
fi

# Real user (whoever called sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~${REAL_USER}")

# ─── Global variables ────────────────────────────────────────────────────────
OPENCLAW_CONFIG_DIR="${REAL_HOME}/.openclaw"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_CONFIG_DIR}/workspace"
SHEETS_DIR="${OPENCLAW_CONFIG_DIR}/sheets"
AGENTS_DIR="${OPENCLAW_CONFIG_DIR}/agents"
CTL_PATH="/usr/local/bin/lonely-rpg-ctl"
OLLAMA_MODEL=""      # Set automatically by select_model()
OLLAMA_NUM_CTX=8192
OLLAMA_PORT=11434
GATEWAY_PORT=18789
HTTPS_PORT=443
DISTRO=""
PKG_MGR=""
GATEWAY_TOKEN=""
SERVER_IP=""              # Detected in detect_server_ip()
OPENCLAW_BIN=""           # Absolute path to openclaw binary
OPENCLAW_START_ARGS=""    # Detected startup arguments
OPENCLAW_CMD_OVERRIDE=""  # Optional: user-supplied subcommand (--openclaw-cmd)

# ─── Hardware variables (filled by detect_hardware) ─────────────────────────
HW_RAM_GB=0
HW_CPU_CORES=0
HW_CPU_MODEL=""
HW_GPU_VENDOR="none"
HW_GPU_MODEL=""
HW_GPU_VRAM_MB=0
HW_TIER=""
HW_MODEL_REASON=""

# ─── Runtime flags ───────────────────────────────────────────────────────────
MODE="install"   # install | reconfigure | uninstall

###############################################################################
# 1. DISTRO DETECTION
###############################################################################
detect_distro() {
  banner "Detecting Linux Distribution"

  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    DISTRO="${ID:-unknown}"
  else
    DISTRO="unknown"
  fi

  case "$DISTRO" in
    ubuntu|debian|linuxmint|pop|elementary|kali)
      PKG_MGR="apt"
      log "Detected Debian-based distro: $DISTRO"
      ;;
    fedora|rhel|centos|rocky|alma|ol)
      PKG_MGR="dnf"
      log "Detected RHEL-based distro: $DISTRO"
      ;;
    *)
      warn "Unknown distro '$DISTRO'. Attempting to find a package manager..."
      if command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
      elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
      else
        err "No supported package manager found. Please install dependencies manually."
        exit 1
      fi
      ;;
  esac
}

###############################################################################
# 2. SYSTEM DEPENDENCIES
###############################################################################
install_system_deps() {
  banner "Installing System Dependencies"

  local pkgs=(curl git jq tar openssl xxd)

  if [[ "$PKG_MGR" == "apt" ]]; then
    apt-get update -qq
    apt-get install -y "${pkgs[@]}" ca-certificates gnupg lsb-release
    log "System packages installed (apt)"
  else
    dnf install -y "${pkgs[@]}" ca-certificates gnupg vim-common
    log "System packages installed (dnf)"
  fi
}

###############################################################################
# 3. NODE.JS 20+
###############################################################################
install_nodejs() {
  banner "Installing Node.js 22+"

  if command -v node &>/dev/null; then
    local ver
    ver=$(node --version | sed 's/v//' | cut -d. -f1)
    if [[ "$ver" -ge 22 ]]; then
      log "Node.js $(node --version) already installed — skipping"
      return
    fi
    warn "Node.js $ver found, upgrading to 22+ (current LTS)"
  fi

  # NodeSource setup scripts can return non-zero on existing configs; tolerate it
  if [[ "$PKG_MGR" == "apt" ]]; then
    (set +e +o pipefail; curl -fsSL https://deb.nodesource.com/setup_22.x | bash -) || true
    apt-get install -y nodejs
  else
    (set +e +o pipefail; curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -) || true
    dnf install -y nodejs
  fi

  log "Node.js $(node --version) installed"
}

###############################################################################
# 4. HARDWARE DETECTION & MODEL SELECTION
#
#  Model strategy: Dolphin series (by Cognitive Computations / Eric Hartford)
#  These are fine-tuned to follow all instructions without content restrictions,
#  making them ideal for immersive RPG campaigns where the AI must portray
#  villains, describe combat, dark themes, and mature narrative without refusals.
#
#  Tier map:
#    minimal  (<4 GB)  → tinydolphin         (1.1B  ~638 MB)
#    low      (4-8 GB) → dolphin-phi          (2.7B  ~1.6 GB)
#    mid      (8-16GB) → dolphin-mistral:7b   (7B    ~4.1 GB)
#    high     (16-32G) → dolphin-llama3:8b    (8B    ~4.7 GB)
#    ultra    (32+ GB) → dolphin-llama3:70b   (70B   ~39  GB)
###############################################################################
detect_hardware() {
  banner "Analyzing Hardware"

  HW_RAM_GB=$(awk '/MemTotal/ { printf "%d", $2/1024/1024 }' /proc/meminfo)
  HW_CPU_CORES=$(nproc)
  HW_CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)

  HW_GPU_VENDOR="none"
  if command -v nvidia-smi &>/dev/null 2>&1; then
    HW_GPU_VENDOR="nvidia"
    HW_GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
    HW_GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits \
      2>/dev/null | head -1 | tr -d ' ' || echo 0)
  elif command -v lspci &>/dev/null; then
    local lspci_out
    lspci_out=$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' || true)
    if   echo "$lspci_out" | grep -qi nvidia; then HW_GPU_VENDOR="nvidia"
      HW_GPU_MODEL=$(echo "$lspci_out" | grep -i nvidia | head -1)
    elif echo "$lspci_out" | grep -qi amd;    then HW_GPU_VENDOR="amd"
      HW_GPU_MODEL=$(echo "$lspci_out" | grep -i amd    | head -1)
    elif echo "$lspci_out" | grep -qi intel;  then HW_GPU_VENDOR="intel"
      HW_GPU_MODEL=$(echo "$lspci_out" | grep -i intel  | head -1)
    fi
  fi

  info "RAM:  ${HW_RAM_GB} GB"
  info "CPU:  ${HW_CPU_CORES} cores — ${HW_CPU_MODEL}"
  info "GPU:  ${HW_GPU_VENDOR}${HW_GPU_MODEL:+ (${HW_GPU_MODEL})}"
  [[ "$HW_GPU_VRAM_MB" -gt 0 ]] && info "VRAM: $(( HW_GPU_VRAM_MB / 1024 )) GB"

  select_model
}

select_model() {
  # Skip auto-selection if --model flag was provided
  if [[ -n "$OLLAMA_MODEL" ]]; then
    HW_TIER="custom"
    HW_MODEL_REASON="manually specified via --model flag"
    log "Using user-specified model: ${OLLAMA_MODEL} (ctx: ${OLLAMA_NUM_CTX})"
    return
  fi

  local available_gb="$HW_RAM_GB"
  if [[ "$HW_GPU_VENDOR" != "none" && "$HW_GPU_VRAM_MB" -gt 0 ]]; then
    available_gb=$(( HW_GPU_VRAM_MB / 1024 ))
  fi

  if [[ "$available_gb" -ge 32 ]]; then
    HW_TIER="ultra"
    OLLAMA_MODEL="dolphin-llama3:70b"
    OLLAMA_NUM_CTX=16384
    HW_MODEL_REASON="≥32 GB — full 70B Dolphin model, richest narrative and roleplay"
  elif [[ "$available_gb" -ge 16 ]]; then
    HW_TIER="high"
    OLLAMA_MODEL="dolphin-llama3:8b"
    OLLAMA_NUM_CTX=8192
    HW_MODEL_REASON="≥16 GB — Dolphin Llama 3 8B, excellent for immersive RPG sessions"
  elif [[ "$available_gb" -ge 8 ]]; then
    HW_TIER="mid"
    OLLAMA_MODEL="dolphin-mistral:7b"
    OLLAMA_NUM_CTX=8192
    HW_MODEL_REASON="≥8 GB — Dolphin Mistral 7B, strong storytelling with no restrictions"
  elif [[ "$available_gb" -ge 4 ]]; then
    HW_TIER="low"
    OLLAMA_MODEL="dolphin-phi"
    OLLAMA_NUM_CTX=4096
    HW_MODEL_REASON="≥4 GB — Dolphin Phi 2.7B, capable for basic RPG interaction"
  else
    HW_TIER="minimal"
    OLLAMA_MODEL="tinydolphin"
    OLLAMA_NUM_CTX=2048
    HW_MODEL_REASON="<4 GB — TinyDolphin 1.1B, minimal footprint; responses may be short"
    warn "Less than 4 GB available. AI responses may be brief. Consider upgrading RAM."
  fi

  log "Selected model: ${OLLAMA_MODEL} (tier: ${HW_TIER}, ctx: ${OLLAMA_NUM_CTX})"
  info "Reason: ${HW_MODEL_REASON}"
}

###############################################################################
# 5. OLLAMA INSTALLATION
###############################################################################

# Guarantee the ollama systemd service unit exists.
# The official Ollama installer sometimes skips service registration when it
# detects a pre-existing installation (group/user already present). We create
# the unit ourselves using the same content as the official installer.
_ensure_ollama_service() {
  # systemctl cat exits non-zero when the unit is unknown
  if systemctl cat ollama &>/dev/null 2>&1; then
    log "Ollama systemd unit already registered"
    return
  fi

  info "Ollama service unit not found — creating it..."
  local ollama_bin
  ollama_bin=$(command -v ollama)

  # Ensure the 'ollama' system user exists (group may already exist from
  # a previous install without a matching user)
  if ! id ollama &>/dev/null 2>&1; then
    if getent group ollama &>/dev/null; then
      useradd -r -s /bin/false -g ollama -d /usr/share/ollama ollama 2>/dev/null || true
    else
      useradd -r -s /bin/false -m -d /usr/share/ollama ollama 2>/dev/null || true
    fi
    log "System user 'ollama' created"
  fi

  cat > /etc/systemd/system/ollama.service <<EOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=${ollama_bin} serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="HOME=/usr/share/ollama"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  log "Ollama service unit created: /etc/systemd/system/ollama.service"
}

install_ollama() {
  banner "Installing Ollama"

  if command -v ollama &>/dev/null; then
    log "Ollama already installed — skipping binary install"
  else
    info "Downloading and installing Ollama..."
    # The official Ollama installer can return non-zero on harmless warnings
    # (e.g. "useradd: group ollama already exists"). Run in a subshell with
    # relaxed error handling so it doesn't abort our script.
    (
      set +e +o pipefail
      curl -fsSL https://ollama.ai/install.sh | sh
    ) || true
    # Verify the binary actually arrived
    if ! command -v ollama &>/dev/null; then
      err "Ollama binary not found after install attempt."
      err "Try installing manually: https://ollama.ai/download/linux"
      exit 1
    fi
    log "Ollama installed"
  fi

  # Guarantee the service unit exists before we try to start it
  _ensure_ollama_service

  # Always fix the ollama home directory — this must run even when the service
  # unit already existed and _ensure_ollama_service returned early, since the
  # directory may still be missing or have wrong ownership from a broken
  # previous install.
  mkdir -p /usr/share/ollama
  chown ollama:ollama /usr/share/ollama
  chmod 750 /usr/share/ollama
  log "Ollama home directory: /usr/share/ollama (ownership verified)"

  # The Ollama install.sh may start the process itself right after installation.
  # Check if the API is already responding before touching systemd, to avoid
  # a restart that resets the timer.
  if curl -sf --max-time 3 "http://localhost:${OLLAMA_PORT}/api/tags" &>/dev/null; then
    log "Ollama API already responding — enabling service unit only"
    systemctl enable ollama 2>/dev/null || true
  else
    # Stop any leftover process from a previous install, then start cleanly
    systemctl stop ollama 2>/dev/null || true
    pkill -x ollama        2>/dev/null || true
    sleep 2
    systemctl enable ollama 2>/dev/null || true
    systemctl start ollama  2>/dev/null || true
  fi

  info "Waiting for Ollama API (up to 120s)..."
  local retries=24 elapsed=0
  while [[ $retries -gt 0 ]]; do
    if curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" &>/dev/null; then break; fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
    (( retries-- )) || true
    (( elapsed % 20 == 0 )) && printf "  [%ds elapsed]\n" "$elapsed"
  done

  if ! curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" &>/dev/null; then
    warn "Ollama API did not respond after 120s. Last service logs:"
    echo ""
    journalctl -u ollama -n 25 --no-pager 2>/dev/null \
      || journalctl -xe --no-pager 2>/dev/null | tail -25 \
      || true
    echo ""
    err "Ollama failed to start. Common causes on Fedora/RHEL:"
    err "  • SELinux blocking: run 'ausearch -c ollama' for denials"
    err "  • GPU driver issue:  run 'nvidia-smi' to verify the driver"
    err "  • Port conflict:     run 'ss -tlnp | grep ${OLLAMA_PORT}'"
    err ""
    err "Fix the issue then re-run: sudo ./openclaw-rpg-installer.sh"
    exit 1
  fi

  log "Ollama is running"
  info "Pulling model: ${OLLAMA_MODEL} — this may take several minutes..."
  ollama pull "${OLLAMA_MODEL}"
  log "Model ${OLLAMA_MODEL} ready"
}

###############################################################################
# 6. OPENCLAW INSTALLATION
###############################################################################

# Detect the server's primary LAN/external IP
detect_server_ip() {
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
  fi
  [[ -z "$SERVER_IP" ]] && SERVER_IP="localhost"
  info "Server IP: ${SERVER_IP}"
}

# Probe the openclaw binary to find the correct startup subcommand and flags.
# Sets: OPENCLAW_BIN, OPENCLAW_START_ARGS
detect_openclaw_cmd() {
  OPENCLAW_BIN=$(command -v openclaw 2>/dev/null || true)
  if [[ -z "$OPENCLAW_BIN" ]]; then
    # Some npm installs place binaries under the npm global prefix/bin
    # (npm bin -g was deprecated in npm 9; use npm prefix -g instead)
    local npm_bin
    npm_bin=$(npm prefix -g 2>/dev/null || true)
    [[ -f "${npm_bin}/bin/openclaw" ]] && OPENCLAW_BIN="${npm_bin}/bin/openclaw"
  fi

  if [[ -z "$OPENCLAW_BIN" ]]; then
    err "openclaw binary not found in PATH after install."
    exit 1
  fi

  # Capture the full --help output into a temp file.
  # Using a temp file (rather than a pipe) avoids Commander.js EPIPE errors
  # that occur when the consumer (e.g. `head`) closes the pipe early.
  local tmp_help
  tmp_help=$(mktemp /tmp/openclaw-help.XXXXXX)
  "$OPENCLAW_BIN" --help > "$tmp_help" 2>&1 || true
  local help_out
  help_out=$(cat "$tmp_help")
  rm -f "$tmp_help"

  # Extract command names from the 'Commands:' section using awk.
  # awk handles both space- and tab-indented Commander.js output correctly;
  # the previous grep/tr/sed pipeline failed silently on tab-indented output
  # (tr -d ' ' does not remove tabs), causing gateway/daemon to not match.
  # Commander.js format: "  commandname[*]   description text"
  local all_cmds
  all_cmds=$(echo "$help_out" | awk '
    /^Commands:/          { in_cmds=1; next }
    in_cmds && /^[^ \t]/ { in_cmds=0 }
    in_cmds && /^[ \t]+[a-z]/ {
      cmd = $1; gsub(/[*]/, "", cmd)
      if (cmd ~ /^[a-z][a-z0-9-]+$/) print cmd
    }
  ' | sort -u)
  info "Detected OpenClaw commands: ${all_cmds:-(none)}"

  # Determine the subcommand used to start the gateway/web server.
  # --openclaw-cmd flag (OPENCLAW_CMD_OVERRIDE) takes precedence.
  # 'run' and 'launch' are excluded — they appear in help descriptions and
  # cause false positives ("error: unknown command 'run'").
  # 'gateway' is listed first as it is OpenClaw's canonical serve command.
  local subcmd="${OPENCLAW_CMD_OVERRIDE:-}"

  if [[ -z "$subcmd" ]]; then
    local candidates="gateway serve server start up daemon"
    local candidate
    for candidate in $candidates; do
      # grep -Fx: fixed-string + exact whole-line match; immune to regex
      # metacharacters and insensitive to leading/trailing whitespace.
      if echo "$all_cmds" | grep -qFx "$candidate"; then
        subcmd="$candidate"
        log "Server-start subcommand detected: '${subcmd}'"
        break
      fi
    done
  fi

  if [[ -z "$subcmd" ]]; then
    info "No server-start subcommand found — using bare invocation"
    info "Tip: re-run with --openclaw-cmd <name> to override"
  fi

  # Capture the subcommand's own --help for flag detection.
  # Port, config, and host flags are subcommand-specific in most CLIs;
  # probing only the top-level help gives wrong results (false positives
  # or misses). Use subcommand help preferentially; fall back to top-level.
  local sub_help=""
  if [[ -n "$subcmd" ]]; then
    local tmp_sub
    tmp_sub=$(mktemp /tmp/openclaw-sub-help.XXXXXX)
    "$OPENCLAW_BIN" "$subcmd" --help > "$tmp_sub" 2>&1 || true
    sub_help=$(cat "$tmp_sub")
    rm -f "$tmp_sub"
    [[ -n "$sub_help" ]] && info "Probed subcommand flags via: openclaw ${subcmd} --help"
  fi
  local probe_help="${sub_help:-$help_out}"

  # Extract only the Options: section from the help for flag detection.
  # This prevents false positives from flags mentioned in description text,
  # e.g. "use --port to configure" appearing in a command description line
  # would incorrectly trigger port_flag detection.
  # Commander.js Options section: lines starting with spaces after "Options:"
  local options_section
  options_section=$(echo "$probe_help" | awk '
    /^Options:/              { in_opts=1; next }
    in_opts && /^[^ \t]/    { in_opts=0 }
    in_opts                  { print }
  ')
  # Fall back to full help text if no Options section was found
  local flag_probe="${options_section:-$probe_help}"

  # All flag probing uses grep -qF -e PATTERN (fixed-string, explicit pattern).
  # This avoids both BRE '\-' warnings and ambiguity from patterns starting
  # with '--' that can confuse grep's argument parser on some systems.
  local cfg_flag=""
  if   echo "$flag_probe" | grep -qF -e '--config';    then cfg_flag="--config ${OPENCLAW_CONFIG_DIR}/config.json"
  elif echo "$flag_probe" | grep -qF -e '--workspace'; then cfg_flag="--workspace ${OPENCLAW_WORKSPACE_DIR}"
  fi

  # Determine port/token flags only when no config file flag is available.
  # NOTE: port/token are only added when truly absent from config — if the
  # tool reads a config.json, it already knows the port from there.
  local port_flag=""
  if [[ -z "$cfg_flag" ]]; then
    echo "$flag_probe" | grep -qF -e '--port'  && port_flag="--port ${GATEWAY_PORT}"
    echo "$flag_probe" | grep -qF -e '--token' && port_flag="${port_flag} --token ${GATEWAY_TOKEN}"
  fi

  # Determine host/bind flag — critical for remote network access.
  # Without this, most Node.js servers bind to 127.0.0.1 (localhost only).
  # Use -wF (word-match + fixed-string) to prevent matching substrings
  # (e.g. '--host' should not match '--hostname').
  local host_flag=""
  if   echo "$flag_probe" | grep -qwF -e '--host';    then host_flag="--host 0.0.0.0"
  elif echo "$flag_probe" | grep -qwF -e '--bind';    then host_flag="--bind 0.0.0.0"
  elif echo "$flag_probe" | grep -qwF -e '--address'; then host_flag="--address 0.0.0.0"
  elif echo "$flag_probe" | grep -qwF -e '--listen';  then host_flag="--listen 0.0.0.0"
  fi

  OPENCLAW_START_ARGS="${subcmd}${cfg_flag:+ ${cfg_flag}}${port_flag:+ ${port_flag}}${host_flag:+ ${host_flag}}"
  # Trim leading/trailing whitespace
  OPENCLAW_START_ARGS="${OPENCLAW_START_ARGS## }"; OPENCLAW_START_ARGS="${OPENCLAW_START_ARGS%% }"

  log "OpenClaw binary: ${OPENCLAW_BIN}"
  log "Startup command: ${OPENCLAW_BIN} ${OPENCLAW_START_ARGS:-<no args>}"
  [[ -n "$host_flag" ]] && log "Bind flag: ${host_flag} — remote access enabled via flag"
  [[ -z "$host_flag" ]] && info "No --host/--bind flag found; relying on OPENCLAW_HOST=0.0.0.0 env var"
}

install_openclaw() {
  banner "Installing OpenClaw"

  npm install -g @openclaw/cli 2>/dev/null \
    || npm install -g openclaw 2>/dev/null \
    || { err "Failed to install OpenClaw via npm. Check your npm registry."; exit 1; }

  log "OpenClaw installed: $(openclaw --version 2>/dev/null || echo 'version unknown')"

  detect_server_ip
  detect_openclaw_cmd

  # Scale MemoryMax to 75% of system RAM, clamped between 2G and 16G
  local mem_max_gb=$(( HW_RAM_GB * 3 / 4 ))
  [[ "$mem_max_gb" -lt 2  ]] && mem_max_gb=2
  [[ "$mem_max_gb" -gt 16 ]] && mem_max_gb=16
  local mem_max="${mem_max_gb}G"
  info "OpenClaw MemoryMax: ${mem_max} (based on ${HW_RAM_GB} GB RAM)"

  cat > /etc/systemd/system/openclaw.service <<EOF
[Unit]
Description=OpenClaw — Lonely RPG AI Session
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=${REAL_USER}
WorkingDirectory=${OPENCLAW_WORKSPACE_DIR}
Environment=HOME=${REAL_HOME}
Environment=OPENCLAW_PORT=${GATEWAY_PORT}
Environment=OPENCLAW_TOKEN=${GATEWAY_TOKEN}
Environment=OPENCLAW_HOST=0.0.0.0
Environment=HOST=0.0.0.0
Environment=BIND_ADDRESS=0.0.0.0
ExecStart=${OPENCLAW_BIN} ${OPENCLAW_START_ARGS}
Restart=on-failure
RestartSec=10
CPUQuota=80%
MemoryMax=${mem_max}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  log "Systemd service created: openclaw.service"
  log "ExecStart: ${OPENCLAW_BIN} ${OPENCLAW_START_ARGS}"
}

###############################################################################
# 7. CHARACTER SHEET HELPERS
###############################################################################

# Print a numbered menu and return the chosen value via REPLY
# Usage: prompt_choice "Prompt text" "opt1" "opt2" ...
prompt_choice() {
  local prompt="$1"; shift
  local options=("$@")
  local i reply

  ask "$prompt"
  for (( i=0; i<${#options[@]}; i++ )); do
    echo -e "    ${BOLD}$((i+1))${NC}) ${options[$i]}"
  done
  while true; do
    read -r -p "    Choice [1-${#options[@]}]: " reply
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#options[@]} )); then
      REPLY="${options[$((reply-1))]}"
      return
    fi
    warn "Invalid choice. Please enter a number between 1 and ${#options[@]}."
  done
}

# Write a blank player character sheet template
make_player_sheet() {
  local out="$1"
  cat > "$out" <<'SHEET'
{
  "type": "player",
  "name": "Aventureiro",
  "class": "Guerreiro",
  "race": "Humano",
  "level": 1,
  "xp": 0,
  "hp": { "current": 10, "max": 10 },
  "mp": { "current": 0, "max": 0 },
  "attributes": {
    "forca":        10,
    "destreza":     10,
    "constituicao": 10,
    "inteligencia": 10,
    "sabedoria":    10,
    "carisma":      10
  },
  "proficiencia": 2,
  "ca": 10,
  "iniciativa": 0,
  "velocidade": 9,
  "habilidades": [],
  "magias":      [],
  "inventario":  [],
  "moedas": { "po": 0, "pp": 0, "pe": 0, "pc": 0 },
  "historico": "",
  "tracos_personalidade": "",
  "ideais": "",
  "vinculos": "",
  "fraquezas": "",
  "notas": ""
}
SHEET
  log "Player sheet created: $out"
}

# Write a blank companion character sheet template
make_companion_sheet() {
  local out="$1" name="$2" class="$3" race="$4"
  cat > "$out" <<SHEET
{
  "type": "companion",
  "name": "${name}",
  "class": "${class}",
  "race": "${race}",
  "level": 1,
  "xp": 0,
  "hp": { "current": 10, "max": 10 },
  "mp": { "current": 0, "max": 0 },
  "attributes": {
    "forca":        10,
    "destreza":     10,
    "constituicao": 10,
    "inteligencia": 10,
    "sabedoria":    10,
    "carisma":      10
  },
  "proficiencia": 2,
  "ca": 10,
  "iniciativa": 0,
  "velocidade": 9,
  "habilidades": [],
  "magias":      [],
  "inventario":  [],
  "moedas": { "po": 0, "pp": 0, "pe": 0, "pc": 0 },
  "historico": "",
  "personalidade": "",
  "notas": ""
}
SHEET
  log "Companion sheet created: $out (${name} — ${class} ${race})"
}

# Write the Game Master's session state sheet
make_gm_sheet() {
  local out="$1"
  cat > "$out" <<'SHEET'
{
  "type": "game_master",
  "campanha": "Lonely RPG",
  "arco_atual": "Prólogo",
  "sessao": 1,
  "local_atual": "Vila de Início",
  "estado_mundo": "",
  "npcs_ativos": [],
  "quests_ativas": [],
  "quests_concluidas": [],
  "itens_especiais_distribuidos": [],
  "eventos_marcantes": [],
  "notas_secretas": "",
  "proximos_encontros": []
}
SHEET
  log "GM session sheet created: $out"
}

###############################################################################
# 8. CHARACTER SHEET SETUP  (interactive)
###############################################################################
setup_character_sheets() {
  banner "Character Sheets (Fichas de Personagem)"

  mkdir -p "${SHEETS_DIR}/party"

  # ── Player sheet ──────────────────────────────────────────────────────────
  local player_sheet="${SHEETS_DIR}/player.json"

  if [[ -f "$player_sheet" ]]; then
    local existing_name
    existing_name=$(jq -r '.name // "?"' "$player_sheet" 2>/dev/null || echo "?")
    ask "Ficha do jogador já existe: ${BOLD}${existing_name}${NC}"
    prompt_choice "O que deseja fazer?" \
      "Reutilizar ficha existente (${existing_name})" \
      "Criar nova ficha em branco"
    if [[ "$REPLY" == "Criar nova ficha em branco" ]]; then
      make_player_sheet "$player_sheet"
    else
      log "Reutilizando ficha do jogador: ${existing_name}"
    fi
  else
    make_player_sheet "$player_sheet"
  fi

  # ── GM sheet ──────────────────────────────────────────────────────────────
  local gm_sheet="${SHEETS_DIR}/game-master.json"

  if [[ -f "$gm_sheet" ]]; then
    local gm_campanha
    gm_campanha=$(jq -r '.campanha // "?"' "$gm_sheet" 2>/dev/null || echo "?")
    ask "Estado de campanha do Mestre já existe: ${BOLD}${gm_campanha}${NC}"
    prompt_choice "O que deseja fazer?" \
      "Reutilizar estado existente (${gm_campanha})" \
      "Reiniciar campanha (novo estado)"
    if [[ "$REPLY" == "Reiniciar campanha (novo estado)" ]]; then
      make_gm_sheet "$gm_sheet"
    else
      log "Reutilizando estado de campanha do Mestre"
    fi
  else
    make_gm_sheet "$gm_sheet"
  fi

  # ── Companion sheets ──────────────────────────────────────────────────────
  echo ""
  info "Configurando fichas dos companheiros da party..."
  echo ""

  # Default party: Guerreiro, Mago, Ladino
  declare -A DEFAULT_PARTY=(
    ["guerreiro"]="Thorin:Guerreiro:Anão"
    ["mago"]="Elara:Mago:Elfa"
    ["ladino"]="Sombra:Ladino:Halfling"
  )

  local slot
  for slot in guerreiro mago ladino; do
    local sheet_path="${SHEETS_DIR}/party/${slot}.json"
    local default_val="${DEFAULT_PARTY[$slot]}"
    local default_name default_class default_race
    IFS=: read -r default_name default_class default_race <<< "$default_val"

    if [[ -f "$sheet_path" ]]; then
      local existing_name existing_class
      existing_name=$(jq -r '.name  // "?"' "$sheet_path" 2>/dev/null || echo "?")
      existing_class=$(jq -r '.class // "?"' "$sheet_path" 2>/dev/null || echo "?")
      ask "Companheiro '${slot}' já tem ficha: ${BOLD}${existing_name} (${existing_class})${NC}"
      prompt_choice "O que deseja fazer?" \
        "Reutilizar ficha existente (${existing_name})" \
        "Criar nova ficha para ${slot}"
      if [[ "$REPLY" == "Criar nova ficha para ${slot}" ]]; then
        make_companion_sheet "$sheet_path" "$default_name" "$default_class" "$default_race"
      else
        log "Reutilizando ficha: ${existing_name}"
      fi
    else
      make_companion_sheet "$sheet_path" "$default_name" "$default_class" "$default_race"
    fi
  done

  chown -R "${REAL_USER}:${REAL_USER}" "${SHEETS_DIR}"
  chmod 700 "${SHEETS_DIR}"
  log "All character sheets ready under ${SHEETS_DIR}"
}

###############################################################################
# 9. CONFIGURE RPG WORKSPACE
###############################################################################
configure_rpg_workspace() {
  banner "Configuring Lonely RPG Workspace"

  mkdir -p "${OPENCLAW_WORKSPACE_DIR}"
  mkdir -p "${AGENTS_DIR}"

  # Generate (or reuse) access token; back up existing config if present
  if [[ -f "${OPENCLAW_CONFIG_DIR}/config.json" ]]; then
    local existing_token
    existing_token=$(jq -r '.gateway.auth_token // ""' "${OPENCLAW_CONFIG_DIR}/config.json" 2>/dev/null || true)
    if [[ -n "$existing_token" ]]; then
      GATEWAY_TOKEN="$existing_token"
      log "Reusing existing auth token"
    fi
    # Back up the existing config before overwriting
    cp "${OPENCLAW_CONFIG_DIR}/config.json" "${OPENCLAW_CONFIG_DIR}/config.json.bak"
    log "Config backed up: ${OPENCLAW_CONFIG_DIR}/config.json.bak"
  fi
  if [[ -z "$GATEWAY_TOKEN" ]]; then
    GATEWAY_TOKEN=$(openssl rand -hex 16 2>/dev/null \
      || head -c 16 /dev/urandom | xxd -p 2>/dev/null \
      || cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 32)
  fi

  # Build cors_origins: always allow localhost; also allow server LAN IP if known
  local cors_origins='"http://localhost:3000", "https://localhost", "http://localhost:'"${GATEWAY_PORT}"'"'
  if [[ -n "$SERVER_IP" && "$SERVER_IP" != "localhost" ]]; then
    cors_origins+=', "http://'"${SERVER_IP}:${GATEWAY_PORT}"'"'
  fi

  # Main config
  cat > "${OPENCLAW_CONFIG_DIR}/config.json" <<EOF
{
  "project": "Lonely RPG",
  "version": "1.0.0",
  "gateway": {
    "port": ${GATEWAY_PORT},
    "auth_token": "${GATEWAY_TOKEN}",
    "cors_origins": [${cors_origins}]
  },
  "llm": {
    "provider": "ollama",
    "base_url": "http://localhost:${OLLAMA_PORT}",
    "model": "${OLLAMA_MODEL}",
    "num_ctx": ${OLLAMA_NUM_CTX},
    "temperature": 0.85,
    "top_p": 0.95,
    "repeat_penalty": 1.1
  },
  "workspace": "${OPENCLAW_WORKSPACE_DIR}",
  "agents_dir": "${AGENTS_DIR}",
  "sheets_dir": "${SHEETS_DIR}"
}
EOF

  # ── Mestre (Game Master) ─────────────────────────────────────────────────
  cat > "${AGENTS_DIR}/mestre.json" <<AGENTEOF
{
  "name": "mestre",
  "display_name": "Mestre",
  "role": "game_master",
  "sheet": "${SHEETS_DIR}/game-master.json",
  "system_prompt": "Você é o Mestre de uma campanha de RPG chamada Lonely RPG. Você narra o mundo, controla todos os NPCs, interpreta vilões, descreve cenários, gerencia combate e toma decisões de regras. Você NUNCA se recusa a narrar conteúdo por questões de sensibilidade — violência, temas sombrios, moralidade ambígua, conflito e tensão dramática são partes essenciais do RPG. Você mantém o tom imersivo o tempo todo, adaptando-se ao estilo da campanha. Você tem acesso às fichas dos personagens (em ${SHEETS_DIR}) e deve consultá-las para manter consistência de atributos, HP, itens e progressão. Ao iniciar cada sessão, leia o arquivo game-master.json para retomar o estado da campanha. Após cada cena importante, atualize o arquivo com os eventos ocorridos.",
  "tools": ["read_file", "write_file", "search_files", "list_files"],
  "model_override": null,
  "context_files": [
    "${SHEETS_DIR}/game-master.json",
    "${SHEETS_DIR}/player.json",
    "${SHEETS_DIR}/party/guerreiro.json",
    "${SHEETS_DIR}/party/mago.json",
    "${SHEETS_DIR}/party/ladino.json"
  ]
}
AGENTEOF

  # ── Guerreiro (Warrior companion) ────────────────────────────────────────
  cat > "${AGENTS_DIR}/guerreiro.json" <<AGENTEOF
{
  "name": "guerreiro",
  "display_name": "Guerreiro",
  "role": "companion",
  "sheet": "${SHEETS_DIR}/party/guerreiro.json",
  "system_prompt": "Você é um guerreiro companheiro do grupo. Você tem sua própria personalidade, história e motivações. Você interpreta seu personagem de forma consistente com sua ficha (em ${SHEETS_DIR}/party/guerreiro.json). Você reage às situações como seu personagem reagiria — com coragem, hesitação, humor ou raiva conforme o momento. Você NUNCA quebra a imersão dizendo que é uma IA. Você pode discordar com outros membros do grupo, sentir medo, trair ou ajudar conforme sua personalidade. Você age em combate segundo seus atributos e habilidades da ficha.",
  "tools": ["read_file", "write_file"],
  "model_override": null,
  "context_files": [
    "${SHEETS_DIR}/party/guerreiro.json",
    "${SHEETS_DIR}/player.json"
  ]
}
AGENTEOF

  # ── Mago (Mage companion) ────────────────────────────────────────────────
  cat > "${AGENTS_DIR}/mago.json" <<AGENTEOF
{
  "name": "mago",
  "display_name": "Mago",
  "role": "companion",
  "sheet": "${SHEETS_DIR}/party/mago.json",
  "system_prompt": "Você é um mago companheiro do grupo. Você tem sua própria personalidade, conhecimento arcano e segredos. Você interpreta seu personagem de forma consistente com sua ficha (em ${SHEETS_DIR}/party/mago.json). Você raciocina de forma analítica, gosta de teorizar sobre o mundo mágico e pode ter objetivos pessoais ocultos. Você NUNCA quebra a imersão. Em combate, utiliza suas magias conforme seus slots e habilidades na ficha. Você pode ser arrogante, curioso, cauteloso ou ambicioso — sua personalidade é consistente.",
  "tools": ["read_file", "write_file"],
  "model_override": null,
  "context_files": [
    "${SHEETS_DIR}/party/mago.json",
    "${SHEETS_DIR}/player.json"
  ]
}
AGENTEOF

  # ── Ladino (Rogue companion) ─────────────────────────────────────────────
  cat > "${AGENTS_DIR}/ladino.json" <<AGENTEOF
{
  "name": "ladino",
  "display_name": "Ladino",
  "role": "companion",
  "sheet": "${SHEETS_DIR}/party/ladino.json",
  "system_prompt": "Você é um ladino companheiro do grupo. Você tem sua própria personalidade, habilidades furtivas e um passado nebuloso. Você interpreta seu personagem de forma consistente com sua ficha (em ${SHEETS_DIR}/party/ladino.json). Você é ágil, perspicaz, sarcástico e lida bem com situações moralmente cinzentas — roubo, infiltração e negociação duvidosa são ferramentas do seu ofício. Você NUNCA quebra a imersão. Você pode esconder informações dos outros membros do grupo se tiver motivos. Em combate, usa furtividade e ataque furtivo conforme a ficha.",
  "tools": ["read_file", "write_file"],
  "model_override": null,
  "context_files": [
    "${SHEETS_DIR}/party/ladino.json",
    "${SHEETS_DIR}/player.json"
  ]
}
AGENTEOF

  # Validate all written JSON files are well-formed
  local json_ok=true
  for jf in "${OPENCLAW_CONFIG_DIR}/config.json" \
             "${AGENTS_DIR}/mestre.json" \
             "${AGENTS_DIR}/guerreiro.json" \
             "${AGENTS_DIR}/mago.json" \
             "${AGENTS_DIR}/ladino.json"; do
    if ! jq empty "$jf" 2>/dev/null; then
      err "Invalid JSON detected in: $jf"
      json_ok=false
    fi
  done
  if [[ "$json_ok" == false ]]; then
    err "One or more config files contain invalid JSON. Check the errors above."
    exit 1
  fi

  # Fix permissions
  chown -R "${REAL_USER}:${REAL_USER}" "${OPENCLAW_CONFIG_DIR}"
  chmod 700 "${OPENCLAW_CONFIG_DIR}"
  chmod 600 "${OPENCLAW_CONFIG_DIR}/config.json"

  log "RPG workspace configured"
  log "Agents: mestre, guerreiro, mago, ladino"
  log "Config: ${OPENCLAW_CONFIG_DIR}/config.json"
}

###############################################################################
# 10. START OPENCLAW
###############################################################################

# Return 0 if the gateway is responding on a given host
_gateway_up_on() {
  local host="$1"
  local ep
  for ep in "/health" "/api/health" "/api/status" "/api" "/"; do
    if curl -sf --max-time 3 "http://${host}:${GATEWAY_PORT}${ep}" &>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Return 0 if the gateway is up locally (HTTP) or at least listening (TCP)
_gateway_up() {
  _gateway_up_on "localhost" && return 0
  _gateway_up_on "127.0.0.1" && return 0
  command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT}" && return 0
  return 1
}

# Rewrite ExecStart in the service file and reload systemd.
# Usage: _set_service_exec <full_exec_start_line>
_set_service_exec() {
  local exec_line="$1"
  local svc="/etc/systemd/system/openclaw.service"
  # Replace every ExecStart= line (clear any previous overrides too)
  sed -i "s|^ExecStart=.*|ExecStart=${exec_line}|g" "$svc"
  systemctl daemon-reload
}

# Wait up to <secs> for the gateway to respond OR the process to crash.
# Returns 0 if gateway came up, 1 if it crashed or timed out.
_wait_gateway() {
  local secs="${1:-30}" elapsed=0
  while [[ $elapsed -lt $secs ]]; do
    sleep 3; elapsed=$(( elapsed + 3 ))
    if _gateway_up; then return 0; fi
    # If systemd reports the process exited (failure), bail immediately
    # rather than waiting the full timeout on each fallback attempt.
    if ! systemctl is-active --quiet openclaw 2>/dev/null; then
      return 1
    fi
  done
  _gateway_up && return 0 || return 1
}

start_openclaw() {
  banner "Starting OpenClaw Service"

  systemctl enable openclaw
  systemctl restart openclaw

  # ── Primary attempt ──────────────────────────────────────────────────────
  info "Waiting for OpenClaw gateway (up to 90s)..."
  local retries=18 elapsed=0
  while [[ $retries -gt 0 ]]; do
    if _gateway_up; then break; fi
    sleep 5; elapsed=$(( elapsed + 5 ))
    (( retries-- )) || true
    (( elapsed % 15 == 0 )) && printf "  [%ds elapsed]\n" "$elapsed"
    # Bail early if we can already see a crash error in the logs
    if journalctl -u openclaw -n 5 --no-pager 2>/dev/null \
        | grep -qE "unknown option|unknown command|exit-code"; then
      warn "Crash detected in logs — switching to fallback commands"
      break
    fi
  done

  if _gateway_up; then
    _confirm_remote_access
    return
  fi

  # ── Auto-recovery: try progressively simpler startup commands ────────────
  # The CLI may reject flags that were auto-detected from help text (e.g.
  # --port is in a description sentence, not an actual option). Strip flags
  # one at a time until the service starts, or report failure.
  local bin="$OPENCLAW_BIN"
  local base_subcmd="${OPENCLAW_CMD_OVERRIDE:-gateway}"  # best known subcommand

  # Build fallback list: each entry is the argument string after the binary.
  # "gateway" reads port from config.json; bind address via env var fallback.
  local -a fallbacks=()

  # If current args have --port, try without it first
  if echo "$OPENCLAW_START_ARGS" | grep -qF -e '--port'; then
    local no_port="${OPENCLAW_START_ARGS//--port [0-9]*/}"
    no_port="${no_port## }"; no_port="${no_port%% }"
    fallbacks+=("$no_port")
  fi
  # If current args have extra flags, try subcommand alone
  [[ "${OPENCLAW_START_ARGS}" != "${base_subcmd}" ]] && fallbacks+=("${base_subcmd}")
  # Bare invocation (no subcommand, rely on config + env vars entirely)
  [[ "${OPENCLAW_START_ARGS}" != "" ]] && fallbacks+=("")

  local fb attempt=1
  for fb in "${fallbacks[@]}"; do
    local exec_line="${bin}${fb:+ ${fb}}"
    info "[Attempt $((attempt++))] Trying: ${exec_line}"

    systemctl stop openclaw 2>/dev/null || true
    sleep 2
    _set_service_exec "$exec_line"
    systemctl start openclaw

    if _wait_gateway 40; then
      log "Gateway is up with command: ${exec_line}"
      OPENCLAW_START_ARGS="$fb"
      _confirm_remote_access
      return
    fi

    warn "Command failed: ${exec_line}"
    journalctl -u openclaw -n 5 --no-pager 2>/dev/null | sed 's/^/  /' || true
  done

  # ── All fallbacks exhausted ───────────────────────────────────────────────
  warn "OpenClaw did not start after trying all startup variants."
  warn "Last log lines:"
  echo ""
  journalctl -u openclaw -n 30 --no-pager 2>/dev/null || true
  echo ""
  warn "Manual fix — find the correct command:"
  warn "  openclaw --help"
  warn "  openclaw gateway --help"
  warn "Then set it:"
  warn "  sudo systemctl edit openclaw"
  warn "  # Add:  [Service]"
  warn "  #        ExecStart="
  warn "  #        ExecStart=/usr/local/sbin/openclaw <correct-command>"
  warn "  sudo systemctl restart openclaw"
  warn ""
  warn "Or reinstall with the correct subcommand:"
  warn "  sudo ./openclaw-rpg-installer.sh --openclaw-cmd <name>"
}

# Verify remote reachability after the gateway is confirmed up locally.
_confirm_remote_access() {
  log "OpenClaw gateway is up on port ${GATEWAY_PORT}"
  if [[ -n "$SERVER_IP" && "$SERVER_IP" != "localhost" ]]; then
    if _gateway_up_on "$SERVER_IP"; then
      log "Remote access confirmed: http://${SERVER_IP}:${GATEWAY_PORT}"
    else
      warn "Gateway is UP locally but NOT reachable via ${SERVER_IP}:${GATEWAY_PORT}"
      warn "The service may be bound to 127.0.0.1 only."
      warn "Check: ss -tlnp | grep ${GATEWAY_PORT}  (should show 0.0.0.0, not 127.0.0.1)"
      warn "The systemd unit sets OPENCLAW_HOST=0.0.0.0 — restart may fix this:"
      warn "  lonely-rpg-ctl restart"
      warn "Firewall check:"
      warn "  sudo firewall-cmd --list-ports    (Fedora/RHEL)"
      warn "  sudo ufw status | grep ${GATEWAY_PORT}    (Ubuntu/Debian)"
    fi
  fi
}

###############################################################################
# 11. CONTROL SCRIPT  (lonely-rpg-ctl)
###############################################################################
install_ctl_script() {
  banner "Installing lonely-rpg-ctl"

  # Capture vars needed inside the heredoc
  local cfg_dir="$OPENCLAW_CONFIG_DIR"
  local sheets="$SHEETS_DIR"

  cat > "${CTL_PATH}" <<CTLEOF
#!/usr/bin/env bash
# lonely-rpg-ctl — manage Lonely RPG services

SERVICES=(ollama openclaw)
SHEETS_DIR="${sheets}"
CONFIG_DIR="${cfg_dir}"

case "\${1:-help}" in
  start)
    for svc in "\${SERVICES[@]}"; do
      systemctl start "\$svc" && echo "[OK] Started \$svc" || echo "[WARN] Could not start \$svc"
    done
    ;;
  stop)
    for svc in "\${SERVICES[@]}"; do
      systemctl stop "\$svc" && echo "[OK] Stopped \$svc" || echo "[WARN] Could not stop \$svc"
    done
    ;;
  restart)
    for svc in "\${SERVICES[@]}"; do
      systemctl restart "\$svc" && echo "[OK] Restarted \$svc" || echo "[WARN] Could not restart \$svc"
    done
    ;;
  status)
    for svc in "\${SERVICES[@]}"; do
      echo "--- \$svc ---"
      systemctl status "\$svc" --no-pager -l 2>/dev/null || true
    done
    ;;
  logs)
    journalctl -u openclaw -u ollama -f --no-pager
    ;;
  sheets)
    echo "=== Fichas de Personagem ==="
    echo ""
    echo "Jogador:"
    if [[ -f "\${SHEETS_DIR}/player.json" ]]; then
      n=\$(jq -r '.name  // "?"' "\${SHEETS_DIR}/player.json" 2>/dev/null)
      c=\$(jq -r '.class // "?"' "\${SHEETS_DIR}/player.json" 2>/dev/null)
      l=\$(jq -r '.level // "?"' "\${SHEETS_DIR}/player.json" 2>/dev/null)
      echo "  \${n} — \${c} Nível \${l}"
    fi
    echo ""
    echo "Party:"
    for f in "\${SHEETS_DIR}"/party/*.json; do
      [[ -f "\$f" ]] || continue
      n=\$(jq -r '.name  // "?"' "\$f" 2>/dev/null)
      c=\$(jq -r '.class // "?"' "\$f" 2>/dev/null)
      l=\$(jq -r '.level // "?"' "\$f" 2>/dev/null)
      echo "  \${n} — \${c} Nível \${l}  (\$(basename "\$f" .json))"
    done
    echo ""
    echo "Mestre (estado da campanha):"
    if [[ -f "\${SHEETS_DIR}/game-master.json" ]]; then
      arc=\$(jq -r '.arco_atual // "?"' "\${SHEETS_DIR}/game-master.json" 2>/dev/null)
      ses=\$(jq -r '.sessao    // "?"' "\${SHEETS_DIR}/game-master.json" 2>/dev/null)
      echo "  Arco: \${arc} | Sessão: \${ses}"
    fi
    ;;
  sheet)
    target="\${2:-}"
    if [[ -z "\$target" ]]; then
      echo "Usage: lonely-rpg-ctl sheet <player|guerreiro|mago|ladino|mestre>"
      exit 1
    fi
    case "\$target" in
      player)  jq . "\${SHEETS_DIR}/player.json" 2>/dev/null || echo "Sheet not found." ;;
      mestre)  jq . "\${SHEETS_DIR}/game-master.json" 2>/dev/null || echo "Sheet not found." ;;
      *)       jq . "\${SHEETS_DIR}/party/\${target}.json" 2>/dev/null || echo "Sheet not found: \$target" ;;
    esac
    ;;
  agents)
    echo "Configured agents:"
    ls "\${CONFIG_DIR}/agents/"*.json 2>/dev/null \
      | xargs -I{} bash -c 'echo "  - \$(jq -r .display_name {} 2>/dev/null) (\$(basename {} .json))"'
    ;;
  *)
    echo "Usage: lonely-rpg-ctl {start|stop|restart|status|logs|sheets|sheet <name>|agents}"
    echo ""
    echo "Commands:"
    echo "  start         — Start all Lonely RPG services"
    echo "  stop          — Stop all services (frees resources)"
    echo "  restart       — Restart all services"
    echo "  status        — Show service status"
    echo "  logs          — Tail live logs from all services"
    echo "  sheets        — List all character sheets with summary"
    echo "  sheet <name>  — Show full JSON sheet (player|guerreiro|mago|ladino|mestre)"
    echo "  agents        — List configured AI agents"
    ;;
esac
CTLEOF

  chmod +x "${CTL_PATH}"
  log "Installed: ${CTL_PATH}"
}

###############################################################################
# 12. FIREWALL
###############################################################################
configure_firewall() {
  banner "Configuring Firewall"

  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${GATEWAY_PORT}/tcp" comment "OpenClaw - Lonely RPG" 2>/dev/null || true
    ufw allow "${HTTPS_PORT}/tcp"   comment "HTTPS - Lonely RPG"    2>/dev/null || true
    log "ufw: ports ${GATEWAY_PORT} and ${HTTPS_PORT} opened"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${GATEWAY_PORT}/tcp" 2>/dev/null || true
    firewall-cmd --permanent --add-port="${HTTPS_PORT}/tcp"   2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log "firewalld: ports ${GATEWAY_PORT} and ${HTTPS_PORT} opened"
  else
    warn "No active firewall detected — skipping firewall configuration"
  fi
}

###############################################################################
# 13. UNINSTALL
###############################################################################
uninstall() {
  banner "Desinstalação do Lonely RPG"

  # ── Perguntar o modo de desinstalação ────────────────────────────────────
  echo -e "  Escolha o que deseja remover:\n"
  echo -e "  ${BOLD}1)${NC} ${GREEN}Desinstalação parcial${NC}"
  echo -e "     Remove: serviço OpenClaw, lonely-rpg-ctl, pacote npm"
  echo -e "     Mantém: fichas de personagem, configuração, Ollama e modelos\n"

  echo -e "  ${BOLD}2)${NC} ${YELLOW}Desinstalação completa${NC}"
  echo -e "     Remove tudo acima, mais:"
  echo -e "       • Fichas de personagem e configuração (~/.openclaw)"
  echo -e "       • Ollama (binário + serviço systemd)"
  echo -e "       • Modelos LLM baixados (~/.ollama  —  pode ser grande!)\n"

  echo -e "  ${BOLD}3)${NC} ${RED}Restaurar o OS ao estado anterior à instalação${NC}"
  echo -e "     Remove tudo acima, mais:"
  echo -e "       • Node.js (se instalado por este script via NodeSource)"
  echo -e "       • Pacotes de sistema instalados (curl git jq openssl)\n"

  local uninstall_mode=""
  while true; do
    read -r -p "  Escolha [1-3] ou Enter para cancelar: " uninstall_mode
    [[ -z "$uninstall_mode" ]] && { info "Desinstalação cancelada."; exit 0; }
    [[ "$uninstall_mode" =~ ^[123]$ ]] && break
    warn "Opção inválida. Digite 1, 2 ou 3."
  done

  # Confirmação extra para modos destrutivos
  if [[ "$uninstall_mode" =~ ^[23]$ ]]; then
    local label
    [[ "$uninstall_mode" == "2" ]] && label="COMPLETA (fichas + Ollama + modelos)"
    [[ "$uninstall_mode" == "3" ]] && label="TOTAL — restaurar OS ao estado anterior"
    echo ""
    warn "Você escolheu desinstalação ${label}."
    warn "Esta operação NÃO pode ser desfeita."
    read -r -p "  Digite 'sim' para confirmar: " confirm
    if [[ "$confirm" != "sim" ]]; then
      info "Desinstalação cancelada."
      exit 0
    fi
  fi

  echo ""

  # ── Etapa 1 (comum a todos os modos): OpenClaw ───────────────────────────
  info "Parando e removendo OpenClaw..."
  systemctl stop openclaw    2>/dev/null || true
  systemctl disable openclaw 2>/dev/null || true
  rm -f /etc/systemd/system/openclaw.service
  systemctl daemon-reload    2>/dev/null || true

  # Find and remove the openclaw npm package — try every known package name
  local npm_pkg
  for npm_pkg in "@openclaw/cli" "openclaw" "@openclaw/openclaw"; do
    if npm list -g --depth=0 2>/dev/null | grep -q "${npm_pkg}"; then
      npm uninstall -g "${npm_pkg}" 2>/dev/null && break
    fi
  done

  # Also remove the binary directly if it still exists
  local oc_bin
  oc_bin=$(command -v openclaw 2>/dev/null || true)
  [[ -n "$oc_bin" ]] && rm -f "$oc_bin" && log "Removed binary: ${oc_bin}"

  rm -f "${CTL_PATH}"
  log "OpenClaw removido"

  # ── Etapa 2+: fichas, config e Ollama ────────────────────────────────────
  if [[ "$uninstall_mode" -ge 2 ]]; then

    # Fichas e configuração
    if [[ -d "${OPENCLAW_CONFIG_DIR}" ]]; then
      rm -rf "${OPENCLAW_CONFIG_DIR}"
      log "Fichas e configuração removidas: ${OPENCLAW_CONFIG_DIR}"
    fi

    # Ollama — serviço
    info "Parando e removendo Ollama..."
    systemctl stop ollama    2>/dev/null || true
    systemctl disable ollama 2>/dev/null || true
    rm -f /etc/systemd/system/ollama.service \
          /usr/local/lib/systemd/system/ollama.service \
          /lib/systemd/system/ollama.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    # Ollama — binário
    rm -f /usr/local/bin/ollama /usr/bin/ollama 2>/dev/null || true

    # Modelos LLM (pode ocupar dezenas de GB)
    local ollama_home="${REAL_HOME}/.ollama"
    if [[ -d "$ollama_home" ]]; then
      local size
      size=$(du -sh "$ollama_home" 2>/dev/null | cut -f1 || echo "?")
      info "Removendo modelos LLM em ${ollama_home} (${size})..."
      rm -rf "$ollama_home"
      log "Modelos e dados do Ollama removidos (${size} liberados)"
    fi

    # Usuário ollama (criado pelo instalador oficial)
    if id ollama &>/dev/null; then
      userdel -r ollama 2>/dev/null || userdel ollama 2>/dev/null || true
      log "Usuário do sistema 'ollama' removido"
    fi

    log "Ollama completamente removido"
  fi

  # ── Etapa 3: Node.js e pacotes do sistema ────────────────────────────────
  if [[ "$uninstall_mode" -ge 3 ]]; then

    # Detectar gerenciador de pacotes
    local pkg_mgr="unknown"
    if command -v apt-get &>/dev/null; then pkg_mgr="apt"
    elif command -v dnf &>/dev/null;    then pkg_mgr="dnf"
    fi

    # Node.js
    info "Removendo Node.js..."
    if [[ "$pkg_mgr" == "apt" ]]; then
      apt-get remove -y nodejs npm 2>/dev/null || true
      apt-get autoremove -y       2>/dev/null || true
      rm -f /etc/apt/sources.list.d/nodesource.list \
            /etc/apt/sources.list.d/nodesource.list.save \
            /usr/share/keyrings/nodesource.gpg 2>/dev/null || true
      apt-get update -qq 2>/dev/null || true
    elif [[ "$pkg_mgr" == "dnf" ]]; then
      dnf remove -y nodejs npm 2>/dev/null || true
      rm -f /etc/yum.repos.d/nodesource*.repo 2>/dev/null || true
    fi
    rm -rf /usr/local/lib/node_modules 2>/dev/null || true
    log "Node.js removido"

    # Pacotes de sistema instalados pelo script
    info "Removendo pacotes de sistema (curl, git, jq, openssl)..."
    local sys_pkgs=(jq)   # removemos apenas o que é menos comum
    # curl, git e openssl provavelmente existiam antes — mantemos por segurança
    if [[ "$pkg_mgr" == "apt" ]]; then
      apt-get remove -y "${sys_pkgs[@]}" 2>/dev/null || true
      apt-get autoremove -y              2>/dev/null || true
    elif [[ "$pkg_mgr" == "dnf" ]]; then
      dnf remove -y "${sys_pkgs[@]}" 2>/dev/null || true
    fi
    log "Pacotes de sistema removidos"

    # npm global cache / prefix
    rm -rf "${REAL_HOME}/.npm" "${REAL_HOME}/.npmrc" 2>/dev/null || true
    log "Cache npm removido"
  fi

  # ── Resumo ────────────────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}${GREEN}=======================================${NC}"
  echo -e "${BOLD}${GREEN}  Desinstalação concluída${NC}"
  echo -e "${BOLD}${GREEN}=======================================${NC}"
  echo ""

  case "$uninstall_mode" in
    1)
      log "OpenClaw e lonely-rpg-ctl removidos"
      info "Fichas mantidas em:  ${OPENCLAW_CONFIG_DIR}"
      info "Ollama mantido   —  modelos disponíveis via: ollama list"
      ;;
    2)
      log "OpenClaw, Ollama, modelos e fichas removidos"
      info "Node.js e pacotes de sistema foram mantidos"
      ;;
    3)
      log "Sistema restaurado ao estado anterior à instalação"
      info "curl, git e openssl foram preservados (provavelmente preexistentes)"
      ;;
  esac
  echo ""
}

###############################################################################
# 14. SUMMARY
###############################################################################
print_summary() {
  local player_name="?"
  [[ -f "${SHEETS_DIR}/player.json" ]] && \
    player_name=$(jq -r '.name // "?"' "${SHEETS_DIR}/player.json" 2>/dev/null || echo "?")

  # Ensure SERVER_IP is populated (reconfigure mode skips detect_server_ip)
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$SERVER_IP" ]] && SERVER_IP="localhost"
  fi

  local url_local="http://localhost:${GATEWAY_PORT}"
  local url_remote="http://${SERVER_IP}:${GATEWAY_PORT}"

  echo ""
  echo -e "${BOLD}${GREEN}==========================================${NC}"
  echo -e "${BOLD}${GREEN}  Lonely RPG — Pronto para Aventura!${NC}"
  echo -e "${BOLD}${GREEN}==========================================${NC}"
  echo ""
  echo -e "  ${BOLD}Modelo LLM:${NC}   ${OLLAMA_MODEL} (tier: ${HW_TIER})"
  echo ""
  echo -e "  ${BOLD}── Acesso no Browser ──────────────────────────────${NC}"
  echo -e "  Na própria máquina:  ${CYAN}${url_local}${NC}"
  echo -e "  De outro dispositivo: ${CYAN}${url_remote}${NC}"
  echo ""
  echo -e "  ${BOLD}Token de acesso:${NC}  ${YELLOW}${GATEWAY_TOKEN}${NC}"
  echo ""
  echo -e "  ${DIM}Como usar: abra a URL no browser e, quando solicitado,${NC}"
  echo -e "  ${DIM}cole o token acima. Ou acesse diretamente com:${NC}"
  echo -e "  ${DIM}  ${url_remote}/?token=${GATEWAY_TOKEN}${NC}"
  echo ""
  echo -e "  ${BOLD}── Teste rápido via curl ──────────────────────────${NC}"
  echo -e "  ${DIM}curl -H 'Authorization: Bearer ${GATEWAY_TOKEN}' ${url_local}/health${NC}"
  echo ""
  echo -e "  ${BOLD}── Personagens ────────────────────────────────────${NC}"
  echo -e "  Jogador:   ${player_name}"
  echo -e "  ${CYAN}⚔${NC}  Guerreiro  — $(jq -r '.name // "Thorin"' "${SHEETS_DIR}/party/guerreiro.json" 2>/dev/null)"
  echo -e "  ${CYAN}✦${NC}  Mago       — $(jq -r '.name // "Elara"'  "${SHEETS_DIR}/party/mago.json"      2>/dev/null)"
  echo -e "  ${CYAN}◈${NC}  Ladino     — $(jq -r '.name // "Sombra"' "${SHEETS_DIR}/party/ladino.json"    2>/dev/null)"
  echo ""
  echo -e "  ${BOLD}── Gerenciar ───────────────────────────────────────${NC}"
  echo -e "    lonely-rpg-ctl start | stop | restart | status | logs"
  echo -e "    lonely-rpg-ctl sheets"
  echo -e "    lonely-rpg-ctl sheet <player|guerreiro|mago|ladino|mestre>"
  echo ""
  echo -e "  ${DIM}Fichas:  ${SHEETS_DIR}/${NC}"
  echo -e "  ${DIM}Config:  ${OPENCLAW_CONFIG_DIR}/config.json${NC}"
  echo -e "  ${DIM}Reconfigurar: sudo ./openclaw-rpg-installer.sh --reconfigure${NC}"
  echo ""
  echo -e "  ${BOLD}── Se não conseguir conectar no browser ────────────${NC}"
  echo -e "  ${DIM}1. Verifique se o serviço está rodando:${NC}"
  echo -e "  ${DIM}     systemctl status openclaw${NC}"
  echo -e "  ${DIM}2. Confirme em qual IP/porta o serviço está ouvindo:${NC}"
  echo -e "  ${DIM}     ss -tlnp | grep ${GATEWAY_PORT}${NC}"
  echo -e "  ${DIM}   Deve mostrar 0.0.0.0:${GATEWAY_PORT}, não 127.0.0.1:${GATEWAY_PORT}${NC}"
  echo -e "  ${DIM}3. Teste localmente no servidor:${NC}"
  echo -e "  ${DIM}     curl -s http://localhost:${GATEWAY_PORT}/health${NC}"
  echo -e "  ${DIM}4. Verifique o firewall:${NC}"
  echo -e "  ${DIM}     ufw status | grep ${GATEWAY_PORT}          (Ubuntu/Debian)${NC}"
  echo -e "  ${DIM}     firewall-cmd --list-ports               (Fedora/RHEL)${NC}"
  echo -e "  ${DIM}5. Veja os logs do serviço:${NC}"
  echo -e "  ${DIM}     journalctl -u openclaw -n 50 --no-pager${NC}"
  echo ""
}

###############################################################################
# MAIN
###############################################################################
main() {
  # Parse arguments
  MODE="install"
  local i=1
  while [[ $i -le $# ]]; do
    arg="${!i}"
    case "$arg" in
      --uninstall|-u)    MODE="uninstall" ;;
      --reconfigure|-r)  MODE="reconfigure" ;;
      --model)
        i=$(( i + 1 ))
        if [[ $i -gt $# ]]; then
          err "--model requires a model name (e.g. --model dolphin-mistral:7b)"
          exit 1
        fi
        OLLAMA_MODEL="${!i}"
        ;;
      --model=*)
        OLLAMA_MODEL="${arg#--model=}"
        ;;
      --openclaw-cmd)
        i=$(( i + 1 ))
        if [[ $i -gt $# ]]; then
          err "--openclaw-cmd requires a subcommand name (e.g. --openclaw-cmd serve)"
          exit 1
        fi
        OPENCLAW_CMD_OVERRIDE="${!i}"
        ;;
      --openclaw-cmd=*)
        OPENCLAW_CMD_OVERRIDE="${arg#--openclaw-cmd=}"
        ;;
      --help|-h)
        echo "Usage: sudo $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  (none)               Full install: deps, Ollama, OpenClaw, party setup"
        echo "  --reconfigure        Reconfigure party, agents and character sheets only"
        echo "                       (skips system/Ollama/OpenClaw reinstall)"
        echo "  --uninstall          Remove OpenClaw service and lonely-rpg-ctl"
        echo "  --model <name>       Override automatic model selection"
        echo "                       (e.g. --model dolphin-mistral:7b)"
        echo "  --openclaw-cmd <cmd> Override OpenClaw startup subcommand"
        echo "                       (e.g. --openclaw-cmd serve)"
        echo "                       Run 'openclaw --help' to see available commands"
        echo "  --help               Show this help message"
        echo ""
        echo "After installation, use 'lonely-rpg-ctl' to manage services."
        echo ""
        echo "LLM Models (Dolphin series — unrestricted for RPG immersion):"
        echo "  tinydolphin         < 4 GB  (1.1B)"
        echo "  dolphin-phi          4-8 GB  (2.7B)"
        echo "  dolphin-mistral:7b   8-16 GB (7B)"
        echo "  dolphin-llama3:8b   16-32 GB (8B)"
        echo "  dolphin-llama3:70b  32+ GB  (70B)"
        exit 0
        ;;
    esac
    i=$(( i + 1 ))
  done

  case "$MODE" in

    uninstall)
      uninstall
      exit 0
      ;;

    reconfigure)
      banner "Lonely RPG — Reconfiguring Party & Sheets"
      echo -e "  Started: $(date)"
      echo ""

      # We still need REAL_USER vars and config dir to exist
      if [[ ! -f "${OPENCLAW_CONFIG_DIR}/config.json" ]]; then
        err "No existing installation found at ${OPENCLAW_CONFIG_DIR}"
        err "Run a full install first: sudo $0"
        exit 1
      fi

      # Reload model from existing config so summary is correct
      OLLAMA_MODEL=$(jq -r '.llm.model // "unknown"' "${OPENCLAW_CONFIG_DIR}/config.json" 2>/dev/null || echo "unknown")
      HW_TIER="existing"

      detect_server_ip

      setup_character_sheets
      configure_rpg_workspace
      install_ctl_script

      # Restart service to pick up new agent configs
      if systemctl is-active --quiet openclaw 2>/dev/null; then
        systemctl restart openclaw
        log "OpenClaw service restarted with new configuration"
      fi

      print_summary
      echo -e "  Finished: $(date)"
      ;;

    install)
      banner "Lonely RPG — OpenClaw Installer"
      echo -e "  Started: $(date)"
      echo ""

      detect_distro
      install_system_deps
      install_nodejs
      detect_hardware
      install_ollama
      install_openclaw
      setup_character_sheets
      configure_rpg_workspace
      start_openclaw
      install_ctl_script
      configure_firewall
      print_summary

      echo -e "  Finished: $(date)"
      ;;

  esac
}

main "$@"
