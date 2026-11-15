# sentinels

A guard for your servers and workstations that ends a break-in while it is still starting.

[![verify](https://github.com/gary23w/sentinels/actions/workflows/verify.yml/badge.svg)](https://github.com/gary23w/sentinels/actions/workflows/verify.yml)
[![release](https://img.shields.io/github/v/release/gary23w/sentinels)](https://github.com/gary23w/sentinels/releases)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Most security tools watch an attack happen and then send you an alert about it. By the time you read the alert, the attacker has settled in.

`garrett`, the sentinel in this repo, works the other way round. It sits on the machine, sees your web server start a shell that downloads a script, and ends that shell before the script runs. Then it tells you what it did and why.

It is one program file. You don't need an account, a cloud console or a kernel module. It runs on Linux, macOS and Windows.

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

It acts the moment a program starts. In our tests a hostile shell is gone roughly 5 to 10 milliseconds after it appears, which is before it has done what it was sent to do.

It cleans up. The dropped file goes to quarantine, and the cron job, Run key or service that would bring it back gets switched off. If garrett got it wrong, `garrett restore <case>` puts everything back the way it was.

It tells you why. Every case comes with its reasons in plain sentences, like "A shell was started by the web server process, the pattern a web shell leaves."

It listens to you. Run `garrett trust <case>` once and it leaves that program alone for good.

It stays current. New versions are signed with a key that is kept off GitHub, and garrett checks that signature before it installs anything. If you would rather update by hand, put `UPDATE=off` in its config file.

## Protect a whole fleet

One machine on its own is fine. If you have several, turn one of them into your own service:

```sh
curl -fsSL https://gary23w.github.io/sentinels/service.sh | sudo sh
```

It prints the command that joins your other machines. From then on, what one machine learns from an attack protects the rest, and every case shows up in one place. The service runs on your hardware and your cases stay there.

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
