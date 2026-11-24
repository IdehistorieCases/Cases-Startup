# Cases-Startup

Reproducible Windows startup for the CASES game. This repository pins matching Cases-AI, Cases-Backend, and Cases-GUI revisions, creates private local configuration, and starts the model gateway, backend, and GUI as separate services.

## Prerequisites

- Windows 11, Git, PowerShell 5.1 or newer, and Docker Desktop using Linux containers.
- Python 3.11 or newer and the Codex CLI installed and signed in as the Windows user running CASES.
- Godot 4.7.2 at `D:\tools\Godot-4.7.2\Godot_v4.7.2-stable_win64.exe` (or pass `-GodotPath`).
- For the Luna consent screen, install the Cases-AI dashboard once. Its installer requires Node.js 22.12+ and Python 3.11+.

Cases-AI is the canonical inference repository. The primary narrator is ChatGPT 6 Luna (`gpt-6-luna`) through the signed-in Codex CLI bridge; no OpenAI API key is needed. The launcher does not start local Qwen or optional retrieval workers. New game sessions default to Luna, and a Luna-pinned session never falls back to Qwen.

## First run

Clone this repository, then run these commands in PowerShell:

~~~powershell
git clone https://github.com/IdehistorieCases/Cases-Startup.git D:\projects\Cases-Startup
Set-ExecutionPolicy -Scope Process Bypass
cd D:\projects\Cases-Startup
.\cases.ps1 setup
.\cases.ps1 install-dashboard
~~~

On the dashboard's first visit, open http://127.0.0.1:8765 and create its local administrator account. Setup downloads the pinned source checkouts, writes ignored `.env` files under Cases-AI and Cases-Backend, and creates independent gateway, bridge, and database credentials. Secrets stay outside this repository and are never printed. Existing valid secrets are preserved. If the gateway and backend client tokens disagree, setup stops without rotating either token.

## Start the game

~~~powershell
.\cases.ps1 start
~~~

The launcher starts the Luna bridge and isolated Cases-AI gateway, then the backend and waits for API/database readiness. It checks Luna availability before opening Godot. On a fresh install, Luna is disabled. The launcher opens the dashboard and waits for an operator to review the cloud-data disclosure, check the consent box, and enable Luna on the Providers page. It never enables Luna through an API call or sends a completion during startup.

If Luna was enabled previously, startup proceeds after checking readiness. If the dashboard is not installed or Luna is not ready, the model services and backend stay available for diagnosis; the game GUI is not launched. Resolve the dashboard/provider state and run `.\cases.ps1 start-gui`.

## Start each service separately

The launcher gives each Compose stack a dedicated project name and state volume. The backend uses `cases-startup-backend` and publishes its API on loopback port 18082 by default. The inference gateway uses `cases-startup-inference-gateway`, has its own network alias, gateway state, and loopback admin port (18768 by default). These settings keep the existing `ddu-backend` and `inference-gateway` projects separate. If the selected admin port is occupied, the launcher finds a free port in 18768–18820. If bridge port 18765 is occupied, it tries 18767; if both are occupied, it stops without interrupting either listener.

~~~powershell
.\cases.ps1 start-models
.\cases.ps1 start-backend
.\cases.ps1 start-gui
.\cases.ps1 status
~~~

Run those commands in that order when starting manually. The GUI receives the backend URL only in the Godot process launched by this script. Local Qwen and historical retrieval are optional services documented in Cases-AI.

Use `-ProjectRoot` to choose another checkout directory and `-GodotPath` if Godot is elsewhere:

~~~powershell
.\cases.ps1 setup -ProjectRoot E:\CASES
.\cases.ps1 start -ProjectRoot E:\CASES -BackendPort 18083 -GodotPath 'C:\Apps\Godot\Godot_v4.7.2-stable_win64.exe'
~~~

The launcher verifies every source checkout's origin, locked commit, and clean working tree. It never resets or overwrites a mismatched or dirty checkout; choose a separate `-ProjectRoot` for a clean pinned copy.

## Stop and inspect

~~~powershell
.\cases.ps1 status
.\cases.ps1 stop
~~~

`stop` stops only the GUI process tracked by this launcher, its backend and inference-gateway Compose projects, and its bridge process. It does not stop the existing `ddu-backend` or `inference-gateway` projects. Compose down runs without `-v`, so the startup stack's PostgreSQL and gateway state volumes remain intact.

## Service boundaries

- Cases-AI is the canonical inference repository. The bridge binds only to 127.0.0.1. The inference gateway has no host-published inference port; its backend-only alias is `cases-startup-gateway:8080`.
- The gateway admin proxy binds only to loopback. Its port is configurable and is exposed to the dashboard through the ignored Cases-AI `.env`.
- The gateway's Luna enabled state is controlled through the Cases-AI dashboard consent flow. A fresh gateway starts disabled; its state volume preserves later operator choices.
- Cases-Backend exposes its API on 127.0.0.1:18082 by default. PostgreSQL has no host-published port.
- `setup` creates local configuration only. It does not start containers, contact the model, or send prompts.
- The exact source commits are pinned in `repos.lock.json`. Update the lock when promoting new source revisions.

For repository-specific operations and recovery limits, see the READMEs in Cases-AI, Cases-Backend, and Cases-GUI.
