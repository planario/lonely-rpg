# ⚔️ Lonely RPG

> Uma sessão de RPG de mesa completa, narrada por IA local, com party de companheiros autônomos — tudo rodando na sua própria máquina.

**Lonely RPG** conecta o [OpenClaw](https://github.com/openclaw) a um LLM local irrestrito (série Dolphin) para criar um ambiente de RPG imersivo onde:

- O **Mestre** (Game Master) narra o mundo, controla NPCs e toma decisões de regra
- Três **companheiros autônomos** (Guerreiro, Mago, Ladino) integram a sua party com personalidades próprias
- Todos os personagens possuem **fichas de personagem** (fichas) persistidas em disco
- O estado da campanha é salvo entre sessões
- O modelo de linguagem nunca quebra a imersão com recusas de conteúdo

---

## Índice

- [Pré-requisitos](#pré-requisitos)
- [Instalação](#instalação)
- [Reconfiguração](#reconfiguração)
- [Desinstalação](#desinstalação)
- [Modelos LLM](#modelos-llm)
- [Agentes da Campanha](#agentes-da-campanha)
- [Fichas de Personagem](#fichas-de-personagem)
- [Gerenciamento de Serviços](#gerenciamento-de-serviços)
- [Estrutura de Arquivos](#estrutura-de-arquivos)
- [Configuração Avançada](#configuração-avançada)
- [Solução de Problemas](#solução-de-problemas)

---

## Pré-requisitos

| Requisito | Mínimo | Recomendado |
|-----------|--------|-------------|
| **OS** | Ubuntu 20.04 / Debian 11 / Fedora 38 | Ubuntu 22.04+ |
| **RAM** | 4 GB | 16 GB+ |
| **Armazenamento** | 8 GB livres | 50 GB+ (modelos grandes) |
| **CPU** | x86_64, 4 núcleos | 8+ núcleos |
| **GPU** | Opcional | NVIDIA 8 GB+ VRAM (recomendado) |
| **Permissão** | sudo / root | — |
| **Rede** | Conexão para download | — |

> **GPU NVIDIA**: se presente, o instalador detecta automaticamente a VRAM e usa aceleração CUDA via Ollama, reduzindo drasticamente o tempo de resposta.

---

## Instalação

```bash
# 1. Clone o repositório
git clone https://github.com/planario/lonely-rpg.git
cd lonely-rpg

# 2. Torne o script executável
chmod +x openclaw-rpg-installer.sh

# 3. Execute como root
sudo ./openclaw-rpg-installer.sh
```

O instalador faz tudo automaticamente:

1. Detecta a distribuição Linux (Debian/Ubuntu ou Fedora/RHEL)
2. Instala dependências do sistema (`curl`, `git`, `jq`, `openssl`)
3. Instala Node.js 20+ via NodeSource
4. Analisa o hardware e escolhe o modelo LLM ideal
5. Instala o Ollama e baixa o modelo selecionado
6. Instala o OpenClaw via npm
7. Cria um serviço systemd para o OpenClaw
8. Pergunta sobre as fichas de personagem (criação ou reutilização)
9. Configura os 4 agentes de IA (Mestre + party)
10. Instala o utilitário `lonely-rpg-ctl`
11. Configura o firewall (ufw ou firewalld)
12. Exibe URL + token de acesso

---

## Reconfiguração

Use `--reconfigure` para reconfigurar os agentes e fichas **sem reinstalar** o Ollama, Node.js ou OpenClaw.

```bash
sudo ./openclaw-rpg-installer.sh --reconfigure
```

Durante a reconfiguração, o script verifica se já existem fichas salvas e pergunta interativamente o que fazer com cada uma:

```
[?]  Ficha do jogador já existe: Arathorn
     1) Reutilizar ficha existente (Arathorn)
     2) Criar nova ficha em branco
    Choice [1-2]: _
```

```
[?]  Companheiro 'guerreiro' já tem ficha: Thorin (Guerreiro)
     1) Reutilizar ficha existente (Thorin)
     2) Criar nova ficha para guerreiro
    Choice [1-2]: _
```

> Fichas reutilizadas mantêm todos os dados: XP, HP, inventário, histórico e notas.

---

## Desinstalação

```bash
sudo ./openclaw-rpg-installer.sh --uninstall
```

O processo é **interativo** e oferece três modos:

---

### Modo 1 — Desinstalação parcial *(padrão seguro)*

Remove apenas o serviço, o binário de controle e o pacote npm.

**Mantém:**
- Fichas de personagem e configuração (`~/.openclaw/`)
- Ollama e todos os modelos LLM baixados

Ideal para pausar ou trocar de ambiente sem perder o progresso da campanha.

---

### Modo 2 — Desinstalação completa

Remove tudo do Modo 1, mais:

- Fichas e configuração (`~/.openclaw/`)
- Serviço e binário do Ollama
- Todos os modelos LLM (`~/.ollama/` — pode liberar dezenas de GB)
- Usuário de sistema `ollama`

> Exige confirmação digitando `sim`.

---

### Modo 3 — Restaurar o OS ao estado anterior

Remove tudo do Modo 2, mais:

- Node.js e npm (incluindo repositório NodeSource)
- Pacote `jq` instalado pelo script
- Cache e configuração global do npm (`~/.npm`, `~/.npmrc`)

> `curl`, `git` e `openssl` são preservados por serem pré-existentes na maioria dos sistemas.
> Exige confirmação digitando `sim`.

---

### Fluxo de confirmação

```
  Escolha o que deseja remover:

  1) Desinstalação parcial
     Remove: serviço OpenClaw, lonely-rpg-ctl, pacote npm
     Mantém: fichas de personagem, configuração, Ollama e modelos

  2) Desinstalação completa
     Remove tudo acima, mais:
       • Fichas de personagem e configuração (~/.openclaw)
       • Ollama (binário + serviço systemd)
       • Modelos LLM baixados (~/.ollama  —  pode ser grande!)

  3) Restaurar o OS ao estado anterior à instalação
     Remove tudo acima, mais:
       • Node.js (se instalado por este script via NodeSource)
       • Pacotes de sistema instalados (jq)

  Escolha [1-3] ou Enter para cancelar: _
```

---

## Modelos LLM

O Lonely RPG usa exclusivamente a **série Dolphin** — modelos fine-tuned pela [Cognitive Computations](https://huggingface.co/cognitivecomputations) sobre bases Llama 3, Mistral e Phi para remover filtros de conteúdo.

Isso é essencial para RPG: o Mestre precisa narrar combate, vilões convincentes, dilemas morais, temas sombrios e situações de tensão sem interrupções por filtros de segurança.

### Seleção Automática por Hardware

| Tier | RAM / VRAM disponível | Modelo | Tamanho |
|------|----------------------|--------|---------|
| `minimal` | < 4 GB | `tinydolphin` | ~638 MB |
| `low` | 4–8 GB | `dolphin-phi` | ~1,6 GB |
| `mid` | 8–16 GB | `dolphin-mistral:7b` | ~4,1 GB |
| `high` | 16–32 GB | `dolphin-llama3:8b` | ~4,7 GB |
| `ultra` | 32+ GB | `dolphin-llama3:70b` | ~39 GB |

> Se uma **GPU NVIDIA** for detectada, o instalador usa a **VRAM** como critério (em vez da RAM do sistema), resultando em inferência muito mais rápida.

### Troca Manual de Modelo

Para trocar o modelo após a instalação, edite `~/.openclaw/config.json`:

```json
{
  "llm": {
    "model": "dolphin-llama3:8b"
  }
}
```

Em seguida, baixe o novo modelo e reinicie:

```bash
ollama pull dolphin-llama3:8b
lonely-rpg-ctl restart
```

### Por que Dolphin?

- **Sem recusas de conteúdo**: o modelo segue todas as instruções de roleplay, incluindo personagens moralmente complexos, cenas de conflito e narrativas maduras
- **Instrução fiel**: fine-tuning especializado para seguir prompts de sistema com precisão — ideal para manter as personas dos agentes consistentes
- **Boa capacidade narrativa**: treinados sobre dados de alta qualidade de escrita criativa
- **100% local**: nenhum dado sai da sua máquina

---

## Agentes da Campanha

O Lonely RPG cria 4 agentes de IA, cada um com um papel distinto na campanha.

### 🎲 Mestre (Game Master)

O cérebro da campanha. Narra o mundo, controla todos os NPCs, adjudica regras e decide as consequências das ações do jogador.

**Responsabilidades:**
- Narrar cenários, transições e eventos do mundo
- Interpretar NPCs com personalidades consistentes
- Gerenciar combate (iniciativa, ataques, consequências)
- Tomar decisões de regras
- Manter o estado da campanha em `game-master.json`
- Consultar todas as fichas para manter coerência de atributos e inventário

**Acesso a arquivos:**
- Lê e atualiza `~/.openclaw/sheets/game-master.json` (estado da campanha)
- Lê todas as fichas da party para referência em combate e roleplay

---

### ⚔️ Guerreiro (Thorin, por padrão)

Companheiro de linha de frente. Tank e combatente principal da party.

**Personalidade padrão:** Anão corajoso e direto, leal à party, desconfiado de magia.

**Em combate:** Age segundo seus atributos de força e constituição, usa armadura pesada e ataque de múltiplos alvos quando disponível.

---

### ✦ Mago (Elara, por padrão)

Companheiro arcano. Especialista em magia e conhecimento esotérico.

**Personalidade padrão:** Elfa analítica e ligeiramente arrogante, curiosa sobre fenômenos mágicos, com objetivos pessoais ocultos.

**Em combate:** Gerencia slots de magia com cuidado, prioriza controle de multidão antes de dano bruto.

---

### ◈ Ladino (Sombra, por padrão)

Companheiro furtivo. Especialista em infiltração, reconhecimento e situações moralmente ambíguas.

**Personalidade padrão:** Halfling sarcástico com passado nebuloso, leal mas reservado, confortável com roubos e negociações duvidosas.

**Em combate:** Usa furtividade para posicionamento e ataque furtivo para dano alto.

---

### Comportamento Geral dos Agentes

- **Imersão total**: nenhum agente quebra o personagem dizendo que é uma IA
- **Consistência de ficha**: atributos, HP, magias e inventário são consultados para decisões de combate e roleplay
- **Conflito interno**: companheiros podem discordar entre si e com o jogador, conforme suas personalidades
- **Persistência**: o estado da campanha é salvo e carregado entre sessões

---

## Fichas de Personagem

As fichas ficam em `~/.openclaw/sheets/` e são arquivos JSON editáveis.

```
~/.openclaw/sheets/
├── player.json            # Ficha do personagem do jogador
├── game-master.json       # Estado da campanha (arco, sessão, NPCs, quests)
└── party/
    ├── guerreiro.json     # Ficha do companheiro Guerreiro
    ├── mago.json          # Ficha do companheiro Mago
    └── ladino.json        # Ficha do companheiro Ladino
```

### Estrutura da Ficha do Jogador (`player.json`)

```json
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
    "forca": 10,
    "destreza": 10,
    "constituicao": 10,
    "inteligencia": 10,
    "sabedoria": 10,
    "carisma": 10
  },
  "proficiencia": 2,
  "ca": 10,
  "iniciativa": 0,
  "velocidade": 9,
  "habilidades": [],
  "magias": [],
  "inventario": [],
  "moedas": { "po": 0, "pp": 0, "pe": 0, "pc": 0 },
  "historico": "",
  "tracos_personalidade": "",
  "ideais": "",
  "vinculos": "",
  "fraquezas": "",
  "notas": ""
}
```

### Estrutura do Estado do Mestre (`game-master.json`)

```json
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
```

### Editando Fichas Manualmente

As fichas são JSON puro — edite com qualquer editor:

```bash
# Editar ficha do jogador
nano ~/.openclaw/sheets/player.json

# Ver ficha formatada
lonely-rpg-ctl sheet player
lonely-rpg-ctl sheet guerreiro
lonely-rpg-ctl sheet mago
lonely-rpg-ctl sheet ladino
lonely-rpg-ctl sheet mestre
```

> **Dica:** Após editar uma ficha manualmente, reinicie o OpenClaw para que os agentes carreguem as mudanças: `lonely-rpg-ctl restart`

---

## Gerenciamento de Serviços

O utilitário `lonely-rpg-ctl` gerencia todos os serviços da stack.

### Comandos

```bash
# Iniciar todos os serviços
lonely-rpg-ctl start

# Parar todos os serviços (libera RAM/GPU)
lonely-rpg-ctl stop

# Reiniciar (útil após editar config ou fichas)
lonely-rpg-ctl restart

# Ver status detalhado de cada serviço
lonely-rpg-ctl status

# Acompanhar logs em tempo real
lonely-rpg-ctl logs

# Listar fichas com resumo
lonely-rpg-ctl sheets

# Ver ficha completa de um personagem
lonely-rpg-ctl sheet player
lonely-rpg-ctl sheet guerreiro
lonely-rpg-ctl sheet mestre

# Listar agentes configurados
lonely-rpg-ctl agents
```

### Gerenciamento Manual via systemctl

```bash
# Status individual
systemctl status openclaw
systemctl status ollama

# Logs individuais
journalctl -u openclaw -f
journalctl -u ollama -f
```

---

## Estrutura de Arquivos

```
/
├── /etc/systemd/system/
│   └── openclaw.service           # Serviço systemd do OpenClaw
│
├── /usr/local/bin/
│   └── lonely-rpg-ctl             # Utilitário de gerenciamento
│
└── ~/.openclaw/                   # Configuração do usuário
    ├── config.json                # Config principal (gateway, LLM, paths)
    ├── workspace/                 # Diretório de trabalho do OpenClaw
    ├── agents/                    # Definições dos agentes de IA
    │   ├── mestre.json
    │   ├── guerreiro.json
    │   ├── mago.json
    │   └── ladino.json
    └── sheets/                    # Fichas de personagem
        ├── player.json
        ├── game-master.json
        └── party/
            ├── guerreiro.json
            ├── mago.json
            └── ladino.json
```

---

## Configuração Avançada

### Ajustar Parâmetros do LLM

Edite `~/.openclaw/config.json`:

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

| Parâmetro | Padrão | Efeito |
|-----------|--------|--------|
| `num_ctx` | `8192` | Janela de contexto (tokens). Mais = maior memória de sessão, mais VRAM |
| `temperature` | `0.85` | Criatividade. `1.0` = mais aleatório, `0.5` = mais determinístico |
| `top_p` | `0.95` | Diversidade de vocabulário. Reduzir para respostas mais focadas |
| `repeat_penalty` | `1.1` | Penaliza repetição. Aumentar se o modelo travar em loops |

### Customizar um Agente

Edite qualquer arquivo em `~/.openclaw/agents/`, por exemplo para dar ao ladino uma personalidade diferente:

```json
{
  "name": "ladino",
  "display_name": "Ladino",
  "system_prompt": "Você é Víbora, uma assassina élfica fria e calculista..."
}
```

### Adicionar Modelos Alternativos

```bash
# Baixar modelos adicionais
ollama pull dolphin-llama3:70b
ollama pull nous-hermes2:34b

# Listar modelos disponíveis
ollama list
```

### Portas

| Serviço | Porta padrão | Variável |
|---------|-------------|----------|
| OpenClaw Gateway | `18789` | `GATEWAY_PORT` |
| Ollama API | `11434` | `OLLAMA_PORT` |
| HTTPS | `443` | `HTTPS_PORT` |

Para mudar a porta do gateway, edite `GATEWAY_PORT` no script antes de instalar, ou atualize `~/.openclaw/config.json` após.

---

## Solução de Problemas

### Ollama não inicia

```bash
systemctl status ollama
journalctl -u ollama -n 50
```

Verifique se outra instância já está rodando na porta 11434:

```bash
ss -tlnp | grep 11434
```

### OpenClaw não responde

```bash
systemctl status openclaw
journalctl -u openclaw -n 100 --no-pager
```

Teste o gateway diretamente:

```bash
curl http://localhost:18789/health
```

### Modelo não baixa (timeout ou erro de rede)

```bash
# Tentar baixar manualmente
ollama pull dolphin-mistral:7b

# Verificar espaço em disco
df -h ~/.ollama
```

### Erro de permissão nas fichas

```bash
chown -R $USER:$USER ~/.openclaw
chmod 700 ~/.openclaw
chmod 600 ~/.openclaw/config.json
```

### Respostas lentas mesmo com GPU

Confirme que o Ollama está usando a GPU:

```bash
# Verificar uso de GPU durante inferência
watch -n1 nvidia-smi

# Logs do Ollama com nível de detalhe
OLLAMA_DEBUG=1 ollama serve
```

### Recriar toda a configuração do zero

```bash
# Parar serviços
lonely-rpg-ctl stop

# Remover config (mantém Ollama e modelos)
rm -rf ~/.openclaw

# Reinstalar
sudo ./openclaw-rpg-installer.sh
```

---

## Licença

MIT © Lonely RPG Project
