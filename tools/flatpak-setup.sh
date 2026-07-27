#!/usr/bin/bash

if ! rpm -q flatpak; then
  sudo dnf install -y flatpak
else
  echo "Flatpak already installed."
fi

if ! flatpak remotes --user --columns=name | grep -q flathub; then
  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  echo "Remote flathub configured."
else
  echo "Remote flathub already configured."
fi

if ! flatpak remotes --user --columns=name | grep -q fedora; then
  flatpak remote-add --user --if-not-exists fedora oci+https://registry.fedoraproject.org
  echo "Remote fedora configured."
else
  echo "Remote fedora already configured."
fi

apps=(
    com.bambulab.BambuStudio
    org.freecad.FreeCAD
    cc.arduino.IDE2
    com.spotify.Client
    us.zoom.Zoom
    me.proton.Mail
)

for app in "${apps[@]}"; do
  if ! flatpak list --app --columns=application | grep -q "$app"; then
    flatpak install -y --user "$app"
    echo "Flatpak installed $app"
  else
    echo "Flatpak already installed $app"
  fi
done

