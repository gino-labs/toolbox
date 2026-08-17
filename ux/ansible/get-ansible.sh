#!/usr/bin/bash

if ! command -v python3 > /dev/null; then
  echo "Python3 unavailable..."
  exit 1
fi

if [[ ! -d ".venv" ]]; then
  echo "Creating python virtual environmet."
  python3 -m venv .venv
fi

source .venv/bin/activate
echo "Running pip installs"
python3 -m pip install -U pip
echo "Installing ansible"
python3 -m pip install ansible
deactivate
