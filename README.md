![Agent Garrett shields computers from the AI apocalypse](assets/agent-garrett-ai-apocalypse.png)

# sentinels

A guard for your servers and workstations that ends a break-in while it is still starting.

[![verify](https://github.com/gary23w/sentinels/actions/workflows/verify.yml/badge.svg)](https://github.com/gary23w/sentinels/actions/workflows/verify.yml)
[![release](https://img.shields.io/github/v/release/gary23w/sentinels)](https://github.com/gary23w/sentinels/releases)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Most security tools watch an attack happen and then send you an alert about it. By the time you read the alert, the attacker has settled in.

`garrett`, the sentinel in this repo, works the other way round. It sits on the machine, sees your web server start a shell that downloads a script, and ends that shell before the script runs. Then it tells you what it did and why.

It also knows how an AI agent works once it gets in: commands at machine pace, retries with small changes, sub-agents repeating each other. When a web server or a document starts running commands at machine pace, garrett ends it. [How it spots one](https://gary23w.github.io/sentinels/ai-attacks.html).

It is one program file. You don't need an account, a cloud console or a kernel module. It runs on Linux, macOS and Windows.

## Setup

One line per machine. No account, no sign-up, nothing to configure.

### One computer

Linux or macOS, in a terminal:

```sh
curl -fsSL https://gary23w.github.io/sentinels/install.sh | sudo sh
```

Windows, in PowerShell opened with "Run as administrator":

```powershell
irm https://gary23w.github.io/sentinels/install.ps1 | iex
```

Done. The machine is protected from that moment, garrett starts again at every boot, and it keeps itself up to date.

### With a package manager

The same garrett, from the project's signed repositories or your package manager. The packages are named garrett, after the program they install; the name sentinels works as well, and installs garrett with apt, pacman, dnf and zypper (`sudo apt install sentinels`).

| System | Install |
|---|---|
| Debian, Ubuntu | Add the apt repository below, then `sudo apt install garrett` |
| Arch Linux | Add the pacman repository below, then `sudo pacman -Syu garrett && sudo systemctl enable --now garrett` |
| Fedora, RHEL | `sudo curl -fsSL -o /etc/yum.repos.d/garrett.repo https://gary23w.github.io/sentinels/garrett.repo`, then `sudo dnf install garrett && sudo systemctl enable --now garrett` |
| openSUSE | `sudo zypper addrepo https://gary23w.github.io/sentinels/garrett.repo`, then `sudo zypper install garrett && sudo systemctl enable --now garrett` |
| macOS, Linux with Homebrew | `brew install gary23w/sentinels/garrett`, then the `sudo sh …/install.sh` line it prints, which starts garrett as root from a root-owned folder |
| Windows with Scoop | `scoop install https://gary23w.github.io/sentinels/garrett.json`, from PowerShell opened with "Run as administrator" |
| Windows Installer | [garrett-windows.msi](https://github.com/gary23w/sentinels/releases/latest/download/garrett-windows.msi): double-click it, or `msiexec /i garrett-windows.msi /qn` from Intune, Group Policy or your own tools |

The apt repository:

```sh
curl -fsSL https://gary23w.github.io/sentinels/garrett.gpg | sudo tee /usr/share/keyrings/garrett.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/garrett.gpg] https://gary23w.github.io/sentinels stable main" | sudo tee /etc/apt/sources.list.d/garrett.list
sudo apt update
```

The pacman repository:

```sh
curl -fsSL https://gary23w.github.io/sentinels/garrett.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key 6857EBCBBEF51040C3F20107362688BFC238AB45
printf '\n[sentinels]\nServer = https://gary23w.github.io/sentinels/arch/$arch\n' | sudo tee -a /etc/pacman.conf
```

All three repositories are signed with the key whose fingerprint is `6857 EBCB BEF5 1040 C3F2 0107 3626 88BF C238 AB45`.

### All your computers and servers

**1. Pick one machine to be the hub.** Run this on it.

Linux:

```sh
curl -fsSL https://gary23w.github.io/sentinels/service.sh | sudo sh
```

Windows, in PowerShell opened with "Run as administrator":

```powershell
irm https://gary23w.github.io/sentinels/service.ps1 | iex
```

**2. Copy the line it prints.** There is one for Linux and macOS and one for Windows. It is the install line from above with your hub's address and key added.

**3. Run that line on every other machine.** By hand, or with whatever already runs commands on your machines: ssh, Ansible, Intune, your MDM. It is the same line everywhere and it asks no questions.

Every machine now protects itself and reports to your hub, and what one machine learns from an attack protects the rest. Keep the line private: anyone who has it can add a machine. To print it again: `sudo garrett-service join` (on a Windows hub, `"C:\Program Files\garrett-service\garrett-service.cmd" join`).

On Kubernetes, `deploy/kubernetes-daemonset.yaml` puts garrett on every node: build the image, fill in your hub's address and key, and `kubectl apply` it.

Or with Helm, which puts the same DaemonSet on every node with the release's image, using the address and key from the line your hub printed (to keep the key in a Secret of your own instead, see `enrolment.existingSecret` in [deploy/helm/garrett/values.yaml](deploy/helm/garrett/values.yaml)):

```sh
helm install garrett oci://ghcr.io/gary23w/charts/garrett --namespace garrett --create-namespace --set enrolment.server=https://your-hub --set enrolment.key=<enrolment key>
```

### Check that it worked

| On | Run |
|---|---|
| Linux | `garrett status` |
| macOS | `sudo "/Library/Application Support/Garrett/garrett" status` |
| Windows | `"C:\Program Files\garrett\garrett.cmd" status` |
| A Linux hub | `sudo garrett-service devices` lists every machine that reports to it |
| A Windows hub | `"C:\Program Files\garrett-service\garrett-service.cmd" devices` does the same |

Put `cases` in place of `status` to see what garrett has caught.

### If you are an AI agent doing the install

- Run the lines above as they are, as root or as an administrator. They take no input and stop with an error if anything fails.
- Each installer checks what it downloads against a SHA-256 written into the script, and installs nothing that does not match. Do not work around a failed check.
- Do not print, log or commit the join line or the hub's key. Pass them straight to the machine that needs them.
- Confirm with the status command above before reporting success.

## What you get

It acts as a program starts. Current internal stopping-time figures are about 20 ms for rapid process-chain tests and under 5 ms for selected tool-driven tests. The test setup, timing boundaries, sample size and raw results have not yet been added here; these figures are not a guarantee for every host or attack.

It cleans up. The dropped file goes to quarantine, and the cron job, Run key or service that would bring it back gets switched off. If garrett got it wrong, `garrett restore <case>` puts everything back the way it was.

It tells you why. Every case comes with its reasons in plain sentences, like "A shell was started by the web server process, the pattern a web shell leaves."

It listens to you. Run `garrett trust <case>` once and it leaves that program alone for good.

It stays current. New versions are signed with a key that is kept off GitHub, and garrett checks that signature before it installs anything. If you would rather update by hand, put `UPDATE=off` in its config file.

## Protect a whole fleet

One machine on its own is fine. If you have several, the hub from [Setup](#setup) is your own service.

Its install line fetches one file from the release, checks it, and runs it. Inside it are the service, its decision model and the agent for that machine, so nothing else is downloaded. The service and the agent are set up as daemons that start at every boot. It prints the command that joins your other machines. From then on, what one machine learns from an attack protects the rest, and every case shows up in one place. The service runs on your hardware and your cases stay there.

The decision model is [crivo-sentinel-v1](https://huggingface.co/gary23w/crivo-sentinel-v1). When a machine freezes a hostile program, the model says whether to stop it, release it or hold it for you. It runs inside the service's own process, on the CPU; nothing leaves your machine. Add `--model off` (`$env:GARRETT_MODEL = 'off'` on Windows) to do without it.

To plug in a model of your own, or your own reasoning, run `sudo garrett-service setup` (`garrett-service.cmd setup` on Windows): a few questions, then it writes the settings and restarts the service. Add `--wizard` (`$env:GARRETT_WIZARD = '1'`) to the install line to answer them during the install instead. Or edit `/etc/garrett-service/service.conf` by hand: the lines are `AI_PROVIDER` (`decision`, `chat`, `custom` or `none`), `AI_BASE_URL`, `AI_MODEL`, `AI_API_KEY`, `AI_HIGH_CONFIDENCE`, `DECISION_RELEASE` and `DECISION_FALLBACK`, and `MODEL_DIR` for the model that came with it, described in `server/serve.mjs` and `server/wrangler.example.jsonc`. Restart the service after a change.

### Windows domain rollout

From the unpacked Windows bundle, run the rollout script in an elevated Windows PowerShell session with the Group Policy and Active Directory modules. Start with a pilot OU and use the enrolment key exactly as the service supplied it, including the certificate fingerprint if present.

```powershell
.\deploy\domain-rollout.ps1 -Target 'OU=Pilot,DC=example,DC=org' -Server 'https://sentinel.example.org' -EnrollKey $enrollKey -Mode report -Update off
```

Group Policy installs the agent as SYSTEM at the next computer startup. The rollout options apply to new installations, and the startup script records installation and task repair in `%WINDIR%\Temp\garrett-rollout.log`. The service coverage view reports whether the agent successfully queried the Security log. Windows audit policy controls which events reach that log. Directory Service Access events also require a matching audit rule on the directory object. [Microsoft’s Windows event auditing guide](https://learn.microsoft.com/en-us/defender-for-identity/deploy/configure-windows-event-collection)

See the [Active Directory lab runbook](deploy/active-directory-lab.md) for the two-tenant service setup, DNS repair and rollout checks.

### Development logs

Set `LOG=on` in the self-hosted service configuration to emit JSON Lines to standard error, or set `LOG` to a file path to append there as well. For local-only testing with `node local.mjs`, use `SENTINEL_LOG`. The logs show request status and timing, accepted device IDs, signal IDs, and housekeeping results. Look up device labels in the operator device list. The local service runs housekeeping every `SENTINEL_HOUSEKEEP` seconds when that variable is set.

## How hard it hits

You choose. The default is `kill`.

| Mode | What garrett does with a hostile program |
|---|---|
| `kill` | Ends it, and everything it started, at once |
| `pause` | Freezes it and waits for you to decide |
| `decide` | Freezes it and lets the service's model decide: [crivo-sentinel-v1](https://huggingface.co/gary23w/crivo-sentinel-v1), or one of your own |
| `report` | Only tells you |

The default `kill` mode does not call a model. AI case analysis and `decide` mode need a model on the service; the service installer sets one up, and `decide` becomes the default for machines that report to it.

Nervous about letting it end things? Start it in report mode and read the cases for a week:

```sh
curl -fsSL https://gary23w.github.io/sentinels/install.sh | sudo sh -s -- --mode report
```

## Docs, source and removal

The manual is at [gary23w.github.io/sentinels/manual.html](https://gary23w.github.io/sentinels/manual.html), or `man garrett` on Debian and Ubuntu.

To build it yourself you need Rust:

```sh
cd rust && cargo test && cargo build --release
```

The agent lives in `rust/`, the service in `server/`, the installers in `packaging/` and `deploy/`, and the stub of the one-file service installer in `packaging/installer/`. The decision model, with the code that trains and measures it, is its own repository: [huggingface.co/gary23w/crivo-sentinel-v1](https://huggingface.co/gary23w/crivo-sentinel-v1). Clone it as `model/` inside this one to train it again.

To remove it: `sudo apt purge garrett` on Debian and Ubuntu, `sudo pacman -R garrett`, `sudo dnf remove garrett` or `sudo zypper remove garrett` where those installed it, `sudo sh install.sh --remove` from the Linux or macOS bundle (with Homebrew, the `--remove` line it printed, then `brew uninstall garrett`), `scoop uninstall garrett`, garrett in Windows' Apps and Features, or `Uninstall garrett.cmd` from the Windows bundle. It takes its firewall rules and its files with it.

## License

MIT. Found a hole in it? Open an issue, or [report it privately](SECURITY.md) if it could hurt people before a fix is out. That is exactly the kind of thing I want to know about.

## Want to power your Sentinels with AI?

We can host the Sentinels service for you through [Agent Garrett](https://agent.garrettstimpson.ca/apocalypse). Keep the open-source agent on your computers and manage their cases in one place, with unlimited AI case reviews, plain-language reports and AI-assisted response.

**Flat $9.99/month in CAD or USD, based on your location. Sentinel AI is a standalone subscription.**
