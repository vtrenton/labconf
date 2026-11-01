# kiosk

The rack TV: a Raspberry Pi running `kiosk.service`, which starts
[cage](https://github.com/cage-kiosk/cage) (a single-app Wayland compositor)
with Chromium in kiosk mode on the Lab overview dashboard:

```
https://grafana.infra.lab.trentonvanderwert.com/?kiosk
```

## Why it needs no login

That URL is the **LAN** path to Grafana, not the Teleport one:

| | TV (LAN) | Teleport |
|---|---|---|
| URL | `https://grafana.infra.lab.trentonvanderwert.com` | `https://grafana.teleport.aws.trentonvanderwert.com` |
| Resolves via | `labns` only (`10.0.0.165`); public DNS has no record | public DNS -> the Teleport proxy |
| Path | TV -> infralab Gateway -> Grafana | browser -> Teleport login + MFA -> tunnel -> Grafana |
| Grafana sees | no Teleport JWT -> **anonymous Viewer** (read-only) | a signed JWT -> that user (`lab-admin` = Admin) |

Grafana serves both at once: requests carrying Teleport's JWT are that user,
everything else is anonymous Viewer (no editing, no login form). So the TV
holds no credentials, and isn't joined to Teleport: anything on the LAN can
view Grafana read-only. To restrict the anonymous path to the TV, a Cilium
network policy on the Gateway could allow it only from the TV's IP.

Seeing a Teleport login instead means the browser opened the Teleport URL,
or is on a network whose DNS doesn't use `labns` (the LAN URL then doesn't
resolve at all).

## Requirements on the TV Pi

The unit file is the only part in git. It expects:

- packages `cage` and `chromium`;
- a `kiosk` user, and a PAM service `kiosk` (`/etc/pam.d/kiosk`) for the
  logind session (`PAMName=kiosk`);
- `/etc/default/kiosk` (`EnvironmentFile`; present on the Pi, not in git);
- DNS through `labns` (`10.0.0.5`), or the URL won't resolve;
- `graphical.target` as the default target, with the unit enabled:

```
sudo cp kiosk.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kiosk.service
```

It takes over `tty1` (`Conflicts=getty@tty1.service`) and restarts every 5 s
if Chromium or cage exits. Logs: `journalctl -u kiosk`.

The TV Pi is not managed by Ansible or Teleport.
