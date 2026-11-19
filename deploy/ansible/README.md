# gary23w.sentinels

garrett, the agent of [sentinels](https://github.com/gary23w/sentinels), on every machine of a fleet. Its role `garrett` installs garrett the way the project's own instructions do, and enrols each machine with your Sentinel service if you give it one.

```sh
ansible-galaxy collection install gary23w.sentinels
```

```yaml
- hosts: all
  become: true
  roles:
    - role: gary23w.sentinels.garrett
      vars:
        garrett_server: https://sentinel.example.org
        garrett_enroll_key: "{{ vault_garrett_enroll_key }}"
        garrett_mode: report
```

On Windows, connect as an administrator and leave out `become`.

## What the role does

| System | |
|---|---|
| Debian, Ubuntu | Adds the project's signed apt repository (the key is checked against the SHA-256 that `packaging/install.sh` pins), then `apt install garrett`. |
| Fedora, RHEL and their relatives | Imports the project's signing key only if its fingerprint is `6857 EBCB BEF5 1040 C3F2 0107 3626 88BF C238 AB45`, adds the rpm repository as `packaging/rpm/garrett.repo` defines it, then installs garrett with dnf. On Fedora, Ansible's dnf5 module needs `python3-libdnf5` on the machine. |
| openSUSE | The same key and repository, in `/etc/zypp/repos.d`, then `zypper install garrett`. |
| Windows | Downloads `garrett-windows.msi` from the newest GitHub release and installs it, unless garrett is already installed: garrett updates itself. |

On Linux it then starts garrett and has it start at every boot (`systemctl enable --now garrett`).

## Settings

| Variable | Default | |
|---|---|---|
| `garrett_server` | empty | Your Sentinel service. Give it with `garrett_enroll_key`, or leave both out and each machine protects itself by itself. |
| `garrett_enroll_key` | empty | The enrolment key the service gave you. Keep it in Ansible Vault; the role never prints it. Anyone who has it can add a machine. |
| `garrett_mode` | empty (`kill`) | `kill`, `decide`, `pause` or `report`: what garrett does with a hostile program. |
| `garrett_label` | empty (the host name) | The name a machine enrols under. |
| `garrett_manage_service` | `true` | Linux: start garrett now and restart it when its settings change. `false` leaves the service alone, for an image that starts it on its first boot. |
| `garrett_repository` | `https://gary23w.github.io/sentinels` | Where the apt and rpm repositories are. |
| `garrett_apt_key_sha256`, `garrett_key_fingerprint` | the project's key | The signing key the repositories must carry. |
| `garrett_msi_url` | the newest release's `garrett-windows.msi` | Windows: where the package comes from. |

On Linux the settings go into `/etc/garrett/garrett.conf` (root only, mode 0600) before garrett is installed, as the one-line installer writes them, and the role writes the whole file. With a service and a key in it, garrett enrols the machine the first time it starts. On Windows the role runs `garrett enroll` itself, with the key handed to the agent through its environment, and restarts the `garrett` scheduled task. There, `garrett_mode` and `garrett_label` take effect with enrolment.

A machine enrols once and keeps its credential: a new key or service changes nothing on a machine that is enrolled already. To move one, run `garrett forget` on it first (`sudo garrett forget` on Linux, `"C:\Program Files\garrett\garrett.cmd" forget` on Windows).

## Removing it

`sudo apt purge garrett`, `sudo dnf remove garrett` or `sudo zypper remove garrett`, or garrett in Windows' Apps and Features. See the [README](https://github.com/gary23w/sentinels#docs-source-and-removal).

MIT licensed. The source is in `deploy/ansible` of [gary23w/sentinels](https://github.com/gary23w/sentinels).
