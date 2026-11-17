# Security

Found a hole in garrett, the Sentinel service or the way they are installed and updated? Good. That is exactly the kind of thing this project wants to know about.

## How to report it

If the hole could be used against machines that run garrett before a fix is out, report it privately: [report a vulnerability](https://github.com/gary23w/sentinels/security/advisories/new). Only the maintainers see that report.

Anything else, [open an issue](https://github.com/gary23w/sentinels/issues/new/choose).

Please include:

- the version (`garrett version` prints it);
- the system it runs on;
- what you did, what you expected and what happened.

## What it covers

- the agent in `rust/`;
- the service in `server/`;
- the installers and packages in `packaging/`, `deploy/` and `debian/`;
- the update path: the site's update list, its signature and the signed apt repository.

## Fixes

A fix ships as a new release. Installed agents pick it up on their own unless `UPDATE=off` is set in their configuration file.
