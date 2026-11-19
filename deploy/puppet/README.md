# garrett

garrett, the agent of [sentinels](https://github.com/gary23w/sentinels), on every Linux machine Puppet manages. The class `garrett` installs it the way the project's own instructions do, starts it at every boot, and enrols the machine with your Sentinel service if you give it one.

```sh
puppet module install gary23w-garrett
```

```puppet
# Each machine protects itself.
include garrett

# Each machine reports to your service, in report mode.
class { 'garrett':
  server     => 'https://sentinel.example.org',
  enroll_key => Sensitive(lookup('garrett_enroll_key')),
  mode       => 'report',
}
```

## What it does

| System | |
|---|---|
| Debian, Ubuntu | Adds the project's signed apt repository (the key is checked against the SHA-256 that `packaging/install.sh` pins), then installs the package garrett. |
| Fedora, RHEL and their relatives, openSUSE | Imports the project's signing key only if its fingerprint is `6857 EBCB BEF5 1040 C3F2 0107 3626 88BF C238 AB45` (with `curl`, `gpg` and `rpm`), adds the rpm repository as `packaging/rpm/garrett.repo` defines it, then installs the package garrett with dnf or zypper. |

Then it starts garrett and has it start at every boot.

Windows is not covered: Puppet's Windows package provider installs only from a local or network path, so the Windows Installer package has to reach each machine first. Install `garrett-windows.msi` with `msiexec /i garrett-windows.msi /qn`, or with the domain rollout in the project's README.

## Parameters

| Parameter | Default | |
|---|---|---|
| `server` | none | Your Sentinel service. Give it with `enroll_key`, or leave both out and each machine protects itself by itself. |
| `enroll_key` | none | The enrolment key the service gave you, best as a `Sensitive` value. Anyone who has it can add a machine. |
| `mode` | none (`kill`) | `kill`, `decide`, `pause` or `report`: what garrett does with a hostile program. |
| `label` | none (the host name) | The name a machine enrols under. |
| `manage_service` | `true` | Start garrett now and restart it when its settings change. `false` leaves the service alone, for an image that starts it on its first boot. |
| `repository` | `https://gary23w.github.io/sentinels` | Where the apt and rpm repositories are. |
| `apt_key_sha256`, `key_fingerprint` | the project's key | The signing key the repositories must carry. |

The settings go into `/etc/garrett/garrett.conf` (root only, mode 0600, never shown in a diff) before garrett is installed, as the one-line installer writes them, and the class writes the whole file. With a service and a key in it, garrett enrols the machine the first time it starts. A machine enrols once and keeps its credential: a new key or service changes nothing on a machine that is enrolled already. To move one, run `sudo garrett forget` on it first.

## Removing it

`sudo apt purge garrett`, `sudo dnf remove garrett` or `sudo zypper remove garrett`. See the [README](https://github.com/gary23w/sentinels#docs-source-and-removal).

MIT licensed. The source is in `deploy/puppet` of [gary23w/sentinels](https://github.com/gary23w/sentinels).
