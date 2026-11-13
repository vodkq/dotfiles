#!/bin/bash
# install.sh - Arch + Hyprland: минимальная установка, сине-голубая тема
# Запуск: su -   затем   bash install.sh [ИМЯ_ПОЛЬЗОВАТЕЛЯ]
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Запусти от root: su -"; exit 1; }
[ -f /etc/arch-release ] || { echo "Нужен Arch Linux"; exit 1; }
U="${1:-$(getent passwd 1000 | cut -d: -f1 || true)}"
[ -n "$U" ] || { echo "Не нашёл пользователя. Запусти: bash install.sh ИМЯ"; exit 1; }
id "$U" >/dev/null 2>&1 || { echo "Пользователь $U не существует"; exit 1; }
H="/home/$U"
G="$(id -gn "$U")"

# ================= пакеты =================
# multilib нужен только для Steam (32-бит библиотеки)
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
  grep -q '^\[multilib\]' /etc/pacman.conf \
    || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
fi
# Arch - rolling: без полного обновления ставить пакеты нельзя
pacman -Syu --noconfirm --needed sudo
nv="$(pacman -Qq 2>/dev/null | grep -E '^(nvidia|lib32-nvidia|opencl-nvidia|lib32-opencl-nvidia)' || true)"
[ -z "$nv" ] || pacman -Rns --noconfirm $nv || true
pacman -S --noconfirm --needed \
  hyprland hyprland-guiutils xdg-desktop-portal-hyprland xorg-xwayland qt6-wayland \
  kitty waybar wofi swaybg \
  pipewire pipewire-pulse wireplumber \
  brightnessctl grim slurp wl-clipboard \
  ttf-dejavu ttf-font-awesome noto-fonts-emoji papirus-icon-theme adwaita-icon-theme lxqt-policykit ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols \
  python-gobject gtk3 mesa vulkan-intel udisks2 xdg-utils xdg-user-dirs \
  fastfetch cava nano curl \
  firefox firefox-i18n-ru telegram-desktop \
  jre21-openjdk prismlauncher
echo "=== Steam ==="
pacman -S --noconfirm --needed steam lib32-mesa lib32-vulkan-intel \
  || echo "!! Steam не установился (скрипт продолжает работу)"

# ================= sudo =================
usermod -aG wheel,video "$U"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers.d/10-wheel >/dev/null || rm -f /etc/sudoers.d/10-wheel

# ================= системные утилиты =================
cat > /usr/local/bin/pkg-install <<'EOF2'
#!/bin/sh
f="$(readlink -f "$1")"
[ -f "$f" ] || { echo "Файл не найден: $1"; exit 1; }
exec kitty --title "Установка пакета Arch" sh -c '
echo "Устанавливаю: $1"; echo
sudo pacman -U --noconfirm "$1"
echo; printf "Готово. Нажми Enter, чтобы закрыть..."; read _
' sh "$f"
EOF2
chmod 755 /usr/local/bin/pkg-install

cat > /usr/local/bin/launcher.sh <<'EOF'
#!/bin/sh
# повторное нажатие закрывает wofi
if pgrep -x wofi >/dev/null 2>&1; then
  pkill -x wofi
  exit 0
fi
exec wofi --show drun
EOF
chmod 755 /usr/local/bin/launcher.sh

# ---------- файловый менеджер Files ----------
cat > /usr/local/bin/files <<'EOF'
#!/usr/bin/python3
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import threading
import time
from urllib.parse import unquote
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango

HOME = os.path.realpath(os.path.expanduser("~"))
TRASH = os.path.join(HOME, ".local", "share", "Trash")
TRASH_FILES = os.path.join(TRASH, "files")
TRASH_INFO = os.path.join(TRASH, "info")
CONF = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "files")
MARKS = os.path.join(CONF, "bookmarks")
DND = [Gtk.TargetEntry.new("text/uri-list", 0, 0)]
ACT_COPY, ACT_MOVE = Gdk.DragAction.COPY, Gdk.DragAction.MOVE
CSS = b"""
* { font-family: "DejaVu Sans Mono", monospace; font-size: 11px; }
window { background-color: rgba(13,17,27,0.82); color: #cdd6f4; }
window.dialog, window.messagedialog { background-color: rgb(17,22,34); }
.bar { padding: 8px 10px 4px 10px; }
button { background-image: none; background-color: rgba(137,180,250,0.06); color: #cdd6f4;
border: 1px solid rgba(137,180,250,0.25); border-radius: 14px; box-shadow: none;
padding: 2px 10px; min-height: 0; min-width: 0; }
button:hover { background-color: rgba(137,180,250,0.16); }
button:checked { background-color: rgba(137,180,250,0.30); }
entry { background-image: none; background-color: rgba(137,180,250,0.06); color: #cdd6f4;
border: 1px solid rgba(137,180,250,0.25); border-radius: 14px; box-shadow: none;
padding: 2px 12px; min-height: 0; }
entry:focus { border-color: #89b4fa; }
.side { background-color: rgba(137,180,250,0.04); border-right: 1px solid rgba(137,180,250,0.15); }
.side row { padding: 5px 10px; margin: 1px 8px; border-radius: 10px; background: transparent; }
.side row:hover { background-color: rgba(137,180,250,0.10); }
.side row:selected { background-color: rgba(137,180,250,0.25); color: #ffffff; }
.side row:drop(active) { background-color: rgba(137,180,250,0.35); }
.sect { color: #7f8fae; font-size: 9px; padding: 10px 18px 2px 18px; }
treeview.view { background-color: transparent; color: #cdd6f4; }
treeview.view:hover { background-color: rgba(137,180,250,0.08); }
treeview.view:selected { background-color: rgba(137,180,250,0.28); color: #ffffff; }
treeview.view:drop(active) { border: 1px solid rgba(137,180,250,0.80); }
treeview.view.dnd { border: 1px solid rgba(137,180,250,0.80); }
treeview header button { background-color: transparent; border: none; border-radius: 0;
border-bottom: 1px solid rgba(137,180,250,0.18); color: #7f8fae; padding: 3px 8px; }
scrolledwindow, viewport { background-color: transparent; }
scrollbar slider { background-color: rgba(137,180,250,0.35); border-radius: 4px; min-width: 6px; min-height: 6px; }
scrollbar { background: transparent; border: none; }
.status { color: #7f8fae; padding: 3px 14px 6px 14px; }
.err { color: #f38ba8; }
.dim { color: #7f8fae; }
menu, .menu { background-color: rgb(17,22,34); color: #cdd6f4; border: 1px solid rgba(137,180,250,0.30);
border-radius: 8px; padding: 4px; }
menuitem { padding: 4px 10px; border-radius: 6px; }
menuitem:hover { background-color: rgba(137,180,250,0.18); }
separator { background-color: rgba(137,180,250,0.15); min-height: 1px; }
"""
PLACES = [
    ("user-home-symbolic", "Домашняя папка", HOME),
    ("user-desktop-symbolic", "Рабочий стол", os.path.join(HOME, "Desktop")),
    ("folder-documents-symbolic", "Документы", os.path.join(HOME, "Documents")),
    ("folder-download-symbolic", "Загрузки", os.path.join(HOME, "Downloads")),
    ("folder-pictures-symbolic", "Изображения", os.path.join(HOME, "Pictures")),
    ("folder-music-symbolic", "Музыка", os.path.join(HOME, "Music")),
    ("folder-videos-symbolic", "Видео", os.path.join(HOME, "Videos")),
]
SKIP_FS = ("swap", "crypto_LUKS", "LVM2_member", "linux_raid_member")


def human(n):
    units = ("Б", "КБ", "МБ", "ГБ", "ТБ")
    for i, u in enumerate(units):
        if n < 1024 or i == len(units) - 1:
            return f"{n:.0f} {u}" if i == 0 else f"{n:.1f} {u}"
        n /= 1024


def unique(dest_dir, name):
    base, ext = os.path.splitext(name)
    cand, i = name, 1
    while os.path.lexists(os.path.join(dest_dir, cand)):
        cand = f"{base} ({i}){ext}"
        i += 1
    return os.path.join(dest_dir, cand)


def is_real_dir(p):
    return os.path.isdir(p) and not os.path.islink(p)


def in_trash(p):
    return p == TRASH_FILES or p.startswith(TRASH_FILES + os.sep)


def err_text(e):
    return getattr(e, "message", None) or str(e)


def remove_path(p):
    if is_real_dir(p):
        shutil.rmtree(p)
    else:
        os.remove(p)


def drop_trashinfo(src):
    if os.path.dirname(src) == TRASH_FILES:
        try:
            os.remove(os.path.join(TRASH_INFO, os.path.basename(src) + ".trashinfo"))
        except OSError:
            pass


def transfer(paths, dest, move):
    """Копирует или переносит paths в папку dest. Возвращает (сколько сделано, [ошибки])."""
    done, errs = 0, []
    to_trash = in_trash(dest)
    rdest = os.path.realpath(dest)
    for src in paths:
        try:
            if not os.path.lexists(src):
                raise OSError("нет такого файла: " + os.path.basename(src))
            if to_trash:
                if not in_trash(src):
                    Gio.File.new_for_path(src).trash(None)
                    done += 1
                continue
            if move and os.path.realpath(os.path.dirname(src)) == rdest:
                continue
            dst = unique(dest, os.path.basename(src))
            rsrc = os.path.realpath(src)
            if is_real_dir(src) and (rdest + os.sep).startswith(rsrc + os.sep):
                raise OSError("нельзя поместить папку саму в себя")
            if move:
                shutil.move(src, dst)
                drop_trashinfo(src)
            elif is_real_dir(src):
                shutil.copytree(src, dst, symlinks=True)
            else:
                shutil.copy2(src, dst, follow_symlinks=False)
            done += 1
        except Exception as e:
            errs.append(err_text(e))
    return done, errs


