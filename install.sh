#!/bin/bash
# Hyprland на чистом Debian 13 (trixie): минимум пакетов + стиль как на скриншотах.
# Запуск от root:  su -   затем   bash install.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

[ "$(id -u)" -eq 0 ] || { echo "Запусти от root: su -"; exit 1; }
. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || { echo "Нужен Debian 13 (trixie)"; exit 1; }

U="${1:-$(getent passwd 1000 | cut -d: -f1 || true)}"
[ -n "$U" ] || { echo "Не нашёл пользователя. Запусти: bash install.sh ИМЯ"; exit 1; }
H="/home/$U"

# --- Пакеты (Hyprland есть только в trixie-backports), без recommends = без мусора ---
echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list
apt-get update
apt-get install -y --no-install-recommends sudo
apt-get install -y --no-install-recommends -t trixie-backports \
  hyprland hyprland-guiutils xdg-desktop-portal-hyprland \
  kitty waybar wofi swaybg \
  pipewire pipewire-pulse wireplumber \
  brightnessctl grim slurp wl-clipboard \
  fonts-dejavu-core fonts-font-awesome polkitd lxqt-policykit \
  fastfetch cava pcmanfm \
  dbus-user-session xdg-utils xwayland \
  gvfs gvfs-daemons udisks2 \
  firefox-esr firefox-esr-l10n-ru \
  telegram-desktop \
  flatpak curl

# --- Steam через Flatpak: сам Steam, но без i386-мусора в системе ---
if command -v flatpak >/dev/null 2>&1; then
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak install -y flathub com.valvesoftware.Steam || echo "!! Steam (flatpak) не установился (скрипт продолжает работу)"
else
  echo "!! flatpak не установился — Steam пропущен"
fi

usermod -aG sudo,video "$U"

# --- Установщик .deb: двойной щелчок по файлу в PCMan открывает окно установки с зависимостями ---
cat > /usr/local/bin/deb-install <<'EOF'
#!/bin/sh
f="$(readlink -f "$1")"
[ -f "$f" ] || { echo "Файл не найден: $1"; exit 1; }
exec kitty --title "Установка .deb" sh -c '
  echo "Устанавливаю: $1"; echo
  sudo apt install -y "$1"
  echo; printf "Готово. Нажми Enter, чтобы закрыть..."; read _
' sh "$f"
EOF
chmod 755 /usr/local/bin/deb-install

# --- Happ (официальный .deb с GitHub; в репозиториях Debian его нет) ---
if command -v curl >/dev/null 2>&1; then
  HAPP_URL="$(curl -fsSL https://api.github.com/repos/Happ-proxy/happ-desktop/releases/latest 2>/dev/null \
    | grep -o 'https://[^"]*\.deb' | grep -vi 'arm' | head -n1 || true)"
  if [ -n "$HAPP_URL" ] && curl -fL -o /tmp/happ.deb "$HAPP_URL"; then
    apt-get install -y --no-install-recommends /tmp/happ.deb || echo "!! Happ не установился (скрипт продолжает работу)"
    rm -f /tmp/happ.deb
  else
    echo "!! Happ не скачался автоматически. Скачай .deb (Linux x64) со страницы"
    echo "!! https://github.com/Happ-proxy/happ-desktop/releases и открой файл двойным щелчком в PCMan."
  fi

  # --- Limusic (официальный .deb с GitHub Releases; в репозиториях Debian его нет) ---
  LIMUSIC_URL="$(curl -fsSL https://api.github.com/repos/SimoHypers/limusic/releases/latest 2>/dev/null \
    | grep -o 'https://[^"]*_amd64\.deb' | head -n1 || true)"
  if [ -n "$LIMUSIC_URL" ] && curl -fL -o /tmp/limusic.deb "$LIMUSIC_URL"; then
    apt-get install -y --no-install-recommends /tmp/limusic.deb || echo "!! Limusic не установился (скрипт продолжает работу)"
    rm -f /tmp/limusic.deb
  else
    echo "!! Limusic не скачался автоматически. Скачай .deb (Linux amd64) со страницы"
    echo "!! https://github.com/SimoHypers/limusic/releases и открой файл двойным щелчком в PCMan."
  fi
else
  echo "!! curl не установился — Happ и Limusic пропущены"
fi

# --- Конфиги (старые сохраняются как .bak) ---
w() {
  mkdir -p "$(dirname "$1")"
  if [ -f "$1" ]; then cp -f "$1" "$1.bak"; fi
  cat > "$1"
}

w "$H/.config/hypr/hyprland.conf" <<'EOF'
monitor = , preferred, auto, 1
$mod = SUPER

# Обои: любой файл ~/Pictures/wall/wall.png (или wall.jpg), если файла нет - тёмный фон
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = sh ~/.config/hypr/wallpaper.sh
exec-once = waybar
exec-once = lxqt-policykit-agent

input {
    kb_layout = us,ru
    kb_options = grp:alt_shift_toggle
    touchpad {
        natural_scroll = true
    }
}

