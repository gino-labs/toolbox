#!/usr/bin/env python3
import subprocess
import argparse
import sys

def build_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument("-i", "--iso", type=str, required=True, help="Path to ISO file for installion")
    parser.add_argument("-n", "--name", required=True, help="Virtual machine name")
    parser.add_argument("-c", "--cpus", type=int, default=8, help="Virtual machine vCPUs to allocate")
    parser.add_argument("-m", "--memory", type=int, default=16384, help="Virtual machine memory to allocate in MiB")
    parser.add_argument("-d", "--disk-size", type=int, default=200, help="Virtual machine disk size to allocate in GB")
    parser.add_argument("-b", "--bridge", type=str, default="br0", help="Virtual machine bridge to use")
    
    return parser

def install(name, cpus, memory, disk_size, bridge, iso):
    print(f"""
    VM Details:
        NAME: {name}
        CPUS: {cpus}
        MEMORY: {memory} MiB
        DISK SIZE: {disk_size} GB
        BRIDGE: {bridge}
        ISO: {iso}
    """)
    confirm = None
    while confirm not in ('y','n'):
        confirm = input("Enter y/n to confirm install: ")

    if confirm == 'n':
        sys.exit(1)
    else:
        virt_install_command = [
            "virt-install",
            "--name",
            name,
            "--vcpus",
            cpus,
            "--memory",
            memory,
            "--disk",
            f"path=/vmpool/images/{name}.qcow2,size={disk_size},format=qcow2",
            "--network",
            f"bridge={bridge}",
            "--boot",
            "uefi",
            "--os-variant",
            "detect=on,require=off",
            "--graphics",
            "none",
            "--serial",
            "pty",
            "--console",
            "pty,target_type=serial",
            "--location",
            iso,
            "--extra-args",
            f"console=ttyS0,115200n8 console=tty0"
        ]

    result = subprocess.run(virt_install_command, check=True)

def main(): 
    parser = build_parser()
    
    args = parser.parse_args()
    install(args.name, args.cpus, args.memory, args.disk_size, args.bridge, args.iso)

if __name__ == "__main__":
    main()