def restore(path):
    """Возвращает файл из корзины на прежнее место."""
    if os.path.dirname(path) != TRASH_FILES:
        raise OSError("восстановить можно только то, что лежит в корне корзины")
    info = os.path.join(TRASH_INFO, os.path.basename(path) + ".trashinfo")
    orig = None
    try:
        with open(info, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("Path="):
                    orig = unquote(line[5:].strip())
                    break
    except OSError:
        pass
    if not orig or not os.path.isabs(orig):
        raise OSError("неизвестно, откуда этот файл")
    parent = os.path.dirname(orig)
    os.makedirs(parent, exist_ok=True)
    dst = unique(parent, os.path.basename(orig))
    shutil.move(path, dst)
    try:
        os.remove(info)
    except OSError:
        pass
    return dst


def empty_trash():
    errs = []
    for d in (TRASH_FILES, TRASH_INFO):
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            try:
                remove_path(os.path.join(d, n))
            except Exception as e:
                errs.append(err_text(e))
    return errs


def tree_stats(paths, stop):
    size = files = dirs = 0
    stack = list(paths)
    while stack and not stop.is_set():
        p = stack.pop()
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if stat.S_ISDIR(st.st_mode):
            dirs += 1
            try:
                with os.scandir(p) as it:
                    stack.extend(e.path for e in it)
            except OSError:
                pass
        else:
            files += 1
            size += st.st_size
    return size, files, dirs


def load_marks():
    try:
        with open(MARKS, encoding="utf-8") as f:
            return [ln.strip() for ln in f if ln.strip().startswith("/")]
    except OSError:
        return []


def save_marks(marks):
    try:
        os.makedirs(CONF, exist_ok=True)
        with open(MARKS, "w", encoding="utf-8") as f:
            f.write("".join(m + "\n" for m in marks))
    except OSError:
        pass


def uris_to_paths(data):
    out = []
    for u in data.get_uris() or []:
        p = Gio.File.new_for_uri(u).get_path()
        if p:
            out.append(p)
    return out


def drag_status(ctx, action, t):
    f = getattr(Gdk, "drag_status", None)
    if f is not None:
        f(ctx, action, t)
    else:
        ctx.drag_status(action, t)


def list_devices():
    try:
        out = subprocess.run(["lsblk", "-J", "-o", "NAME,LABEL,SIZE,FSTYPE,MOUNTPOINT,PATH"],
                             capture_output=True, text=True, timeout=5).stdout
        data = json.loads(out)
    except Exception:
        return []
    res = []

    def walk(nodes):
        for n in nodes:
            mp = n.get("mountpoint") or next((m for m in (n.get("mountpoints") or []) if m), None)
            fs = n.get("fstype")
            if fs and fs not in SKIP_FS and (not mp or mp.startswith(("/media", "/run/media", "/mnt"))):
                res.append(dict(path=n.get("path"), label=n.get("label") or n.get("name"),
                                size=n.get("size") or "", fstype=fs, mp=mp))
            walk(n.get("children") or [])
    walk(data.get("blockdevices", []))
    return res


class Item:
    __slots__ = ("name", "path", "isdir", "size", "mtime", "icon")

    def __init__(self, name, path, isdir, size, mtime, icon):
        self.name, self.path, self.isdir, self.size, self.mtime, self.icon = name, path, isdir, size, mtime, icon


class FilesWindow(Gtk.Window):
    def __init__(self, start, select=None):
        super().__init__(title="Files")
        self.set_default_size(1040, 660)
        self.set_decorated(False)
        self.cwd = None
        self.hist, self.fwd = [], []
        self.hidden = False
        self.sort = ("name", False)
        self.clip = ([], False)
        self.devs = []
        self.marks = load_marks()
        self.sizes = {}
        self.drag_paths = []
        self.drag_xy = (0, 0)
        self.scroll_id = 0
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
        self.apply_css(screen)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(root)
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        bar.get_style_context().add_class("bar")
        self.b_back = self.icon_button("go-previous-symbolic", self.go_back)
        self.b_fwd = self.icon_button("go-next-symbolic", self.go_forward)
        self.b_up = self.icon_button("go-up-symbolic", self.go_up)
        self.entry = Gtk.Entry()
        self.entry.set_hexpand(True)
        self.entry.connect("activate", self.on_entry)
        self.b_new = self.icon_button("folder-new-symbolic", lambda *_: self.new_folder())
        self.b_new.set_tooltip_text("Новая папка (Ctrl+Shift+N)")
        self.b_newf = self.icon_button("document-new-symbolic", lambda *_: self.new_file())
        self.b_newf.set_tooltip_text("Новый файл")
        self.b_hidden = Gtk.ToggleButton()
        self.b_hidden.add(Gtk.Image.new_from_icon_name("view-reveal-symbolic", Gtk.IconSize.BUTTON))
        self.b_hidden.set_tooltip_text("Скрытые файлы (Ctrl+H)")
        self.b_hidden.connect("toggled", self.on_hidden_toggled)
        for w in (self.b_back, self.b_fwd, self.b_up):
            bar.pack_start(w, False, False, 0)
        bar.pack_start(self.entry, True, True, 0)
        bar.pack_start(self.b_new, False, False, 0)
        bar.pack_start(self.b_newf, False, False, 0)
        bar.pack_start(self.b_hidden, False, False, 0)
        root.pack_start(bar, False, False, 0)
        paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        root.pack_start(paned, True, True, 0)
        self.side = Gtk.ListBox()
        self.side.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.side.get_style_context().add_class("side")
        self.side.connect("row-activated", self.on_side_activated)
        self.side.connect("button-press-event", self.on_side_click)
        self.side.drag_dest_set(Gtk.DestDefaults.DROP, DND, ACT_COPY | ACT_MOVE)
        self.side.connect("drag-motion", self.on_side_motion)
        self.side.connect("drag-leave", self.on_side_leave)
        self.side.connect("drag-data-received", self.on_side_received)
        side_scroll = Gtk.ScrolledWindow()
        side_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        side_scroll.add(self.side)
        side_scroll.set_size_request(190, -1)
        paned.pack1(side_scroll, False, False)
        self.build_side()
        self.store = Gtk.ListStore(Gio.Icon, str, str, str, bool, str)
        self.view = Gtk.TreeView(model=self.store)
        self.view.set_enable_search(True)
        self.view.set_search_column(1)
        self.view.set_rubber_banding(True)
        self.view.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
        self.view.connect("row-activated", self.on_row_activated)
        self.view.connect("button-press-event", self.on_view_click)
        self.view.enable_model_drag_source(Gdk.ModifierType.BUTTON1_MASK, DND, ACT_COPY | ACT_MOVE)
        self.view.drag_dest_set(Gtk.DestDefaults.DROP, DND, ACT_COPY | ACT_MOVE)
        self.view.connect("drag-begin", self.on_drag_begin)
        self.view.connect("drag-end", self.on_drag_end)
        self.view.connect("drag-data-get", self.on_drag_get)
        self.view.connect("drag-data-delete", self.on_drag_delete)
        self.view.connect("drag-motion", self.on_view_motion)
        self.view.connect("drag-leave", self.on_view_leave)
        self.view.connect("drag-data-received", self.on_view_received)
        self.name_col = Gtk.TreeViewColumn("Имя")
        self.name_col.set_expand(True)
        self.name_col.set_resizable(True)
        pix = Gtk.CellRendererPixbuf()
        pix.set_property("stock-size", int(Gtk.IconSize.LARGE_TOOLBAR))
        pix.set_property("xpad", 6)
        pix.set_property("ypad", 3)
        self.name_r = Gtk.CellRendererText()
        self.name_r.set_property("ellipsize", Pango.EllipsizeMode.END)
        self.name_r.connect("edited", self.on_edited)
        self.name_r.connect("editing-canceled", lambda *_: self.name_r.set_property("editable", False))
        self.name_col.pack_start(pix, False)
        self.name_col.pack_start(self.name_r, True)
        self.name_col.add_attribute(pix, "gicon", 0)
        self.name_col.add_attribute(self.name_r, "text", 1)
        self.name_col.set_clickable(True)
        self.name_col.connect("clicked", self.on_header, "name")
        self.view.append_column(self.name_col)
        self.size_col = self.text_column("Размер", 2, "size")
        self.date_col = self.text_column("Изменён", 3, "date")
        scroll = Gtk.ScrolledWindow()
        scroll.add(self.view)
        paned.pack2(scroll, True, False)
        self.status = Gtk.Label(xalign=0)
        self.status.get_style_context().add_class("status")
        self.status.set_ellipsize(Pango.EllipsizeMode.END)
        root.pack_start(self.status, False, False, 0)
        # подключаем после создания строки статуса
        self.view.get_selection().connect("changed", self.update_status)
        self.connect("key-press-event", self.on_key)
        self.connect("notify::is-active", lambda *_: self.refresh_devices())
        GLib.timeout_add_seconds(20, self.on_timer)
        self.load(start, push=False, select=select)
        self.refresh_devices()
        self.view.grab_focus()

    def apply_css(self, screen):
        for rule in re.findall(rb"[^{}]+\{[^{}]*\}", CSS):
            prov = Gtk.CssProvider()
            try:
                prov.load_from_data(rule)
            except GLib.Error:
                continue
            Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def icon_button(self, icon, cb):
        b = Gtk.Button()
        b.add(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.BUTTON))
        b.connect("clicked", cb)
        return b

    def text_column(self, title, idx, key):
        r = Gtk.CellRendererText()
        r.set_property("xalign", 1.0)
        r.set_property("foreground", "#8fa3c4")
        col = Gtk.TreeViewColumn(title, r, text=idx)
        col.set_min_width(110)
        col.set_clickable(True)
        col.connect("clicked", self.on_header, key)
        self.view.append_column(col)
        return col

    # ---------- боковая панель ----------
    def side_row(self, icon, text, data):
        row = Gtk.ListBoxRow()
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        box.pack_start(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.MENU), False, False, 0)
        lab = Gtk.Label(label=text, xalign=0)
        lab.set_ellipsize(Pango.EllipsizeMode.END)
        box.pack_start(lab, True, True, 0)
        row.add(box)
        row.fm_data = data
        return row

    def side_section(self, text):
        row = Gtk.ListBoxRow()
        row.set_selectable(False)
        row.set_activatable(False)
        lab = Gtk.Label(label=text, xalign=0)
        lab.get_style_context().add_class("sect")
        row.add(lab)
        return row

    def build_side(self):
        for r in self.side.get_children():
            self.side.remove(r)
        self.side.add(self.side_section("МЕСТА"))
        for icon, name, path in PLACES:
            if os.path.isdir(path):
                self.side.add(self.side_row(icon, name, ("dir", path)))
        self.side.add(self.side_row("user-trash-symbolic", "Корзина", ("dir", TRASH_FILES)))
        if self.marks:
            self.side.add(self.side_section("ЗАКЛАДКИ"))
            for p in self.marks:
                self.side.add(self.side_row("folder-symbolic", os.path.basename(p) or p, ("mark", p)))
        if self.devs:
            self.side.add(self.side_section("ДИСКИ"))
            for d in self.devs:
                label = d["label"] + (f"  {d['size']}" if d["size"] else "")
                self.side.add(self.side_row("drive-removable-media-symbolic", label, ("dev", d)))
        self.side.show_all()
        self.sync_side()

    def sync_side(self):
        self.side.unselect_all()
        if not self.cwd:
            return
        for row in self.side.get_children():
            data = getattr(row, "fm_data", None)
            if data and data[0] in ("dir", "mark") and os.path.realpath(data[1]) == self.cwd:
                self.side.select_row(row)
                break

    def refresh_devices(self):
        threading.Thread(target=lambda: GLib.idle_add(self.show_devices, list_devices()), daemon=True).start()

    def on_timer(self):
        if self.is_active():
            self.refresh_devices()
        return True

    def show_devices(self, devs):
        if devs != self.devs:
            self.devs = devs
            self.build_side()
        return False

    def mount_and_open(self, d):
        def work():
            if d["mp"]:
                GLib.idle_add(self.load, d["mp"])
                return
            r = subprocess.run(["udisksctl", "mount", "-b", d["path"]], capture_output=True, text=True)
            m = re.search(r" at (.+?)\.?\s*$", r.stdout.strip())
            if r.returncode == 0 and m:
                GLib.idle_add(self.load, m.group(1))
                GLib.idle_add(self.refresh_devices)
            else:
                GLib.idle_add(self.say, (r.stderr.strip() or "Не удалось подключить").splitlines()[0], True)
        threading.Thread(target=work, daemon=True).start()

    def unmount(self, d):
        def work():
            r = subprocess.run(["udisksctl", "unmount", "-b", d["path"]], capture_output=True, text=True)
            if r.returncode == 0:
                GLib.idle_add(self.say, "Отключено: " + d["label"], False)
                if self.cwd and d["mp"] and self.cwd.startswith(d["mp"]):
                    GLib.idle_add(self.load, HOME)
                GLib.idle_add(self.refresh_devices)
            else:
                GLib.idle_add(self.say, (r.stderr.strip() or "Не удалось отключить").splitlines()[0], True)
        threading.Thread(target=work, daemon=True).start()

    def on_side_activated(self, box, row):
        data = getattr(row, "fm_data", None)
        if not data:
            return
        kind, val = data
        if kind == "dev":
            self.mount_and_open(val)
            return
        if val == TRASH_FILES:
            os.makedirs(val, exist_ok=True)
        if os.path.isdir(val):
            self.load(val)
        else:
            self.say("Папка недоступна: " + val, True)

    def on_side_click(self, box, ev):
        if ev.button != 3:
            return False
        row = box.get_row_at_y(int(ev.y))
        data = getattr(row, "fm_data", None) if row else None
        if not data:
            return False
        kind, val = data
        menu = Gtk.Menu()

        def add(label, cb):
            it = Gtk.MenuItem(label=label)
            it.connect("activate", lambda *_: cb())
            menu.append(it)
        if kind == "dev":
            if val["mp"]:
                add("Отключить", lambda: self.unmount(val))
            else:
                add("Подключить", lambda: self.mount_and_open(val))
        elif kind == "mark":
            add("Убрать из закладок", lambda: self.toggle_mark(val))
        elif val == TRASH_FILES:
            add("Очистить корзину", self.empty_trash_ask)
        else:
            return False
        menu.show_all()
        menu.popup_at_pointer(ev)
        return True

    # ---------- перетаскивание ----------
    def on_drag_begin(self, view, ctx):
        self.drag_paths = self.selected_paths()

    def on_drag_end(self, view, ctx):
        self.drag_paths = []
        self.stop_scroll()
        view.set_drag_dest_row(None, Gtk.TreeViewDropPosition.BEFORE)

    def on_drag_get(self, view, ctx, data, info, t):
        paths = self.drag_paths or self.selected_paths()
        data.set_uris([Gio.File.new_for_path(p).get_uri() for p in paths])

    def on_drag_delete(self, view, ctx):
        # файлы переносим сами, строки из списка удалять не нужно
        view.stop_emission_by_name("drag-data-delete")

    def copy_wanted(self):
        if not self.drag_paths:
            return True
        try:
            seat = Gdk.Display.get_default().get_default_seat()
            _, _, _, mask = self.get_window().get_device_position(seat.get_pointer())
            return bool(mask & Gdk.ModifierType.CONTROL_MASK)
        except Exception:
            return False

    def can_drop(self, dest, copy):
        if not dest:
            return False
        paths = self.drag_paths
        if in_trash(dest):
            return bool(paths) and not all(in_trash(p) for p in paths)
        if not os.access(dest, os.W_OK | os.X_OK):
            return False
        rd = os.path.realpath(dest)
        for p in paths:
            rp = os.path.realpath(p)
            if rd == rp or rd.startswith(rp + os.sep):
                return False
        if paths and not copy and all(os.path.realpath(os.path.dirname(p)) == rd for p in paths):
            return False
        return True

    def pick_action(self, ctx, copy):
        want = ACT_COPY if copy else ACT_MOVE
        if ctx.get_actions() & want:
            return want
        return ctx.get_suggested_action() & (ACT_COPY | ACT_MOVE)

    def view_dest(self, view, x, y):
        hit = view.get_dest_row_at_pos(x, y)
        if hit:
            path = hit[0]
            row = self.store[path]
            if row[4] and row[5] not in self.drag_paths:
                return row[5], path
        return self.cwd, None

    def on_view_motion(self, view, ctx, x, y, t):
        dest, path = self.view_dest(view, x, y)
        copy = self.copy_wanted()
        ok = self.can_drop(dest, copy)
        view.set_drag_dest_row(path if ok else None, Gtk.TreeViewDropPosition.INTO_OR_AFTER)
        drag_status(ctx, self.pick_action(ctx, copy) if ok else 0, t)
        self.drag_xy = (x, y)
        self.start_scroll()
        return True

    def on_view_leave(self, view, ctx, t):
        view.set_drag_dest_row(None, Gtk.TreeViewDropPosition.BEFORE)
        self.stop_scroll()

    def on_view_received(self, view, ctx, x, y, data, info, t):
        view.set_drag_dest_row(None, Gtk.TreeViewDropPosition.BEFORE)
        self.stop_scroll()
        dest, _ = self.view_dest(view, x, y)
        self.do_drop(uris_to_paths(data), dest, ctx.get_selected_action())

    def side_dest(self, y):
        row = self.side.get_row_at_y(int(y))
        data = getattr(row, "fm_data", None) if row else None
        if not data:
            return None, None
        kind, val = data
        if kind == "dev":
            return (val["mp"], row) if val["mp"] else (None, None)
        if val == TRASH_FILES or os.path.isdir(val):
            return val, row
        return None, None

    def on_side_motion(self, box, ctx, x, y, t):
        dest, row = self.side_dest(y)
        copy = self.copy_wanted()
        ok = self.can_drop(dest, copy)
        if ok and row:
            box.drag_highlight_row(row)
        else:
            box.drag_unhighlight_row()
        drag_status(ctx, self.pick_action(ctx, copy) if ok else 0, t)
        return True

    def on_side_leave(self, box, ctx, t):
        box.drag_unhighlight_row()

    def on_side_received(self, box, ctx, x, y, data, info, t):
        box.drag_unhighlight_row()
        dest, _ = self.side_dest(y)
        self.do_drop(uris_to_paths(data), dest, ctx.get_selected_action())

    def do_drop(self, paths, dest, action):
        if not paths or not dest:
            return
        copy = bool(action & ACT_COPY)
        if not self.can_drop(dest, copy) and self.drag_paths:
            return
        if not in_trash(dest) and not os.access(dest, os.W_OK | os.X_OK):
            self.say("Нет прав на запись: " + dest, True)
            return
        self.run_transfer(paths, dest, not copy)

    def start_scroll(self):
        if not self.scroll_id:
            self.scroll_id = GLib.timeout_add(60, self.autoscroll)

    def stop_scroll(self):
        if self.scroll_id:
            GLib.source_remove(self.scroll_id)
            self.scroll_id = 0

    def autoscroll(self):
        adj = self.view.get_vadjustment()
        y = self.drag_xy[1]
        h = self.view.get_allocated_height()
        step = -18 if y < 45 else (18 if y > h - 35 else 0)
        if step:
            top = max(adj.get_lower(), adj.get_upper() - adj.get_page_size())
            adj.set_value(max(adj.get_lower(), min(top, adj.get_value() + step)))
        return True

    # ---------- чтение папки ----------
    def say(self, text, err=False):
        ctx = self.status.get_style_context()
        if err:
            ctx.add_class("err")
        else:
            ctx.remove_class("err")
        self.status.set_text(text)
        return False

    def read_dir(self, path):
        attrs = ("standard::name,standard::type,standard::size,standard::symbolic-icon,"
                 "standard::icon,time::modified")
        items = []
        en = Gio.File.new_for_path(path).enumerate_children(attrs, Gio.FileQueryInfoFlags.NONE, None)
        while True:
            info = en.next_file(None)
            if info is None:
                break
            name = info.get_name()
            if not self.hidden and name.startswith("."):
                continue
            icon = info.get_symbolic_icon() or info.get_icon()
            items.append(Item(name, os.path.join(path, name),
                              info.get_file_type() == Gio.FileType.DIRECTORY,
                              info.get_size(), info.get_attribute_uint64("time::modified"), icon))
        en.close(None)
        return items

    def sort_items(self, items):
        key, rev = self.sort
        if key == "size":
            kf = lambda i: (i.size, i.name.lower())
        elif key == "date":
            kf = lambda i: (i.mtime, i.name.lower())
        else:
            kf = lambda i: i.name.lower()
        dirs = sorted([i for i in items if i.isdir], key=kf, reverse=rev)
        files = sorted([i for i in items if not i.isdir], key=kf, reverse=rev)
        return dirs + files

    def load(self, path, push=True, select=None):
        path = os.path.realpath(os.path.expanduser(path))
        try:
            items = self.read_dir(path)
        except GLib.Error as e:
            self.say(f"Нет доступа: {path} ({e.message})", True)
            return False
        if push and self.cwd and self.cwd != path:
            self.hist.append(self.cwd)
            self.fwd = []
        self.cwd = path
        self.sizes = {i.path: i.size for i in items if not i.isdir}
        self.store.clear()
        for it in self.sort_items(items):
            self.store.append([it.icon, it.name, "" if it.isdir else human(it.size),
                               time.strftime("%d.%m.%Y %H:%M", time.localtime(it.mtime)), it.isdir, it.path])
        shown = path.replace(HOME, "~", 1) if path.startswith(HOME) else path
        self.entry.set_text(shown)
        self.set_title(os.path.basename(path) or "/")
        self.b_back.set_sensitive(bool(self.hist))
        self.b_fwd.set_sensitive(bool(self.fwd))
        self.b_up.set_sensitive(path != "/")
        self.sync_side()
        if select:
            self.select_name(select)
        self.update_status()
        self.view.grab_focus()
        return False

    def reload(self, select=None):
        self.load(self.cwd, push=False, select=select)

    def select_name(self, name):
        for row in self.store:
            if row[1] == name:
                sel = self.view.get_selection()
                sel.unselect_all()
                sel.select_path(row.path)
                self.view.scroll_to_cell(row.path, None, False, 0, 0)
                self.view.set_cursor(row.path)
                return

    def update_status(self, *_):
        rows = self.selected_rows()
        total = len(self.store)
        if rows:
            total_size = sum(int(self.sizes.get(self.store[r][5], 0)) for r in rows)
            text = f"Выбрано: {len(rows)} из {total}"
            if total_size:
                text += f"  ·  {human(total_size)}"
            self.say(text)
        else:
            self.say(f"{total} элементов" if total else "Папка пуста")

    def go_back(self, *_):
        if self.hist:
            self.fwd.append(self.cwd)
            self.load(self.hist.pop(), push=False)

    def go_forward(self, *_):
        if self.fwd:
            self.hist.append(self.cwd)
            self.load(self.fwd.pop(), push=False)

    def go_up(self, *_):
        parent = os.path.dirname(self.cwd)
        if parent != self.cwd:
            self.load(parent, select=os.path.basename(self.cwd))

    def on_entry(self, entry):
        p = os.path.expanduser(entry.get_text().strip())
        if os.path.isdir(p):
            self.load(p)
        elif os.path.exists(p):
            self.load(os.path.dirname(p), select=os.path.basename(p))
        else:
            self.say("Нет такого пути: " + p, True)
        self.view.grab_focus()

    def on_hidden_toggled(self, btn):
        self.hidden = btn.get_active()
        self.reload()

    def on_header(self, col, key):
        k, rev = self.sort
        self.sort = (key, (not rev) if k == key else False)
        for c, kk in ((self.name_col, "name"), (self.size_col, "size"), (self.date_col, "date")):
            c.set_sort_indicator(kk == self.sort[0])
            c.set_sort_order(Gtk.SortType.DESCENDING if self.sort[1] else Gtk.SortType.ASCENDING)
        self.reload()

    def on_row_activated(self, view, path, col):
        row = self.store[path]
        if row[4]:
            self.load(row[5])
        else:
            self.open_path(row[5])

    def open_path(self, path):
        if path.lower().endswith((".pkg.tar.zst", ".pkg.tar.xz")) and shutil.which("pkg-install"):
            subprocess.Popen(["pkg-install", path], start_new_session=True)
            self.say("Устанавливаю: " + os.path.basename(path))
            return
        ok = False
        try:
            ok = Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(path).get_uri(), None)
        except GLib.Error:
            ok = False
        if ok:
            return
        ctype, _ = Gio.content_type_guess(path, None)
        try:
            if Gio.content_type_is_a(ctype, "text/plain") and shutil.which("nano"):
                subprocess.Popen(["kitty", "nano", path], start_new_session=True)
            else:
                subprocess.Popen(["firefox", path], start_new_session=True)
        except Exception as e:
            self.say(f"Нечем открыть ({ctype}): {e}", True)

    # ---------- операции с файлами ----------
    def selected_rows(self):
        _, rows = self.view.get_selection().get_selected_rows()
        return rows

    def selected_paths(self):
        return [self.store[r][5] for r in self.selected_rows()]

    def confirm(self, text):
        dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                buttons=Gtk.ButtonsType.YES_NO, text=text)
        resp = dlg.run()
        dlg.destroy()
        return resp == Gtk.ResponseType.YES

    def copy(self, cut=False):
        paths = self.selected_paths()
        if paths:
            self.clip = (paths, cut)
            self.say(("Вырезано: " if cut else "Скопировано: ") + str(len(paths)))

    def paste(self):
        paths, cut = self.clip
        if not paths:
            self.say("Буфер пуст")
        elif in_trash(self.cwd):
            self.say("В корзину удаляют клавишей Delete", True)
        else:
            self.run_transfer(paths, self.cwd, cut, clear_clip=cut)

    def run_transfer(self, paths, dest, move, clear_clip=False):
        self.say("Перемещаю…" if move else "Копирую…")

        def work():
            done, errs = transfer(paths, dest, move)
            GLib.idle_add(self.after_transfer, done, move, errs, clear_clip)
        threading.Thread(target=work, daemon=True).start()

    def after_transfer(self, done, move, errs, clear_clip):
        if clear_clip:
            self.clip = ([], False)
        self.reload()
        if errs:
            self.say("Ошибка: " + errs[0] + (f"  (и ещё {len(errs) - 1})" if len(errs) > 1 else ""), True)
        elif done:
            self.say(("Перемещено: " if move else "Скопировано: ") + str(done))
        return False

    def trash(self, force=False):
        paths = self.selected_paths()
        if not paths:
            return
        perm = force or in_trash(self.cwd)
        if perm and not self.confirm(f"Удалить навсегда ({len(paths)})?"):
            return
        errs = []
        for p in paths:
            try:
                if perm:
                    remove_path(p)
                    drop_trashinfo(p)
                else:
                    Gio.File.new_for_path(p).trash(None)
            except Exception as e:
                errs.append(err_text(e))
        self.reload()
        if errs:
            self.say("Ошибка: " + errs[0], True)

    def restore_selected(self):
        n, errs = 0, []
        for p in self.selected_paths():
            try:
                restore(p)
                n += 1
            except Exception as e:
                errs.append(err_text(e))
        self.reload()
        if errs:
            self.say("Ошибка: " + errs[0], True)
        elif n:
            self.say("Восстановлено: " + str(n))

    def empty_trash_ask(self):
        if not self.confirm("Очистить корзину насовсем?"):
            return

        def work():
            errs = empty_trash()
            GLib.idle_add(self.after_empty, errs)
        self.say("Чищу корзину…")
        threading.Thread(target=work, daemon=True).start()

    def after_empty(self, errs):
        if self.cwd and in_trash(self.cwd):
            self.reload()
        self.say("Ошибка: " + errs[0] if errs else "Корзина пуста", bool(errs))
        return False

    def start_rename(self):
        rows = self.selected_rows()
        if len(rows) != 1 or in_trash(self.cwd):
            return
        self.name_r.set_property("editable", True)
        self.view.set_cursor(rows[0], self.name_col, True)

    def on_edited(self, renderer, path, text):
        renderer.set_property("editable", False)
        old = self.store[path][1]
        text = text.strip()
        if not text or text == old or "/" in text:
            return
        new = os.path.join(self.cwd, text)
        if os.path.lexists(new) and text.lower() != old.lower():
            self.say("Уже есть такое имя: " + text, True)
            return
        try:
            os.rename(os.path.join(self.cwd, old), new)
        except OSError as e:
            self.say("Ошибка: " + e.strerror, True)
            return
        self.reload(select=text)

    def new_folder(self):
        if in_trash(self.cwd):
            return
        path = unique(self.cwd, "Новая папка")
        try:
            os.mkdir(path)
        except OSError as e:
            self.say("Ошибка: " + e.strerror, True)
            return
        self.reload(select=os.path.basename(path))
        self.start_rename()

    def new_file(self):
        if in_trash(self.cwd):
            return
        path = unique(self.cwd, "Новый файл.txt")
        try:
            open(path, "x").close()
        except OSError as e:
            self.say("Ошибка: " + e.strerror, True)
            return
        self.reload(select=os.path.basename(path))
        self.start_rename()

    def copy_path(self):
        text = "\n".join(self.selected_paths() or [self.cwd])
        try:
            subprocess.run(["wl-copy"], input=text.encode(), check=True, timeout=3)
        except Exception:
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(text, -1)
        self.say("Путь скопирован")

    def open_terminal(self, path=None):
        path = path if path and os.path.isdir(path) else self.cwd
        try:
            subprocess.Popen(["kitty", "--directory", path], start_new_session=True)
        except OSError as e:
            self.say("Не запустился kitty: " + str(e), True)

    def toggle_mark(self, path):
        path = os.path.realpath(path)
        if path in self.marks:
            self.marks.remove(path)
        else:
            self.marks.append(path)
        save_marks(self.marks)
        self.build_side()

    def select_all(self):
        self.view.get_selection().select_all()

    def properties(self):
        paths = self.selected_paths() or [self.cwd]
        dlg = Gtk.Dialog(title="Свойства", transient_for=self, modal=True)
        dlg.add_button("Закрыть", Gtk.ResponseType.CLOSE)
        grid = Gtk.Grid(column_spacing=16, row_spacing=6, margin=16)
        dlg.get_content_area().add(grid)
        state = {"row": 0}

        def add(title, text):
            k = Gtk.Label(label=title, xalign=0)
            k.get_style_context().add_class("dim")
            v = Gtk.Label(label=text, xalign=0)
            v.set_selectable(True)
            v.set_line_wrap(True)
            v.set_max_width_chars(48)
            grid.attach(k, 0, state["row"], 1, 1)
            grid.attach(v, 1, state["row"], 1, 1)
            state["row"] += 1
            return v
        if len(paths) == 1:
            p = paths[0]
            try:
                st = os.lstat(p)
            except OSError as e:
                dlg.destroy()
                self.say("Ошибка: " + (e.strerror or str(e)), True)
                return
            add("Имя", os.path.basename(p) or "/")
            if stat.S_ISLNK(st.st_mode):
                kind = "Ссылка → " + os.readlink(p)
            elif stat.S_ISDIR(st.st_mode):
                kind = "Папка"
            else:
                ctype, _ = Gio.content_type_guess(p, None)
                kind = Gio.content_type_get_description(ctype) or ctype
            add("Тип", kind)
            add("Где", os.path.dirname(p) or "/")
            add("Изменён", time.strftime("%d.%m.%Y %H:%M:%S", time.localtime(st.st_mtime)))
            try:
                owner = pwd.getpwuid(st.st_uid).pw_name
            except KeyError:
                owner = str(st.st_uid)
            add("Права", f"{stat.filemode(st.st_mode)}   {owner}")
        else:
            add("Выбрано", f"{len(paths)} объектов")
        size_lbl = add("Размер", "считаю…")
        stop = threading.Event()
        top_dirs = sum(1 for p in paths if is_real_dir(p))

        def work():
            size, files, dirs = tree_stats(paths, stop)
            if stop.is_set():
                return
            text = human(size)
            if top_dirs or files > len(paths):
                text += f"   ·   файлов: {files}, папок: {max(dirs - top_dirs, 0)}"
            GLib.idle_add(size_lbl.set_text, text)
        threading.Thread(target=work, daemon=True).start()
        dlg.show_all()
        dlg.run()
        stop.set()
        dlg.destroy()

    # ---------- мышь и клавиши ----------
    def on_view_click(self, view, ev):
        if ev.button == 1 and ev.type == Gdk.EventType.BUTTON_PRESS:
            # рамка выделения - только с пустого места, иначе строку можно тащить
            view.set_rubber_banding(view.get_path_at_pos(int(ev.x), int(ev.y)) is None)
            return False
        if ev.button != 3:
            return False
        hit = view.get_path_at_pos(int(ev.x), int(ev.y))
        sel = view.get_selection()
        if hit:
            if not sel.path_is_selected(hit[0]):
                sel.unselect_all()
                sel.select_path(hit[0])
        else:
            sel.unselect_all()
        menu = Gtk.Menu()

        def add(label, cb, enabled=True):
            it = Gtk.MenuItem(label=label)
            it.set_sensitive(enabled)
            it.connect("activate", lambda *_: cb())
            menu.append(it)

        def sep():
            menu.append(Gtk.SeparatorMenuItem())
        rows = self.selected_rows()
        has, one = bool(rows), len(rows) == 1
        one_dir = one and self.store[rows[0]][4]
        one_path = self.store[rows[0]][5] if one else None
        in_tr = in_trash(self.cwd)
        if one:
            add("Открыть", lambda: self.on_row_activated(view, self.selected_rows()[0], None))
        if one_dir:
            add("Открыть в терминале", lambda: self.open_terminal(one_path))
            marked = os.path.realpath(one_path) in self.marks
            add("Убрать из закладок" if marked else "Добавить в закладки", lambda: self.toggle_mark(one_path))
        if one:
            sep()
        add("Копировать", lambda: self.copy(False), has)
        add("Вырезать", lambda: self.copy(True), has)
        add("Вставить", self.paste, bool(self.clip[0]) and not in_tr)
        sep()
        if in_tr:
            add("Восстановить", self.restore_selected, has)
            add("Удалить навсегда", self.trash, has)
            add("Очистить корзину", self.empty_trash_ask)
        else:
            add("Переименовать", self.start_rename, one)
            add("В корзину", self.trash, has)
            add("Удалить навсегда", lambda: self.trash(True), has)
        sep()
        add("Копировать путь", self.copy_path)
        if not in_tr:
            add("Новая папка", self.new_folder)
            add("Новый файл", self.new_file)
        sep()
        add("Выделить всё", self.select_all)
        add("Терминал здесь", self.open_terminal)
        add("Свойства", self.properties)
        menu.show_all()
        menu.popup_at_pointer(ev)
        return True

    def on_key(self, win, ev):
        key = Gdk.keyval_name(ev.keyval)
        ctrl = bool(ev.state & Gdk.ModifierType.CONTROL_MASK)
        shift = bool(ev.state & Gdk.ModifierType.SHIFT_MASK)
        alt = bool(ev.state & Gdk.ModifierType.MOD1_MASK)
        typing = isinstance(self.get_focus(), Gtk.Entry)
        if ctrl and key in ("q", "Q", "w", "W"):
            self.destroy()
            return True
        if ctrl and key in ("l", "L"):
            self.entry.grab_focus()
            return True
        if key == "Escape" and typing:
            self.view.grab_focus()
            return True
        if typing:
            return False
        if alt and key == "Left":
            self.go_back()
        elif alt and key == "Right":
            self.go_forward()
        elif alt and key in ("Return", "KP_Enter"):
            self.properties()
        elif (alt and key == "Up") or key == "BackSpace":
            self.go_up()
        elif key == "F5":
            self.reload()
        elif key == "F2":
            self.start_rename()
        elif key == "F4":
            self.open_terminal()
        elif key == "Delete":
            self.trash(shift)
        elif ctrl and shift and key in ("n", "N"):
            self.new_folder()
        elif ctrl and key in ("a", "A"):
            self.select_all()
        elif ctrl and key in ("d", "D"):
            self.toggle_mark(self.cwd)
        elif ctrl and key in ("c", "C"):
            self.copy(False)
        elif ctrl and key in ("x", "X"):
            self.copy(True)
        elif ctrl and key in ("v", "V"):
            self.paste()
        elif ctrl and key in ("h", "H"):
            self.b_hidden.set_active(not self.b_hidden.get_active())
        else:
            return False
        return True


