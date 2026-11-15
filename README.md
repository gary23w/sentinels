# sentinels

Automated host intrusion detection and response for Linux, macOS and Windows. Sentinels watches for hostile behavior on a machine and can stop a suspicious process before the next stage runs.

[![verify](https://github.com/gary23w/sentinels/actions/workflows/verify.yml/badge.svg)](https://github.com/gary23w/sentinels/actions/workflows/verify.yml)
[![release](https://img.shields.io/github/v/release/gary23w/sentinels)](https://github.com/gary23w/sentinels/releases)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Fast, automated attack chains leave little time for a person to read an alert and intervene. [CERT-EU has documented how AI-powered frameworks such as ARTEX can work through long attack chains](https://www.cert.europa.eu/blog/from-penetration-testing-to-cyber-threat-beware-of-artex).

`garrett`, the sentinel in this repo, sits on the machine. If a web server starts a shell that downloads a script, it can end that shell before the script runs. Then it tells you what it did and why.

The agent is one program file. Local protection needs no account, cloud console or kernel module. For a fleet, run the service on your own hardware or use a managed hosted deployment. AI-assisted case analysis is optional; the fast local response path does not wait for a model.

## Install

Linux and macOS:

```sh
curl -fsSL https://gary23w.github.io/sentinels/install.sh | sudo sh
```

Windows, from an elevated PowerShell:

```powershell
irm https://gary23w.github.io/sentinels/install.ps1 | iex
```

That is the whole setup. The machine is protected from that moment, and garrett keeps itself up to date from here on.

To see what it has caught:

```sh
garrett cases
```

## What you get

It acts as a program starts. In current internal benchmarks, reported stopping time is about **20 ms** in rapid process-chain scenarios and **under 5 ms** in selected tool-driven scenarios. These are scenario-specific measurements, not a guarantee for every attack or machine. The test setup, timing boundaries, sample size and raw results will be attached to this README.

It cleans up. The dropped file goes to quarantine, and the cron job, Run key or service that would bring it back gets switched off. If garrett got it wrong, `garrett restore <case>` puts everything back the way it was.

It tells you why. Every case comes with its reasons in plain sentences, like "A shell was started by the web server process, the pattern a web shell leaves."

It listens to you. Run `garrett trust <case>` once and it leaves that program alone for good.

It stays current. New versions are signed with a key that is kept off GitHub, and garrett checks that signature before it installs anything. If you would rather update by hand, put `UPDATE=off` in its config file.

## Protect a whole fleet

One machine on its own is fine. If you have several, turn one of them into your own service:

```sh
curl -fsSL https://gary23w.github.io/sentinels/service.sh | sudo sh
```

It prints the command that joins your other machines. From then on, what one machine learns from an attack protects the rest, and every case shows up in one place. This self-hosted option runs on your hardware and keeps your cases there. A managed hosted option is also available.

## Optional AI analysis

The service can ask a configured AI provider for a second opinion on a case and a plain-language summary. In `decide` mode, the agent first freezes a suspicious program, then lets the configured model recommend whether to stop, release or hold it. The default `kill` mode uses the local detection and response path; it does not require an AI provider.

## How hard it hits

You choose. The default is `kill`.

| Mode | What garrett does with a hostile program |
|---|---|
| `kill` | Ends it, and everything it started, at once |
| `pause` | Freezes it and waits for you to decide |
| `decide` | Freezes it and lets your service's model decide |
| `report` | Only tells you |

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

The agent lives in `rust/`, the service in `server/`, and the installers in `packaging/` and `deploy/`.

To remove it: `sudo apt purge garrett` on Debian and Ubuntu, `sudo sh install.sh --remove` from the Linux or macOS bundle, or `Uninstall garrett.cmd` from the Windows bundle. It takes its firewall rules and its files with it.

## License

MIT. Found a hole in it? Open an issue. That is exactly the kind of thing I want to know about.
