#Commands

text
eula --agreed
firstboot --disable

lang en_US.UTF-8
keyboard --xlayouts='us'
timezone UTC --utc

# Root will be accessed through console autologin.
# This also prevents password-based root authentication.
rootpw --lock

selinux --enforcing

# Permit SSH through the live environment's firewall.
firewall --enabled --service=ssh

# Use the first interface that has carrier.
network --bootproto=dhcp --device=link --activate --hostname=rocky-rescue

services --enabled="NetworkManager,sshd"

cdrom
repo --name="epel" --metalink="https://mirrors.fedoraproject.org/metalink?repo=epel-9&arch=x86_64"

# This layout is for livemedia-creator's temporary installation disk.
zerombr
clearpart --all --initlabel
part / --fstype=xfs --size=16384

bootloader --location=mbr --timeout=3

shutdown

%packages
@core

# ---------------------------------------------------------
# Live-image boot support
# ---------------------------------------------------------
kernel
kernel-modules
kernel-modules-extra
dracut
dracut-live
squashfs-tools

# ---------------------------------------------------------
# Essential shell and administrative tools
# ---------------------------------------------------------
bash-completion
sudo
vim-enhanced
nano
less
which
file
findutils
diffutils
patch
tar
gzip
bzip2
xz
zstd
unzip
zip
cpio
rsync
tree
tmux
screen
man-db
man-pages
util-linux
util-linux-user
coreutils
procps-ng
psmisc
lsof
time

# ---------------------------------------------------------
# Partitioning and filesystem tools
# ---------------------------------------------------------
parted
gdisk
dosfstools
e2fsprogs
xfsprogs
exfatprogs
quota
attr
acl

# ---------------------------------------------------------
# LVM, RAID, encryption, device mapper
# ---------------------------------------------------------
lvm2
mdadm
cryptsetup
device-mapper
device-mapper-multipath
device-mapper-event
clevis
clevis-luks
clevis-dracut
keyutils

# ---------------------------------------------------------
# Disk and hardware inspection
# ---------------------------------------------------------
nvme-cli
smartmontools
hdparm
sdparm
sg3_utils
lsscsi
pciutils
usbutils
dmidecode
hwdata
efibootmgr
mokutil
fwupd
rasdaemon
mcelog

# ---------------------------------------------------------
# Network configuration and diagnostics
# ---------------------------------------------------------
NetworkManager
NetworkManager-tui
iproute
iputils
ethtool
bind-utils
traceroute
tcpdump
nmap
nmap-ncat
wireshark-cli
curl
wget
openssh-clients
openssh-server
rsync
socat
net-tools
whois
iptraf-ng

# ---------------------------------------------------------
# Remote and network-backed storage
# ---------------------------------------------------------
nfs-utils
cifs-utils
iscsi-initiator-utils
device-mapper-multipath
fcoe-utils
lldpad

# ---------------------------------------------------------
# System diagnostics and performance
# ---------------------------------------------------------
strace
ltrace
sysstat
iotop
perf
numactl
tuned
blktrace
trace-cmd
pciutils
usbutils

# ---------------------------------------------------------
# Logs, boot troubleshooting, and systemd
# ---------------------------------------------------------
systemd
systemd-udev
systemd-container
journalctl
kexec-tools
dracut-config-rescue

# ---------------------------------------------------------
# SELinux and security inspection
# ---------------------------------------------------------
policycoreutils
policycoreutils-python-utils
setools-console
checkpolicy
audit
openscap-scanner
scap-security-guide

# ---------------------------------------------------------
# Package and repository repair
# ---------------------------------------------------------
rpm
dnf
dnf-plugins-core
createrepo_c
rpm-build
rpm-sign
python3
python3-pip

# ---------------------------------------------------------
# Virtual disk and VM recovery
# ---------------------------------------------------------
qemu-img
qemu-kvm-core
libguestfs
guestfs-tools
libnbd
nbdkit

# ---------------------------------------------------------
# Compression and archive formats
# ---------------------------------------------------------
pigz
pbzip2
xz
zstd
lz4
tar
cpio
gzip

# ---------------------------------------------------------
# Useful text/data processing
# ---------------------------------------------------------
grep
gawk
sed
jq
bc
ed
diffutils