def main():
    GLib.set_prgname("files")
    GLib.set_application_name("Files")
    start, select = HOME, None
    if len(sys.argv) > 1:
        p = os.path.abspath(os.path.expanduser(sys.argv[1]))
        if os.path.isdir(p):
            start = p
        elif os.path.exists(p):
            start, select = os.path.dirname(p), os.path.basename(p)
    win = FilesWindow(start, select)
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
EOF
chmod 755 /usr/local/bin/files

# ---------- меню питания ----------
cat > /usr/local/bin/power-menu <<'EOF'
#!/usr/bin/python3
import os
import re
import subprocess
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk

LOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "power-menu.pid")
CSS = b"""
* { font-family: "DejaVu Sans Mono", "FontAwesome", monospace; }
window { background-color: rgba(5,8,14,0.60); }
.card { background-color: rgba(13,17,27,0.85); border: 1px solid rgba(137,180,250,0.45);
border-radius: 20px; padding: 22px 24px 14px 24px; }
button { background-image: none; background-color: rgba(137,180,250,0.06); color: #cdd6f4;
border: 1px solid rgba(137,180,250,0.25); border-radius: 16px; box-shadow: none; padding: 0; }
button:hover, button:focus { background-color: rgba(137,180,250,0.18); border-color: #89b4fa; }
button.danger { color: #f38ba8; border-color: rgba(243,139,168,0.45); }
button.danger:hover, button.danger:focus { background-color: rgba(243,139,168,0.20); border-color: #f38ba8; }
.icon { font-size: 30px; }
.name { font-size: 11px; }
.key { color: #7f8fae; font-size: 9px; }
.hint { color: #6b7a96; font-size: 9px; }
"""

