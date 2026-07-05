# NordVPN Easy — Diagnostics Guide

This document describes how to investigate runtime behaviour on an OpenWrt router running **NordVPN Easy**, including built-in diagnostics, syslog correlation, and the optional **LuCI timing log** used to measure Save & Apply phases (for example long **Applying (connect)...** labels).

---

## 1. Quick reference

| Source | Path or command | What it shows |
|--------|-----------------|---------------|
| LuCI | **Services → NordVPN Easy → Diagnostics** | Structured assessment + log export |
| Status JSON | `ubus call nordvpn.easy status` or LuCI status panel | Live VPN/runtime snapshot |
| Syslog | `logread -e nordvpn-easy` | Backend actions with timestamps |
| Runtime dir | `/tmp/run/nordvpn-easy/` | Status cache, public IP cache, diagnostics history |
| Execution lock | `/tmp/nordvpn-easy.lock/` | Current holder PID, action name, age |
| **LuCI timing log** (debug) | `/tmp/nordvpn-easy-luci-timing.ndjson` | Browser-side phase durations (NDJSON) |

---

## 2. Built-in diagnostics (production)

### 2.1 LuCI Diagnostics page

Open **Services → NordVPN Easy → Diagnostics**.

- **Refresh assessment** runs `diagnostics_summary` with active WAN/DNS probes (typically a few seconds).
- **Download log** runs `diagnostics_log` and returns a full text export.
- The main configuration page polls `diagnostics_summary` in the background with **light probes** (no extra WAN/DNS load).

Findings use stable codes (for example `runtime.no_handshake`, `routing.blackhole_default_via_vpn`). See the main [README](../README.md) for severity and auto-recovery behaviour.

### 2.2 CLI / ubus

On the router (SSH):

```sh
# Compact status used by LuCI polling
ubus call nordvpn.easy status

# Structured diagnostics (JSON)
/etc/init.d/nordvpn-easy diagnostics_summary

# Full log export (stdout)
/etc/init.d/nordvpn-easy diagnostics_log
```

### 2.3 Syslog

All significant backend steps log to syslog with tag `nordvpn-easy` (and `nordvpn-easy-hotplug`, `nordvpn-easy-cron` for hooks):

```sh
logread -e nordvpn-easy | tail -100
```

Useful markers during **Save & Apply** / server change:

| Log line (substring) | Meaning |
|----------------------|---------|
| `service: stop_vpn requested` | LuCI/rpcd started stop |
| `apply: core action 'stop_vpn' completed` | Stop RPC finished |
| `service: connect requested` | Connect RPC started |
| `service: setup requested` | init.d `connect` invoked `setup` |
| `apply: running core action 'setup'` | Core provisioning started |
| `apply: VPN connectivity validated` | WireGuard handshake OK |
| `Public IP verification passed` | Country/IP check OK inside setup |
| `apply: core action 'setup' completed` | Setup RPC finished |
| `service: install_hooks requested` | End of `connect` shell script |
| `manual health-check requested` | Separate `check` (often from hotplug) |

Correlate **wall-clock times** between syslog lines and LuCI labels when investigating slow applies.

### 2.4 Runtime files

Default locations (under `/tmp/run/nordvpn-easy/` unless overridden):

| File | Purpose |
|------|---------|
| `status.json` | Cached status snapshot |
| `public_ip` | Key/value public IP cache |
| `public_country` | Cached geolocation country code |
| `diagnostics_history.log` | Rolling diagnostics history |

Lock directory (while an action runs):

```sh
ls -la /tmp/nordvpn-easy.lock/
cat /tmp/nordvpn-easy.lock/action
cat /tmp/nordvpn-easy.lock/pid
```

---

## 3. LuCI timing log (development / lab)

The timing log records **browser-side** milestones during **Save & Apply**. It complements syslog: syslog shows backend work; the timing log shows when LuCI entered each apply phase (`configuration` -> `stop_phase` -> `connect` -> `apply_finished`).

It is **opt-in and same-origin only**: nothing is posted unless you set a browser-local flag, and records go only to the timing CGI on the same origin as LuCI (`request.post('/cgi-bin/nordvpn-easy-timing-log', ...)`). It never contacts any external endpoint.

Enable it from the browser devtools console on the NordVPN Easy page:

```js
localStorage.setItem('nordvpnEasyTimingLog', '1');   // enable
localStorage.removeItem('nordvpnEasyTimingLog');      // disable
```

The flag is read per milestone, so toggling it takes effect on the next Save & Apply without reloading.

### 3.1 Components

