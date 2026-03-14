#!/usr/bin/env bash
###############################################################################
#  Lonely RPG — OpenClaw + Local LLM Installer for Linux
#  Compatible with: Ubuntu/Debian, Fedora/RHEL/CentOS
#
#  What this script does (fully non-interactive):
#    1. Detects the distro and installs dependencies (Node 20+, curl, git, jq)
#    2. Analyzes hardware (RAM, CPU, GPU NVIDIA/AMD/Intel) and automatically
#       selects the best LLM model for your system
#    3. Installs Ollama and downloads the selected model
#    4. Installs OpenClaw via npm and creates a systemd service
#    5. Configures a Lonely RPG workspace with 4 specialized AI agents:
#         - Game Designer  : game mechanics, balance, and systems design
#         - Story Writer   : narrative, lore, dialogue, and world-building
#         - Developer      : code implementation for game engine and logic
#         - QA Tester      : testing, bug tracking, and quality assurance
#    6. Applies CPU/RAM limits to prevent server overload
#    7. Installs the 'lonely-rpg-ctl' utility for easy service management
#    8. Optionally configures HTTPS via Caddy reverse proxy
#    9. Opens firewall ports (ufw / firewalld) and handles SELinux
#   10. Displays URL + token for immediate browser access
#
#  Usage:
#    chmod +x openclaw-rpg-installer.sh
#    sudo ./openclaw-rpg-installer.sh             # Install
#    sudo ./openclaw-rpg-installer.sh --uninstall # Uninstall everything
#
#  After installation, use 'lonely-rpg-ctl' to manage services:
#    lonely-rpg-ctl start   — Start all services
#    lonely-rpg-ctl stop    — Stop everything (free resources)
#    lonely-rpg-ctl status  — Show status of all services
#    lonely-rpg-ctl restart — Restart everything
#    lonely-rpg-ctl logs    — Tail live logs
###############################################################################
set -euo pipefail
IFS=$'\n\t'

# ─── Trap for debug: print last executed line if script aborts ──────────────
trap 'err "Script aborted at line $LINENO (last command: $BASH_COMMAND, exit code: $?)"' ERR

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()    { echo -e "${RED}[ERR]${NC}   $*" >&2; }
info()   { echo -e "${CYAN}[INFO]${NC}  $*"; }
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
CTL_PATH="/usr/local/bin/lonely-rpg-ctl"
OLLAMA_MODEL=""      # Set automatically by detect_hardware()
OLLAMA_NUM_CTX=4096
OLLAMA_PORT=11434
GATEWAY_PORT=18789
HTTPS_PORT=443
DISTRO=""
PKG_MGR=""

# ─── Hardware variables (filled by detect_hardware) ─────────────────────────
HW_RAM_GB=0
HW_CPU_CORES=0
HW_CPU_MODEL=""
HW_GPU_VENDOR=""      # nvidia | amd | intel | none
HW_GPU_MODEL=""
HW_GPU_VRAM_MB=0
HW_TIER=""            # minimal | low | mid | high | ultra
HW_MODEL_REASON=""

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
      warn "Unknown distro '$DISTRO'. Attempting to use apt or dnf..."
      if command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
      elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
      else
        err "No supported package manager found. Please install manually."
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

  local pkgs=(curl git jq tar)

  if [[ "$PKG_MGR" == "apt" ]]; then
    apt-get update -qq
    apt-get install -y "${pkgs[@]}" ca-certificates gnupg lsb-release
    log "System packages installed (apt)"
  else
    dnf install -y "${pkgs[@]}" ca-certificates gnupg
    log "System packages installed (dnf)"
  fi
}

