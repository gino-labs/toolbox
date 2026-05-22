%pre --interpreter=/usr/libexec/platform-python --log=/tmp/pre_script.log --erroronfail
import json
import subprocess

# In bytes for comparing to lsblk output
MIN_SIZE = 60 * 1024**3
MAX_SIZE = 2000 * 1024**3

lsblk_cmd = ["lsblk", "-Jbdpo", "NAME,SIZE,TRAN,RM"]
result = subprocess.run(lsblk_cmd, stdout=subprocess.PIPE, universal_newlines=True, check=True).stdout
json_result = json.loads(result)
block_devs = json_result["blockdevices"]

disks=[]
for dev in block_devs: 
    if (MIN_SIZE < int(dev["size"]) < MAX_SIZE) and dev["rm"] not in ("true", "1", True, 1):
        disks.append(dev)

if len(disks) == 2:
    d1 = disks[0]['name']
    d2 = disks[1]['name']
elif len(disks) == 1:
    d1 = disks[0]['name']
    d2 = None
elif len(disks) > 2:
    # Check for 2 equal or 1 smallest disk
    min_disk_size = min(int(disk["size"]) for disk in disks)
    matched_disks = [disk for disk in disks if disk["size"] == min_disk_size]
    if len(matched_disks) > 1:
        d1 = matched_disks[0]["name"]
        d2 = matched_disks[1]["name"]
    else:
        d1 = matched_disks[0]["name"]
        d2 = None
else:
    Raise RuntimeError("No valid disks in given range.")
        

raid_partitions = f'''
ignoredisk --only-use={d1},{d2}
bootloader --location=mbr --boot-drive={d1} --driveorder={d1},{d2}  --iscrypted --password={{ grub_pw }}

part raid.0 --size=2048 --ondisk={d1}
part raid.1 --size=2048 --ondisk={d2}

part raid.2 --size={50 * 1024} --grow --ondisk={d1}
part raid.3 --size={50 * 1024} --grow --ondisk={d2}

part /boot/efi --fstype=efi --size=512 --ondisk={d1} --label=EFI
part efi.02 --fstype=efi --size=512 --ondisk={d2} --label=EFI2

raid /boot --fstype=xfs --level=1 --device=md0 raid.0 raid.1 --label=BOOT
raid pv.1 --fstype=lvmpv --level=1 --device=md1 --encrypted --passphrase={{ luks_pw }} raid.2 raid.3

'''
reg_partitions = f'''
ignoredisk --only-use={d1}
bootloader --location=mbr --boot-drive={d1} --driveorder={d1}  --iscrypted --password={{ grub_pw }}
clearpart --all --initlabel --drives={d1}

part /boot --fstype=xfs --size=2048 --ondisk={d1} --label=BOOT
part /boot/efi --fstype=efi --size=512  --ondisk={d1} --label=EFI
part pv.1 --fstype=lvmpv --encrypted --passphrase={{ luks_pw }}

'''

lvm_partitions = f'''
volgroup vg pv.1
logvol / --vgname=vg --name=root --fstype=xfs --percent=25 --grow --fsoptions=defaults
logvol /home --vgname=vg --name=home --fstype=xfs --percent=15 --grow --fsoptions=defaults
logvol /var --vgname=vg --name=var --fstype=xfs --percent=5 --grow --fsoptions=defaults
logvol /var/log --vgname=vg --name=var_log --fstype=xfs --percent=5 --grow --fsoptions=defaults
logvol /var/tmp --vgname=vg --name=var_tmp --fstype=xfs --percent=3 --grow --fsoptions=defaults
logvol /tmp --vgname=vg --name=tmp --fstype=xfs --percent=2 --grow --fsoptions=defaults
logvol /scratch --vgname=vg --name=scratch --fstype=xfs --percent=15 --grow --fsoptions=defaults
logvol swap --vgname=vg --name=swap --fstype=swap --size=8 --fsoptions=defaults

'''

with open("/tmp/partitioning", "w") as f:
    if d2 is not None:
        f.write(raid_partitions)
    else:
        f.write(reg_partitions)
    f.write(lvm_partitions)
%end

# Command Section
text
skipx
reboot
eula --agreed
keyboard us
lang en_US.UTF-8
selinux --enforcing

network --bootproto=dhcp --onboot=on --activate

rootpw --allow-ssh --iscrypted {{ root_pw }}
user --name=ansible
sshkey --username=ansible {{ ansible_key }}

timezone {{ timezone }} --utc --no
zerombr
%include /tmp/partitioning

%packages --ignoremissing
@^minimal-environment
bash-completion
tmux
vim
%end

%post --interpreter=/usr/libexec/platform-python --log=/root/post-kickstart.log
import os
# Setup passwordless sudo for ansible
sudo_file = "/etc/sudoers.d/ansible"
with open(sudo_file, w) as f:
    text = "ansible ALL=(ALL) NOPASSWD: ALL"
    f.write(text)
os.chown(sudo_file, 0, 0)
os.chmod(sudo_file", "0o440")
%end
