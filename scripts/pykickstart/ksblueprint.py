#!/usr/bin/env python3
"""
ksblueprint - generate a NON-CONFLICTING pair of:
  * a composer-cli TOML blueprint   (what the OS *is*: packages + baked identity)
  * an anaconda kickstart file       (how it *installs*: source, disk, accounts)

The anti-conflict trick is a strict ownership split. Each concern is declared in
exactly ONE artifact, never both:

  BLUEPRINT owns -> packages, groups, hostname, timezone/NTP, locale/keyboard,
                    firewall, systemd services, kernel append args
  KICKSTART owns -> install source, disk layout (via the %pre script),
                    network, SELinux mode, root/user accounts

Two traps this avoids on purpose:
  * filesystem customizations in the blueprint would fight the dynamic %pre
    partitioning -> the generator refuses to emit them and errors if configured.
  * kernel args live only in the blueprint (customizations.kernel.append), so the
    kickstart bootloader line (from %pre) never carries --append.

Config is YAML (python3-pyyaml, available as an RPM). CLI flags override config.
"""

import argparse
import os
import re
import sys

try:
    import yaml
except ImportError:                       # pyyaml missing
    yaml = None


# ---------------------------------------------------------------------------
# tiny TOML emitter (only the shapes a blueprint needs: scalars, string arrays,
# [tables], [[arrays of tables]], and nested [a.b] tables)
# ---------------------------------------------------------------------------
def toml_str(s):
    """Quote+escape a TOML basic string."""
    s = str(s).replace("\\", "\\\\").replace('"', '\\"')
    return '"%s"' % s


def toml_val(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (list, tuple)):
        return "[%s]" % ", ".join(toml_val(x) for x in v)
    return toml_str(v)


def kv(key, value):
    return "%s = %s" % (key, toml_val(value))


# ---------------------------------------------------------------------------
# repository catalog -> composer "sources" (separate TOMLs, pushed with
# `composer-cli sources add`). Repos NEVER go in the blueprint; the blueprint
# only lists package NAMES, and these sources make those packages resolvable at
# build time. BaseOS/AppStream are already the host's system repos, so only the
# extras (EPEL, CRB, ...) need generating here.
# ---------------------------------------------------------------------------
_EL_FAMILIES = ("centos", "rhel", "almalinux", "rocky")


def _epel(family, major, arch):
    if family not in _EL_FAMILIES:
        return None                        # EPEL is Enterprise-Linux only
    return {
        "id": "epel%s" % major,
        "name": "Extra Packages for Enterprise Linux %s" % major,
        "type": "yum-metalink",
        "url": "https://mirrors.fedoraproject.org/metalink?repo=epel-%s&arch=%s"
               % (major, arch),
        "check_gpg": True,
        "check_ssl": True,
        "gpgkey_urls": ["https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-%s" % major],
    }


def _crb(family, major, arch):
    if family == "centos":
        comp = "PowerTools" if major == "8" else "CRB"
        return {
            "id": "crb",
            "name": "CentOS Stream %s - %s" % (major, comp),
            "type": "yum-baseurl",
            "url": "https://mirror.stream.centos.org/%s-stream/%s/%s/os/"
                   % (major, comp, arch),
            "check_gpg": False,            # same CentOS Official key as BaseOS;
            "check_ssl": True,             # flip on once you add its gpgkey_urls
        }
    if family in _EL_FAMILIES:
        return {"_note": "CRB on %s comes from a subscription/vendor mirror - enable it "
                         "with subscription-manager or add a custom baseurl entry." % family}
    return None                            # not applicable to Fedora


REPO_CATALOG = {
    "epel": _epel,
    "crb": _crb,
    "codeready-builder": _crb,
    "codeready": _crb,
    "powertools": _crb,
}


def parse_distro(distro):
    """'centos-9' -> ('centos','9'); 'rhel-92' -> ('rhel','9'); 'fedora-40' ->
    ('fedora','40'). Returns (None, None) when it can't tell."""
    if not distro:
        return None, None
    m = re.match(r"^([a-z]+)[-_]?(\d+)", distro.strip().lower())
    if not m:
        return None, None
    family, num = m.group(1), m.group(2)
    if len(num) == 2 and num != "10":      # RHEL '92' means 9.2 -> major 9
        num = num[0]
    return family, num