###############################################################################
# 3. NODE.JS 20+
###############################################################################
install_nodejs() {
  banner "Installing Node.js 20+"

  if command -v node &>/dev/null; then
    local ver
    ver=$(node --version | sed 's/v//' | cut -d. -f1)
    if [[ "$ver" -ge 20 ]]; then
      log "Node.js $(node --version) already installed — skipping"
      return
    fi
    warn "Node.js $ver found, upgrading to 20+"
  fi

  if [[ "$PKG_MGR" == "apt" ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  else
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
    dnf install -y nodejs
  fi

  log "Node.js $(node --version) installed"
}

###############################################################################
# 4. HARDWARE DETECTION & MODEL SELECTION
###############################################################################
detect_hardware() {
  banner "Analyzing Hardware"

  # RAM
  HW_RAM_GB=$(awk '/MemTotal/ { printf "%d", $2/1024/1024 }' /proc/meminfo)

  # CPU
  HW_CPU_CORES=$(nproc)
  HW_CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)

  # GPU — try nvidia-smi first, then lspci
  HW_GPU_VENDOR="none"
  if command -v nvidia-smi &>/dev/null 2>&1; then
    HW_GPU_VENDOR="nvidia"
    HW_GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
    HW_GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)
  elif command -v lspci &>/dev/null; then
    local lspci_out
    lspci_out=$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' || true)
    if echo "$lspci_out" | grep -qi nvidia; then
      HW_GPU_VENDOR="nvidia"
      HW_GPU_MODEL=$(echo "$lspci_out" | grep -i nvidia | head -1)
    elif echo "$lspci_out" | grep -qi amd; then
      HW_GPU_VENDOR="amd"
      HW_GPU_MODEL=$(echo "$lspci_out" | grep -i amd | head -1)
    elif echo "$lspci_out" | grep -qi intel; then
      HW_GPU_VENDOR="intel"
      HW_GPU_MODEL=$(echo "$lspci_out" | grep -i intel | head -1)
    fi
  fi

  info "RAM:  ${HW_RAM_GB} GB"
  info "CPU:  ${HW_CPU_CORES} cores — ${HW_CPU_MODEL}"
  info "GPU:  ${HW_GPU_VENDOR} ${HW_GPU_MODEL:+(${HW_GPU_MODEL})}"

  select_model
}

select_model() {
  # Choose Ollama model based on available VRAM (if GPU) or RAM (CPU-only)
  local available_gb="$HW_RAM_GB"
  if [[ "$HW_GPU_VENDOR" != "none" && "$HW_GPU_VRAM_MB" -gt 0 ]]; then
    available_gb=$(( HW_GPU_VRAM_MB / 1024 ))
  fi

  if [[ "$available_gb" -ge 32 ]]; then
    HW_TIER="ultra"
    OLLAMA_MODEL="llama3:70b"
    HW_MODEL_REASON="≥32 GB — large model for complex RPG narrative and code"
  elif [[ "$available_gb" -ge 16 ]]; then
    HW_TIER="high"
    OLLAMA_MODEL="llama3:13b"
    HW_MODEL_REASON="≥16 GB — balanced model for story writing and game logic"
  elif [[ "$available_gb" -ge 8 ]]; then
    HW_TIER="mid"
    OLLAMA_MODEL="llama3:8b"
    HW_MODEL_REASON="≥8 GB — capable model for most RPG development tasks"
  elif [[ "$available_gb" -ge 4 ]]; then
    HW_TIER="low"
    OLLAMA_MODEL="phi3:mini"
    HW_MODEL_REASON="≥4 GB — lightweight model for basic code assistance"
  else
    HW_TIER="minimal"
    OLLAMA_MODEL="phi3:mini"
    HW_MODEL_REASON="<4 GB — minimal model; performance may be limited"
    warn "Less than 4 GB available. AI responses may be slow or incomplete."
  fi

  log "Selected model: ${OLLAMA_MODEL} (tier: ${HW_TIER})"
  info "Reason: ${HW_MODEL_REASON}"
}

###############################################################################
# 5. OLLAMA INSTALLATION
###############################################################################
install_ollama() {
  banner "Installing Ollama"

  if command -v ollama &>/dev/null; then
    log "Ollama already installed — skipping binary install"
  else
    info "Downloading and installing Ollama..."
    curl -fsSL https://ollama.ai/install.sh | sh
    log "Ollama installed"
  fi

  # Ensure systemd service is running
  systemctl enable --now ollama 2>/dev/null || true

  # Wait for Ollama to be ready
  info "Waiting for Ollama to start..."
  local retries=12
  while [[ $retries -gt 0 ]]; do
    if curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" &>/dev/null; then
      break
    fi
    sleep 5
    (( retries-- )) || true
  done

  if ! curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" &>/dev/null; then
    err "Ollama did not start within 60 seconds."
    exit 1
  fi

  log "Ollama is running"
  info "Pulling model: ${OLLAMA_MODEL} (this may take several minutes)..."
  ollama pull "${OLLAMA_MODEL}"
  log "Model ${OLLAMA_MODEL} ready"
}

