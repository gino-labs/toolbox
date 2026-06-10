#!/usr/bin/env bash

BD="$HOME/.bashrc.d"
[[ -d "$BD" ]] || mkdir -p "$BD" && echo "OK: $BD"

find files -iname 'bash_*' -type f -print -exec cp {} "$BD/" \; 

if ! grep -q "Source Bash Files" "$HOME/.bashrc"; then
cat >> "$HOME/.bashrc" <<'EOF'
# Source Bash Files
for f in "$HOME/.bashrc.d"/*; do
  [[ -f "$f" && -r "$f" ]] && source "$f"
done
EOF
fi

echo -e "Bash environment setup."

