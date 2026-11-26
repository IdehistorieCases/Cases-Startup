# Cases-Startup

Windows startup for the CASES game. Each normal run follows the latest `origin/main` revision of Cases-AI, Cases-Backend, and Cases-GUI, while command-line selectors can target feature branches. The launcher creates private local configuration and starts the model gateway, backend, and GUI as separate services.

## Prerequisites

- Windows 11, Git, PowerShell 5.1 or newer, and Docker Desktop using Linux containers.
- Python 3.11 or newer and the Codex CLI installed and signed in as the Windows user running CASES. For an npm installation, use `npm install -g @openai/codex`; the launcher also checks npm's global prefix if its command shim is not already on `PATH`.
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

On the dashboard's first visit, open http://127.0.0.1:8765 and create its local administrator account. Setup checks out the latest `main` branch of each source repository, writes ignored `.env` files under Cases-AI and Cases-Backend, and creates independent gateway, bridge, and database credentials. Secrets stay outside this repository and are never printed. Existing valid secrets are preserved. If the gateway and backend client tokens disagree, setup stops without rotating either token.

## Start the game

~~~powershell
.\cases.ps1 start
~~~

The launcher starts the Luna bridge and isolated Cases-AI gateway, then the backend and waits for API/database readiness. It checks Luna availability before opening Godot. On a fresh install, Luna is disabled. The launcher opens the dashboard and waits for an operator to review the cloud-data disclosure, check the consent box, and enable Luna on the Providers page. It never enables Luna through an API call or sends a completion during startup.

If Luna was enabled previously, startup proceeds after checking readiness. If the dashboard is not installed or Luna is not ready, the model services and backend stay available for diagnosis; the game GUI is not launched. Resolve the dashboard/provider state and run `.\cases.ps1 start-gui`.

## Choose branches and find stranded work

Normal startup preflights all selected refs and worktrees, then fetches `origin/main` for all three source repositories and fast-forwards clean checkouts before launching. New main-branch changes are therefore used on the next run. Dirty checkouts and local commits that are not on origin stop startup without being overwritten.

~~~powershell
.\cases.ps1 start -Branch main
.\cases.ps1 start -GUIRef codex/feature-name
.\cases.ps1 start -AIRef codex/ai-feature -BackendRef main -GUIRef codex/gui-feature
.\cases.ps1 branches
.\cases.ps1 start -Locked
~~~

Use `-Branch` (or its `-Ref` alias) when the same branch exists in all three repositories. Use `-AIRef`, `-BackendRef`, and `-GUIRef` for projects whose feature branches have different names. `branches` refreshes origin refs and reports worktrees, dirty edits, and unique commits ahead of main without changing any worktree. `-Locked` selects the exact revisions recorded in `repos.lock.json`; use a fresh `-ProjectRoot` if the normal checkout has moved past those pins, since the launcher never rewinds a checkout.

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

The launcher verifies each checkout's origin and requires a clean working tree before changing branches. It never resets or overwrites local edits. Use another `-ProjectRoot` for an isolated checkout when preserving a dirty worktree.

## Stop and inspect

~~~powershell
.\cases.ps1 status
.\cases.ps1 stop
~~~

`stop` stops only the GUI process tracked by this launcher, its backend and inference-gateway Compose projects, and its bridge process. It does not stop the existing `ddu-backend` or `inference-gateway` projects. Compose down runs without `-v`, so the startup stack's PostgreSQL and gateway state volumes remain intact.

## Private browser preview

On Marcus-Computer, run `powershell -ExecutionPolicy Bypass -File .\web-preview.ps1 install` once to build the Godot Web export, start the selected model/backend services, add a local password gate, and expose only that gate through Tailscale Funnel over HTTPS. The installer registers the same start sequence at the current Windows user's next logon. The PC must remain on, connected to the internet, and signed in.

The preview server listens only on `127.0.0.1:8767`. It serves the Godot export and proxies only `/healthz`, `/readyz`, and `/api/v1/*` to the backend on loopback. PostgreSQL, the inference gateway, and the Codex CLI bridge remain private. The password is stored in the ignored local `.env.web-preview` file; do not commit or share it. Requests through this single-user preview use the Codex CLI account configured on Marcus-Computer, so Marcus must be the person actively using the game. A separate reviewer who plays the game must use their own eligible ChatGPT plan through an approved integration.

Use `powershell -ExecutionPolicy Bypass -File .\web-preview.ps1 status` to inspect the route, and `-Action stop` to remove the Funnel route and stop only the web preview. Backend and inference containers remain running.

## Service boundaries

- Cases-AI is the canonical inference repository. The bridge binds only to 127.0.0.1. The inference gateway has no host-published inference port; its backend-only alias is `cases-startup-gateway:8080`.
- The gateway admin proxy binds only to loopback. Its port is configurable and is exposed to the dashboard through the ignored Cases-AI `.env`.
- The gateway's Luna enabled state is controlled through the Cases-AI dashboard consent flow. A fresh gateway starts disabled; its state volume preserves later operator choices.
- Cases-Backend exposes its API on 127.0.0.1:18082 by default. PostgreSQL has no host-published port.
- `setup` updates clean source checkouts and creates local configuration only. It does not start containers, contact the model, or send prompts.
- `repos.lock.json` stores the optional exact revisions selected by `-Locked`; normal startup tracks the `main` branches.

For repository-specific operations and recovery limits, see the READMEs in Cases-AI, Cases-Backend, and Cases-GUI.