def render_source_toml(spec):
    order = ["id", "name", "type", "url", "check_gpg", "check_ssl",
             "check_repogpg", "gpgkey_urls", "distro", "proxy"]
    lines = [kv(k, spec[k]) for k in order if spec.get(k) is not None]
    lines += [kv(k, v) for k, v in spec.items()
              if k not in order and not k.startswith("_")]
    return "\n".join(lines) + "\n"


def build_sources(cfg, warnings):
    """Return a list of (filename, toml_text), one composer source per extra repo."""
    repos = cfg.get("repos") or []
    if not repos:
        return []

    family = cfg.get("repo_family")
    major = str(cfg["repo_release"]) if cfg.get("repo_release") else None
    if not (family and major):
        pf, pm = parse_distro(cfg.get("distro"))
        family, major = family or pf, major or pm
    arch = cfg.get("arch", "x86_64")

    if (cfg.get("install_source") or {}).get("type") == "url":
        warnings.append("repos generate composer BUILD sources; they do not affect a "
                        "url-mode anaconda install (that needs kickstart 'repo' lines).")

    out = []
    for entry in repos:
        if isinstance(entry, dict):                    # fully custom source
            spec = entry
        else:
            fn = REPO_CATALOG.get(str(entry).lower())
            if not fn:
                warnings.append("unknown repo '%s' - skipped (define it as a custom dict "
                                "with id/name/type/url)." % entry)
                continue
            if not (family and major):
                warnings.append("repo '%s' needs a target - set 'distro', or "
                                "'repo_family'+'repo_release'." % entry)
                continue
            spec = fn(family, major, arch)
            if spec is None:
                warnings.append("repo '%s' does not apply to %s - skipped." % (entry, family))
                continue
            if "_note" in spec:
                warnings.append("repo '%s': %s" % (entry, spec["_note"]))
                continue
        if cfg.get("distro") and "distro" not in spec:
            spec = dict(spec, distro=[cfg["distro"]])  # scope source to this distro
        out.append(("%s.source.toml" % spec["id"], render_source_toml(spec)))
    return out


# ---------------------------------------------------------------------------
# helpers to normalise loose config into canonical shapes
# ---------------------------------------------------------------------------
def normalize_packages(raw):
    """Accept 'vim', {'name':'vim','version':'1.2'}; strings starting with '@'
    are groups, returned separately."""
    pkgs, groups = [], []
    for item in raw or []:
        if isinstance(item, dict):
            pkgs.append({"name": item["name"], "version": item.get("version", "*")})
        elif isinstance(item, str):
            if item.startswith("@"):
                groups.append(item[1:])
            else:
                pkgs.append({"name": item, "version": "*"})
    return pkgs, groups


# ---------------------------------------------------------------------------
# blueprint (TOML) builder
# ---------------------------------------------------------------------------
def build_customizations(cfg):
    scalars, sub = [], []   # sub = list of (header, [lines])

    if cfg.get("hostname"):
        scalars.append(kv("hostname", cfg["hostname"]))

    if cfg.get("kernel_append"):
        sub.append(("[customizations.kernel]", [kv("append", cfg["kernel_append"])]))

    tz_lines = []
    if cfg.get("timezone"):
        tz_lines.append(kv("timezone", cfg["timezone"]))
    if cfg.get("ntp_servers"):
        tz_lines.append(kv("ntpservers", cfg["ntp_servers"]))
    if tz_lines:
        sub.append(("[customizations.timezone]", tz_lines))

    loc = cfg.get("locale") or {}
    loc_lines = []
    if loc.get("languages"):
        loc_lines.append(kv("languages", loc["languages"]))
    if loc.get("keyboard"):
        loc_lines.append(kv("keyboard", loc["keyboard"]))
    if loc_lines:
        sub.append(("[customizations.locale]", loc_lines))

    fw = cfg.get("firewall") or {}
    if fw.get("ports"):
        sub.append(("[customizations.firewall]", [kv("ports", fw["ports"])]))
    if fw.get("services_enabled") or fw.get("services_disabled"):
        fw_svc = []
        if fw.get("services_enabled"):
            fw_svc.append(kv("enabled", fw["services_enabled"]))
        if fw.get("services_disabled"):
            fw_svc.append(kv("disabled", fw["services_disabled"]))
        sub.append(("[customizations.firewall.services]", fw_svc))

    svc = cfg.get("services") or {}
    if svc.get("enabled") or svc.get("disabled"):
        svc_lines = []
        if svc.get("enabled"):
            svc_lines.append(kv("enabled", svc["enabled"]))
        if svc.get("disabled"):
            svc_lines.append(kv("disabled", svc["disabled"]))
        sub.append(("[customizations.services]", svc_lines))

    block = []
    if scalars:
        block += ["[customizations]"] + scalars + [""]
    for header, lines in sub:
        block += [header] + lines + [""]
    return block


