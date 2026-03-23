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
10. Upload the key file.
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
19. Log in again.
20. Open `Services -> NordVPN Easy`.
21. Configure the service.

The configuration guide will be expanded separately.

## Runtime model

The runtime model is service-driven and one-shot based:

- `/etc/config/nordvpn_easy` stores user configuration
- `/etc/init.d/nordvpn-easy` manages setup and recurring hooks
- `/usr/libexec/nordvpn-easy/core.sh` contains setup, check and rotation logic
- `cron` runs periodic checks
- `hotplug` triggers checks when WAN or VPN interfaces change state

There is no permanently running watchdog loop.

## How checks work

Each `check` execution is one-shot and does this:

- ensures the VPN interface exists
- ensures firewall membership is correct
- verifies VPN connectivity
- attempts recovery if the VPN is degraded but WAN is still working
- rotates server after repeated failures
- restarts the VPN interface or related services when necessary

This makes the project a service-managed maintenance job rather than a daemon
that loops forever.

## Configuration highlights

The packaged service is configured through UCI in `/etc/config/nordvpn_easy`.
Key settings include:

- `nordvpn_token`
- `wan_if`
- `vpn_if`
- `vpn_country`
- recovery thresholds and timing values

Country filtering is supported. The backend resolves the requested country and
then asks NordVPN for recommended WireGuard servers inside that country. City
selection is not implemented.

## Current status

- package names are fixed: `nordvpn-easy` and `luci-app-nordvpn-easy`
- LuCI reads and writes UCI config `nordvpn_easy`
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
