# Cases-Startup

Reproducible Windows startup for the CASES game. This repository pins the matching Cases-AI, Cases-Backend, and Cases-GUI revisions, prepares private local configuration, and starts the separate services in order.

## Prerequisites

- Windows 11, Git, PowerShell 5.1 or newer, and Docker Desktop using Linux containers.
- Python 3.11 or newer and the Codex CLI installed and signed in as the Windows user who will run CASES.
- Godot 4.7.2 at D:\tools\Godot-4.7.2\Godot_v4.7.2-stable_win64.exe (or pass -GodotPath).
- For the Luna consent screen: install the Cases-AI dashboard once. Its installer requires Node.js 22.12+ and Python 3.11+.

The launcher uses the signed-in Codex CLI bridge for ChatGPT 6 Luna (gpt-6-luna). It does not need an OpenAI API key. It does not start local Qwen or the optional retrieval workers. Luna is the default narrator for new sessions, and a Luna-pinned session never falls back to Qwen.

## First run

Clone this repository, then run these commands in PowerShell:

~~~powershell
Set-ExecutionPolicy -Scope Process Bypass
cd D:\projects\Cases-Startup
.\cases.ps1 setup
.\cases.ps1 install-dashboard
~~~

On the dashboard's first visit, open http://127.0.0.1:8765 and create its local administrator account. This setup downloads pinned source checkouts, writes ignored .env files under Cases-AI and Cases-Backend, and generates independent gateway and database secrets. Secrets stay outside this repository and are never printed. Existing valid secrets are preserved. If the Cases-AI and backend client tokens disagree, setup stops and asks you to align them rather than rotating either one.

## Start the game

~~~powershell
.\cases.ps1 start
~~~

The launcher starts the Luna bridge and private gateway, starts the backend and waits for its API and database readiness, then checks Luna availability before opening Godot. On a fresh install, Luna is disabled. The launcher opens the dashboard and waits for an operator to review the cloud-data disclosure, check the consent box, and enable Luna on the Providers page. It does not enable Luna through an API call or send a completion during startup.

If Luna is already enabled from a previous dashboard consent, startup proceeds directly to the GUI after checking readiness. If the dashboard has not been installed or Luna is not ready, the model services and backend remain available for diagnosis; the game GUI is not launched. Fix the dashboard/provider state and run .\cases.ps1 start-gui afterward.

## Start each part separately

~~~powershell
.\cases.ps1 start-models
.\cases.ps1 start-backend
.\cases.ps1 start-gui
.\cases.ps1 status
~~~

start-models starts the Cases-AI Codex bridge and gateway. start-backend starts PostgreSQL, migrations, API, and turn worker. start-gui starts Godot only after the backend and Luna narrator report ready. Run the commands in that order when starting manually. Local Qwen and historical retrieval are separate optional services documented in Cases-AI.

Use -ProjectRoot to choose another checkout directory, and -GodotPath if Godot is installed elsewhere:

~~~powershell
.\cases.ps1 setup -ProjectRoot E:\CASES
.\cases.ps1 start -ProjectRoot E:\CASES -GodotPath 'C:\Apps\Godot\Godot_v4.7.2-stable_win64.exe'
~~~

The launcher verifies each repository's origin, locked commit, and clean working tree. It never resets or overwrites a mismatched or dirty checkout; choose a separate -ProjectRoot to create a clean pinned copy.

## Stop and inspect

~~~powershell
.\cases.ps1 status
.\cases.ps1 stop
~~~

stop stops the GUI process started by this launcher, the Cases backend and gateway Compose projects, and the bridge process recorded by this launcher. It uses docker compose down without -v; the PostgreSQL and gateway state volumes remain intact. It does not stop unrelated processes that happen to use the bridge ports.

## Service boundaries

- Cases-AI is the canonical inference repository. The local bridge binds only to 127.0.0.1; the gateway inference network has no host-published port. The administrator proxy is loopback-only.
- The gateway's Luna enabled state is controlled through the Cases-AI dashboard consent flow. A new gateway state starts disabled; the persistent volume preserves later operator choices.
- Cases-Backend exposes its API on 127.0.0.1:18081, matching the Godot client's default URL. PostgreSQL has no host-published port.
- setup creates configuration only. It does not start containers, use the model, or send prompts.
- The three source revisions are pinned in repos.lock.json. Review/update that lock when promoting new source revisions.

For repository-specific operations and recovery limits, see the READMEs in Cases-AI, Cases-Backend, and Cases-GUI.