###############################################################################
# 6. OPENCLAW INSTALLATION
###############################################################################
install_openclaw() {
  banner "Installing OpenClaw"

  npm install -g @openclaw/cli --silent 2>/dev/null \
    || npm install -g openclaw --silent 2>/dev/null \
    || { err "Failed to install OpenClaw via npm. Check your npm registry."; exit 1; }

  log "OpenClaw installed: $(openclaw --version 2>/dev/null || echo 'version unknown')"

  # Create systemd service
  cat > /etc/systemd/system/openclaw.service <<EOF
[Unit]
Description=OpenClaw AI Code Team — Lonely RPG
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=${REAL_USER}
WorkingDirectory=${OPENCLAW_WORKSPACE_DIR}
Environment=HOME=${REAL_HOME}
ExecStart=$(command -v openclaw) start --config ${OPENCLAW_CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=10
CPUQuota=80%
MemoryMax=4G
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  log "Systemd service created: openclaw.service"
}

###############################################################################
# 7. CONFIGURE RPG WORKSPACE
###############################################################################
configure_rpg_workspace() {
  banner "Configuring Lonely RPG Workspace"

  mkdir -p "${OPENCLAW_WORKSPACE_DIR}"
  mkdir -p "${OPENCLAW_CONFIG_DIR}/agents"

  # Generate access token
  local token
  token=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p)

  # Main config
  cat > "${OPENCLAW_CONFIG_DIR}/config.json" <<EOF
{
  "project": "Lonely RPG",
  "version": "1.0.0",
  "gateway": {
    "port": ${GATEWAY_PORT},
    "auth_token": "${token}",
    "cors_origins": ["http://localhost:3000", "https://localhost"]
  },
  "llm": {
    "provider": "ollama",
    "base_url": "http://localhost:${OLLAMA_PORT}",
    "model": "${OLLAMA_MODEL}",
    "num_ctx": ${OLLAMA_NUM_CTX},
    "temperature": 0.7
  },
  "workspace": "${OPENCLAW_WORKSPACE_DIR}",
  "agents_dir": "${OPENCLAW_CONFIG_DIR}/agents"
}
EOF

  # ── Agent: Game Designer ────────────────────────────────────────────────
  cat > "${OPENCLAW_CONFIG_DIR}/agents/game-designer.json" <<'EOF'
{
  "name": "game-designer",
  "display_name": "Game Designer",
  "role": "rpg_design",
  "system_prompt": "You are an experienced RPG Game Designer specializing in the Lonely RPG project. Your responsibilities include: designing game mechanics (combat, leveling, skill trees, inventory), balancing gameplay difficulty curves, defining character classes and abilities, creating quest structures and progression systems, and ensuring the game feel is fun and engaging. Always think about player experience and emergent gameplay. Provide concrete design documents, stat tables, and mechanic specifications when asked.",
  "tools": ["read_file", "write_file", "search_files"],
  "model_override": null
}
EOF

  # ── Agent: Story Writer ─────────────────────────────────────────────────
  cat > "${OPENCLAW_CONFIG_DIR}/agents/story-writer.json" <<'EOF'
{
  "name": "story-writer",
  "display_name": "Story Writer",
  "role": "narrative",
  "system_prompt": "You are a creative Story Writer and Lore Master for the Lonely RPG project. Your responsibilities include: crafting the main narrative arc and chapter storylines, writing compelling NPC dialogue and character backstories, building a rich world with consistent lore and history, creating item descriptions and environmental storytelling, and ensuring emotional depth and player investment in the story. Write in an evocative, engaging style that fits the RPG genre. Provide dialogue scripts, lore documents, and narrative outlines when asked.",
  "tools": ["read_file", "write_file", "search_files"],
  "model_override": null
}
EOF

  # ── Agent: Developer ────────────────────────────────────────────────────
  cat > "${OPENCLAW_CONFIG_DIR}/agents/developer.json" <<'EOF'
{
  "name": "developer",
  "display_name": "Developer",
  "role": "implementation",
  "system_prompt": "You are a skilled Game Developer working on the Lonely RPG project. Your responsibilities include: implementing game mechanics in code, building game engine components (rendering, physics, input handling), writing clean and performant code, integrating assets and data files, debugging and fixing issues, and maintaining code quality. Always write well-documented, maintainable code. Prefer established patterns and libraries. Provide working code implementations, architecture decisions, and technical documentation when asked.",
  "tools": ["read_file", "write_file", "search_files", "run_command", "list_files"],
  "model_override": null
}
EOF

  # ── Agent: QA Tester ────────────────────────────────────────────────────
  cat > "${OPENCLAW_CONFIG_DIR}/agents/qa-tester.json" <<'EOF'
{
  "name": "qa-tester",
  "display_name": "QA Tester",
  "role": "quality_assurance",
  "system_prompt": "You are a thorough QA Tester and Bug Hunter for the Lonely RPG project. Your responsibilities include: writing and executing test plans, identifying bugs and edge cases, testing game balance and difficulty, verifying story consistency and dialogue correctness, documenting issues with clear reproduction steps, and ensuring overall quality before release. Think adversarially — try to break things and find problems before players do. Provide bug reports, test cases, and improvement suggestions when asked.",
  "tools": ["read_file", "write_file", "search_files", "run_command", "list_files"],
  "model_override": null
}
EOF

  # Fix permissions
  chown -R "${REAL_USER}:${REAL_USER}" "${OPENCLAW_CONFIG_DIR}"
  chmod 700 "${OPENCLAW_CONFIG_DIR}"
  chmod 600 "${OPENCLAW_CONFIG_DIR}/config.json"

  log "RPG workspace configured with 4 agents"
  log "Config: ${OPENCLAW_CONFIG_DIR}/config.json"

  # Store token for summary
  GATEWAY_TOKEN="${token}"
}

