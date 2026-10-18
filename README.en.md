# dshctl

> An all-in-one installer / operator / cleaner script for DeepSeek Harness (dsh)

[![CI](https://github.com/ThzxxArt/dshctl/actions/workflows/ci.yml/badge.svg)](https://github.com/ThzxxArt/dshctl/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/thzxx/dshctl?display_name=tag)](https://github.com/ThzxxArt/dshctl/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-blue)](#requirements)

`dshctl.sh` is a zero-dependency, single-file Bash script that installs
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) from source and then
covers day-to-day operations: status checks, service control, plugin management, model
configuration troubleshooting, data backup, version rollback and full uninstall.

```bash
# Install from source (clone + deps + build + launcher) in one command
bash dshctl.sh --install -y --api-key sk-xxxx
# Then
dshctl --status / --doctor / --restart / --logs
```

> [!IMPORTANT]
> This is a community-maintained **unofficial** tool, not affiliated with DeepSeek.
> DeepSeek Harness itself is an early developer preview and may introduce breaking changes.
> Report upstream issues to [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness/issues).

## Features

- One-command install: environment check → Node.js (nvm first, official tarball fallback) →
  pnpm via Corepack → clone → `pnpm install` → `pnpm run build` → `.env` → `dsh` launcher.
- Idempotent and incremental: skips install/build when the source tree is unchanged,
  backs up `~/.dsh` before upgrades, prints the failing line on errors.
- China-network friendly: proxy auto-detection, GitHub mirror, npm/Node mirror fallback.
- Operations: `--status`, `--doctor`, `--start|--stop|--restart|--logs`, optional `systemd --user`.
- Web exposure: `--url`, `--web-lan` / `--host <IP>` (binds a concrete interface address on
  dsh 0.2.1+, or the `0.0.0.0` patch on older dsh), `--public-url` for reverse-proxy fronting,
  `--tls-cert`/`--tls-key` native HTTPS, `--port 0` for an OS-assigned port.
- Plugin management per profile, including pnpm `minimumReleaseAge` policy audit, lockfile
  repair, and the dsh 0.2.0+ plugin compatibility gate (exact-version exemption management).
- Model config checks/fixes for the dsh 0.1.6+ Messages protocol (Base URL must not be in `.env`),
  with dsh 0.1.7+ settings stored in the profile's `cordis.patch.yml`.
- Data maintenance: backup/restore/session archive/cache prune, all destructive actions confirmed
  and `--dry-run` previewable.
- Uninstall: partial (`--uninstall`) or full (`--purge`, with automatic data backup).

## Requirements

Linux, macOS or WSL (x86_64 / arm64); Bash 3.2+; `git` ≥ 2.26, `curl`, `tar`.
Node.js 22.19+ / 24+ is installed automatically when missing. About 5 GB free disk recommended.

## Quick start

```bash
git clone https://github.com/ThzxxArt/dshctl.git
cd dshctl
bash dshctl.sh --install -y --api-key sk-xxxx
bash dshctl.sh --register      # optional: install the dshctl command globally
dshctl --status
```

Then open `http://127.0.0.1:3080` (use `dshctl --url` for the tokenized URL), fill in your
API key under Settings → Model, and select a workspace directory. On a loopback HTTP origin
(dsh 0.2.1+), Settings → Account can sign in to a DeepSeek account instead of using an API key;
deployments exposed through `--web-lan` / `--public-url` / `--tls-cert` / `--trusted-host` still
need an API key.

Update, rollback and uninstall:

```bash
bash dshctl.sh --install          # update from upstream
bash dshctl.sh --upgrade-check    # check only
bash dshctl.sh --rollback         # roll back to the previous successful install
bash dshctl.sh --uninstall        # keep source and data
bash dshctl.sh --purge -y         # full cleanup (backs up ~/.dsh first)
```

## Command overview

| Area | Commands |
| --- | --- |
| Install | `--install` (`--dir` `--ref` `--shallow` `--clean` `--force-update` `--clean-build`) |
| Inspect | `--status`, `--doctor` |
| Service | `--start`, `--stop`, `--restart`, `--logs [--last N]` |
| Plugins | `--plugin-list/add/remove/update/why/repair` |
| Plugin policy | `--plugin-policy`, `--plugin-policy-set N`, `--plugin-policy-reset` |
| Plugin exemptions | `--plugin-exemptions`, `--plugin-allow SPEC`, `--plugin-revoke SPEC` (dsh 0.2.0+) |
| Model | `--model-show`, `--model-check`, `--model-fix`, `--model-set-base URL` |
| Data | `--data-backup`, `--data-restore FILE`, `--data-archive-sessions`, `--data-prune` |
| Versions | `--rollback [REF]`, `--upgrade-check`, `--backups-list`, `--backups-prune [N]` |
| Web access | `--url`, `--web-lan`, `--host IP`, `--public-url URL`, `--tls-cert FILE`, `--tls-key FILE`, `--trusted-host HOST` |
| Network | `--git-proxy URL`, `--github-mirror URL`, `--npm-mirror URL`, `--node-mirror URL`, `--no-proxy`, `--no-mirror` |
| Lifecycle | `--register`, `--unregister`, `--uninstall`, `--purge` |
| Common | `-y`, `--dry-run`, `--log FILE`, `-V`, `-h` |

Run `bash dshctl.sh --help` for the authoritative option list.

## Documentation

The primary documentation is written in Chinese:

- [README.md](README.md) — full feature and configuration reference
- [docs/usage.md](docs/usage.md) — scenario-based usage guide
- [docs/troubleshooting.md](docs/troubleshooting.md) — FAQ and troubleshooting
- [docs/reverse-proxy.md](docs/reverse-proxy.md) — reverse proxy (nginx) requirements and template
- [docs/development.md](docs/development.md) — repository layout, tests and release process

## Security

`--web-lan` / `--host <IP>` (and `--public-url` behind a reverse proxy) expose a
shell-capable web UI to a wider network — use them only on trusted networks, and name
custom domains with `--trusted-host`. dsh itself gates first access with a launch token
(open the full `?token=` URL; `dshctl --url` prints it), but the listening port is not
protected: never expose it directly to the internet, and add your own authentication at
the proxy. Secrets are stored with `600` permissions and never uploaded. See
[SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

[MIT](LICENSE). DeepSeek Harness is an official DeepSeek project (MIT); dshctl is an
unaffiliated community tool.
