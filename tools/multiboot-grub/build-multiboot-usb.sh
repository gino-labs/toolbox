#!/usr/bin/env bash
#
# build-multiboot-usb.sh
# -----------------------------------------------------------------------------
# Build a Ventoy-style, self-scanning multiboot USB for the RHEL family
# (RHEL, Rocky, AlmaLinux, CentOS Stream) plus Fedora (Live + installer).
#
# It creates this layout on the target device:
#   part1  ~100 MiB  FAT32  label MULTIESP  ->  holds the UEFI bootloader
#   part2  remainder ext4   label MULTIISO  ->  drop your *.iso files in /isos
#
# Why ext4 (not FAT32) for the data partition: RHEL/Rocky/Alma DVD ISOs are
# well over 4 GiB, and FAT32 caps single files at 4 GiB. GRUB reads ext4
# natively, so this is the least-fuss choice on a Linux host.
#
# UEFI ONLY. (ryzenbolt and any modern Ryzen box boot UEFI; adding legacy BIOS
# means a BIOS-boot partition + i386-pc target, which is a "build-on", not MVP.)
#
# !! SECURE BOOT MUST BE DISABLED ON THE TARGET MACHINE !!
# grub-mkstandalone produces an UNSIGNED BOOTX64.EFI. With Secure Boot on, the
# firmware silently refuses it -- the stick often doesn't even appear in the boot
# menu, or you get a one-line "Security Policy Violation". Nothing in this script
# can work around that; it's a firmware setting. (Signing your own binary with a
# MOK, or chainloading the distro's signed shim, is a later build-on.)
#
# Host packages needed (Fedora/RHEL):
#   sudo dnf install grub2-efi-x64-modules grub2-tools-extra parted \
#                    dosfstools e2fsprogs
#
# Usage:
#   sudo ./build-multiboot-usb.sh /dev/sdX     # whole device, NOT a partition
#
# Then copy ISOs onto the stick:
#   cp Rocky-9.5-x86_64-dvd.iso  /run/media/$USER/MULTIISO/isos/
# -----------------------------------------------------------------------------
set -euo pipefail

ESP_LABEL="MULTIESP"
DATA_LABEL="MULTIISO"
GRUB_EFI_DIR="/usr/lib/grub/x86_64-efi"   # where the *.mod files live (Fedora/RHEL)

# ---------- 0. args, root, tooling ----------
DEV="${1:-}"
if [[ -z "$DEV" || ! -b "$DEV" ]]; then
    echo "Usage: sudo $0 /dev/sdX   (whole device, e.g. /dev/sdb, NOT /dev/sdb1)" >&2
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
fi