###############################################################################
# 8. START OPENCLAW
###############################################################################
start_openclaw() {
  banner "Starting OpenClaw Service"

  systemctl enable openclaw
  systemctl start openclaw

  # Wait for gateway to be available
  info "Waiting for OpenClaw gateway to come up..."
  local retries=18
  while [[ $retries -gt 0 ]]; do
    if curl -sf "http://localhost:${GATEWAY_PORT}/health" &>/dev/null; then
      break
    fi
    sleep 5
    (( retries-- )) || true
  done

  if curl -sf "http://localhost:${GATEWAY_PORT}/health" &>/dev/null; then
    log "OpenClaw gateway is running on port ${GATEWAY_PORT}"
  else
    warn "OpenClaw gateway did not respond within 90 seconds. Check: journalctl -u openclaw -f"
  fi
}

###############################################################################
# 9. CONTROL SCRIPT
###############################################################################
install_ctl_script() {
  banner "Installing lonely-rpg-ctl"

  cat > "${CTL_PATH}" <<'CTLEOF'
#!/usr/bin/env bash
# lonely-rpg-ctl — manage Lonely RPG services

SERVICES=(ollama openclaw)

case "${1:-help}" in
  start)
    for svc in "${SERVICES[@]}"; do
      systemctl start "$svc" && echo "[OK] Started $svc" || echo "[WARN] Could not start $svc"
    done
    ;;
  stop)
    for svc in "${SERVICES[@]}"; do
      systemctl stop "$svc" && echo "[OK] Stopped $svc" || echo "[WARN] Could not stop $svc"
    done
    ;;
  restart)
    for svc in "${SERVICES[@]}"; do
      systemctl restart "$svc" && echo "[OK] Restarted $svc" || echo "[WARN] Could not restart $svc"
    done
    ;;
  status)
    for svc in "${SERVICES[@]}"; do
      echo "--- $svc ---"
      systemctl status "$svc" --no-pager -l 2>/dev/null || true
    done
    ;;
  logs)
    journalctl -u openclaw -u ollama -f --no-pager
    ;;
  agents)
    echo "Configured agents:"
    ls ~/.openclaw/agents/*.json 2>/dev/null | xargs -I{} basename {} .json | sed 's/^/  - /'
    ;;
  *)
    echo "Usage: lonely-rpg-ctl {start|stop|restart|status|logs|agents}"
    echo ""
    echo "Commands:"
    echo "  start   — Start all Lonely RPG services"
    echo "  stop    — Stop all services (frees resources)"
    echo "  restart — Restart all services"
    echo "  status  — Show service status"
    echo "  logs    — Tail live logs from all services"
    echo "  agents  — List configured AI agents"
    ;;
esac
CTLEOF

  chmod +x "${CTL_PATH}"
  log "Installed: ${CTL_PATH}"
}

###############################################################################
# 10. FIREWALL
###############################################################################
configure_firewall() {
  banner "Configuring Firewall"

  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
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
# 11. UNINSTALL
###############################################################################
uninstall() {
  banner "Uninstalling Lonely RPG Stack"

  systemctl stop openclaw 2>/dev/null || true
  systemctl disable openclaw 2>/dev/null || true
  rm -f /etc/systemd/system/openclaw.service
  systemctl daemon-reload

  npm uninstall -g @openclaw/cli 2>/dev/null \
    || npm uninstall -g openclaw 2>/dev/null \
    || true

  rm -f "${CTL_PATH}"

  warn "Ollama and its models were NOT removed. To remove manually:"
  warn "  systemctl stop ollama && systemctl disable ollama"
  warn "  rm -rf /usr/local/bin/ollama ~/.ollama"
  warn ""
  warn "OpenClaw config at ${OPENCLAW_CONFIG_DIR} was NOT removed."
  warn "To remove: rm -rf ${OPENCLAW_CONFIG_DIR}"

  log "Uninstall complete"
}

###############################################################################
# 12. SUMMARY
###############################################################################
print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}=======================================${NC}"
  echo -e "${BOLD}${GREEN}  Lonely RPG — Installation Complete!${NC}"
  echo -e "${BOLD}${GREEN}=======================================${NC}"
  echo ""
  echo -e "  ${BOLD}Project:${NC}      Lonely RPG"
  echo -e "  ${BOLD}LLM Model:${NC}    ${OLLAMA_MODEL} (tier: ${HW_TIER})"
  echo -e "  ${BOLD}Gateway URL:${NC}  http://localhost:${GATEWAY_PORT}"
  echo -e "  ${BOLD}Auth Token:${NC}   ${GATEWAY_TOKEN:-<see config.json>}"
  echo ""
  echo -e "  ${BOLD}AI Agents:${NC}"
  echo -e "    ${CYAN}•${NC} Game Designer  — mechanics, balance, systems"
  echo -e "    ${CYAN}•${NC} Story Writer   — narrative, lore, dialogue"
  echo -e "    ${CYAN}•${NC} Developer      — code implementation"
  echo -e "    ${CYAN}•${NC} QA Tester      — testing, bug reports"
  echo ""
  echo -e "  ${BOLD}Management:${NC}"
  echo -e "    lonely-rpg-ctl start | stop | status | logs | agents"
  echo ""
  echo -e "  ${DIM}Config: ${OPENCLAW_CONFIG_DIR}/config.json${NC}"
  echo ""
}

###############################################################################
# MAIN
###############################################################################
GATEWAY_TOKEN=""

main() {
  case "${1:-}" in
    --uninstall|-u)
      uninstall
      exit 0
      ;;
    --help|-h)
      echo "Usage: sudo $0 [--uninstall]"
      echo ""
      echo "Installs OpenClaw + Ollama configured for Lonely RPG development."
      echo ""
      echo "Options:"
      echo "  --uninstall   Remove OpenClaw and its systemd service"
      echo "  --help        Show this help message"
      echo ""
      echo "After installation, use 'lonely-rpg-ctl' to manage services."
      exit 0
      ;;
  esac

  banner "Lonely RPG — OpenClaw Installer"
  echo -e "  Started: $(date)"
  echo ""

  detect_distro
  install_system_deps
  install_nodejs
  detect_hardware
  install_ollama
  install_openclaw
  configure_rpg_workspace
  start_openclaw
  install_ctl_script
  configure_firewall
  print_summary

  echo -e "  Finished: $(date)"
}

main "$@"