# Packages that add size without much rescue value
-anaconda
-anaconda-gui
-initial-setup-gui
-gnome-shell
-firefox
-libreoffice-core
-evolution

# Fedora EPEL (Optional)
ddrescue
testdisk
ntfs-3g
ntfsprogs
hfsplus-tools
htop
stress-ng
aria2
pv
fdupes
rclone
nload
iftop
iotop-c
tldr
ncdu 
bmon
nmon
ngrep
extundelete
duf
stress-ng
%end

%post --erroronfail --log=/root/ks-post.log

set -euxo pipefail

# ---------------------------------------------------------
# System identity
# ---------------------------------------------------------

echo 'rocky9-rescue' > /etc/hostname

# Generate a unique machine ID on every live boot.
truncate -s 0 /etc/machine-id

rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# ---------------------------------------------------------
# Required services
# ---------------------------------------------------------

systemctl enable NetworkManager.service
systemctl enable sshd.service

# ---------------------------------------------------------
# Automatic root login on the primary virtual console
# ---------------------------------------------------------

mkdir -p /etc/systemd/system/getty@tty1.service.d

cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
EOF

# Automatic root login on the serial/console getty used by many VMs
# and systems booted with console=ttyS0.
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d

cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud 115200,57600,38400,9600 %I $TERM
Type=idle
EOF

# ---------------------------------------------------------
# SSH security
# ---------------------------------------------------------

mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/20-live-rescue.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UseDNS no
EOF

# Optional: place trusted public keys in this file before building.
install -d -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys

# ---------------------------------------------------------
# Concise MOTD
# ---------------------------------------------------------

cat > /etc/motd <<'EOF'
Rocky Linux 9 Rescue Environment

Storage:  lsblk -f | blkid | pvs | vgs | lvs
Network:  nmcli device status | nmtui | ip -brief address
Help:     tldr COMMAND | man COMMAND
EOF

# Prevent dynamic MOTD fragments from creating extra output, when present.
rm -rf /etc/motd.d/* 2>/dev/null || true

# ---------------------------------------------------------
# Interactive shell configuration
# ---------------------------------------------------------

cat > /etc/profile.d/rescue.sh <<'EOF'
export EDITOR=vim
export VISUAL=vim
export PAGER=less

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

alias disks='lsblk -e7 -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN,ROTA,TYPE,FSTYPE,LABEL,MOUNTPOINTS'
alias lsblkf='lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,FSVER,LABEL,UUID,PARTUUID,MOUNTPOINTS'
alias netbrief='ip -brief address'
alias routes='ip route show'
alias ports='ss -tulpn'
EOF

chmod 0644 /etc/profile.d/rescue.sh

# ---------------------------------------------------------
# TLDR offline command pages
# ---------------------------------------------------------

# Different TLDR clients use different update syntax and cache locations.
# Run the supported update command without failing the entire image build.
if command -v tldr >/dev/null 2>&1; then
    tldr --update ||
    tldr --update-cache ||
    echo 'WARNING: TLDR pages could not be cached during the build.' >&2
fi

# Ensure cached pages remain readable if the client cached them under /root.
find /root/.cache -type d -exec chmod a+rx {} + 2>/dev/null || true
find /root/.cache -type f -exec chmod a+r {} + 2>/dev/null || true

# ---------------------------------------------------------
# Disable unnecessary live-system background work
# ---------------------------------------------------------

systemctl disable dnf-makecache.timer 2>/dev/null || true
systemctl disable dnf-makecache.service 2>/dev/null || true

# Do not automatically activate swap found on attached recovery disks.
systemctl mask systemd-gpt-auto-generator 2>/dev/null || true

# ---------------------------------------------------------
# Package and build cleanup
# ---------------------------------------------------------

dnf clean all

rm -rf \
    /var/cache/dnf/* \
    /var/cache/yum/* \
    /var/log/anaconda/* \
    /var/log/dnf* \
    /var/log/hawkey.log \
    /tmp/* \
    /var/tmp/*

# Preserve this build log for troubleshooting.
chmod 0600 /root/ks-post.log 2>/dev/null || true

%end