def build_blueprint(cfg, embedded_ks=None):
    pkgs, at_groups = normalize_packages(cfg.get("packages"))
    groups = at_groups + list(cfg.get("groups") or [])

    out = [
        kv("name", cfg["name"]),
        kv("description", cfg.get("description", "Generated by ksblueprint")),
        kv("version", str(cfg.get("version", "0.0.1"))),
    ]
    if cfg.get("distro"):
        out.append(kv("distro", cfg["distro"]))
    out.append("")

    for p in pkgs:
        out += ["[[packages]]", kv("name", p["name"]), kv("version", p["version"]), ""]
    for g in groups:
        out += ["[[groups]]", kv("name", g), ""]

    out += build_customizations(cfg)
    if embedded_ks is not None:
        out += build_installer_kickstart(embedded_ks)
    return "\n".join(out).rstrip() + "\n"


def build_installer_kickstart(ks_text):
    """Fold the kickstart into [customizations.installer.kickstart] as a TOML
    *literal* multi-line string ('''...'''), which does no escape processing -
    so the %pre's backslashes and heredocs are preserved byte-for-byte. A basic
    string (\"\"\"...\"\"\") would mangle things like printf '\\n'."""
    if "'''" in ks_text:
        raise SystemExit("cannot embed: the kickstart contains ''' which would break a "
                         "TOML literal string. Deliver it via inst.ks= instead.")
    # A newline right after the opening ''' is trimmed by TOML parsers, so the
    # body lines up correctly.
    return ["[customizations.installer.kickstart]",
            "contents = '''",
            ks_text.rstrip("\n"),
            "'''",
            ""]


# ---------------------------------------------------------------------------
# kickstart builder
# ---------------------------------------------------------------------------
def ks_install_source(cfg, warnings):
    src = cfg.get("install_source") or {}
    t = src.get("type")
    if t in ("media", "iso"):
        # Install from the payload baked into the booted installer ISO: fully
        # offline, no repo access required.
        if src.get("payload") == "ostree":
            osname = src.get("osname") or cfg["name"]
            remote = src.get("remote") or osname
            url = src.get("url", "file:///run/install/repo/ostree/repo")
            ref = src.get("ref", "REF_UNSET")
            if not src.get("ref"):
                warnings.append("media (ostree) source has no 'ref' - REF_UNSET emitted.")
            return ["# install source: OSTree commit on the booted installer ISO (offline)",
                    "ostreesetup --osname=%s --remote=%s --url=%s --ref=%s --nogpg"
                    % (osname, remote, url, ref)]
        # default payload: liveimg from the on-media root filesystem
        path = src.get("path", "/run/install/repo/liveimg.tar.gz")
        return ["# install source: payload on the booted installer ISO (offline).",
                "# This is the osbuild image-installer default path; hand-built live",
                "# ISOs instead use /run/install/repo/LiveOS/squashfs.img",
                "liveimg --url=file://%s" % path]
    if t == "ostree":
        osname = src.get("osname") or cfg["name"]
        remote = src.get("remote") or osname
        url = src.get("url", "URL_UNSET")
        ref = src.get("ref", "REF_UNSET")
        line = "ostreesetup --osname=%s --remote=%s --url=%s --ref=%s" % (
            osname, remote, url, ref)
        if src.get("nogpg", True):
            line += " --nogpg"
        return ["# install source: OSTree commit built by the paired blueprint", line]
    if t == "liveimg":
        return ["# install source: filesystem image built by the paired blueprint",
                "liveimg --url=%s" % src.get("url", "URL_UNSET")]
    if t == "url":
        return ["# install source: package repo",
                "# NOTE: blueprint customizations do NOT auto-apply in url mode.",
                'url --url="%s"' % src.get("url", "URL_UNSET")]
    warnings.append("no install_source.type set - kickstart has a TODO placeholder.")
    return ["# TODO: no install_source provided - set type: media | ostree | liveimg | url"]