ITEMS = (
    ("\uf011", "Выключить", "P", "poweroff", True),
    ("\uf021", "Перезагрузить", "R", "reboot", False),
    ("\uf186", "Сон", "S", "suspend", False),
    ("\uf08b", "Выйти", "E", "exit", False),
)


def running():
    try:
        with open(LOCK) as f:
            pid = int(f.read().strip())
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return pid if b"power-menu" in f.read() else 0
    except Exception:
        return 0


def drop_lock():
    try:
        os.remove(LOCK)
    except OSError:
        pass


def logout():
    # сначала обычная команда Hyprland, потом вариант для Lua-конфига, в конце - через logind
    for args in (["hyprctl", "dispatch", "exit"], ["hyprctl", "dispatch", "hl.dsp.exit()"]):
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=3)
            if r.returncode == 0 and r.stdout.strip().lower().startswith("ok"):
                return
        except Exception:
            pass
    sid = os.environ.get("XDG_SESSION_ID")
    try:
        if sid:
            subprocess.Popen(["loginctl", "terminate-session", sid], start_new_session=True)
        else:
            subprocess.Popen(["loginctl", "terminate-user", os.environ.get("USER", "")], start_new_session=True)
    except Exception:
        pass


class PowerMenu(Gtk.Window):
    def __init__(self):
        super().__init__(title="power-menu")
        self.set_decorated(False)
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
        for rule in re.findall(rb"[^{}]+\{[^{}]*\}", CSS):
            prov = Gtk.CssProvider()
            try:
                prov.load_from_data(rule)
            except GLib.Error:
                continue
            Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        bg = Gtk.EventBox()
        bg.set_visible_window(False)
        bg.connect("button-press-event", lambda w, e: self.quit())
        hold = Gtk.EventBox()
        hold.set_visible_window(False)
        hold.set_halign(Gtk.Align.CENTER)
        hold.set_valign(Gtk.Align.CENTER)
        hold.connect("button-press-event", lambda w, e: True)
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        card.get_style_context().add_class("card")
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        self.buttons = []
        self.keys = {}
        for icon, name, key, cmd, danger in ITEMS:
            b = Gtk.Button()
            b.set_size_request(132, 112)
            if danger:
                b.get_style_context().add_class("danger")
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            col.set_valign(Gtk.Align.CENTER)
            for text, cls in ((icon, "icon"), (name, "name"), (key, "key")):
                lab = Gtk.Label(label=text)
                lab.get_style_context().add_class(cls)
                col.pack_start(lab, False, False, 0)
            b.add(col)
            b.connect("clicked", lambda w, c=cmd: self.run(c))
            row.pack_start(b, False, False, 0)
            self.buttons.append(b)
            self.keys[key.lower()] = cmd
        hint = Gtk.Label(label="← →  выбор    Enter  подтвердить    Esc  закрыть")
        hint.get_style_context().add_class("hint")
        card.pack_start(row, False, False, 0)
        card.pack_start(hint, False, False, 0)
        hold.add(card)
        bg.add(hold)
        self.add(bg)
        self.connect("key-press-event", self.on_key)
        self.fullscreen()

    def focus_step(self, d):
        cur = self.get_focus()
        i = self.buttons.index(cur) if cur in self.buttons else -1
        self.buttons[(i + d) % len(self.buttons)].grab_focus()

    def on_key(self, w, ev):
        k = Gdk.keyval_name(ev.keyval) or ""
        if k == "Escape":
            self.quit()
        elif k in ("Left", "Up", "ISO_Left_Tab"):
            self.focus_step(-1)
        elif k in ("Right", "Down", "Tab"):
            self.focus_step(1)
        elif k.lower() in self.keys:
            self.run(self.keys[k.lower()])
        else:
            return False
        return True

    def run(self, cmd):
        self.hide()
        if cmd == "exit":
            logout()
        else:
            subprocess.Popen(["systemctl", cmd], start_new_session=True)
        self.quit()

    def quit(self):
        self.destroy()


