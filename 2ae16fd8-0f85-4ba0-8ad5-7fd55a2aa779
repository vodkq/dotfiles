#!/bin/bash
# Hyprland на чистом Debian 13 (trixie): минимум пакетов + стиль как на скриншотах.
# Запуск от root:  su -   затем   bash install.sh
set -euo pipefail

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
  fonts-jetbrains-mono polkitd lxqt-policykit \
  fastfetch cava \
  firefox-esr firefox-esr-l10n-ru
usermod -aG sudo,video "$U"

# --- Конфиги (старые сохраняются как .bak) ---
w() {
  mkdir -p "$(dirname "$1")"
  if [ -f "$1" ]; then cp -f "$1" "$1.bak"; fi
  cat > "$1"
}

w "$H/.config/hypr/hyprland.conf" <<'EOF'
monitor = , preferred, auto, 1
$mod = SUPER

# Обои: ~/Pictures/wall/wall.png, если файла нет - тёмный фон
exec-once = sh -c 'if [ -f ~/Pictures/wall/wall.png ]; then swaybg -i ~/Pictures/wall/wall.png -m fill; else swaybg -c 0a0a12; fi'
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
    animation = windows, 1, 4, default, slide
    animation = workspaces, 1, 4, default, slide
}

misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}

# --- Программы ---
bind = $mod, Return, exec, kitty sh ~/.config/fastfetch/show.sh
bind = $mod, D, exec, wofi --show drun
bind = $mod, B, exec, firefox-esr

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
font_family JetBrains Mono
font_size 10
background_opacity 0.55
window_padding_width 10
background #0a0a12
foreground #d0d0d6
cursor #ffffff
confirm_os_window_close 0
EOF

w "$H/.config/waybar/config.jsonc" <<'EOF'
{
  "layer": "top", "height": 26, "margin-top": 6, "margin-left": 8, "margin-right": 8,
  "modules-left": ["hyprland/workspaces", "hyprland/window"],
  "modules-center": ["hyprland/language", "clock", "cpu", "memory", "temperature"],
  "modules-right": ["network", "pulseaudio", "battery"],

  "hyprland/workspaces": { "format": "{id}", "persistent-workspaces": { "*": 5 } },
  "hyprland/window": { "max-length": 30 },
  "hyprland/language": { "format": "{short}" },
  "clock": { "format": "{:%H:%M}", "tooltip-format": "{:%d %B %Y}" },
  "cpu": { "format": "CPU {usage}%" },
  "memory": { "format": "RAM {used:0.1f}G" },
  "temperature": { "format": "{temperatureC}°C" },
  "network": { "format-wifi": "WiFi {signalStrength}%", "format-ethernet": "ETH", "format-disconnected": "offline" },
  "pulseaudio": { "format": "VOL {volume}%", "format-muted": "MUTE", "on-click": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle" },
  "battery": { "format": "BAT {capacity}%" }
}
EOF

w "$H/.config/waybar/style.css" <<'EOF'
* { font-family: "JetBrains Mono"; font-size: 11px; border: none; min-height: 0; }
window#waybar { background: transparent; color: #d0d0d6; }
.modules-left, .modules-center, .modules-right {
  background: rgba(10,10,18,0.65);
  border: 1px solid rgba(255,255,255,0.12);
  border-radius: 10px; padding: 0 8px;
}
#workspaces button { color: #777780; background: transparent; padding: 0 7px; }
#workspaces button.active { color: #ffffff; background: rgba(255,255,255,0.18); border-radius: 8px; }
#window, #language, #clock, #cpu, #memory, #temperature, #network, #pulseaudio, #battery { padding: 0 8px; }
EOF

w "$H/.config/wofi/config" <<'EOF'
width=520
height=330
prompt=Search...
allow_images=false
insensitive=true
EOF

w "$H/.config/wofi/style.css" <<'EOF'
window { background-color: rgba(10,10,18,0.85); border: 1px solid rgba(255,255,255,0.25); border-radius: 6px; font-family: "JetBrains Mono"; font-size: 12px; }
#input { background: transparent; color: #d0d0d6; border: none; margin: 4px; }
#entry { padding: 4px 8px; }
#entry:selected { background-color: rgba(110,140,255,0.4); }
#text { color: #d0d0d6; }
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

# --- Автозапуск Hyprland на первом TTY ---
grep -qs Hyprland "$H/.bash_profile" || \
  echo '[ -z "$WAYLAND_DISPLAY" ] && [ "$XDG_VTNR" = 1 ] && exec Hyprland' >> "$H/.bash_profile"

mkdir -p "$H/Pictures/wall"
chown -R "$U:$U" "$H/.config" "$H/Pictures" "$H/.bash_profile" "$H/.local/share/applications"

echo
echo "Готово. Выйди (exit), зайди заново под $U на TTY1 - Hyprland запустится сам."
echo "Обои: положи картинку в ~/Pictures/wall/wall.png и перезайди."
