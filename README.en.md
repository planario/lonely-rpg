# ⚔️ Lonely RPG

> A full tabletop RPG session narrated by a local AI, with a party of autonomous companions — everything running on your own machine.

**Lonely RPG** connects [OpenClaw](https://github.com/openclaw) to an unrestricted local LLM (Dolphin series) to create an immersive RPG environment where:

- The **Game Master** narrates the world, controls NPCs and adjudicates rules
- Three **autonomous companions** (Warrior, Mage, Rogue) join your party with their own personalities
- Every character has a persistent **character sheet** saved to disk
- Campaign state is preserved between sessions
- The language model never breaks immersion with content refusals

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Reconfiguration](#reconfiguration)
- [Uninstall](#uninstall)
- [LLM Models](#llm-models)
- [Campaign Agents](#campaign-agents)
- [Character Sheets](#character-sheets)
- [Service Management](#service-management)
- [File Structure](#file-structure)
- [Advanced Configuration](#advanced-configuration)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| **OS** | Ubuntu 20.04 / Debian 11 / Fedora 38 | Ubuntu 22.04+ |
| **RAM** | 4 GB | 16 GB+ |
| **Storage** | 8 GB free | 50 GB+ (for large models) |
| **CPU** | x86_64, 4 cores | 8+ cores |
| **GPU** | Optional | NVIDIA 8 GB+ VRAM (recommended) |
| **Permission** | sudo / root | — |
| **Network** | Connection for download | — |

> **NVIDIA GPU**: if present, the installer automatically detects VRAM and enables CUDA acceleration via Ollama, drastically reducing response times.

---

## Installation

```bash
# 1. Clone the repository
git clone https://github.com/planario/lonely-rpg.git
cd lonely-rpg

# 2. Make the script executable
chmod +x openclaw-rpg-installer.sh

# 3. Run as root
sudo ./openclaw-rpg-installer.sh
```

The installer handles everything automatically:

1. Detects the Linux distribution (Debian/Ubuntu or Fedora/RHEL)
2. Installs system dependencies (`curl`, `git`, `jq`, `openssl`)
3. Installs Node.js 20+ via NodeSource
4. Analyzes hardware and selects the best LLM model
5. Installs Ollama and downloads the selected model
6. Installs OpenClaw via npm
7. Creates a systemd service for OpenClaw
8. Prompts about character sheets (create new or reuse existing)
9. Configures the 4 AI agents (Game Master + party)
10. Installs the `lonely-rpg-ctl` management utility
11. Configures the firewall (ufw or firewalld)
12. Displays the access URL and token

---

## Reconfiguration

Use `--reconfigure` to reconfigure agents and character sheets **without reinstalling** Ollama, Node.js or OpenClaw.

```bash
sudo ./openclaw-rpg-installer.sh --reconfigure
```

During reconfiguration, the script checks whether sheets already exist and interactively asks what to do with each one:

```
[?]  Player sheet already exists: Arathorn
     1) Reuse existing sheet (Arathorn)
     2) Create a new blank sheet
    Choice [1-2]: _
```

```
[?]  Companion 'guerreiro' already has a sheet: Thorin (Warrior)
     1) Reuse existing sheet (Thorin)
     2) Create a new sheet for guerreiro
    Choice [1-2]: _
```

> Reused sheets retain all data: XP, HP, inventory, backstory and notes.

---

## Uninstall

```bash
sudo ./openclaw-rpg-installer.sh --uninstall
```

The process is **interactive** and offers three modes:

---

### Mode 1 — Partial uninstall *(safe default)*

Removes only the service, the control binary and the npm package.

**Keeps:**
- Character sheets and configuration (`~/.openclaw/`)
- Ollama and all downloaded LLM models

Ideal for pausing or switching environments without losing campaign progress.

---

### Mode 2 — Full uninstall

Removes everything from Mode 1, plus:

- Character sheets and configuration (`~/.openclaw/`)
- Ollama service and binary
- All downloaded LLM models (`~/.ollama/` — may free tens of GB)
- `ollama` system user

> Requires confirmation by typing `sim`.

---

### Mode 3 — Restore OS to pre-installation state

Removes everything from Mode 2, plus:

- Node.js and npm (including the NodeSource repository)
- The `jq` package installed by this script
- Global npm cache and configuration (`~/.npm`, `~/.npmrc`)

> `curl`, `git` and `openssl` are preserved as they are likely pre-existing on most systems.
> Requires confirmation by typing `sim`.

---

### Confirmation flow

```
  Choose what to remove:

  1) Partial uninstall
     Removes: OpenClaw service, lonely-rpg-ctl, npm package
     Keeps:   character sheets, config, Ollama and models

  2) Full uninstall
     Removes everything above, plus:
       • Character sheets and configuration (~/.openclaw)
       • Ollama (binary + systemd service)
       • Downloaded LLM models (~/.ollama  —  can be large!)

  3) Restore OS to pre-installation state
     Removes everything above, plus:
       • Node.js (if installed by this script via NodeSource)
       • System packages installed by the script (jq)

  Choose [1-3] or press Enter to cancel: _
```

---

## LLM Models

Lonely RPG exclusively uses the **Dolphin series** — models fine-tuned by [Cognitive Computations](https://huggingface.co/cognitivecomputations) on top of Llama 3, Mistral and Phi bases to remove content filters.

This is essential for RPG: the Game Master needs to narrate combat, convincing villains, moral dilemmas, dark themes and tension-filled situations without being interrupted by safety filters.

### Automatic Selection by Hardware

| Tier | Available RAM / VRAM | Model | Size |
|------|---------------------|-------|------|
| `minimal` | < 4 GB | `tinydolphin` | ~638 MB |
| `low` | 4–8 GB | `dolphin-phi` | ~1.6 GB |
| `mid` | 8–16 GB | `dolphin-mistral:7b` | ~4.1 GB |
| `high` | 16–32 GB | `dolphin-llama3:8b` | ~4.7 GB |
| `ultra` | 32+ GB | `dolphin-llama3:70b` | ~39 GB |

> If an **NVIDIA GPU** is detected, the installer uses **VRAM** as the criterion (instead of system RAM), resulting in much faster inference.

### Switching Models Manually

To change the model after installation, edit `~/.openclaw/config.json`:

```json
{
  "llm": {
    "model": "dolphin-llama3:8b"
  }
}
```

Then pull the new model and restart:

```bash
ollama pull dolphin-llama3:8b
lonely-rpg-ctl restart
```

### Why Dolphin?

- **No content refusals**: the model follows all roleplay instructions, including morally complex characters, conflict scenes and mature narratives
- **Instruction-faithful**: fine-tuned specifically to follow system prompts precisely — ideal for keeping agent personas consistent
- **Strong narrative output**: trained on high-quality creative writing data
- **100% local**: no data ever leaves your machine

---

## Campaign Agents

Lonely RPG creates 4 AI agents, each with a distinct role in the campaign.

### 🎲 Game Master (Mestre)

The brain of the campaign. Narrates the world, controls all NPCs, adjudicates rules and decides the consequences of player actions.

**Responsibilities:**
- Narrating scenes, world transitions and events
- Voicing NPCs with consistent personalities
- Managing combat (initiative, attacks, consequences)
- Making rule calls
- Maintaining campaign state in `game-master.json`
- Reading all character sheets to maintain consistency of stats and inventory

**File access:**
- Reads and updates `~/.openclaw/sheets/game-master.json` (campaign state)
- Reads all party sheets for combat and roleplay reference

---

### ⚔️ Warrior — Thorin (default)

Front-line companion. Tank and main combatant of the party.

**Default personality:** A brave and straightforward Dwarf, loyal to the party, distrustful of magic.

**In combat:** Acts according to strength and constitution attributes, uses heavy armor and multi-target strikes when available.

---

### ✦ Mage — Elara (default)

Arcane companion. Specialist in magic and esoteric knowledge.

**Default personality:** An analytical and slightly arrogant Elf, curious about magical phenomena, with hidden personal objectives.

**In combat:** Carefully manages spell slots, prioritizes crowd control before raw damage.

---

### ◈ Rogue — Sombra (default)

Stealthy companion. Specialist in infiltration, scouting and morally ambiguous situations.

**Default personality:** A sarcastic Halfling with a murky past, loyal but guarded, comfortable with theft and dubious negotiations.

**In combat:** Uses stealth for positioning and sneak attack for burst damage.

---

### General Agent Behaviour

- **Full immersion**: no agent breaks character by claiming to be an AI
- **Sheet consistency**: attributes, HP, spells and inventory are consulted for combat and roleplay decisions
- **Internal conflict**: companions can disagree with each other and with the player, according to their personalities
- **Persistence**: campaign state is saved and loaded between sessions

---

## Character Sheets

Sheets live in `~/.openclaw/sheets/` as plain, editable JSON files.

```
~/.openclaw/sheets/
├── player.json            # Player character sheet
├── game-master.json       # Campaign state (arc, session, NPCs, quests)
└── party/
    ├── guerreiro.json     # Warrior companion sheet
    ├── mago.json          # Mage companion sheet
    └── ladino.json        # Rogue companion sheet
```

### Player Sheet Structure (`player.json`)

```json
{
  "type": "player",
  "name": "Adventurer",
  "class": "Warrior",
  "race": "Human",
  "level": 1,
  "xp": 0,
  "hp": { "current": 10, "max": 10 },
  "mp": { "current": 0,  "max": 0  },
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
```

### Game Master State Structure (`game-master.json`)

```json
{
  "type": "game_master",
  "campanha": "Lonely RPG",
  "arco_atual": "Prologue",
  "sessao": 1,
  "local_atual": "Starting Village",
  "estado_mundo": "",
  "npcs_ativos": [],
  "quests_ativas": [],
  "quests_concluidas": [],
  "itens_especiais_distribuidos": [],
  "eventos_marcantes": [],
  "notas_secretas": "",
  "proximos_encontros": []
}
```

### Editing Sheets Manually

Sheets are plain JSON — edit them with any editor:

```bash
# Edit the player sheet
nano ~/.openclaw/sheets/player.json

# View a formatted sheet
lonely-rpg-ctl sheet player
lonely-rpg-ctl sheet guerreiro
lonely-rpg-ctl sheet mago
lonely-rpg-ctl sheet ladino
lonely-rpg-ctl sheet mestre
```

> **Tip:** After editing a sheet manually, restart OpenClaw so agents reload the changes: `lonely-rpg-ctl restart`

---

## Service Management

The `lonely-rpg-ctl` utility manages all services in the stack.

### Commands

```bash
# Start all services
lonely-rpg-ctl start

# Stop all services (frees RAM / GPU memory)
lonely-rpg-ctl stop

# Restart (useful after editing config or sheets)
lonely-rpg-ctl restart

# Show detailed status for each service
lonely-rpg-ctl status

# Tail live logs
lonely-rpg-ctl logs

# List all character sheets with a summary
lonely-rpg-ctl sheets

# Show a full character sheet
lonely-rpg-ctl sheet player
lonely-rpg-ctl sheet guerreiro
lonely-rpg-ctl sheet mestre

# List configured AI agents
lonely-rpg-ctl agents
```

### Manual Management via systemctl

```bash
# Individual status
systemctl status openclaw
systemctl status ollama

# Individual logs
journalctl -u openclaw -f
journalctl -u ollama -f
```

---

## File Structure

```
/
├── /etc/systemd/system/
│   └── openclaw.service           # OpenClaw systemd service
│
├── /usr/local/bin/
│   └── lonely-rpg-ctl             # Management utility
│
└── ~/.openclaw/                   # User configuration
    ├── config.json                # Main config (gateway, LLM, paths)
    ├── workspace/                 # OpenClaw working directory
    ├── agents/                    # AI agent definitions
    │   ├── mestre.json
    │   ├── guerreiro.json
    │   ├── mago.json
    │   └── ladino.json
    └── sheets/                    # Character sheets
        ├── player.json
        ├── game-master.json
        └── party/
            ├── guerreiro.json
            ├── mago.json
            └── ladino.json
```

---

## Advanced Configuration

### Tuning LLM Parameters

Edit `~/.openclaw/config.json`:

```json
{
  "llm": {
    "model": "dolphin-llama3:8b",
    "num_ctx": 8192,
    "temperature": 0.85,
    "top_p": 0.95,
    "repeat_penalty": 1.1
  }
}
```

| Parameter | Default | Effect |
|-----------|---------|--------|
| `num_ctx` | `8192` | Context window (tokens). Higher = longer session memory, more VRAM |
| `temperature` | `0.85` | Creativity. `1.0` = more random, `0.5` = more deterministic |
| `top_p` | `0.95` | Vocabulary diversity. Lower for more focused responses |
| `repeat_penalty` | `1.1` | Penalises repetition. Increase if the model gets stuck in loops |

### Customising an Agent

Edit any file under `~/.openclaw/agents/`, for example to give the rogue a different personality:

```json
{
  "name": "ladino",
  "display_name": "Rogue",
  "system_prompt": "You are Viper, a cold and calculating elven assassin..."
}
```

### Pulling Alternative Models

```bash
# Download additional models
ollama pull dolphin-llama3:70b
ollama pull nous-hermes2:34b

# List available models
ollama list
```

### Ports

| Service | Default port | Variable |
|---------|-------------|----------|
| OpenClaw Gateway | `18789` | `GATEWAY_PORT` |
| Ollama API | `11434` | `OLLAMA_PORT` |
| HTTPS | `443` | `HTTPS_PORT` |

To change the gateway port, edit `GATEWAY_PORT` in the script before installing, or update `~/.openclaw/config.json` afterwards.

---

## Troubleshooting

### Ollama won't start

```bash
systemctl status ollama
journalctl -u ollama -n 50
```

Check whether another instance is already running on port 11434:

```bash
ss -tlnp | grep 11434
```

### OpenClaw not responding

```bash
systemctl status openclaw
journalctl -u openclaw -n 100 --no-pager
```

Test the gateway directly:

```bash
curl http://localhost:18789/health
```

### Model download times out or fails

```bash
# Try pulling manually
ollama pull dolphin-mistral:7b

# Check available disk space
df -h ~/.ollama
```

### Permission error on sheets

```bash
chown -R $USER:$USER ~/.openclaw
chmod 700 ~/.openclaw
chmod 600 ~/.openclaw/config.json
```

### Slow responses even with a GPU

Confirm that Ollama is actually using the GPU:

```bash
# Monitor GPU usage during inference
watch -n1 nvidia-smi

# Run Ollama with verbose logging
OLLAMA_DEBUG=1 ollama serve
```

### Rebuilding the entire configuration from scratch

```bash
# Stop services
lonely-rpg-ctl stop

# Remove config (keeps Ollama and models)
rm -rf ~/.openclaw

# Reinstall
sudo ./openclaw-rpg-installer.sh
```

---

## License

MIT © Lonely RPG Project
