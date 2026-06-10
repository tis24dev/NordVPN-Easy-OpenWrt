#!/bin/sh
# Deploy the full NordVPN Easy development tree (backend + rpcd + LuCI) to a
# running OpenWrt VM via the QEMU guest agent, for fast iteration on the VM 102
# busybox-ash test bench without rebuilding packages.
#
# The whole tree is bundled into one gzip tarball and streamed in a SINGLE
# `qm guest exec --pass-stdin` call (the guest agent forwards stdin, up to 1 MiB,
# straight to the remote shell). That one call decodes, verifies the tarball md5,
# extracts into place, verifies every file's md5, restarts rpcd, clears the LuCI
# cache and confirms the ubus object re-registered. One round-trip, a few seconds.
#
# Usage: ./scripts/deploy-debug-vm102-qemu.sh [VMID]   (VMID defaults to 102)

set -eu
VMID="${1:-102}"
REPO_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

export VMID REPO_ROOT
exec python3 - <<'PY'
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile

VM = os.environ.get("VMID", "102")
REPO = os.environ["REPO_ROOT"]
PKG = os.path.join(REPO, "openwrt-packages")

# Source roots mapped to their on-device prefix:
#   backend  files/*   -> /*
#   LuCI     htdocs/*  -> /www/*
#   LuCI     root/*    -> /*
SOURCES = [
    (os.path.join(PKG, "nordvpn-easy/files"), ""),
    (os.path.join(PKG, "luci-app-nordvpn-easy/htdocs"), "www"),
    (os.path.join(PKG, "luci-app-nordvpn-easy/root"), ""),
]

# Everything ships 0644 except these entry points, which stay executable.
EXECUTABLES = {
    "etc/init.d/nordvpn-easy",
    "etc/uci-defaults/99-nordvpn-easy-rpcd-timeout",
    "usr/libexec/nordvpn-easy/core.sh",
    "usr/libexec/nordvpn-easy/migrate-config.sh",
    "usr/libexec/nordvpn-easy/public-ip-poll.sh",
    "usr/libexec/rpcd/nordvpn.easy",
    "www/luci-static/resources/nordvpn-easy/nordvpn-easy-timing-log.cgi",
}

REMOTE_TGZ = "/tmp/nvpn-deploy.tgz"
REMOTE_MANIFEST = "/tmp/nvpn-deploy.md5"  # relative-path md5 list, checked from /


def collect_files():
    """Return [(local_path, arcname, mode)] for the whole dev tree."""
    out = []
    for root, prefix in SOURCES:
        if not os.path.isdir(root):
            sys.exit(f"missing source tree: {root}")
        for dirpath, _dirs, names in os.walk(root):
            for name in names:
                local = os.path.join(dirpath, name)
                rel = os.path.relpath(local, root).replace(os.sep, "/")
                arc = rel if not prefix else f"{prefix}/{rel}"
                mode = 0o755 if arc in EXECUTABLES else 0o644
                out.append((local, arc, mode))
    out.sort(key=lambda item: item[1])
    return out


def add_member(tf, arcname, data, mode):
    info = tarfile.TarInfo(arcname)
    info.size = len(data)
    info.mode = mode
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    tf.addfile(info, io.BytesIO(data))


def build_tarball(files):
    """Build a gzip tarball rooted at '/', with an embedded md5 manifest."""
    buf = io.BytesIO()
    manifest_lines = []
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        for local, arc, mode in files:
            with open(local, "rb") as fh:
                data = fh.read()
            manifest_lines.append(f"{hashlib.md5(data).hexdigest()}  {arc}")
            add_member(tf, arc, data, mode)
        manifest = ("\n".join(manifest_lines) + "\n").encode()
        # Manifest paths are relative; the remote checks them from `cd /`.
        add_member(tf, REMOTE_MANIFEST.lstrip("/"), manifest, 0o644)
    return buf.getvalue(), len(files)


def remote_script(tar_md5):
    return f"""set -e
cat > {REMOTE_TGZ}
got=$(md5sum {REMOTE_TGZ} | cut -d' ' -f1)
[ "$got" = "{tar_md5}" ] || {{ echo "TARBALL_MD5_MISMATCH $got"; exit 1; }}
tar -xzf {REMOTE_TGZ} -C /
cd / && md5sum -c {REMOTE_MANIFEST} >/dev/null 2>&1 || {{ echo MANIFEST_FAIL; exit 1; }}
for f in /etc/init.d/nordvpn-easy /usr/libexec/rpcd/nordvpn.easy /usr/libexec/nordvpn-easy/core.sh; do
    sh -n "$f" || {{ echo "PARSE_FAIL $f"; exit 1; }}
done
/etc/init.d/rpcd restart >/dev/null 2>&1 || /etc/init.d/rpcd reload >/dev/null 2>&1
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache 2>/dev/null || true
sleep 1
ubus list 2>/dev/null | grep -qx nordvpn.easy && echo UBUS_OK || echo UBUS_MISSING
rm -f {REMOTE_TGZ} {REMOTE_MANIFEST}
echo DEPLOY_DONE
"""


def require_running_vm():
    r = subprocess.run(["qm", "status", VM], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"cannot query VM {VM}: {r.stderr.strip() or r.stdout.strip()}")
    if "running" not in r.stdout:
        sys.exit(f"VM {VM} is not running ({r.stdout.strip()})")


def guest_exec_stdin(stdin_bytes, script, timeout=90):
    """Run a remote shell with stdin forwarded via the guest agent (one call)."""
    r = subprocess.run(
        [
            "qm", "guest", "exec", VM,
            "--pass-stdin", "1", "--timeout", str(timeout),
            "--", "/bin/sh", "-c", script,
        ],
        input=stdin_bytes,
        capture_output=True,
        timeout=timeout + 30,
    )
    out = r.stdout.decode("utf-8", "replace")
    try:
        j = json.loads(out)
    except json.JSONDecodeError:
        sys.exit(f"unexpected qm output: {out}{r.stderr.decode('utf-8', 'replace')}")
    return j.get("exitcode", 1) or 0, j.get("out-data", ""), j.get("err-data", "")


def main():
    require_running_vm()

    files = collect_files()
    tarball, count = build_tarball(files)
    tar_md5 = hashlib.md5(tarball).hexdigest()
    if len(tarball) > 1024 * 1024:
        sys.exit(f"tarball {len(tarball)} bytes exceeds the 1 MiB guest-agent stdin limit")
    print(f"Bundling {count} files ({len(tarball)} bytes, md5={tar_md5}) and streaming to VM {VM}...")

    rc, out, err = guest_exec_stdin(tarball, remote_script(tar_md5))
    out = out.strip()
    if rc != 0 or "DEPLOY_DONE" not in out:
        sys.exit(f"deploy failed (rc={rc}): {out}\n{err}")
    if "UBUS_MISSING" in out:
        print(f"WARNING: nordvpn.easy ubus object not listed after rpcd restart.", file=sys.stderr)
    else:
        print(f"Verified {count} files; rpcd restarted; nordvpn.easy ubus object registered.")
    print(f"Deploy to VM {VM} complete. Hard-refresh LuCI (Ctrl+F5).")


if __name__ == "__main__":
    main()
PY
