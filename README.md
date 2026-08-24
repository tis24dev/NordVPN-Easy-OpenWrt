# NordVPN Easy for OpenWrt

NordVPN Easy is a package-first NordVPN WireGuard integration for OpenWrt.
The project is being built around native OpenWrt components: UCI
configuration, init service integration, a LuCI frontend, and periodic
health-check and recovery logic.

## Project goals

- install `luci-app-nordvpn-easy` from LuCI `System -> Software`
  This only works after the relevant OpenWrt feeds and package indexes are set up and refreshed. In the build system, run the usual feeds update/install steps first; on the device, refresh package lists with `opkg update` or `apk update` before attempting installation from LuCI.
- configure NordVPN from LuCI and UCI instead of editing shell code
- keep the tunnel healthy through scheduled checks and event-triggered recovery
- support NordVPN recommended WireGuard servers, optionally filtered by country

## Repository layout

- `openwrt-packages/nordvpn-easy`
  Backend package with UCI defaults, init integration and the runtime shell
  core
- `openwrt-packages/luci-app-nordvpn-easy`
  LuCI frontend package

## Installation — OpenWrt 24.x and earlier (OPKG)

1. Log in to LuCI.
2. Open `System -> Software`.
3. Click `Update lists...`.
4. Install `luci-app-filebrowser`.
5. Log out from LuCI.
6. Log in again.
7. Open `System -> File Browser`.
8. Open `etc/opkg/keys`.
9. Download:
   `https://github.com/tis24dev/NordVPN-Easy-OpenWrt/raw/gh-pages/packages/opkg/e45702ccdd8637fd`
