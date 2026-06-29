#!/usr/bin/env python3
from pathlib import Path
import argparse
import sys
import re

def insert_line(new_line: str, file: str):
    filepath = Path(file).resolve()
    file_text = filepath.read_text()
    lines = file_text.splitlines()

    insert_index = None
    h1_pattern = re.compile(r"<h1[^>]*>.*?</h1>")

    for index, line in enumerate(lines):
        m = h1_pattern.search(line)
        if m:
            insert_index = index + 1
            break
    if not m:
        sys.exit(f"No matches found in {file}")
    
    return "\n".join(lines[:insert_index] + [new_line] + lines[insert_index:])
    

def main():
    p = argparse.ArgumentParser()
    p.add_argument("-f", "--file", required=True)
    p.add_argument("-l", "--line", required=True)
    args = p.parse_args()

    text = insert_line(args.line, args.file)
    print(text)

if __name__ == "__main__":
    main()
