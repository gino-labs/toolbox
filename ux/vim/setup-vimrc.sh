#!/usr/bin/env bash
cp ./vimrc "$HOME/.vimrc" 

echo "Vim environment setup."

if [[ ! -d $HOME/.config/nvim ]]; then
    mkdir -p $HOME/.config/nvim
fi

cp ./vimrc "$HOME/.config/nvim/init.vim
echo "NeoVim environment also setup."