def ks_network(cfg):
    net = cfg.get("network") or {}
    bp = net.get("bootproto", "dhcp")
    parts = ["network", "--bootproto=%s" % bp, "--activate"]
    if net.get("device"):
        parts.insert(1, "--device=%s" % net["device"])
    if bp == "static":
        for key, flag in (("ip", "--ip"), ("netmask", "--netmask"),
                          ("gateway", "--gateway")):
            if net.get(key):
                parts.append("%s=%s" % (flag, net[key]))
        if net.get("nameservers"):
            parts.append("--nameserver=%s" % ",".join(net["nameservers"]))
    # deliberately NO --hostname: the blueprint owns hostname.
    return [" ".join(parts)]


def ks_identity(cfg):
    out = []
    rp = cfg.get("rootpw")
    if not rp or rp.get("lock"):
        out.append("rootpw --lock")
    else:
        flag = "--iscrypted" if rp.get("iscrypted", True) else "--plaintext"
        out.append("rootpw %s %s" % (flag, rp["value"]))

    for u in cfg.get("users") or []:
        parts = ["user", "--name=%s" % u["name"]]
        if u.get("groups"):
            parts.append("--groups=%s" % ",".join(u["groups"]))
        if u.get("gecos"):
            parts.append('--gecos="%s"' % u["gecos"])
        if u.get("shell"):
            parts.append("--shell=%s" % u["shell"])
        if u.get("uid"):
            parts.append("--uid=%s" % u["uid"])
        if u.get("password"):
            if u.get("iscrypted", True):
                parts.append("--iscrypted")
            parts.append("--password=%s" % u["password"])
        out.append(" ".join(parts))
        for key in u.get("sshkeys") or []:
            out.append('sshkey --username=%s "%s"' % (u["name"], key))
    return out


def build_kickstart(cfg, pre_text, warnings):
    name = cfg["name"]
    ks = [
        "# Kickstart generated by ksblueprint - pairs with blueprint '%s.toml'" % name,
        "#",
        "# Anti-conflict split: the BLUEPRINT owns packages, hostname, timezone,",
        "# locale, firewall, services, and kernel args. This KICKSTART owns the",
        "# install source, disk layout (%pre), network, SELinux, and accounts.",
        "# Do not add blueprint-owned directives here.",
        "",
    ]
    ks += ks_install_source(cfg, warnings)
    ks.append("")
    ks.append("text")
    ks.append("selinux --%s" % cfg.get("selinux", "enforcing"))
    ks += ks_network(cfg)
    ks.append("firstboot --disable")
    ks.append("")
    ks += ks_identity(cfg)
    ks.append("")
    ks.append("# Disk layout is generated at run time by the %pre script below,")
    ks.append("# which writes /tmp/diskpart.ks and is pulled in here:")
    ks.append("%include /tmp/diskpart.ks")
    ks.append("")
    if cfg.get("reboot", True):
        ks.append("reboot")
        ks.append("")

    if pre_text:
        ks.append("# ===== embedded %pre disk-provisioning script =====")
        ks.append(pre_text.strip())
        ks.append("")
    else:
        ks.append("# NOTE: no --pre-file supplied. Add a %pre script that writes")
        ks.append("#       /tmp/diskpart.ks (see diskpart-pre.bash.ks).")
        ks.append("")

    if cfg.get("post_script"):
        ks.append("%post --log=/var/log/ks-post.log")
        ks.append(cfg["post_script"].rstrip())
        ks.append("%end")
        ks.append("")

    return "\n".join(ks).rstrip() + "\n"