def on_destroy(*_):
    drop_lock()
    Gtk.main_quit()


def main():
    GLib.set_prgname("power-menu")
    GLib.set_application_name("power-menu")
    pid = running()
    if pid:
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        drop_lock()
        return
    w = PowerMenu()
    w.connect("destroy", on_destroy)
    w.show_all()
    try:
        with open(LOCK, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    w.buttons[0].grab_focus()
    Gtk.main()


if __name__ == "__main__":
    main()
EOF
chmod 755 /usr/local/bin/power-menu

# ================= конфиги пользователя =================
# w ФАЙЛ - записать stdin в файл (старую версию один раз сохраняет в .bak)
w() {
  mkdir -p "$(dirname "$1")"
  if [ -f "$1" ] && [ ! -f "$1.bak" ]; then cp -p "$1" "$1.bak"; fi
  cat > "$1"
}
rm -f "$H/.config/hypr/quick-kill.sh"
[ ! -f "$H/.config/hypr/hyprland.conf" ] || mv "$H/.config/hypr/hyprland.conf" "$H/.config/hypr/hyprland.conf.old"

# ---------- Hyprland ----------
w "$H/.config/hypr/hyprland.lua" <<'EOF'
local mod = "SUPER"

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

hl.on("hyprland.start", function()
  hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
  hl.exec_cmd("sh ~/.config/hypr/wallpaper.sh")
  hl.exec_cmd("waybar")
  hl.exec_cmd("lxqt-policykit-agent")
end)

hl.config({
  input = {
    kb_layout = "us,ru",
    kb_options = "grp:alt_shift_toggle",
    follow_mouse = 1,
    repeat_rate = 40,
    repeat_delay = 250,
    touchpad = { natural_scroll = true },
  },
  general = {
    gaps_in = 6,       -- между окнами
    gaps_out = 14,     -- от краёв экрана до окон
    border_size = 1,
    col = {
      active_border = "rgba(89b4faee)",
      inactive_border = "rgba(3a4a66aa)",
    },
    layout = "dwindle",
  },
  dwindle = {
    preserve_split = true,  -- раскладка не «прыгает» при закрытии окон
    force_split = 2,        -- новое окно встаёт справа/снизу, экран делится пополам
  },
  decoration = {
    rounding = 8,
    active_opacity = 1.0,
    inactive_opacity = 0.95,
    blur = { enabled = true, size = 6, passes = 3 },
  },
  animations = { enabled = true },
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    new_window_takes_over_fullscreen = 2,  -- новое окно не прячется за полноэкранным
  },
})

