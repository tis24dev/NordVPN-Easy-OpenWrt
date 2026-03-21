# NordVPN Easy for OpenWrt

NordVPN Easy is a package-first NordVPN WireGuard integration for OpenWrt.
The project is being built around native OpenWrt components: UCI
configuration, init service integration, a LuCI frontend, and periodic
health-check and recovery logic.

## <ins>Project goals</ins>

- install `luci-app-nordvpn-easy` from LuCI `System -> Software`
- configure NordVPN from LuCI and UCI instead of editing shell code
- keep the tunnel healthy through scheduled checks and event-triggered recovery
- support NordVPN recommended WireGuard servers, optionally filtered by country

## <ins>Repository layout</ins>

- `openwrt-packages/nordvpn-easy`
  Backend package with UCI defaults, init integration and the runtime shell
  core
- `openwrt-packages/luci-app-nordvpn-easy`
  LuCI frontend package
- `DEVELOPMENT`
  Continuity notes, design decisions and current project state

The package tree is the source of truth. The repository no longer depends on
legacy root-level direct-install files.

## <ins>Runtime model</ins>

The runtime model is service-driven and one-shot based:

- `/etc/config/nordvpn_easy` stores user configuration
- `/etc/init.d/nordvpn-easy` manages setup and recurring hooks
- `/usr/libexec/nordvpn-easy/core.sh` contains setup, check and rotation logic
- `cron` runs periodic checks
- `hotplug` triggers checks when WAN or VPN interfaces change state

There is no permanently running watchdog loop.

## <ins>How checks work</ins>

Each `check` execution is one-shot and does this:

- ensures the VPN interface exists
- ensures firewall membership is correct
- verifies VPN connectivity
- attempts recovery if the VPN is degraded but WAN is still working
- rotates server after repeated failures
- restarts the VPN interface or related services when necessary

This makes the project a service-managed maintenance job rather than a daemon
that loops forever.

## <ins>Configuration highlights</ins>

The packaged service is configured through UCI in `/etc/config/nordvpn_easy`.
Key settings include:

- `nordvpn_token` or `nordvpn_basic_token`
- `wan_if`
- `vpn_if`
- `vpn_country`
- recovery thresholds and timing values

Country filtering is supported. The backend resolves the requested country and
then asks NordVPN for recommended WireGuard servers inside that country. City
selection is not implemented.

## <ins>Current status</ins>

- package names are fixed: `nordvpn-easy` and `luci-app-nordvpn-easy`
- LuCI reads and writes UCI config `nordvpn_easy`
- the backend shell core is already wired into the package layout
- the runtime model is already `service + one-shot checks`
- the main missing work is validation on real OpenWrt targets and final feed
  integration

## <ins>Development focus</ins>

The project is currently a source repository for package development, not a
final end-user distribution channel.

High-value validation work is:

- OpenWrt buildroot or feed validation
- LuCI rendering and action testing
- UCI-to-runtime rendering checks
- cron and hotplug behaviour on device
- recovery, rotation and country-filter validation on real routers

## <ins>Packaged service commands</ins>

- One-shot health check: `/etc/init.d/nordvpn-easy check`
- Force server rotation: `/etc/init.d/nordvpn-easy rotate`
- Re-run setup logic: `/etc/init.d/nordvpn-easy setup`
- Reinstall cron and hotplug hooks: `/etc/init.d/nordvpn-easy install_hooks`
- Remove cron and hotplug hooks: `/etc/init.d/nordvpn-easy remove_hooks`

## <ins>Notes</ins>

- The public product name should remain `NordVPN Easy`.
- If you edit files on another machine, keep Unix `LF` line endings.
- Disable IPv6 if your deployment requires strict anti-leak behaviour.
- After the tunnel is up, IPv4 traffic is routed through the VPN.