| Component | Location |
|-----------|----------|
| CGI append script (source) | `openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/nordvpn-easy-timing-log.cgi` |
| Lab endpoint when manually deployed | `/www/cgi-bin/nordvpn-easy-timing-log` (mode `755`) |
| Instrumented LuCI JS | `manager-actions.js` (`timingLog()` milestones and Country Match transition logs, opt-in via `localStorage['nordvpnEasyTimingLog']`) |
| Log file on router | `/tmp/nordvpn-easy-luci-timing.ndjson` |

Each line is one **NDJSON** object (one JSON object per line).

Environment override:

```sh
export NORDVPN_EASY_LUCI_TIMING_LOG=/tmp/my-custom-timing.ndjson
```

The CGI rotates the file when it exceeds **1 MiB** (renames to `.1`), and
ignores request bodies larger than **8 KiB** without reading them (the only
callers post tiny JSON records). It also mirrors **Country Match indicator
transitions** (`event:"country_match"`) into the system log via
`logger -t nordvpn-easy`, so `logread` / `diagnostics_log` records when the
on-screen indicator changes, cross-referencing the backend's own
country-match transitions. This mirroring is also gated by the same
`nordvpnEasyTimingLog` opt-in flag and only fires on an actual transition.

> This CGI is **lab-only** and must not be installed on production routers
> (it is an unauthenticated, same-origin endpoint). The package ships the
> source under `/www/luci-static/...`; it is **not** placed at the
> `/cgi-bin/` endpoint by the package.

### 3.2 Deploy on a test router

`scripts/deploy-debug-vm102-qemu.sh [VMID]` already installs the CGI to
`/www/cgi-bin/nordvpn-easy-timing-log` (executable) alongside the rest of the
dev tree, so on the VM 102 bench no manual step is needed. The manual steps
below are a fallback for other routers.

From your build machine (example: serve files over HTTP on the lab LAN):

```sh
ROUTER=192.168.1.1   # LuCI address
SRC=openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy

# CGI
scp "$SRC/nordvpn-easy-timing-log.cgi" root@"$ROUTER":/www/cgi-bin/nordvpn-easy-timing-log
ssh root@"$ROUTER" 'chmod 755 /www/cgi-bin/nordvpn-easy-timing-log'

# manager-actions.js already ships the (opt-in, disabled) instrumentation,
# so no special build is needed; only the CGI must be deployed.
```

Then open the NordVPN Easy page, enable the flag in the devtools console
(`localStorage.setItem('nordvpnEasyTimingLog', '1')`), and run Save & Apply.

**Proxmox guest exec** (when SSH is disabled on the VM):

```sh
# On the hypervisor: wget from an internal HTTP server, then move into place
qm guest exec <VMID> -- sh -c 'wget -q -O /www/cgi-bin/nordvpn-easy-timing-log http://<host>:<port>/nordvpn-easy-timing-log.cgi && chmod 755 /www/cgi-bin/nordvpn-easy-timing-log'
```

### 3.3 Capture a run

1. Clear the previous log on the router:

   ```sh
   rm -f /tmp/nordvpn-easy-luci-timing.ndjson /tmp/nordvpn-easy-luci-timing.ndjson.1
   ```

2. In LuCI, change country or server and press **Save & Apply**.

3. Wait until Operation Status returns to **Idle** (or VPN shows **Connected**).

4. Copy the log off the router:

   ```sh
   scp root@"$ROUTER":/tmp/nordvpn-easy-luci-timing.ndjson ./luci-timing.ndjson
   # or
   qm guest exec <VMID> -- cat /tmp/nordvpn-easy-luci-timing.ndjson
   ```

No external URL needs to be opened in the browser. Posts go to the **same origin** as LuCI: `https://<router>/cgi-bin/nordvpn-easy-timing-log`.

The CGI reads the POST body using `CONTENT_LENGTH` (required for uhttpd). If the script exits before printing `Status:` and headers, uhttpd returns **502 Bad Gateway**.

Verify the endpoint from the router:

```sh
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"message":"ping","timestamp":1}' \
  http://127.0.0.1/cgi-bin/nordvpn-easy-timing-log
# expect: {"ok":true}
```

### 3.4 NDJSON fields

Each record has the shape:

```json
{
  "location": "runApplyCycleConnectPhase",
  "event": "connect",
  "data": { "selectionChanged": true },
  "timestamp": 1779627320000
}
```

| event | Emitted when |
|-------|--------------|
| `configuration` | Save & Apply entered the configuration phase (`data.country` = target country) |
| `stop_phase` | Entered the stop phase (`data.selectionChanged` = whether the server/country changed) |
| `connect` | Entered the connect phase (the `start_connect` RPC is dispatched next) |
| `apply_finished` | The apply cycle settled and polling resumed (`data.suppressAutoReconcile`) |

Compute deltas in milliseconds between consecutive `timestamp` fields to see where time goes (the `connect` -> `apply_finished` gap is the connect + convergence duration).