hl.curve("ease", { type = "bezier", points = { {0.22, 1}, {0.36, 1} } })
hl.animation({ leaf = "windows",    enabled = true, speed = 5, bezier = "ease", style = "slide" })
hl.animation({ leaf = "fade",       enabled = true, speed = 5, bezier = "ease" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 5, bezier = "ease", style = "slide" })

hl.bind(mod .. " + Return", hl.dsp.exec_cmd("kitty sh ~/.config/fastfetch/show.sh"))
hl.bind(mod .. " + D", hl.dsp.exec_cmd("/usr/local/bin/launcher.sh"))
hl.bind(mod .. " + B", hl.dsp.exec_cmd("firefox"))
hl.bind(mod .. " + E", hl.dsp.exec_cmd("/usr/local/bin/files"))
hl.bind(mod .. " + W", hl.dsp.exec_cmd("sh ~/.config/hypr/wallpaper.sh next"))
hl.bind(mod .. " + Q", hl.dsp.window.close())
hl.bind(mod .. " + SHIFT + Q", hl.dsp.window.close(), { repeating = true })
hl.bind(mod .. " + SHIFT + Escape", hl.dsp.exec_cmd("/usr/local/bin/power-menu"))
hl.bind(mod .. " + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind(mod .. " + V", hl.dsp.window.float({ action = "toggle" }))

for _, d in ipairs({ "left", "right", "up", "down" }) do
  hl.bind(mod .. " + " .. d, hl.dsp.focus({ direction = d }))
  hl.bind(mod .. " + SHIFT + " .. d, hl.dsp.window.move({ direction = d }))
end

hl.bind(mod .. " + CTRL + left",  hl.dsp.window.resize({ x = -40, y = 0,  relative = true }), { repeating = true })
hl.bind(mod .. " + CTRL + right", hl.dsp.window.resize({ x = 40,  y = 0,  relative = true }), { repeating = true })
hl.bind(mod .. " + CTRL + up",    hl.dsp.window.resize({ x = 0,   y = -40, relative = true }), { repeating = true })
hl.bind(mod .. " + CTRL + down",  hl.dsp.window.resize({ x = 0,   y = 40,  relative = true }), { repeating = true })

hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

for i = 1, 5 do
  hl.bind(mod .. " + " .. i, hl.dsp.focus({ workspace = i }))
  hl.bind(mod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end

hl.bind(mod .. " + Tab", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mod .. " + Space", hl.dsp.exec_cmd("hyprctl switchxkblayout all next"))
hl.bind(mod .. " + SHIFT + S", hl.dsp.exec_cmd('grim -g "$(slurp)" - | wl-copy'))

hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true })
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl set 5%+"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 5%-"), { locked = true, repeating = true })

