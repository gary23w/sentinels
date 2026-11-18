# Active Directory lab

The lab uses two Windows Server domains, `alpha.lab.test` and `bravo.lab.test`. Each has a domain controller and one member on its own VirtualBox internal network. The host runs one HTTPS service for both tenants. Use a report-mode pilot when validating installation and telemetry.

## Configure the host service

Set up two tenant DNS names that the guests can reach. For guests using VirtualBox NAT to reach the host loopback, the service destination is `10.0.2.2` and the NAT adapter must allow access to the host loopback. Use a certificate valid for both tenant names or the certificate fingerprint included with a self-hosted enrolment command. [VirtualBox NAT settings](https://docs.oracle.com/en/virtualization/virtualbox/7.2/user/vboxmanage.html)

Use this layout for the host service configuration.

```ini
ADDRESS=127.0.0.1
PORT=18443
TLS_CERT=C:/garrett-lab/service/tls.crt
TLS_KEY=C:/garrett-lab/service/tls.key
TENANTS=C:/garrett-lab/service/tenants
LOG=C:/garrett-lab/service/dev.jsonl
```

Create one file per tenant in that directory, for example `alpha.conf`. Replace the example values with credentials generated for that tenant. Keep the tenant files on the host with restricted permissions.

```ini
HOST=alpha.sentinel.lab
DATABASE=C:/garrett-lab/service/alpha.db
ENROLL_KEY=<unique enrolment key, 32 or more characters>
ADMIN_TOKEN=<unique operator token, 32 or more characters>
DATA_KEY=<unique data key, 32 or more characters>
RESPONSE_MODE=report
WATCHLIST=off
TOR_EXITS=off
```

Give Bravo its own hostname, database file, and keys. When forwarding audit or edge events, assign a distinct `INGEST_TOKEN` to each tenant. Start the host service with `node server/serve.mjs C:/garrett-lab/service/service.conf`. Each tenant can set `MEMORY` in its own file to override the host default.

## Verify domain DNS

From each member, verify `Test-ComputerSecureChannel` returns `True` and resolve its DC's fully qualified hostname against the domain DNS server. The lab DC addresses are `10.10.1.10` and `10.10.2.10`.

If a DC is also publishing the VirtualBox NAT address `10.0.2.15`, keep DNS registration on the domain-facing NIC. Set the DNS service's `PublishAddresses` value under `HKLM\SYSTEM\CurrentControlSet\Services\DNS\Parameters` to the DC's internal address, restart DNS, and remove the stale NAT A record from that DC's hostname. Clear the DNS client cache and verify from the member that the hostname has only the internal address. [Microsoft’s DNS registration guidance](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/enable-disable-dns-dynamic-registration)

## Verify rollout and reporting

On each DC, use `deploy\domain-rollout.ps1` from the Windows bundle. Pass that tenant's HTTPS address and enrolment key. Use `-Target` for the pilot OU, `-Mode report` to record cases, and `-Update off` to keep the pilot on the build under test. At the member's next startup, check that the `garrett` computer policy applies, the `garrett` task runs as SYSTEM, and the startup log at `%WINDIR%\Temp\garrett-rollout.log` records the install or repair.

In the service log, look for a successful `POST /v1/enroll` for a fresh install and `POST /v1/report` from each enrolled machine. Compare the logged device IDs with the tenant's device list. Check the Windows Security log coverage field on the report. Verify audit policies and matching directory audit rules separately when validating a specific event. [Microsoft’s Windows event auditing guide](https://learn.microsoft.com/en-us/defender-for-identity/deploy/configure-windows-event-collection)

Housekeeping records a silence when a previously reporting machine misses the heartbeat window. A saved VM can also miss that window. Use `SILENT_CASES=off` in a tenant file if that tenant is routinely paused during development.