# ---------- 0b. preflight: verify all tools + GRUB EFI modules are present ----------
# Runs BEFORE anything destructive so a missing package can't leave a half-built
# stick. Collects ALL missing deps and prints one dnf line (package names are
# Fedora/RHEL; Debian/Ubuntu equivalents differ).
missing_cmds=()
missing_pkgs=()
need() {  # need <command-or-path> <package>
    if [[ "$1" == /* ]]; then
        [[ -e "$1" ]] || { missing_cmds+=("$1"); missing_pkgs+=("$2"); }
    else
        command -v "$1" >/dev/null 2>&1 || { missing_cmds+=("$1"); missing_pkgs+=("$2"); }
    fi
}

need parted    parted
need mkfs.vfat dosfstools
need mkfs.ext4 e2fsprogs
need wipefs    util-linux
need lsblk     util-linux
need udevadm   systemd-udev
need dumpe2fs  e2fsprogs
# grub-mkstandalone embeds a font (default: unicode) and aborts without it.
need /usr/share/grub/unicode.pf2 grub2-common

# grub-mkstandalone: named grub2-* on Fedora/RHEL, grub-* elsewhere. Need one.
if command -v grub2-mkstandalone >/dev/null 2>&1; then
    MKSTANDALONE="grub2-mkstandalone"
elif command -v grub-mkstandalone >/dev/null 2>&1; then
    MKSTANDALONE="grub-mkstandalone"
else
    missing_cmds+=("grub2-mkstandalone")
    missing_pkgs+=("grub2-tools-extra")
fi

# The x86_64-efi module set -- this is the piece behind the "modinfo.sh doesn't
# exist" error. It ships separately from the grub tools and the BIOS modules.
need "$GRUB_EFI_DIR/modinfo.sh" grub2-efi-x64-modules

if (( ${#missing_pkgs[@]} > 0 )); then
    echo "Missing dependencies:" >&2
    for i in "${!missing_cmds[@]}"; do
        printf '  - %-38s (package: %s)\n' "${missing_cmds[$i]}" "${missing_pkgs[$i]}" >&2
    done
    uniq_pkgs=$(printf '%s\n' "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
    echo >&2
    echo "Install them, then re-run:" >&2
    echo "  sudo dnf install ${uniq_pkgs% }" >&2
    exit 1
fi

# nvme0n1 -> nvme0n1p1 ; mmcblk0 -> mmcblk0p1 ; sdb -> sdb1
if [[ "$DEV" =~ [0-9]$ ]]; then PSEP="p"; else PSEP=""; fi
ESP_PART="${DEV}${PSEP}1"
DATA_PART="${DEV}${PSEP}2"

# ---------- 1. confirm (destructive!) ----------
echo "About to ERASE and repartition this device:"
lsblk -do NAME,MODEL,SIZE,TRAN "$DEV" 2>/dev/null || true
echo
read -rp "Type ERASE (all caps) to continue: " ans
[[ "$ans" == "ERASE" ]] || { echo "Aborted."; exit 1; }

# ---------- 2. clear any existing mounts on the device ----------
umount "${DEV}"?* 2>/dev/null || true

# ---------- 3. partition: GPT, ESP + data ----------
wipefs -a "$DEV"
parted -s "$DEV" mklabel gpt
parted -s "$DEV" mkpart "$ESP_LABEL"  fat32 1MiB 101MiB
parted -s "$DEV" set 1 esp on                 # flag the ESP so firmware finds it
parted -s "$DEV" mkpart "$DATA_LABEL" ext4  101MiB 100%
udevadm settle
sleep 1

# ---------- 4. filesystems ----------
mkfs.vfat -F32 -n "$ESP_LABEL"  "$ESP_PART"    # -n = FAT volume label
# THE BIG GOTCHA. e2fsprogs 1.47+ (Fedora 39+) enables `orphan_file` and
# `metadata_csum_seed` by default, and GRUB's ext2 driver refuses any filesystem
# carrying feature flags it doesn't recognise. Result: GRUB starts, then
# "error: unknown filesystem" and a grub rescue> prompt.
#   -O  = set filesystem features; a leading ^ means "turn this feature OFF"
# Older e2fsprogs doesn't know these names at all, hence the fallback.
# ^64bit is added because GRUB's ext2 driver is the least-exercised link in
# this chain, and 64-bit block addressing plus multi-GiB files (a 12 GiB DVD ISO
# has a deep extent tree) is exactly where it has historically misread blocks.
# Disabling it costs nothing below 16 TiB.
GRUB_UNSAFE_FEATURES="^orphan_file,^metadata_csum_seed,^64bit"
if ! mkfs.ext4 -F -O "$GRUB_UNSAFE_FEATURES" -L "$DATA_LABEL" "$DATA_PART" 2>/dev/null; then
    echo "note: this e2fsprogs doesn't know $GRUB_UNSAFE_FEATURES; using defaults."
    mkfs.ext4 -F -L "$DATA_LABEL" "$DATA_PART"   # -L = ext label (search matches on this)
fi

# Show what we actually ended up with -- if orphan_file or metadata_csum_seed
# still appear here, GRUB will not be able to read this partition.
echo "ext4 features on $DATA_PART:"
dumpe2fs -h "$DATA_PART" 2>/dev/null | sed -n 's/^Filesystem features:/  /p'
if dumpe2fs -h "$DATA_PART" 2>/dev/null | grep -qE 'orphan_file|metadata_csum_seed|64bit'; then
    echo "  WARNING: GRUB-incompatible feature still enabled. Try manually:" >&2
    echo "    tune2fs -O ^orphan_file,^metadata_csum_seed,^64bit $DATA_PART" >&2
fi

# ---------- 5. mount ----------
ESP_MNT="$(mktemp -d)"
DATA_MNT="$(mktemp -d)"
mount "$ESP_PART"  "$ESP_MNT"
mount "$DATA_PART" "$DATA_MNT"
mkdir -p "$ESP_MNT/EFI/BOOT" "$DATA_MNT/isos" "$DATA_MNT/kickstarts" "$DATA_MNT/boot/grub"

# ---------- 6. build a self-contained BOOTX64.EFI ----------
# We use grub-mkstandalone instead of grub-install on purpose:
# Fedora's grub2-install is patched to be a no-op for EFI (it expects the
# distro's signed shim). mkstandalone bakes the modules + a tiny early config
# into one portable BOOTX64.EFI, sidestepping that entirely.
#
# The early config just finds the data partition by label and hands control to
# the *editable* grub.cfg on the stick, so you can tweak the menu without
# rebuilding this binary.
#
# NOTE on `set prefix`: $prefix is where GRUB looks for .mod files when the menu
# runs `insmod`. Pointing it at the stick is only safe if the modules are
# actually THERE -- GRUB looks in $prefix/<cpu>-<platform>/, i.e.
# /boot/grub/x86_64-efi/. Without this copy, every insmod for a module that
# wasn't baked into BOOTX64.EFI fails, and you can't even `insmod ls` to debug.
mkdir -p "$DATA_MNT/boot/grub/x86_64-efi"
cp -a "$GRUB_EFI_DIR"/. "$DATA_MNT/boot/grub/x86_64-efi/"

EARLY_CFG="$(mktemp)"
cat > "$EARLY_CFG" <<EARLY
search --no-floppy --label $DATA_LABEL --set=root
set prefix=(\$root)/boot/grub
configfile (\$root)/boot/grub/grub.cfg
EARLY

# Split modules into ESSENTIAL (boot breaks without them -> hard error if absent)
# and OPTIONAL (nice-to-have, or provided by another module -> skip silently).
#
# Why filter at all: Fedora's EFI module set doesn't ship every module name.
# e.g. there is no standalone initrd.mod -- the `initrd` command comes bundled
# in linux.mod. Passing a name with no matching .mod file makes mkstandalone
# abort ("cannot open <name>.mod"). So we only pass names that actually exist,
# and we fail loudly only if something we truly need is gone.
essential_mods="search search_label configfile normal linux \
                part_gpt ext2 iso9660 loopback probe regexp test echo"
optional_mods="search_fs_uuid part_msdos fat exfat true initrd read sleep \
               all_video videoinfo gfxterm terminal ls halt reboot boot"

mods=()
missing_essential=()
for m in $essential_mods; do
    if [[ -f "$GRUB_EFI_DIR/$m.mod" ]]; then
        mods+=("$m")
    else
        missing_essential+=("$m")
    fi
done
for m in $optional_mods; do
    [[ -f "$GRUB_EFI_DIR/$m.mod" ]] && mods+=("$m")   # silently skip if absent
done

if (( ${#missing_essential[@]} > 0 )); then
    echo "Essential GRUB modules missing from $GRUB_EFI_DIR:" >&2
    printf '  - %s.mod\n' "${missing_essential[@]}" >&2
    echo "Your grub2-efi-x64-modules package looks incomplete; reinstall it." >&2
    exit 1
fi

# -d/--directory pins the module source dir (also silences the earlier
# "specify --target or --directory" hint if auto-detection ever fails).
"$MKSTANDALONE" \
    -O x86_64-efi \
    -d "$GRUB_EFI_DIR" \
    -o "$ESP_MNT/EFI/BOOT/BOOTX64.EFI" \
    --modules="${mods[*]}" \
    "boot/grub/grub.cfg=$EARLY_CFG"

rm -f "$EARLY_CFG"

# ---------- 7. write the real, self-scanning menu ----------
cat > "$DATA_MNT/boot/grub/grub.cfg" <<'CFG'
# -----------------------------------------------------------------------------
# Self-scanning multiboot menu for the RHEL family + Fedora.
#   ISOs       -> /isos/*.iso        on this (MULTIISO) partition
#   Kickstarts -> /kickstarts/*.ks   on this (MULTIISO) partition
# Drop files in and reboot -- no edits needed per ISO or per kickstart.
#
# Use grub-mvp.cfg first to confirm the boot chain works. This file adds the
# generated-menu machinery on top of an already-proven recipe.
# -----------------------------------------------------------------------------
insmod part_gpt
insmod ext2
insmod iso9660
insmod loopback
insmod probe
insmod regexp
insmod search_label
insmod all_video
insmod boot            # provides the explicit `boot` command used below
insmod ls              # so failure paths can list what GRUB actually sees

set timeout=20
set default=0
set pager=1

# The label of THIS partition. Every kernel argument that has to survive into
# the running kernel must reference this, not the ISO's internal label -- the
# kernel can find a real partition by label; it cannot find GRUB's (loop).
set datalabel=@DATA_LABEL@

# Make (root) point at THIS partition so /isos/*.iso globs resolve here.
search --no-floppy --label $datalabel --set=root

# -----------------------------------------------------------------------------
# Shared boot logic. Reads globals set by the chosen menu entry:
#   $isofile  = /isos/<name>.iso            (always set)
#   $ksfile   = /kickstarts/<name>.ks  OR  "" (empty = no kickstart)
#   $liveargs = extra kernel args, live entries only
# -----------------------------------------------------------------------------
function boot_iso {
    # NO pre-emptive "loopback -d loop" here, on purpose. Two reasons:
    #   1. It is unnecessary -- GRUB's loopback command already REPLACES an
    #      existing device of the same name (closes the old file, reuses the
    #      slot). There is no "name already exists" error to avoid.
    #   2. It is actively harmful. On a fresh session it fails with
    #      "grub-core/disk/loopback.c:delete_loopback:59:device not found",
    #      and GRUB skips the implicit boot at the end of a menu entry unless
    #      grub_errno is clear -- so a cosmetic error silently blocks booting.
    #
    # Mount the chosen ISO as (loop), then read its own volume label fresh.
    loopback loop ($root)$isofile
    probe --set=isolabel --label (loop)

    # Locate the kernel + initrd. Paths are stored COMPLETE, including the
    # (loop) device, so the glob fallback below can assign one directly.
    #   /images/pxeboot  RHEL/Rocky/Alma/CentOS DVDs, Fedora installer ISOs,
    #                    most lorax-built live media
    #   /isolinux        older syslinux-based media
    #   /boot            newer GRUB-native ISOs that ship no syslinux tree
    set kernelpath=""
    set initrdpath=""
    if [ -e (loop)/images/pxeboot/vmlinuz ]; then
        set kernelpath="(loop)/images/pxeboot/vmlinuz"
        set initrdpath="(loop)/images/pxeboot/initrd.img"
    elif [ -e (loop)/isolinux/vmlinuz ]; then
        set kernelpath="(loop)/isolinux/vmlinuz"
        set initrdpath="(loop)/isolinux/initrd.img"
    elif [ -e (loop)/isolinux/vmlinuz0 ]; then
        set kernelpath="(loop)/isolinux/vmlinuz0"
        set initrdpath="(loop)/isolinux/initrd0.img"
<<<<<<< HEAD
=======
    elif [ -e (loop)/boot/x86_64/loader/linux ]; then
        # kiwi-style layout (the convention openSUSE media use, and what newer
        # Rocky live images ship): boot/<arch>/loader/{linux,initrd}. Note the
        # kernel is called "linux", not "vmlinuz" -- which is why a vmlinuz
        # search finds nothing even though the kernel is right there.
        set kernelpath="(loop)/boot/x86_64/loader/linux"
        if [ -e (loop)/boot/x86_64/loader/initrd ]; then
            set initrdpath="(loop)/boot/x86_64/loader/initrd"
        elif [ -e (loop)/boot/x86_64/loader/initrd.img ]; then
            set initrdpath="(loop)/boot/x86_64/loader/initrd.img"
        fi
>>>>>>> 7a0c210 (Wed Jul 29 10:24:53 PM MST 2026)
    elif [ -e (loop)/boot/vmlinuz ]; then
        set kernelpath="(loop)/boot/vmlinuz"
        if [ -e (loop)/boot/initrd.img ]; then
            set initrdpath="(loop)/boot/initrd.img"
        elif [ -e (loop)/boot/initramfs.img ]; then
            set initrdpath="(loop)/boot/initramfs.img"
        fi
    else
        # Last resort: glob for VERSIONED names, e.g. /boot/vmlinuz-6.12.0-55.el9.
        # GRUB expands wildcards itself (that's what regexp.mod is for), and the
        # loop variable already holds the full (loop)/... path.
<<<<<<< HEAD
        for k in (loop)/boot/vmlinuz-* (loop)/boot/vmlinuz*; do
            if [ -e "$k" ]; then set kernelpath="$k"; fi
        done
        for i in (loop)/boot/initramfs-*.img (loop)/boot/initrd.img-* (loop)/boot/initrd-*.img; do
=======
        # Arch-agnostic kiwi layout first (aarch64 builds use boot/aarch64/...),
        # then versioned RHEL-style names under /boot.
        for k in (loop)/boot/*/loader/linux (loop)/boot/vmlinuz-* (loop)/boot/vmlinuz*; do
            if [ -e "$k" ]; then set kernelpath="$k"; fi
        done
        for i in (loop)/boot/*/loader/initrd (loop)/boot/initramfs-*.img (loop)/boot/initrd.img-* (loop)/boot/initrd-*.img; do
>>>>>>> 7a0c210 (Wed Jul 29 10:24:53 PM MST 2026)
            if [ -e "$i" ]; then set initrdpath="$i"; fi
        done
    fi

    if [ -z "$kernelpath" ]; then
        # CAREFUL reading this message: reaching here does NOT prove the ISO
        # lacks a kernel. If the `loopback` attach above failed, (loop) doesn't
        # exist and all three tests fail too. So show what GRUB can actually
        # see, which separates the two cases at a glance.
<<<<<<< HEAD
        echo "No kernel found (looked in images/pxeboot and isolinux) in:"
        echo "  $isofile"
=======
        echo "No kernel found in:"
        echo "  $isofile"
        echo "(searched images/pxeboot, isolinux, boot/, boot/<arch>/loader/)"
>>>>>>> 7a0c210 (Wed Jul 29 10:24:53 PM MST 2026)
        echo
        echo "What GRUB can see inside that ISO:"
        ls (loop)/
        echo
<<<<<<< HEAD
=======
        echo "Contents of /boot inside the ISO (empty/error = no such dir):"
        ls (loop)/boot/
        echo
>>>>>>> 7a0c210 (Wed Jul 29 10:24:53 PM MST 2026)
        echo "Sizes GRUB sees for the ISO files themselves:"
        ls -l ($root)/isos/
        echo
        echo "  - listing shows EFI/ images/ LiveOS/ etc -> genuinely an"
        echo "    unexpected layout; add its kernel path to boot_iso."
        echo "  - \"unknown filesystem\" -> GRUB opened the file but found nothing"
        echo "    filesystem-shaped inside. Almost always an incomplete copy:"
        echo "    compare the size above against the real ISO, and re-verify"
        echo "    its sha256 on the host AFTER dropping caches."
        echo "  - listing empty or errors otherwise -> never attached; check the"
        echo "    file actually exists on this partition."
        echo "Press a key to return to the menu..."
        read
        loopback -d loop
        return
    fi

    # Live vs installer. NOT testable via LiveOS/squashfs.img: RHEL/Rocky/Alma
    # DVDs contain that file too -- it is Anaconda's own runtime, the thing
    # inst.stage2 mounts. The dependable marker of INSTALLER media is /.treeinfo
    # (compose metadata, absent from live media); osbuild installers are caught
    # by their baked-in kickstart.
    if [ -e (loop)/.treeinfo ]; then
        set isinstaller=1
    elif [ -e (loop)/osbuild.ks ]; then
        set isinstaller=1
    else
        set isinstaller=0
    fi

    if [ "$isinstaller" = 0 ]; then
        # --- Live image (Fedora Workstation / Spins) ---
        # Kickstart is an installer concept, so it's ignored here on purpose.
        # CDLABEL is the ISO's OWN label, and that is correct here: dracut's
        # iso-scan module loop-mounts the ISO inside the initramfs, so a real
        # device carrying that label does exist by the time it's needed.
        if [ -z "$isolabel" ]; then
            echo "WARNING: this ISO has no volume label; live boot needs one."
            echo "Press a key..."
            read
        fi
<<<<<<< HEAD
=======
        # Hand our graphics mode to the kernel instead of resetting it. Taken
        # from the ISO's own grub.cfg -- omitting it is a classic cause of a
        # black screen once the live kernel takes over.
        set gfxpayload=keep
>>>>>>> 7a0c210 (Wed Jul 29 10:24:53 PM MST 2026)
        linux $kernelpath \
              root=live:CDLABEL=$isolabel rd.live.image \
              iso-scan/filename=$isofile $liveargs
        initrd $initrdpath
        # Explicit boot: the script-level `boot` command runs even with a stale
        # grub_errno, unlike the implicit boot GRUB does for you.
        boot
    else
        # --- Anaconda installer (RHEL/Rocky/Alma/CentOS/Fedora + osbuild) ---
        # inst.stage2 = where the installer runtime (squashfs) is
        # inst.repo   = where the packages are
        # Both are "hd:LABEL=<real partition label>:<path to the ISO on it>".
        # Anaconda mounts that ISO at /run/install/repo, which is how the
        # embedded-kickstart cases below can reach a file inside the ISO.
        #
        # Kickstart precedence:
        #   1. external ks you picked from /kickstarts  -> read off MULTIISO
        #   2. else a ks EMBEDDED in the ISO -- osbuild image-installer and
        #      edge/iot-installer bake one in (commonly /osbuild.ks)
        #   3. else none (plain interactive install).
        # $ksarg has no spaces, so it stays unquoted on the linux line (empty ->
        # expands to nothing).
        if [ -n "$ksfile" ]; then
            set ksarg="inst.ks=hd:LABEL=$datalabel:$ksfile"
        elif [ -e (loop)/osbuild.ks ]; then
            set ksarg="inst.ks=file:///run/install/repo/osbuild.ks"
        elif [ -e (loop)/ks.cfg ]; then
            set ksarg="inst.ks=file:///run/install/repo/ks.cfg"
        else
            set ksarg=""
        fi
        # No `quiet` -- while this is still new, you want the messages.
        linux $kernelpath \
              inst.stage2=hd:LABEL=$datalabel:$isofile \
              inst.repo=hd:LABEL=$datalabel:$isofile \
              $ksarg
        initrd $initrdpath
        boot
    fi
}

# -----------------------------------------------------------------------------
# Menu shape:
#   ISO: Rocky-9.5-dvd            (submenu)
#       Boot
#       + kickstart: ryzenbolt.ks
#       + kickstart: minimal.ks
#   ISO: Fedora-Live              (submenu)
#       Boot (live desktop)
#       ...
#
# Outer loop = one submenu per ISO. Inner loop = one entry per kickstart file,
# plus a "no kickstart" entry. Any ISO x any kickstart is reachable.
#
# Why the "$isofile" arguments on submenu/menuentry: a menuentry body is stored
# as TEXT and executed later, long after this loop finished, so $isofile would
# have moved on. Passing it as an argument freezes today's value; the body reads
# it back as $2 ($1 is the entry's own title).
# -----------------------------------------------------------------------------
for isofile in /isos/*.iso; do
    if [ -e "$isofile" ]; then
        regexp --set=isoname '^/isos/(.*)$' "$isofile"

        submenu "ISO: $isoname" "$isofile" {
            set isofile="$2"

            # Peek inside the ISO ONCE, here (this body runs when you open the
            # submenu). If it's a Live image, kickstart is meaningless, so we
            # won't offer kickstart entries at all. Uses its own loop name so it
            # never clashes with boot_iso's (loop).
            # Again: no pre-emptive detach (see boot_iso). The detach AFTER the
            # attach below is fine -- it succeeds, so it leaves no error behind.
            loopback liveprobe ($root)$isofile
            # Same test as boot_iso: /.treeinfo marks installer media. Do NOT use
            # LiveOS/squashfs.img -- installer DVDs carry that file as well.
            if [ -e (liveprobe)/.treeinfo ]; then
                set islive=0
            elif [ -e (liveprobe)/osbuild.ks ]; then
                set islive=0
            else
                set islive=1
            fi
            loopback -d liveprobe

            if [ "$islive" = 1 ]; then
                # --- Live image: no kickstart; offer normal / RAM / debug. ---
                # 4th arg = extra kernel args, captured as $4 -> $liveargs.
                # $liveargs values below are lifted from the ISOs' own menus:
                #   quiet rhgb      normal boot; rhgb = Red Hat graphical boot
                #   rd.live.ram=1   copy the whole image into RAM, then eject
                #   nomodeset       skip KMS -- for hosts with a black screen
                #   rd.live.check   verify the media checksum before booting
                menuentry "  Boot (live desktop)" "$isofile" "" "quiet rhgb" {
                    set isofile="$2"
                    set ksfile="$3"
                    set liveargs="$4"
                    boot_iso
                }
                menuentry "  Boot (live, into RAM -- ejectable)" "$isofile" "" "rd.live.ram=1 quiet rhgb" {
                    set isofile="$2"
                    set ksfile="$3"
                    set liveargs="$4"
                    boot_iso
                }
                menuentry "  Boot (live, basic graphics -- nomodeset)" "$isofile" "" "nomodeset quiet rhgb" {
                    set isofile="$2"
                    set ksfile="$3"
                    set liveargs="$4"
                    boot_iso
                }
                menuentry "  Boot (live, verify media first)" "$isofile" "" "rd.live.check quiet rhgb" {
                    set isofile="$2"
                    set ksfile="$3"
                    set liveargs="$4"
                    boot_iso
                }
                menuentry "  Boot (live, debug -- verbose)" "$isofile" "" "rd.live.debug systemd.log_level=debug" {
                    set isofile="$2"
                    set ksfile="$3"
                    set liveargs="$4"
                    boot_iso
                }
            else
                # --- Anaconda installer: default boot + one entry per ext. ks ---
                # "Boot" honors a kickstart EMBEDDED in the ISO (osbuild) if
                # present; otherwise it's a plain interactive install.
                menuentry "  Boot" "$isofile" "" {
                    set isofile="$2"
                    set ksfile="$3"
                    set liveargs=""
                    boot_iso
                }
                for ksfile in /kickstarts/*.ks; do
                    if [ -e "$ksfile" ]; then
                        regexp --set=ksname '^/kickstarts/(.*)$' "$ksfile"
                        # Both paths captured as $2 (iso) and $3 (ks).
                        menuentry "  + kickstart: $ksname" "$isofile" "$ksfile" {
                            set isofile="$2"
                            set ksfile="$3"
                            set liveargs=""
                            boot_iso
                        }
                    fi
                done
            fi
        }
    fi
done

# -----------------------------------------------------------------------------
# Escape hatches. If the ISO submenus above are empty, the first entry tells you
# whether GRUB can see the partition contents at all.
# -----------------------------------------------------------------------------
menuentry "Diagnostics: list /isos and /kickstarts" {
    insmod ls
    echo "root = $root"
    ls ($root)/isos/
    ls ($root)/kickstarts/
    echo "Press a key..."
    read
}
menuentry "Reboot" { reboot }
menuentry "Shut down" { halt }
CFG
# The menu is written with a QUOTED heredoc so $isofile etc. survive as literal
# GRUB variables; the one thing we do want substituted is the partition label.
sed -i "s/@DATA_LABEL@/$DATA_LABEL/g" "$DATA_MNT/boot/grub/grub.cfg"

# ---------- 8. finish ----------
sync
umount "$ESP_MNT" "$DATA_MNT"
rmdir  "$ESP_MNT" "$DATA_MNT"

echo
echo "Done."
echo "  ESP  : $ESP_PART  (label $ESP_LABEL)   -> /EFI/BOOT/BOOTX64.EFI"
echo "  DATA : $DATA_PART (label $DATA_LABEL)  -> put ISOs in /isos, kickstarts in /kickstarts"
echo
echo "Copy ISOs, e.g.:"
echo "  cp Rocky-9.5-x86_64-dvd.iso  /run/media/\$USER/$DATA_LABEL/isos/"
echo
echo "BEFORE you blame the stick:"
echo "  1. DISABLE SECURE BOOT on the target machine. BOOTX64.EFI is unsigned."
echo "  2. Boot the USB via the firmware's one-time boot menu (F12 / F11 / F8)."
echo "  3. Test without rebooting real hardware, straight off the device:"
echo "       sudo qemu-system-x86_64 -enable-kvm -m 4096 \\"
echo "         -bios /usr/share/edk2/ovmf/OVMF_CODE.fd \\"
echo "         -drive format=raw,file=$DEV"
<<<<<<< HEAD
echo "     (OVMF here has Secure Boot off, so this tests everything EXCEPT signing.)"
=======
echo "     (OVMF here has Secure Boot off, so this tests everything EXCEPT signing.)"

>>>>>>> 7a0c210 (Wed Jul 29 10:24:53 PM MST 2026)
