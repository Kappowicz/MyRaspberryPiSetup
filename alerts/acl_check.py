#!/usr/bin/env python3
"""Does webserver.acl still match this host's IPv6 address?

The ISP leases the IPv6 prefix and can change it without warning. When that
happens the ACL entry stops matching and devices that prefer IPv6 (phones) get
refused when opening the panel - with no change on our side, so nobody connects
the symptom to a cause. This check turns that silent failure into an alert that
carries a ready-to-paste fix.

Prints "OK ..." or "MISMATCH ...". Always exits 0 - check.sh decides whether to
notify.

For testing: --acl "<list>" substitutes a list instead of reading the file.
"""
import ipaddress
import os
import re
import subprocess
import sys

TOML = os.path.expanduser("~/pihole/etc-pihole/pihole.toml")


def read_acl():
    # Deliberately not "podman exec": this runs every 5 minutes, and every entry
    # into the container leaves a couple of conmon cgroup warnings in the
    # journal. Reading the file is enough.
    for cmd in (["cat", TOML], ["sudo", "-n", "cat", TOML]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        except Exception:
            continue
        if r.returncode == 0 and r.stdout:
            # The lazy .*? matters: pihole.toml appends a comment after the
            # value, like  ### CHANGED, default = ""  - a greedy .* swallows it
            # together with the quotes and corrupts the last entry in the list.
            m = re.search(r'^\s*acl\s*=\s*"(.*?)"', r.stdout, re.M)
            if m:
                return m.group(1)
    return None


def global_addresses():
    try:
        r = subprocess.run(["ip", "-6", "-o", "addr", "show", "scope", "global"],
                           capture_output=True, text=True, timeout=10)
    except Exception:
        return []
    out = []
    for line in r.stdout.splitlines():
        m = re.search(r"inet6 ([0-9a-f:]+)/(\d+)", line)
        if not m:
            continue
        a = ipaddress.IPv6Address(m.group(1))
        # is_private covers ULA (fd00::/8) and friends - those do not interest
        # us here, they have their own permanent entry in the ACL.
        if not a.is_link_local and not a.is_private:
            out.append(a)
    return out


def acl_networks(acl):
    out = []
    for e in acl.split(","):
        e = e.strip()
        if not e.startswith("+"):
            continue
        m = re.match(r"^\[([0-9a-fA-F:]+)\](?:/(\d+))?$", e[1:])
        if m:
            length = m.group(2) or "128"
            try:
                out.append(ipaddress.IPv6Network(f"{m.group(1)}/{length}", strict=False))
            except ValueError:
                pass
    return out


def is_global(net):
    a = net.network_address
    return not a.is_link_local and not a.is_private and not a.is_loopback


def main():
    if "--acl" in sys.argv:
        acl = sys.argv[sys.argv.index("--acl") + 1]
    else:
        acl = read_acl()
    if not acl:
        print("OK could not read the acl - skipping")   # no data is not a failure
        return
    addrs = global_addresses()
    if not addrs:
        print("OK no global IPv6 - nothing to watch")
        return

    nets = acl_networks(acl)
    matching = [a for a in addrs if any(a in n for n in nets)]
    if matching:
        print(f"OK {matching[0]} is covered by the acl")
        return

    new_net = ipaddress.IPv6Network(f"{addrs[0]}/64", strict=False)
    entry = f"+[{new_net.network_address}]/64"
    # Only global entries get replaced. fe80::/10, fd00::/8 and [::1] are left
    # alone - they never change and they are not what this is about.
    new_list = []
    replaced = False
    for e in acl.split(","):
        e = e.strip()
        m = re.match(r"^\+\[([0-9a-fA-F:]+)\](?:/(\d+))?$", e)
        if m:
            try:
                net = ipaddress.IPv6Network(f"{m.group(1)}/{m.group(2) or '128'}", strict=False)
            except ValueError:
                new_list.append(e); continue
            if is_global(net):
                if not replaced:
                    new_list.append(entry); replaced = True
                continue
        new_list.append(e)
    if not replaced:
        new_list.append(entry)

    print(f"MISMATCH host address {addrs[0]} is not covered by any acl entry")
    print(f"  acl now:      {acl}")
    print(f"  it should be: {','.join(new_list)}")
    print("  Fix with one command:")
    print(f'  podman exec pihole pihole-FTL --config webserver.acl "{",".join(new_list)}"')


main()