# ---------------------------------------------------------------------------
# validation - fail hard on true conflicts, warn on soft gaps
# ---------------------------------------------------------------------------
def validate(cfg, warnings):
    problems = []
    if cfg.get("filesystem") or cfg.get("filesystems") or cfg.get("partitioning"):
        problems.append(
            "Disk/filesystem layout is owned by the %pre script. Remove "
            "'filesystem'/'partitioning' from config so it can't conflict with "
            "the kickstart's dynamic partitioning.")
    if cfg.get("blueprint_users"):
        problems.append(
            "Accounts are kickstart-owned. Put users under 'users:', not "
            "'blueprint_users:', to avoid defining them in both artifacts.")

    src = cfg.get("install_source") or {}
    if src.get("type") == "ostree" and not src.get("ref"):
        warnings.append("ostree install_source has no 'ref' - REF_UNSET placeholder emitted.")
    if src.get("type") in ("ostree", "liveimg", "url") and not src.get("url"):
        warnings.append("install_source has no 'url' - URL_UNSET placeholder emitted.")
    if not cfg.get("rootpw") and not cfg.get("users"):
        warnings.append("no rootpw and no users - root will be LOCKED with no login user.")

    if problems:
        raise SystemExit("CONFLICT:\n  - " + "\n  - ".join(problems))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Generate a non-conflicting composer blueprint + kickstart pair.")
    p.add_argument("-c", "--config", help="YAML config file")
    p.add_argument("-o", "--outdir", default=".", help="output directory (default: .)")
    p.add_argument("--pre-file", help="path to a %%pre script to embed in the kickstart")
    p.add_argument("--embed-kickstart", action="store_true",
                   help="fold the kickstart into the blueprint's "
                        "[customizations.installer.kickstart] for a self-contained ISO")
    # scalar overrides (win over config)
    p.add_argument("--name")
    p.add_argument("--distro")
    p.add_argument("--hostname")
    p.add_argument("--timezone")
    p.add_argument("--description")
    p.add_argument("--ostree-url")
    p.add_argument("--ostree-ref")
    p.add_argument("--url", help="package-repo url install source")
    p.add_argument("--liveimg-url")
    return p.parse_args(argv)


def load_config(path):
    if not path:
        return {}
    if yaml is None:
        raise SystemExit("config given but PyYAML missing. Install: dnf install python3-pyyaml")
    with open(path) as fh:
        return yaml.safe_load(fh) or {}


def apply_overrides(cfg, args):
    for key in ("name", "distro", "hostname", "timezone", "description"):
        val = getattr(args, key)
        if val is not None:
            cfg[key] = val
    if args.url:
        cfg["install_source"] = {"type": "url", "url": args.url}
    if args.liveimg_url:
        cfg["install_source"] = {"type": "liveimg", "url": args.liveimg_url}
    if args.ostree_url or args.ostree_ref:
        src = cfg.setdefault("install_source", {})
        src["type"] = "ostree"
        if args.ostree_url:
            src["url"] = args.ostree_url
        if args.ostree_ref:
            src["ref"] = args.ostree_ref
    return cfg


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    cfg = apply_overrides(load_config(args.config), args)

    if not cfg.get("name"):
        raise SystemExit("error: 'name' is required (use --name or set it in the config).")

    warnings = []
    validate(cfg, warnings)

    pre_text = None
    if args.pre_file:
        with open(args.pre_file) as fh:
            pre_text = fh.read()

    blueprint = build_blueprint(cfg)
    kickstart = build_kickstart(cfg, pre_text, warnings)
    embed = bool(cfg.get("embed_kickstart") or args.embed_kickstart)
    if embed:
        blueprint = build_blueprint(cfg, embedded_ks=kickstart)
    sources = build_sources(cfg, warnings)

    os.makedirs(args.outdir, exist_ok=True)
    bp_path = os.path.join(args.outdir, "%s.toml" % cfg["name"])
    ks_path = os.path.join(args.outdir, "%s.ks" % cfg["name"])
    with open(bp_path, "w") as fh:
        fh.write(blueprint)
    with open(ks_path, "w") as fh:
        fh.write(kickstart)
    source_paths = []
    for fname, text in sources:
        path = os.path.join(args.outdir, fname)
        with open(path, "w") as fh:
            fh.write(text)
        source_paths.append(path)

    for w in warnings:
        print("warning: %s" % w, file=sys.stderr)

    print("wrote %s" % bp_path)
    print("wrote %s" % ks_path)
    if embed:
        print("       (kickstart also embedded in the blueprint's installer.kickstart)")
    for p in source_paths:
        print("wrote %s" % p)

    print("\nnext steps:")
    for p in source_paths:                       # sources must exist before depsolve
        print("  composer-cli sources add %s" % p)
    print("  composer-cli blueprints push %s" % bp_path)
    if source_paths:
        print("  composer-cli blueprints depsolve %s   # verify packages resolve" % cfg["name"])
    src_type = (cfg.get("install_source") or {}).get("type")
    if src_type == "ostree":
        print("  composer-cli compose start-ostree %s edge-commit" % cfg["name"])
    elif src_type in ("media", "iso"):
        print("  composer-cli compose start %s image-installer   # self-contained offline ISO"
              % cfg["name"])
    else:
        print("  composer-cli compose start %s <image-type>" % cfg["name"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