Example (jq):

```sh
jq -rs 'sort_by(.timestamp) | .[] | "\(.timestamp) \(.event) \(.location)"' luci-timing.ndjson
```

### 3.5 Correlate with syslog

For the same Save & Apply:

```sh
logread -e nordvpn-easy | grep -E 'stop_vpn|connect|setup|install_hooks|check|Public IP'
```

Build a timeline:

| Layer | Start signal | End signal |
|-------|--------------|------------|
| LuCI | `configuration` event | `apply_finished` event |
| Backend stop | `service: stop_vpn requested` | `core action 'stop_vpn' completed` |
| Backend connect | `service: connect requested` | `core action 'setup' completed` + `install_hooks` |

**Note:** `connect` in init.d runs `setup` then `install_hooks`. A separate `check` may appear in syslog from **hotplug** after `wg0` comes up; it is not always part of the `connect` RPC duration—use both logs to confirm.

### 3.6 Remove debug instrumentation

The instrumentation ships disabled (the `localStorage` flag is never set in production) and posts only to the same origin, so nothing is sent unless a lab operator opts in. For production routers, simply do not deploy the lab CGI; optionally clean up leftovers:

- `/www/cgi-bin/nordvpn-easy-timing-log` (do not install on production)
- `/tmp/nordvpn-easy-luci-timing.ndjson` (and the `.1` rotation)

Restore `manager-actions.js` from the package build or backup (`manager-actions.js.bak.*` on lab VMs).

---

## 4. Interpreting long **Applying (connect)...**

From combined logread + timing analysis on lab VM 102 (country change, VPN enabled):

| Segment | Typical duration | Driven by |
|---------|------------------|-----------|
| `stop_vpn` RPC | ~15–20 s | Immediate shutdown + UCI teardown + network reload |
| LuCI Save UCI / flush | ~5–10 s | `handleSave`, `flushLuCiPendingChanges` |
| **connect** RPC (LuCI label) | ~60–75 s | Mostly `setup` core action |
| └ Pre-setup overhead | ~15–20 s | `render_runtime_config`, init.d spawn, lock |
| └ `setup` core | ~40–50 s | API, network restart, WG wait, public IP verify |
| └ `install_hooks` | ~5–8 s | Cron + hotplug hook install |

The label **Applying (connect)...** stays visible for the entire **`connect` RPC** because `applyPhase` is set to `connect` until that RPC resolves, even when the backend lock action is `setup`.

Possible improvement areas (analysis only; not all implemented):

- Reduce `render_runtime_config` overhead before each `setup`
- Skip redundant `install_hooks` when hooks already exist
- Avoid immediate hotplug `check` right after successful `setup`
- Expose sub-phases in the UI (`setup`, `reconfiguring`, etc.) for clearer feedback

---

## 5. RPC timeouts and Save & Apply connect

LuCI declares per-method timeouts in `service.js`, but **OpenWrt 24 LuCI
`rpc.js` ignores `rpc.declare({ timeout })`** and uses `L.env.rpctimeout` only.
The service client therefore sets `L.env.rpctimeout` immediately before each
RPC call: short dispatch calls stay short, while diagnostics still use the
longer window.

| Layer | Timeout |
|-------|---------|
| Browser ubus XHR (`L.env.rpctimeout`) | Set per RPC call |
| `apply` (Save & Apply dispatch) | **15 s** |
| `start_connect` (Advanced connect) | **15 s** |
| Sync `connect` / `stop_vpn` / `reconcile` | **120 s** |
| Diagnostics RPCs | **180 s** |
| rpcd `@rpcd[0].timeout` | **180 s** |
| uhttpd `script_timeout` / `network_timeout` | **180 s** |
| LuCI Save & Apply watchdog | **240 s** |

### 5.1 Save & Apply uses `start_connect` + status convergence

Long sync `connect` RPCs could finish on the router (~60–70 s) while the LuCI XHR still timed out at 180 s (`code: -1`) with VPN already connected. Root cause: relying on a long-lived ubus response as the completion barrier.

**Fix (production):**

1. **`ubus call nordvpn.easy start_connect`** — returns in under a second with `"async": true`; runs `/etc/init.d/nordvpn-easy connect` in the background. Log: `/tmp/run/nordvpn-easy/start-connect.log`.
2. **LuCI Save & Apply** polls `status_json` every 3 s until `runtimeActionRecoverySucceeded()` (connected, idle lock, matching country/server).
3. **Sync `connect`** remains for Advanced actions and scripts that need an immediate exit code.

Verify dispatch from the router:

```sh
ubus call nordvpn.easy start_connect
# expect: "success": true, "async": true, "code": 0
tail -f /tmp/run/nordvpn-easy/start-connect.log
```

