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

set timeout=20
set default=0
set pager=1

# The label of THIS partition. Every kernel argument that has to survive into
# the running kernel must reference this, not the ISO's internal label -- the
# kernel can find a real partition by label; it cannot find GRUB's (loop).
set datalabel=MULTIISO

# Make (root) point at THIS partition so /isos/*.iso globs resolve here.
search --no-floppy --label $datalabel --set=root

# -----------------------------------------------------------------------------
# Shared boot logic. Reads globals set by the chosen menu entry:
#   $isofile  = /isos/<name>.iso            (always set)
#   $ksfile   = /kickstarts/<name>.ks  OR  "" (empty = no kickstart)
#   $liveargs = extra kernel args, live entries only
# -----------------------------------------------------------------------------
function boot_iso {
    # Detach any leftover loop from a previous (failed/aborted) selection so a
    # retry or a different ISO doesn't hit "device name already exists". On a
    # fresh session there's nothing to detach -- GRUB prints a harmless
    # "no such device: loop" and carries on.
    loopback -d loop

    # Mount the chosen ISO as (loop), then read its own volume label fresh.
    loopback loop ($root)$isofile
    probe --set=isolabel --label (loop)

    # Locate the kernel + initrd. RHEL/Rocky/Alma/CentOS DVDs, Fedora installer
    # ISOs, and modern Fedora Live ISOs all keep them under /images/pxeboot.
    # Older isolinux-based media keep them under /isolinux. Probe in that order.
    if [ -e (loop)/images/pxeboot/vmlinuz ]; then
        set kernel=/images/pxeboot/vmlinuz
        set initrdimg=/images/pxeboot/initrd.img
    elif [ -e (loop)/isolinux/vmlinuz ]; then
        set kernel=/isolinux/vmlinuz
        set initrdimg=/isolinux/initrd.img
    elif [ -e (loop)/isolinux/vmlinuz0 ]; then
        set kernel=/isolinux/vmlinuz0
        set initrdimg=/isolinux/initrd0.img
    else
        echo "No kernel found (looked in images/pxeboot and isolinux) in:"
        echo "  $isofile"
        echo "Press a key to return to the menu..."
        read
        loopback -d loop
        return
    fi

    if [ -e (loop)/LiveOS/squashfs.img ]; then
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
        linux (loop)$kernel \
              root=live:CDLABEL=$isolabel rd.live.image \
              iso-scan/filename=$isofile $liveargs
        initrd (loop)$initrdimg
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
        linux (loop)$kernel \
              inst.stage2=hd:LABEL=$datalabel:$isofile \
              inst.repo=hd:LABEL=$datalabel:$isofile \
              $ksarg
        initrd (loop)$initrdimg
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
            loopback -d liveprobe
            loopback liveprobe ($root)$isofile
            if [ -e (liveprobe)/LiveOS/squashfs.img ]; then set islive=1; else set islive=0; fi
            loopback -d liveprobe

            if [ "$islive" = 1 ]; then
                # --- Live image: no kickstart; offer normal / RAM / debug. ---
                # 4th arg = extra kernel args, captured as $4 -> $liveargs.
                menuentry "  Boot (live desktop)" "$isofile" "" "quiet" {
                    set isofile="$2"
                    set ksfile="$3"
                    set liveargs="$4"
                    boot_iso
                }
                menuentry "  Boot (live, into RAM -- ejectable)" "$isofile" "" "rd.live.ram=1 quiet" {
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