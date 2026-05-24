#!/bin/sh
# Deploy NordVPN Easy LuCI/rpcd lab files to OpenWrt via QEMU guest agent.
# Usage: ./scripts/deploy-debug-vm102-qemu.sh [VMID]

set -eu
VMID="${1:-102}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
BASE="$REPO_ROOT/openwrt-packages"

export VMID REPO_ROOT BASE
exec python3 - "$@" <<'PY'
import json
import os
import subprocess
import sys

VM = os.environ.get("VMID", "102")
BASE = os.environ["BASE"]
CHUNK = 2000  # bytes per guest-exec (faster than 350)

FILES = [
    (
        f"{BASE}/nordvpn-easy/files/etc/init.d/nordvpn-easy",
        "/etc/init.d/nordvpn-easy",
        "755",
    ),
    (
        f"{BASE}/nordvpn-easy/files/usr/libexec/rpcd/nordvpn.easy",
        "/usr/libexec/rpcd/nordvpn.easy",
        "755",
    ),
    (
        f"{BASE}/nordvpn-easy/files/usr/libexec/nordvpn-easy/core.sh",
        "/usr/libexec/nordvpn-easy/core.sh",
        "755",
    ),
    (
        f"{BASE}/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/actions.sh",
        "/usr/libexec/nordvpn-easy/lib/actions.sh",
        "644",
    ),
    (
        f"{BASE}/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh",
        "/usr/libexec/nordvpn-easy/lib/wireguard.sh",
        "644",
    ),
    (
        f"{BASE}/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh",
        "/usr/libexec/nordvpn-easy/lib/common.sh",
        "644",
    ),
    (
        f"{BASE}/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh",
        "/usr/libexec/nordvpn-easy/lib/runtime.sh",
        "644",
    ),
    (
        f"{BASE}/luci-app-nordvpn-easy/root/usr/share/rpcd/acl.d/luci-app-nordvpn-easy.json",
        "/usr/share/rpcd/acl.d/luci-app-nordvpn-easy.json",
        "644",
    ),
    (
        f"{BASE}/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-actions.js",
        "/www/luci-static/resources/nordvpn-easy/manager-actions.js",
        "644",
    ),
    (
        f"{BASE}/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-data.js",
        "/www/luci-static/resources/nordvpn-easy/manager-data.js",
        "644",
    ),
    (
        f"{BASE}/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/service.js",
        "/www/luci-static/resources/nordvpn-easy/service.js",
        "644",
    ),
]


def guest_sh(script, timeout=90):
    r = subprocess.run(
        ["qm", "guest", "exec", VM, "--", "sh", "-c", script],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    try:
        j = json.loads(r.stdout)
        return j.get("exitcode", 1), j.get("out-data", ""), j.get("err-data", "")
    except json.JSONDecodeError:
        return r.returncode, r.stdout, r.stderr


def deploy_binary(local_path, remote_path, chmod=None):
    with open(local_path, "rb") as f:
        data = f.read()
    tmp = remote_path + ".new"
    guest_sh(f"rm -f {tmp}")
    for i in range(0, len(data), CHUNK):
        part = data[i : i + CHUNK]
        esc = "".join(f"\\x{b:02x}" for b in part)
        rc, out, err = guest_sh(f"printf '{esc}' >> {tmp}")
        if rc != 0:
            print(f"chunk failed at {i}: {err}{out}", file=sys.stderr)
            return False
    rc, out, err = guest_sh(f"wc -c {tmp}")
    try:
        size = int(out.strip().split()[0])
    except (ValueError, IndexError):
        print(f"wc failed: {out!r} {err!r}", file=sys.stderr)
        return False
    if size != len(data):
        print(f"size mismatch {remote_path}: {size} != {len(data)}", file=sys.stderr)
        return False
    inst = f"cp {tmp} {remote_path}"
    if chmod:
        inst += f" && chmod {chmod} {remote_path}"
    rc, out, err = guest_sh(inst)
    print(f"OK {remote_path} ({len(data)} bytes)")
    return rc == 0


def main():
    for local, remote, mode in FILES:
        if not os.path.isfile(local):
            print(f"missing: {local}", file=sys.stderr)
            sys.exit(1)
        if not deploy_binary(local, remote, mode):
            sys.exit(1)
    guest_sh("/etc/init.d/rpcd restart; sleep 1")
    print(f"Deploy to VM {VM} complete. Hard-refresh LuCI (Ctrl+F5).")


if __name__ == "__main__":
    main()
PY