hl.window_rule({ name = "float-wofi", match = { class = "^(wofi)$" }, float = true })
hl.window_rule({ name = "tile-kitty", match = { class = "^(kitty)$" }, tile = true })
hl.window_rule({ name = "float-power-menu", match = { class = "^(power-menu)$" }, float = true })
EOF

# ---------- kitty ----------
w "$H/.config/kitty/kitty.conf" <<'EOF'
font_family DejaVu Sans Mono
font_size 11
symbol_map U+F000-U+F8FF FontAwesome
background_opacity 0.78
window_padding_width 10
confirm_os_window_close 0
foreground #cdd6f4
background #0d111b
cursor #89b4fa
selection_foreground #0d111b
selection_background #89b4fa
color0  #1b2333
color8  #4a5878
color1  #f38ba8
color9  #f5a3b9
color2  #94e2d5
color10 #a6ece1
color3  #b4c8f0
color11 #c9d8f5
color4  #89b4fa
color12 #a3c4fb
color5  #b4befe
color13 #c6cdfe
color6  #74c7ec
color14 #93d5f1
color7  #bac2de
color15 #e6ecf8
EOF

# ---------- cava (запуск только из терминала: cava) ----------
w "$H/.config/cava/config" <<'EOF'
[general]
bar_width = 2
bar_spacing = 1

[color]
gradient = 1
gradient_count = 4
gradient_color_1 = '#1e3354'
gradient_color_2 = '#3f6aa8'
gradient_color_3 = '#89b4fa'
gradient_color_4 = '#a6e3f5'
EOF

# ---------- waybar: одна тонкая полоса сверху ----------
w "$H/.config/waybar/config.jsonc" <<'EOF'
{
  "layer": "top", "height": 26, "spacing": 2,
  "margin-top": 8, "margin-left": 14, "margin-right": 14,
  "modules-left": ["custom/launcher", "custom/files", "custom/term", "hyprland/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["tray", "hyprland/language", "network", "pulseaudio", "pulseaudio#mic", "backlight", "battery", "custom/power"],
  "custom/launcher": { "format": "\uf002", "tooltip": false, "on-click": "/usr/local/bin/launcher.sh" },
  "custom/files":    { "format": "\uf07b", "tooltip": false, "on-click": "/usr/local/bin/files" },
  "custom/term":     { "format": "\uf120", "tooltip": false, "on-click": "kitty" },
  "custom/power":    { "format": "\uf011", "tooltip": false, "on-click": "/usr/local/bin/power-menu" },
  "hyprland/workspaces": { "format": "{id}", "persistent-workspaces": { "*": 5 } },
  "hyprland/language": { "format": "{short}" },
  "tray": { "icon-size": 14, "spacing": 6 },
  "clock": { "format": "{:%H:%M}", "tooltip-format": "{:%A, %d %B %Y}" },
  "network": {
    "format-wifi": "\uf1eb",
    "format-ethernet": "\uf6ff",
    "format-disconnected": "\uf127",
    "tooltip-format": "{essid} {ipaddr}"
  },
  "pulseaudio": {
    "format": "\uf028 {volume}%",
    "format-muted": "\uf6a9",
    "on-click": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
  },
  "pulseaudio#mic": {
    "format": "{format_source}",
    "format-source": "\uf130",
    "format-source-muted": "\uf131",
    "on-click": "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
  },
  "backlight": { "format": "\uf185 {percent}%" },
  "battery": {
    "format": "{icon} {capacity}%",
    "format-icons": ["\uf244", "\uf243", "\uf242", "\uf241", "\uf240"],
    "states": { "warning": 25, "critical": 10 }
  }
}
EOF

w "$H/.config/waybar/style.css" <<'EOF'
* { font-family: "DejaVu Sans Mono", "FontAwesome"; font-size: 11px; border: none; border-radius: 0; min-height: 0; }
window#waybar {
  background: rgba(13,17,27,0.82);
  color: #cdd6f4;
  border: 1px solid rgba(137,180,250,0.35);
  border-radius: 10px;
}
tooltip { background: rgba(13,17,27,0.95); border: 1px solid rgba(137,180,250,0.40); border-radius: 8px; }
tooltip label { color: #cdd6f4; }
#clock, #network, #pulseaudio, #backlight, #battery, #language, #tray { padding: 0 7px; }
#custom-launcher, #custom-files, #custom-term { color: #89b4fa; padding: 0 7px; }
#custom-launcher { margin-left: 4px; }
#custom-power { color: #f38ba8; padding: 0 10px 0 7px; }
#clock { color: #b4d0ff; font-weight: bold; }
#language { color: #74c7ec; }
#pulseaudio.muted, #pulseaudio.source-muted { color: #5c6b8a; }
#backlight { color: #a6c8ff; }
#workspaces { margin-left: 6px; }
#workspaces button {
  color: #7f8fae; background: rgba(137,180,250,0.10);
  padding: 0; margin: 4px 2px; min-width: 16px; border-radius: 9px;
  box-shadow: none; text-shadow: none;
}
#workspaces button:hover { background: rgba(137,180,250,0.30); color: #e6ecf8; }
#workspaces button.active { background: #89b4fa; color: #0d111b; min-width: 28px; }
#battery.warning { color: #f9e2af; }
#battery.critical { color: #f38ba8; }
EOF

# ---------- wofi ----------
w "$H/.config/wofi/config" <<'EOF'
width=520
height=330
prompt=Поиск...
allow_images=true
image_size=20
insensitive=true
hide_on_select=true
EOF
w "$H/.config/wofi/style.css" <<'EOF'
window { background-color: rgba(13,17,27,0.88); border: 1px solid rgba(137,180,250,0.40); border-radius: 10px; font-family: "DejaVu Sans Mono"; font-size: 12px; }
#input { background: rgba(137,180,250,0.08); color: #cdd6f4; border: 1px solid rgba(137,180,250,0.25); border-radius: 8px; margin: 6px; }
#entry { padding: 4px 8px; border-radius: 6px; }
#entry:selected { background-color: rgba(137,180,250,0.25); }
#text { color: #cdd6f4; margin-left: 6px; }
EOF

# ---------- GTK, fastfetch, обои ----------
w "$H/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Papirus-Dark
EOF

# Картинка для fastfetch: положи PNG в ~/.config/fastfetch/logo.png (лучше 512x512)
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

w "$H/.config/hypr/wallpaper.sh" <<'EOF'
#!/bin/sh
# Обои: положи картинки в ~/Pictures/wall, Super+W - следующая
D="$HOME/Pictures/wall"; C="$HOME/.cache/wallpaper"
list="$(ls "$D"/*.png "$D"/*.jpg "$D"/*.jpeg "$D"/*.webp 2>/dev/null)"
pkill swaybg 2>/dev/null
[ -n "$list" ] || exec swaybg -c 0d111b
cur="$(cat "$C" 2>/dev/null)"
if [ "$1" = next ]; then
  f="$(printf '%s\n' "$list" | awk -v c="$cur" 'f{print;exit} $0==c{f=1}')"
  [ -n "$f" ] || f="$(printf '%s\n' "$list" | head -n1)"
else
  f="$cur"; [ -f "$f" ] || f="$(printf '%s\n' "$list" | head -n1)"
fi
mkdir -p "$(dirname "$C")"; printf '%s\n' "$f" > "$C"
exec swaybg -i "$f" -m fill
EOF

# ---------- ярлыки и программы по умолчанию ----------
w "$H/.local/share/applications/cava.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=cava
Exec=cava
NoDisplay=true
EOF
w "$H/.local/share/applications/files.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Files
Exec=/usr/local/bin/files %f
Icon=system-file-manager
Terminal=false
Categories=System;FileManager;
MimeType=inode/directory;
StartupWMClass=files
EOF
w "$H/.local/share/applications/pkg-install.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Установщик пакетов Arch
Exec=/usr/local/bin/pkg-install %f
Terminal=false
NoDisplay=true
MimeType=application/x-zstd-compressed-tar;
EOF
w "$H/.config/mimeapps.list" <<'EOF'
[Default Applications]
inode/directory=files.desktop
image/png=firefox.desktop
image/jpeg=firefox.desktop
image/gif=firefox.desktop
image/webp=firefox.desktop
image/svg+xml=firefox.desktop
application/pdf=firefox.desktop
video/mp4=firefox.desktop
video/webm=firefox.desktop
audio/mpeg=firefox.desktop
audio/ogg=firefox.desktop
audio/flac=firefox.desktop
audio/x-wav=firefox.desktop
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
text/html=firefox.desktop
EOF

# ---------- bash ----------
grep -qF '38;5;111m' "$H/.bashrc" 2>/dev/null || cat >> "$H/.bashrc" <<'EOF'
PS1='\[\e[38;5;111m\]\u \[\e[38;5;67m\]\w \[\e[0m\]\$ '
EOF
# автозапуск Hyprland на TTY1
if ! grep -qsi 'hyprland' "$H/.bash_profile"; then
  [ -f "$H/.bash_profile" ] || echo '[ -f ~/.bashrc ] && . ~/.bashrc' > "$H/.bash_profile"
  cat >> "$H/.bash_profile" <<'EOF'
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = 1 ]; then
  start-hyprland || exec bash
fi
EOF
fi
mkdir -p "$H/Pictures/wall"

