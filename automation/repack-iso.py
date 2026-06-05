#!/usr/bin/env python3
import os
import argparse
import subprocess
from pathlib import Path

def build_parser():
    p = argparse.ArgumentParser()
    p.add_argument("iso", help="Specify path to ISO file.")
    p.add_argument("-o", "--outfile", help="Specify output file.")
    p.add_argument("-a", "--addcontent", action="append", help="Specify file or directory to add to iso rebuild.")
    p.add_argument("-m", "--mountpoint", default="/mnt/iso/", help="Specify a mount point to use for iso.")
    p.add_argument("-L", "--label", default="N0LAB3L", help="Specify a disk partition label.")

if __name__ == "__main__":
    pass