If Save & Apply hits **Configuration apply timed out**, check syslog and `start-connect.log` for a stuck lock or hung `network restart`.

### 5.2 Sync `connect` transport note (Advanced / CLI)

The sync `connect` ubus method still uses `rpc_command_result` and may exhibit delayed HTTP response delivery on some OpenWrt 24 images even after init.d exits. Save & Apply no longer depends on that path; use syslog + `status_json` when debugging Advanced **Connect** slowness.

### 5.3 Connect apply optimizations (Phase 4)

`init.d connect` reduces redundant work during Save & Apply background connect:

| Optimization | Syslog markers |
|--------------|----------------|
| Render setup config once | `apply: cached setup config at /tmp/run/nordvpn-easy/connect-setup.conf` then `apply: using cached setup config` |
| Skip hook rewrite when unchanged | `cron hook unchanged`, `hotplug hook unchanged` |
| Skip the supervisor's own ifevents | `nordvpn-easy-hotplug: skipped … (self-generated by supervisor apply)` |

The held runtime transaction lock (and the supervisor's self-ifevent sentinel) suppress the cron/hotplug recovery check from re-entering while `connect` runs.

```sh
logread -e 'nordvpn-easy' | grep -E 'cached setup config|hook unchanged|self-generated by supervisor apply|install_hooks'
```

These optimizations shave seconds off hook/cron/render overhead; VPN `setup` (WireGuard, Nord API, `network restart`) still dominates total time (~60–90 s).

### 5.4 Connect apply backend optimizations (Phase A)

Save & Apply (`stop_vpn` → `start_connect` → `connect`) uses a lighter backend path than manual **Setup** / **Reconnect**:

| Change | Syslog markers | Effect |
|--------|----------------|--------|
| **A1** Stop clears stale caches | `stopping VPN and clearing server selection caches` | The supervised apply always stops in server-change mode, so a fresh server list is fetched for the new selection |
| **A2** Reload + ifup | `reloading network and bringing up wg0` | Avoids full `network restart` when `ifup wg0` succeeds (falls back to restart on failure) |
| **A3** Handshake-first wait | `waiting … for WireGuard handshake` then `WireGuard handshake validated` | Exits the post-provision wait as soon as WG handshake is fresh (up to 25 s), instead of polling ping for the full `post_restart_delay` |
| **A3** Default `post_restart_delay` | UCI default **30** s (was 60) for new configs | Caps ping fallback; existing installs keep their saved value until changed |

### 5.5 LuCI apply convergence (real backend signals)

The supervised Save & Apply reads convergence off the supervisor's OWN journal signal in `status_json`, not from slow `ifstatus` / stale `connected`.

| Signal | Source | Use |
|--------|--------|-----|
| **Primary** | `journal_phase` (`done` / `failed`) + `journal_txn_id` in `status_json` | Close (or fail) the apply as soon as the supervisor stamps the terminal phase of the txn the poll watched go in-flight |
| Secondary | `connected` + `vpn_status=active` + country match | Live-state readiness for the DISABLE path and background recovery |
| Avoid | Stale `connected=true` mid-apply | Ignored during a supervised apply (the journal terminal is the sole verdict) |

Implementation notes:

- `status_json` always does a full live emit (no stale cached fields on the poll path).
- `vpn_status` becomes `active` when WireGuard reports a fresh handshake and the link exists (not only when `ifstatus` lags).
- LuCI polls every **1 s** during a supervised apply and binds the terminal verdict to a `journal_txn_id` it watched go through a non-terminal phase (never a stale leftover `done`/`failed`).
- Bench script logs both `journal converged` and `vpn_active converged` — the gap between them is what the UI used to waste.

Lab tuning (optional on VM 102):

```sh
uci set nordvpn_easy.main.post_restart_delay='30'
uci commit nordvpn_easy
```

Verify markers during one Save & Apply:

```sh
logread -e 'nordvpn-easy' | grep -E 'connect apply|reloading network|WireGuard handshake|server list updated|using existing recommended'
```

---

## 6. Security notes

- Diagnostics export and syslog may contain public IPs, country codes, server hostnames, and error text. Treat exports as sensitive operational data.
- The LuCI timing log is a **debug aid** only; do not leave the CGI endpoint enabled on production systems exposed to untrusted networks.
- The timing CGI accepts unauthenticated POSTs on `/cgi-bin/nordvpn-easy-timing-log`; restrict to lab use.

---

## 7. Related documentation

- [README](../README.md) — feature overview, diagnostics finding codes, health-check behaviour
- LuCI view: `openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/view/nordvpn-easy/diagnostics.js`
- Backend: `openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/diagnostics.sh`
