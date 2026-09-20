# Vultr code-server v0.1.4 deployment

Date: 2026-09-20

## Result

- Connected through the local Windows host using SSH alias `vultr`.
- Upgraded Debian package `code-server` from `0.1.3-1` to `0.1.4-1` (amd64).
- Release: https://github.com/EdwardHamu/code-server/releases/download/v0.1.4/code-server_0.1.4-1_amd64.deb
- Preserved existing service and environment configuration; restarted `code-server-lite.service`.
- Verified systemd `ActiveState=active`, `SubState=running`, `NRestarts=0`.
- Public HTTPS GET at https://meamoe.top/vscode/ returned HTTP 200 and the code-server lite HTML page.
- Recent journal shows successful startup on 127.0.0.1:8444/vscode/ without errors in the inspected entries.
- Authenticated editing and Git operations were not tested.

## Backup and server paths

- Root-only program/configuration archive on server: `/root/code-server-backup-0.1.3-before-0.1.4/program-config.tar.gz` (34 MB). Archive contents have not been restore-tested.
- Downloaded package on server: `/tmp/code-server_0.1.4-1_amd64.deb`.
- Preflight extracted package on server: `/tmp/code-server-0.1.4-preflight`.
- Existing workspace: `/srv/code-workspace`; existing user data was not modified by deployment commands.

## Risks and notes

- Ubuntu 18.10 is end-of-life. Running kernel is 4.9.187, below the package description requirement of kernel >=4.18.
- The new bundled Node.js v24.12.0 launches successfully on this host, and the restarted service responds. This does not establish full compatibility with the old kernel.
- No operating-system upgrade was attempted.
- The preserved service description still mentions v0.1.1; dpkg confirms the actual installed package is 0.1.4-1.