# реальное имя Font Awesome (иконки в waybar, kitty, меню питания)
FA="$(fc-list : family 2>/dev/null | grep -o 'Font Awesome [0-9]* Free' | head -n1 || true)"
FA="${FA:-Font Awesome 7 Free} Solid"
sed -i "s/FontAwesome/$FA/g" /usr/local/bin/power-menu \
  "$H/.config/kitty/kitty.conf" "$H/.config/waybar/style.css"

chown -R "$U:$G" "$H/.config" "$H/.local" "$H/Pictures" "$H/.bashrc" "$H/.bash_profile" 2>/dev/null || true
runuser -u "$U" -- env HOME="$H" xdg-user-dirs-update 2>/dev/null || true

# ================= сторонние приложения =================
# fetch URL ФАЙЛ [sums] - скачать; с "sums" сверить SHA256 по SHA256SUMS.txt из того же релиза
fetch() {
  curl -fL --retry 3 -o "$2" "$1" || { rm -f "$2"; return 1; }
  [ "${3:-}" = sums ] || return 0
  local want have
  want="$(curl -fsSL "${1%/*}/SHA256SUMS.txt" 2>/dev/null | grep -F "${1##*/}" | awk '{print $1}' | head -n1 || true)"
  have="$(sha256sum "$2" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$have" ] || { echo "!! контрольная сумма не подтверждена: ${1##*/}"; rm -f "$2"; return 1; }
}
# gh_asset РЕПО РЕГУЛЯРКА [?per_page=30] - ссылка на файл из последнего релиза на GitHub
gh_asset() {
  curl -fsSL "https://api.github.com/repos/$1/releases${3:-/latest}" 2>/dev/null \
    | grep -o 'https://[^"]*' | grep -E "$2" | head -n1 || true
}
# install_pkg ССЫЛКА ИМЯ [sums] - готовый .pkg.tar.zst
install_pkg() {
  local f="/tmp/$2.pkg.tar.zst"
  if ! fetch "$1" "$f" "${3:-}"; then
    echo "!! $2 не скачался ($1)."
    echo "!! Скачай .pkg.tar.zst вручную и открой его двойным щелчком в Files (Super+E)."
    return 0
  fi
  pacman -U --noconfirm "$f" || echo "!! $2 не установился (скрипт продолжает работу)"
  rm -f "$f"
}
# install_appimage ССЫЛКА КОМАНДА НАЗВАНИЕ КАТЕГОРИИ [sums]
install_appimage() {
  local url="$1" bin="$2" title="$3" cats="$4" P="/opt/$2" run icon src
  if [ ! -x "$P/squashfs-root/AppRun" ]; then
    mkdir -p "$P"; rm -rf "$P/squashfs-root"
    if fetch "$url" "$P/app.AppImage" "${5:-}"; then
      chmod 755 "$P/app.AppImage"
      ( cd "$P" && ./app.AppImage --appimage-extract >/dev/null 2>&1 && rm -f app.AppImage ) || true
    fi
  fi
  chmod -R a+rX "$P" 2>/dev/null || true
  [ ! -f "$P/squashfs-root/chrome-sandbox" ] || { chown root:root "$P/squashfs-root/chrome-sandbox"; chmod 4755 "$P/squashfs-root/chrome-sandbox"; }
  if [ -x "$P/squashfs-root/AppRun" ]; then run="$P/squashfs-root/AppRun"
  elif [ -x "$P/app.AppImage" ]; then run="$P/app.AppImage --appimage-extract-and-run"
  else echo "!! $title не поставился: нет доступа к сайту/GitHub. Включи VPN (Happ) и запусти install.sh ещё раз."; return 0; fi
  printf '#!/bin/sh\n%sexec %s "$@"\n' "${APPENV:-}" "$run" > "/usr/local/bin/$bin"
  chmod 755 "/usr/local/bin/$bin"
  # иконка: сначала .DirIcon (официальная иконка AppImage), потом из usr/share/icons, потом любая png в корне
  src=""
  if [ -f "$P/squashfs-root/.DirIcon" ] && [ "$(head -c 4 "$P/squashfs-root/.DirIcon" 2>/dev/null | tail -c 3)" = PNG ]; then
    src="$P/squashfs-root/.DirIcon"
  fi
  [ -n "$src" ] || src="$(find "$P/squashfs-root/usr/share/icons" -name '*.png' 2>/dev/null | sort -V | tail -n1 || true)"
  [ -n "$src" ] || src="$(find "$P/squashfs-root" -maxdepth 1 -name '*.png' 2>/dev/null | head -n1 || true)"
  icon=application-x-executable
  if [ -n "$src" ] && [ -f "$src" ]; then
    install -Dm644 "$src" "/usr/share/icons/hicolor/256x256/apps/$bin.png"
    icon="$bin"
  fi
  cat > "/usr/share/applications/$bin.desktop" <<DESK_EOF
[Desktop Entry]
Type=Application
Name=$title
Exec=$bin
Icon=$icon
Terminal=false
Categories=$cats
DESK_EOF
  echo "ok: $title"
}
install_photocraft() {
  local u
  u="$(gh_asset storytold/photocraft 'x86_64.*\.pkg\.tar\.zst$')"
  if [ -n "$u" ]; then install_pkg "$u" photocraft sums; return 0; fi
  u="$(gh_asset storytold/photocraft 'x86_64.*\.AppImage$')"
  if [ -n "$u" ]; then install_appimage "$u" photocraft PhotoCraft "Graphics;" sums; return 0; fi
  echo "!! PhotoCraft: не нашёл сборку. Скачай её (Linux x86_64) со страницы"
  echo "!! https://github.com/storytold/photocraft/releases"
}
install_limusic() {
  local u
  u="$(gh_asset SimoHypers/limusic '(x86_64|amd64).*\.AppImage$')"
  if [ -n "$u" ]; then APPENV='export WEBKIT_DISABLE_DMABUF_RENDERER=1
' install_appimage "$u" limusic Limusic "AudioVideo;Audio;Player;"
  else echo "!! Limusic: не нашёл AppImage на https://github.com/SimoHypers/limusic/releases"; fi
}
install_opencode() {
  local u
  u="$(gh_asset anomalyco/opencode 'opencode-desktop-linux-(x86_64|amd64|x64)\.AppImage$' '?per_page=30')"
  if [ -n "$u" ]; then install_appimage "$u" opencode OpenCode "Development;"
  else echo "!! OpenCode: не нашёл AppImage на https://github.com/anomalyco/opencode/releases"; fi
}
install_pkg https://github.com/Happ-proxy/happ-desktop/releases/latest/download/Happ.linux.x64.pkg.tar.zst happ
install_photocraft
install_appimage https://download.onlyoffice.com/install/desktop/editors/linux/DesktopEditors-x86_64.AppImage onlyoffice "ONLYOFFICE" "Office;"
install_limusic
install_opencode
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true

# ================= wofi: в лаунчере только твои приложения =================
allow="$( { for p in steam telegram-desktop prismlauncher happ firefox photocraft; do pacman -Ql "$p" 2>/dev/null; done \
  | awk '{print $2}' | grep '^/usr/share/applications/.*\.desktop$' | while read -r f; do basename "$f"; done
  printf '%s\n' onlyoffice.desktop photocraft.desktop limusic.desktop opencode.desktop; } )"
mkdir -p "$H/.local/share/applications"
for f in /usr/share/applications/*.desktop; do
  [ -e "$f" ] || continue
  b="${f##*/}"; t="$H/.local/share/applications/$b"
  if printf '%s\n' "$allow" | grep -qxF "$b"; then
    { [ ! -f "$t" ] || ! grep -q '^# hidden-by-install' "$t"; } || rm -f "$t"
    continue
  fi
  { [ ! -e "$t" ] || grep -q '^# hidden-by-install' "$t"; } || continue
  { echo '# hidden-by-install'
    awk '/^NoDisplay=/{next} {print} !d && /^\[Desktop Entry\]/{print "NoDisplay=true"; d=1}' "$f"; } > "$t"
done
chown -R "$U:$G" "$H/.local" 2>/dev/null || true
rm -f "$H/.cache/wofi-drun"

# ================= чистка =================
echo "=== Чистка мусора ==="
orph="$(pacman -Qdtq 2>/dev/null || true)"
[ -z "$orph" ] || pacman -Rns --noconfirm $orph || true
pacman -Sc --noconfirm >/dev/null 2>&1 || true
journalctl --vacuum-size=50M >/dev/null 2>&1 || true
rm -f /tmp/*.pkg.tar.zst
rm -rf "$H/.cache/thumbnails"

echo
echo "Готово. ПЕРЕЗАГРУЗИСЬ (reboot). После входа на TTY1 Hyprland запустится сам."
echo "NVIDIA: драйверы удалены - система работает на встройке (Intel)."
echo "Обои: положи картинки в ~/Pictures/wall (светлые аниме-обои дадут вид как на фото)."
echo "Визуализатор: открой терминал и набери  cava"
echo
echo "Горячие клавиши:"
echo "  Super+Enter       - терминал с fastfetch"
echo "  Super+D           - лаунчер (повторное нажатие закрывает)"
echo "  Super+E           - файлы"
echo "  Super+B           - Firefox"
echo "  Super+W           - следующие обои"
echo "  Super+V           - окно: плавающее / тайлинг"
echo "  Super+F           - полный экран"
echo "  Super+Shift+Esc   - меню питания (повторное нажатие закрывает)"
echo "  Super+Q           - закрыть окно"
echo "  Super+Shift+Q     - зажми и води курсором: окна под ним закрываются подряд"
echo "  Super+Shift+S     - скриншот области в буфер"