10. Upload the key file (without any extension, only name `e45702ccdd8637fd`
11. Open `System -> Software`.
12. Click `Configure opkg` and go: `/etc/opkg/customfeeds.conf`
13. Add: `src/gz nordvpn-easy https://tis24dev.github.io/NordVPN-Easy-OpenWrt/packages/opkg`
14. Save the `opkg` configuration.
15. Click `Update lists...`.
16. In the `Filter` box, search for `nordvpn-easy`.
17. Install `luci-app-nordvpn-easy`.
18. Log out from LuCI.
19. Log in again.
20. Open `Services -> NordVPN Easy`.
21. Configure the service.

## Installation — OpenWrt 25.x and later (APK)

1. Log in to LuCI.
2. Open `System -> Software`.
3. Click `Update lists...`.
4. Install `luci-app-filebrowser`.
5. Log out from LuCI.
6. Log in again.
7. Open `System -> File Browser`.
8. Open `etc/apk/keys`.
9. Download:
   `https://github.com/tis24dev/NordVPN-Easy-OpenWrt/releases/latest/download/vpn-easy-tis24dev.pem`
10. Upload the PEM file.
11. Open `System -> Software`.
12. Click `Configure apk` and go: `/etc/apk/repositories.d/customfeeds.list`
13. Add: `https://github.com/tis24dev/NordVPN-Easy-OpenWrt/releases/latest/download/luci-app-nordvpn-easy.adb`
14. Save the `apk` configuration.
15. Click `Update lists...`.
16. In the `Filter` box, search for `nordvpn-easy`.
17. Install `luci-app-nordvpn-easy`.
18. Log out from LuCI.

## Timing diagnostics CGI

The timing-log CGI is a lab/debug tool only. The OPKG/APK packages do **not**
install it to `/www/cgi-bin`; do not deploy it on production routers or routers
reachable from untrusted networks. Enable it only explicitly for controlled
diagnostics as described in `docs/DIAGNOSTICS.md`.

## Generate NordVPN Token

1. https://my.nordaccount.com/dashboard/nordvpn/access-tokens/
2. login
3. Get Access token
4. Generate new token
5. Copy the token
6. Close webpage

## Config NordVPN

1. Open `Services -> NordVPN Easy`
2. Paste the token
3. Select nation/server
4. Flag enable
5. Save&Apply
6. Wait green led

## Runtime model

The runtime model is service-driven and one-shot based:

- `/etc/config/nordvpn_easy` stores user configuration generated from the packaged template
- `/etc/init.d/nordvpn-easy` manages setup and recurring hooks
- `/usr/libexec/nordvpn-easy/core.sh` provisions the VPN through a single `provision` path
- `cron` runs periodic checks
- `hotplug` triggers checks when WAN or VPN interfaces change state

There is no permanently running watchdog loop.

**Connect, Reconnect, Setup, and Reconcile** always perform a clean reprovision: tear down any existing WireGuard UCI, fetch fresh NordLynx credentials and server data over the WAN, recreate `wg0`, then validate connectivity. Stale peer configuration is not reused.

## How checks work

Each `check` execution is one-shot and does this:

- pings the VPN interface
- skips recovery when WAN is down
- reprovisions the VPN when the runtime is degraded (for example no WireGuard handshake while the default route uses `wg0`)
- waits briefly and reprovisions again if ping still fails while WAN is up

This makes the project a service-managed maintenance job rather than a daemon
that loops forever.

## Configuration highlights

The packaged service is configured through UCI in `/etc/config/nordvpn_easy`.
The package ships its defaults as `/usr/share/nordvpn-easy/defaults/nordvpn_easy`
and creates or migrates the live UCI file during install/upgrade, preserving
existing user values without installing `/etc/config/nordvpn_easy` as an opkg
conffile. Removing the package purges the generated config, stale `*-opkg`
files and NordVPN Easy runtime/cache residues. Key settings include:

- `nordvpn_token`
- `wan_if`
- `vpn_if`
- `vpn_country`
- `wireguard_persistent_keepalive` (default `15`)
- `wireguard_mtu` (empty means automatic)
- `firewall_mtu_fix` (default `1`)
- `routing_mode` (`full_tunnel` default, or `policy` -- see below)
- health-check timing values (`failure_retry_delay`, `post_restart_delay`, and related delays)

Country filtering is supported. The backend resolves the requested country and
then asks NordVPN for recommended WireGuard servers inside that country. City
selection is not implemented.

### Routing mode: full tunnel or policy-based routing

`routing_mode` decides who owns the system routing table.

`full_tunnel` (the default, and the historical behaviour) sets
`route_allowed_ips=1` on the WireGuard peer, so netifd installs
`default dev wg0` in the main routing table, and demotes the WAN interface to
`metric 1024` so the tunnel wins. Every LAN client egresses through the VPN.

`policy` leaves the main routing table untouched: no default route is installed
and the WAN metric is not demoted, so the
[Policy-Based Routing](https://docs.mossdef.org/pbr/) (`pbr`) package decides
which traffic uses the tunnel through its own fwmark rules and routing tables.
The peer keeps `allowed_ips=0.0.0.0/0` in this mode too -- that list is
WireGuard's cryptokey routing table, and narrowing it would make the tunnel drop
the very traffic pbr steers into it.

Three consequences are worth knowing before switching:

- **The kill switch is left off.** It blocks LAN-to-WAN IPv4 by firewall *zone*,
  not by route, so it cannot distinguish a leak from traffic pbr deliberately
  sent around the tunnel. pbr's own `strict_enforcement` (which installs
  `unreachable default` in its table while the interface is down) is the
  equivalent guard for the traffic it owns. pbr also
  [documents](https://docs.mossdef.org/pbr/) that it does not support a
  killswitch router topology.
- **IPv6 stays blocked**, exactly as in full tunnel mode. The tunnel is
  IPv4-only, so IPv6 could only ever leave outside it.
- **The VPN resolvers are pinned into the tunnel** with `/32` host routes
  (app-owned `nordvpn_dnsroute_*` sections in `/etc/config/network`), because
  without a default route they would otherwise be unreachable and DNS would fail
  for the whole router. Resolvers on RFC1918, loopback or link-local addresses
  are skipped, so a LAN resolver set as a custom DNS keeps working.

pbr needs no extra configuration to pick the tunnel up: the interface is a
`proto wireguard` client with no `listen_port`, which is what pbr's `is_wg`
detection requires.

## WireGuard stability troubleshooting

NordLynx uses WireGuard over UDP. For routers behind NAT, NordVPN Easy keeps the
peer alive with `wireguard_persistent_keepalive=15` by default on every provision.

## Diagnostics

Use **Services → NordVPN Easy → Diagnostics** for a structured assessment and
full log export. The main NordVPN Easy page also shows an alert banner when a
primary issue is detected (for example routing blackhole, missing handshake, or
kill switch active without a tunnel).

Common `probable_issue_code` values:

| Code | Typical cause |
|------|----------------|
| `routing.blackhole_default_via_vpn` | Default route uses the VPN before WireGuard connects |
| `runtime.no_handshake` | Peer configured but no recent handshake |
| `operational.kill_switch_active` | Kill switch on while the tunnel is down |
| `connectivity.wan_down` | WAN probe failed while VPN is enabled |
| `runtime.endpoint_unreachable` | NordVPN endpoint host not reachable from WAN |

Background `diagnostics_summary` polls from the main page and LuCI view refresh
skip active WAN/DNS probes to avoid extra load. A full log download or manual
assessment refresh runs the complete probe set (typically under a few seconds).

Findings are ranked by severity: routing blackhole and WAN/DNS failures surface
before handshake or configuration warnings. The summary JSON includes
`primary_finding.severity`, `health.degraded_since`, and
`connectivity.vpn_endpoint_reachable` (UDP endpoint probe via WAN when active
probes are enabled).

When the VPN transitions to **degraded** during a cron or health-check run, the
service logs `probable_issue_code` to syslog (`logread -e nordvpn-easy`). Example:

```text
healthcheck: VPN state degraded: probable_issue_code=runtime.no_handshake severity=critical
healthcheck: VPN state recovered: was probable_issue_code=runtime.no_handshake for 120s; now state=connected
```

A short rolling history is kept at `/tmp/run/nordvpn-easy/diagnostics_history.log`.

The VPN health-check clears a **routing blackhole** automatically: if the default
route points at the VPN interface without a WireGuard handshake, it runs `ifdown`
on the tunnel before attempting API or server-list recovery.

If long-lived streams or downloads drop after roughly 30 seconds while OpenVPN is
stable, check diagnostics first. Common causes are an aggressive upstream NAT,
MTU/MSS blackholes, or a bad VPN server path rather than an OpenWrt log-visible
interface failure.

Suggested checks:

- keep `wireguard_persistent_keepalive` at `15`; try `10` only for very
  aggressive NAT devices
- leave `firewall_mtu_fix=1` enabled so TCP MSS is clamped on the VPN firewall
  zone
- if streams still stall, test `wireguard_mtu` values `1420`, `1380`, then
  `1280`
- rotate or choose a fallback server if only one NordVPN endpoint is affected

The NordLynx private key is stored locally by OpenWrt in `/etc/config/network`
under the WireGuard interface so netifd can bring the tunnel up. NordVPN Easy
does not expose that key in LuCI, logs, status JSON or diagnostics export.

### Securing the account token

The NordVPN account token and the NordLynx private key are long-lived secrets
held in `/etc/config/nordvpn_easy` and `/etc/config/network`, which NordVPN Easy
hardens to root-only (`0600`) on a best-effort basis after each config write
(chmod failures are ignored rather than aborting the operation). The LuCI form masks
the token in the page, but that masking is client-side only: any authenticated
LuCI admin session can read the stored token back over the standard `uci` ubus
call (this is inherent to LuCI's uci-over-ubus model). To limit exposure:

- serve LuCI over HTTPS only (configure `uhttpd` with TLS and redirect plain
  HTTP) so the token is never sent to network intermediaries in clear text
- restrict LuCI administrative access to trusted users and networks
- rotate the NordVPN access token if a router or its backups may have been
  exposed

## Current status

- package names are fixed: `nordvpn-easy` and `luci-app-nordvpn-easy`
- LuCI reads and writes UCI config `nordvpn_easy`
- install/upgrade uses a template-backed config migrator to avoid opkg conffile conflicts
- the backend shell core is already wired into the package layout
- the runtime model is already `service + one-shot checks`
- the main missing work is validation on real OpenWrt targets and final feed
  integration

## Development focus

The project is currently a source repository for package development, not a
final end-user distribution channel.

High-value validation work is:

- OpenWrt buildroot or feed validation
- LuCI rendering and action testing
- UCI-to-runtime rendering checks
- cron and hotplug behaviour on device
- recovery, rotation and country-filter validation on real routers

## Packaged service commands

- One-shot health check: `/etc/init.d/nordvpn-easy check`
- Force server rotation: `/etc/init.d/nordvpn-easy rotate`
- Re-run setup logic: `/etc/init.d/nordvpn-easy setup`
- Reinstall cron and hotplug hooks: `/etc/init.d/nordvpn-easy install_hooks`
- Remove cron and hotplug hooks: `/etc/init.d/nordvpn-easy remove_hooks`

## Notes

- The public product name should remain `NordVPN Easy`.
- If you edit files on another machine, keep Unix `LF` line endings.
- Disabling IPv6 can help reduce leak risk in deployments that require stricter isolation, but actual leak prevention still depends on firewall, routing and failure-handling policy.
- When the tunnel is healthy, IPv4 traffic is usually routed through the VPN; verify the effective routing, firewall rules and failure modes on your target system.

## License

Copyright (C) 2026 tis24dev

Licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE). You may use,
modify, and share this software for any noncommercial purpose, and contributions
back via pull request are welcome. Any commercial use requires a separate license
from the copyright holder. Previously released under the GNU GPLv3.

See <https://polyformproject.org/licenses/noncommercial/1.0.0/> for the full terms.