general {
    gaps_in = 4
    gaps_out = 8
    border_size = 1
    col.active_border = rgba(ffffffcc)
    col.inactive_border = rgba(ffffff22)
    layout = dwindle
}

decoration {
    rounding = 6
    active_opacity = 1.0
    inactive_opacity = 1.0
    blur {
        enabled = true
        size = 6
        passes = 3
    }
}

animations {
    enabled = true
    bezier = ease, 0.22, 1, 0.36, 1
    animation = windows, 1, 5, ease, popin 85%
    animation = fade, 1, 5, ease
    animation = workspaces, 1, 5, ease, slide
}

misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}

# --- Программы ---
bind = $mod, Return, exec, kitty sh ~/.config/fastfetch/show.sh
bind = $mod, D, exec, wofi --show drun
bind = $mod, B, exec, firefox-esr
bind = $mod, E, exec, pcmanfm
bind = $mod, W, exec, sh ~/.config/hypr/wallpaper.sh

# --- Окна ---
bind = $mod, Q, killactive
bind = $mod, F, fullscreen
bind = $mod, V, togglefloating

# --- Фокус ---
bind = $mod, left, movefocus, l
bind = $mod, right, movefocus, r
bind = $mod, up, movefocus, u
bind = $mod, down, movefocus, d

# --- Перемещение и размер окон ---
bind = $mod SHIFT, left, movewindow, l
bind = $mod SHIFT, right, movewindow, r
bind = $mod SHIFT, up, movewindow, u
bind = $mod SHIFT, down, movewindow, d
binde = $mod CTRL, left, resizeactive, -40 0
binde = $mod CTRL, right, resizeactive, 40 0
binde = $mod CTRL, up, resizeactive, 0 -40
binde = $mod CTRL, down, resizeactive, 0 40
bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow

# --- Рабочие столы ---
bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4
bind = $mod SHIFT, 5, movetoworkspace, 5
bind = $mod, Tab, workspace, e+1
bind = $mod, mouse_down, workspace, e+1
bind = $mod, mouse_up, workspace, e-1

# --- Раскладка и скриншоты ---
bind = $mod, Space, exec, hyprctl switchxkblayout all next
bind = $mod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy

# --- Звук и яркость ---
bindel = , XF86AudioRaiseVolume, exec, wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindl = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindel = , XF86MonBrightnessUp, exec, brightnessctl set 5%+
bindel = , XF86MonBrightnessDown, exec, brightnessctl set 5%-
EOF

w "$H/.config/kitty/kitty.conf" <<'EOF'
font_family DejaVu Sans Mono
font_size 11
symbol_map U+F000-U+F2E0 FontAwesome
background_opacity 0.5
window_padding_width 10
background #0a0a0c
foreground #e0e0e0
cursor #ffffff
confirm_os_window_close 0
EOF

w "$H/.config/waybar/config.jsonc" <<'EOF'
{
  "layer": "top", "height": 30, "margin-top": 6, "margin-left": 8, "margin-right": 8,
  "modules-left": ["clock", "network", "temperature"],
  "modules-center": ["hyprland/workspaces"],
  "modules-right": ["hyprland/language", "pulseaudio", "backlight", "battery", "pulseaudio#mic"],

  "hyprland/workspaces": { "format": "{id}", "persistent-workspaces": { "*": 5 } },
  "hyprland/language": { "format": "{short}" },
  "clock": { "format": "{:%H:%M | %d %b}", "tooltip-format": "{:%d %B %Y}" },
  "network": {
    "format-wifi": " {essid}",
    "format-ethernet": "{ifname}",
    "format-disconnected": "offline"
  },
  "temperature": { "format": " {temperatureC}°C" },
  "pulseaudio": {
    "format": " {volume}%",
    "format-muted": " mute",
    "on-click": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
  },
  "pulseaudio#mic": {
    "format": "{format_source}",
    "format-source": " {volume}%",
    "format-source-muted": " off",
    "on-click": "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
  },
  "backlight": { "format": " {percent}%" },
  "battery": {
    "format": "{icon} {capacity}%",
    "format-icons": ["", "", "", "", ""]
  }
}
EOF

w "$H/.config/waybar/style.css" <<'EOF'
* { font-family: "DejaVu Sans Mono", "FontAwesome"; font-size: 11px; border: none; min-height: 0; }
window#waybar { background: transparent; color: #e6e6e6; }

#workspaces, #clock, #network, #temperature, #language,
#pulseaudio, #backlight, #battery {
  background: rgba(18,18,20,0.55);
  border: 1px solid rgba(255,255,255,0.35);
  border-radius: 20px;
  padding: 2px 12px;
  margin: 2px 3px;
}
#workspaces { padding: 2px 6px; }
#workspaces button { color: #9a9a9a; background: transparent; padding: 0 8px; border-radius: 20px; }
#workspaces button.active { color: #111111; background: #e6e6e6; }
#battery.warning { color: #ffcc66; }
#battery.critical { color: #ff6b6b; }
EOF

