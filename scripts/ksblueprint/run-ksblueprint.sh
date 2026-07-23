#!/usr/bin/bash
shopt -s nullglob

configs=(vault/*.y*ml)
if [ ${#configs[@]} -eq 0 ]; then
    echo "no config files found in vault/" >&2
    exit 1
fi

for yml in "${configs[@]}"; do
    python3 ksblueprint.py -c "$yml" --pre-file diskpart-pre.bash.ks --embed-kickstart -o build/
done