w "$H/.config/wofi/config" <<'EOF'
width=520
height=330
prompt=Search...
allow_images=true
image_size=20
insensitive=true
EOF

w "$H/.config/wofi/style.css" <<'EOF'
window { background-color: rgba(14,14,16,0.82); border: 1px solid rgba(255,255,255,0.35); border-radius: 8px; font-family: "DejaVu Sans Mono"; font-size: 12px; }
#input { background: transparent; color: #e6e6e6; border: none; margin: 4px; }
#entry { padding: 4px 8px; }
#entry:selected { background-color: rgba(255,255,255,0.18); }
#text { color: #e6e6e6; margin-left: 6px; }
EOF

# cava запускается только командой `cava` в терминале: прячем его из лаунчера
w "$H/.local/share/applications/cava.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=cava
Exec=cava
NoDisplay=true
EOF

# В лаунчере Firefox называется просто "Firefox"
w "$H/.local/share/applications/firefox-esr.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Firefox
Exec=firefox-esr %u
Icon=firefox-esr
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupWMClass=firefox-esr
EOF

# fastfetch: своё фото вместо логотипа Debian
#   поставить фото:  cp /путь/к/фото.png ~/.config/fastfetch/logo.png   (только PNG, лучше квадратное)
#   убрать фото:     rm ~/.config/fastfetch/logo.png
# Без фото логотипа нет вообще. Вернуть логотип Debian: замени "--logo none" на пустое место.
w "$H/.config/fastfetch/show.sh" <<'EOF'
#!/bin/sh
LOGO="$HOME/.config/fastfetch/logo.png"
if [ -f "$LOGO" ]; then
  fastfetch --kitty-direct "$LOGO" --logo-width 30 --logo-height 15
else
  fastfetch --logo none
fi
exec bash
EOF

# PCManFM: в лаунчере называется "PCMan", пункт "параметры рабочего стола" спрятан
w "$H/.local/share/applications/pcmanfm.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=PCMan
Exec=pcmanfm %U
Icon=system-file-manager
Terminal=false
Categories=System;FileManager;
MimeType=inode/directory;
StartupWMClass=Pcmanfm
EOF

w "$H/.local/share/applications/pcmanfm-desktop-pref.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PCManFM Desktop Preferences
Exec=pcmanfm --desktop-pref
NoDisplay=true
Hidden=true
EOF

# Тёмные GTK-приложения (PCMan, Firefox): без лишних пакетов, одной настройкой
w "$H/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Adwaita
EOF

# Установщик .deb: скрыт из лаунчера, но открывает .deb по двойному щелчку
w "$H/.local/share/applications/deb-install.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Установщик .deb
Exec=deb-install %f
Terminal=false
NoDisplay=true
MimeType=application/vnd.debian.binary-package;application/x-deb;
EOF

# Приложения по умолчанию (без DE их выбирать некому)
w "$H/.config/mimeapps.list" <<'EOF'
[Default Applications]
application/vnd.debian.binary-package=deb-install.desktop
application/x-deb=deb-install.desktop
inode/directory=pcmanfm.desktop
x-scheme-handler/http=firefox-esr.desktop
x-scheme-handler/https=firefox-esr.desktop
text/html=firefox-esr.desktop
EOF

# Смена обоев: положи картинку в ~/Pictures/wall/wall.png (или wall.jpg) и нажми Super+W
w "$H/.config/hypr/wallpaper.sh" <<'EOF'
#!/bin/sh
f="$(ls "$HOME"/Pictures/wall/wall.* 2>/dev/null | head -n1)"
pkill swaybg 2>/dev/null
if [ -n "$f" ]; then exec swaybg -i "$f" -m fill; else exec swaybg -c 0a0a12; fi
EOF

# Приглашение в терминале: значок, имя, папка (как на скриншотах)
grep -qs 'PS1-hypr' "$H/.bashrc" || cat >> "$H/.bashrc" <<'EOF'
# PS1-hypr
PS1='\[\e[90m\] \[\e[97m\]\u \[\e[90m\] \[\e[37m\]\w \[\e[0m\]\$ '
EOF

# --- Автозапуск Hyprland на первом TTY ---
if ! grep -qs Hyprland "$H/.bash_profile"; then
  cat >> "$H/.bash_profile" <<'EOF'
if [ -z "$WAYLAND_DISPLAY" ] && [ "${XDG_VTNR:-}" = 1 ]; then
  Hyprland || exec bash
fi
EOF
fi

mkdir -p "$H/Pictures/wall" "$H/.local/bin"
chown -R "$U:$U" "$H/.config" "$H/Pictures" "$H/.bash_profile" "$H/.bashrc" \
  "$H/.local" 2>/dev/null || true

echo
echo "Готово. Выйди (exit), зайди заново под $U на TTY1 - Hyprland запустится сам."
echo "Обои: положи картинку в ~/Pictures/wall/wall.png и перезайди."
