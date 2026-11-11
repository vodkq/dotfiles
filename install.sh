#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "Запусти от root: su -"; exit 1; }
. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || { echo "Нужен Debian 13 (trixie)"; exit 1; }
U="${1:-$(getent passwd 1000 | cut -d: -f1 || true)}"
[ -n "$U" ] || { echo "Не нашёл пользователя. Запусти: bash install.sh ИМЯ"; exit 1; }
id "$U" >/dev/null 2>&1 || { echo "Пользователь $U не существует"; exit 1; }
H="/home/$U"
echo "deb http://deb.debian.org/debian trixie-backports main" > /etc/apt/sources.list.d/backports.list
echo "deb http://deb.debian.org/debian trixie contrib non-free non-free-firmware" > /etc/apt/sources.list.d/extra.list
dpkg --add-architecture i386
apt-get update
apt-get install -y --no-install-recommends sudo
if dpkg -l 'nvidia-*' 2>/dev/null | grep '^ii' >/dev/null; then
apt-get purge -y 'nvidia-*' || true
apt-get autoremove -y --purge || true
fi
apt-get install -y --no-install-recommends -t trixie-backports \
hyprland hyprland-guiutils xdg-desktop-portal-hyprland \
kitty waybar wofi swaybg \
pipewire pipewire-pulse wireplumber \
brightnessctl grim slurp wl-clipboard \
fonts-dejavu-core fonts-font-awesome polkitd lxqt-policykit \
fastfetch cava python3-gi gir1.2-gtk-3.0 mesa-vulkan-drivers \
dbus-user-session xdg-utils xwayland \
adwaita-icon-theme udisks2 \
firefox-esr firefox-esr-l10n-ru \
telegram-desktop curl \
vlc python3-pyqt6 python3-vlc yt-dlp qt6-wayland
echo
echo "=== Steam: запускается установщик. Если появится окно с лицензией - прими её (I AGREE). ==="
if ( exec </dev/tty ) 2>/dev/null; then
DEBIAN_FRONTEND=dialog apt-get install -y --no-install-recommends -t trixie-backports \
steam-installer mesa-vulkan-drivers:i386 libgl1-mesa-dri:i386 </dev/tty \
|| echo "!! Steam не установился (скрипт продолжает работу)"
else
echo "-- нет терминала для вопросов, ставлю Steam без диалога"
apt-get install -y --no-install-recommends -t trixie-backports \
steam-installer mesa-vulkan-drivers:i386 libgl1-mesa-dri:i386 \
|| echo "!! Steam не установился (скрипт продолжает работу)"
fi
echo "=== Этап Steam завершён, продолжаю установку. ==="
usermod -aG sudo,video "$U"
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
cat > /usr/local/bin/launcher.sh <<'EOF'
#!/bin/sh
pkill wofi 2>/dev/null
sleep 0.1
exec wofi --show drun
EOF
chmod 755 /usr/local/bin/launcher.sh
cat > /usr/local/bin/files <<'EOF'
#!/usr/bin/env python3
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango

HOME = os.path.expanduser("~")
TRASH = os.path.join(HOME, ".local", "share", "Trash")
CSS = b"""
* { font-family: "DejaVu Sans Mono", monospace; font-size: 11px; }
window { background-color: rgba(16,16,18,0.80); color: #e6e6e6; }
.bar { padding: 8px 10px 4px 10px; }
button { background-image: none; background-color: rgba(255,255,255,0.06); color: #e6e6e6;
border: 1px solid rgba(255,255,255,0.28); border-radius: 14px; box-shadow: none;
padding: 2px 10px; min-height: 0; min-width: 0; }
button:hover { background-color: rgba(255,255,255,0.16); }
button:checked { background-color: rgba(255,255,255,0.28); }
entry { background-image: none; background-color: rgba(255,255,255,0.06); color: #e6e6e6;
border: 1px solid rgba(255,255,255,0.28); border-radius: 14px; box-shadow: none;
padding: 2px 12px; min-height: 0; }
entry:focus { border-color: rgba(255,255,255,0.65); }
.side { background-color: rgba(255,255,255,0.04); border-right: 1px solid rgba(255,255,255,0.12); }
.side row { padding: 5px 10px; margin: 1px 8px; border-radius: 10px; background: transparent; }
.side row:hover { background-color: rgba(255,255,255,0.08); }
.side row:selected { background-color: rgba(255,255,255,0.20); color: #ffffff; }
.sect { color: #8a8a8a; font-size: 9px; padding: 10px 18px 2px 18px; }
treeview.view { background-color: transparent; color: #e6e6e6; }
treeview.view:hover { background-color: rgba(255,255,255,0.07); }
treeview.view:selected { background-color: rgba(255,255,255,0.22); color: #ffffff; }
treeview header button { background-color: transparent; border: none; border-radius: 0;
border-bottom: 1px solid rgba(255,255,255,0.15); color: #8a8a8a; padding: 3px 8px; }
scrolledwindow, viewport { background-color: transparent; }
scrollbar slider { background-color: rgba(255,255,255,0.30); border-radius: 4px; min-width: 6px; min-height: 6px; }
scrollbar { background: transparent; border: none; }
.status { color: #8a8a8a; padding: 3px 14px 6px 14px; }
.err { color: #ff8a80; }
menu, .menu { background-color: rgb(24,24,28); color: #e6e6e6; border: 1px solid rgba(255,255,255,0.25);
border-radius: 8px; padding: 4px; }
menuitem { padding: 4px 10px; border-radius: 6px; }
menuitem:hover { background-color: rgba(255,255,255,0.15); }
separator { background-color: rgba(255,255,255,0.12); min-height: 1px; }
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
            if fs and fs not in ("swap", "crypto_LUKS") and (not mp or mp.startswith(("/media", "/run/media", "/mnt"))):
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
        self.dev_rows = []
        self.sizes = {}
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
            self.set_app_paintable(True)
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
        self.b_hidden = Gtk.ToggleButton()
        self.b_hidden.add(Gtk.Image.new_from_icon_name("view-reveal-symbolic", Gtk.IconSize.BUTTON))
        self.b_hidden.set_tooltip_text("Скрытые файлы (Ctrl+H)")
        self.b_hidden.connect("toggled", self.on_hidden_toggled)
        for w in (self.b_back, self.b_fwd, self.b_up):
            bar.pack_start(w, False, False, 0)
        bar.pack_start(self.entry, True, True, 0)
        bar.pack_start(self.b_new, False, False, 0)
        bar.pack_start(self.b_hidden, False, False, 0)
        root.pack_start(bar, False, False, 0)
        paned = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        root.pack_start(paned, True, True, 0)
        self.side = Gtk.ListBox()
        self.side.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.side.get_style_context().add_class("side")
        self.side.connect("row-activated", self.on_side_activated)
        self.side.connect("button-press-event", self.on_side_click)
        side_scroll = Gtk.ScrolledWindow()
        side_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        side_scroll.add(self.side)
        side_scroll.set_size_request(190, -1)
        paned.pack1(side_scroll, False, False)
        self.build_places()
        self.store = Gtk.ListStore(Gio.Icon, str, str, str, bool, str)
        self.view = Gtk.TreeView(model=self.store)
        self.view.set_enable_search(True)
        self.view.set_search_column(1)
        self.view.set_rubber_banding(True)
        self.view.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
        self.view.connect("row-activated", self.on_row_activated)
        self.view.connect("button-press-event", self.on_view_click)
        self.view.get_selection().connect("changed", self.update_status)
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
        r.set_property("foreground", "#9a9a9a")
        col = Gtk.TreeViewColumn(title, r, text=idx)
        col.set_min_width(110)
        col.set_clickable(True)
        col.connect("clicked", self.on_header, key)
        self.view.append_column(col)
        return col

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

    def build_places(self):
        self.side.add(self.side_section("МЕСТА"))
        for icon, name, path in PLACES:
            if os.path.isdir(path):
                self.side.add(self.side_row(icon, name, ("dir", path)))
        self.side.add(self.side_row("user-trash-symbolic", "Корзина", ("dir", os.path.join(TRASH, "files"))))
        self.dev_head = self.side_section("ДИСКИ")
        self.head_added = False

    def refresh_devices(self):
        threading.Thread(target=lambda: GLib.idle_add(self.show_devices, list_devices()), daemon=True).start()

    def on_timer(self):
        if self.is_active():
            self.refresh_devices()
        return True

    def show_devices(self, devs):
        for r in self.dev_rows:
            self.side.remove(r)
        self.dev_rows = []
        if devs and not self.head_added:
            self.side.add(self.dev_head)
            self.dev_head.show_all()
            self.head_added = True
        elif not devs and self.head_added:
            self.side.remove(self.dev_head)
            self.head_added = False
        for d in devs:
            label = d["label"] + (f"  {d['size']}" if d["size"] else "")
            row = self.side_row("drive-removable-media-symbolic", label, ("dev", d))
            self.side.add(row)
            row.show_all()
            self.dev_rows.append(row)
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
        if kind == "dir":
            if val.startswith(TRASH):
                os.makedirs(val, exist_ok=True)
            self.load(val)
        else:
            self.mount_and_open(val)

    def on_side_click(self, box, ev):
        if ev.button != 3:
            return False
        row = box.get_row_at_y(int(ev.y))
        data = getattr(row, "fm_data", None) if row else None
        if not data or data[0] != "dev":
            return False
        d = data[1]
        menu = Gtk.Menu()
        if d["mp"]:
            it = Gtk.MenuItem(label="Отключить")
            it.connect("activate", lambda *_: self.unmount(d))
        else:
            it = Gtk.MenuItem(label="Подключить")
            it.connect("activate", lambda *_: self.mount_and_open(d))
        menu.append(it)
        menu.show_all()
        menu.popup_at_pointer(ev)
        return True

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
        self.side.unselect_all()
        for row in self.side.get_children():
            data = getattr(row, "fm_data", None)
            if data and data[0] == "dir" and data[1] == path:
                self.side.select_row(row)
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
        if path.lower().endswith(".deb") and shutil.which("deb-install"):
            subprocess.Popen(["deb-install", path], start_new_session=True)
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
                subprocess.Popen(["firefox-esr", path], start_new_session=True)
        except Exception as e:
            self.say(f"Нечем открыть ({ctype}): {e}", True)

    def selected_rows(self):
        _, rows = self.view.get_selection().get_selected_rows()
        return rows

    def selected_paths(self):
        return [self.store[r][5] for r in self.selected_rows()]

    def copy(self, cut=False):
        paths = self.selected_paths()
        if paths:
            self.clip = (paths, cut)
            self.say(("Вырезано: " if cut else "Скопировано: ") + str(len(paths)))

    def paste(self):
        paths, cut = self.clip
        if not paths:
            self.say("Буфер пуст")
            return
        dest = self.cwd
        def work():
            errs = []
            for src in paths:
                try:
                    dst = unique(dest, os.path.basename(src))
                    if os.path.isdir(src) and (dst + os.sep).startswith(src + os.sep):
                        raise OSError("нельзя вставить папку саму в себя")
                    if cut:
                        shutil.move(src, dst)
                    elif os.path.isdir(src):
                        shutil.copytree(src, dst, symlinks=True)
                    else:
                        shutil.copy2(src, dst)
                except Exception as e:
                    errs.append(str(e))
            GLib.idle_add(self.after_paste, cut, errs)
        self.say("Копирую…")
        threading.Thread(target=work, daemon=True).start()

    def after_paste(self, cut, errs):
        if cut:
            self.clip = ([], False)
        self.reload()
        if errs:
            self.say("Ошибка: " + errs[0], True)
        return False

    def trash(self):
        paths = self.selected_paths()
        if not paths:
            return
        in_trash = self.cwd.startswith(os.path.join(TRASH, "files"))
        if in_trash:
            dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                    buttons=Gtk.ButtonsType.YES_NO,
                                    text=f"Удалить навсегда ({len(paths)})?")
            resp = dlg.run()
            dlg.destroy()
            if resp != Gtk.ResponseType.YES:
                return
        errs = []
        for p in paths:
            try:
                if in_trash:
                    if os.path.isdir(p) and not os.path.islink(p):
                        shutil.rmtree(p)
                    else:
                        os.remove(p)
                    info = os.path.join(TRASH, "info", os.path.basename(p) + ".trashinfo")
                    if os.path.exists(info):
                        os.remove(info)
                else:
                    Gio.File.new_for_path(p).trash(None)
            except Exception as e:
                errs.append(getattr(e, "message", str(e)))
        self.reload()
        if errs:
            self.say("Ошибка: " + errs[0], True)

    def start_rename(self):
        rows = self.selected_rows()
        if len(rows) != 1:
            return
        self.name_r.set_property("editable", True)
        self.view.set_cursor(rows[0], self.name_col, True)

    def on_edited(self, renderer, path, text):
        renderer.set_property("editable", False)
        old = self.store[path][1]
        text = text.strip()
        if not text or text == old or "/" in text:
            return
        try:
            os.rename(os.path.join(self.cwd, old), os.path.join(self.cwd, text))
        except OSError as e:
            self.say("Ошибка: " + e.strerror, True)
            return
        self.reload(select=text)

    def new_folder(self):
        path = unique(self.cwd, "Новая папка")
        try:
            os.mkdir(path)
        except OSError as e:
            self.say("Ошибка: " + e.strerror, True)
            return
        self.reload(select=os.path.basename(path))
        self.start_rename()

    def on_view_click(self, view, ev):
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
        has = bool(self.selected_rows())
        one = len(self.selected_rows()) == 1
        if one:
            add("Открыть", lambda: self.on_row_activated(view, self.selected_rows()[0], None))
            menu.append(Gtk.SeparatorMenuItem())
        add("Копировать", lambda: self.copy(False), has)
        add("Вырезать", lambda: self.copy(True), has)
        add("Вставить", self.paste, bool(self.clip[0]))
        menu.append(Gtk.SeparatorMenuItem())
        add("Переименовать", self.start_rename, one)
        add("В корзину", self.trash, has)
        menu.append(Gtk.SeparatorMenuItem())
        add("Новая папка", self.new_folder)
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
        elif (alt and key == "Up") or key == "BackSpace":
            self.go_up()
        elif key == "F5":
            self.reload()
        elif key == "F2":
            self.start_rename()
        elif key == "Delete":
            self.trash()
        elif ctrl and shift and key in ("n", "N"):
            self.new_folder()
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
cat > /usr/local/bin/power-menu <<'EOF'
#!/usr/bin/env python3
import gi
import os
import subprocess
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, GLib

LOCK = "/tmp/power-menu.pid"

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

def running():
    try:
        with open(LOCK) as f:
            pid = int(f.read().strip())
        return alive(pid)
    except Exception:
        return False

class PowerMenu(Gtk.Window):
    def __init__(self):
        super().__init__()
        self.set_decorated(False)
        self.set_app_paintable(True)
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual:
            self.set_visual(visual)
        css = Gtk.CssProvider()
        css.load_from_data(b".card { border-radius: 16px; } .pbtn { border-radius: 10px; padding: 10px 14px; font-size: 14px; font-weight: bold; }")
        Gtk.StyleContext.add_provider_for_screen(screen, css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        bg = Gtk.EventBox()
        bg.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0, 0, 0, 0.55))
        bg.connect("button-press-event", lambda w, e: self.quit())
        card = Gtk.EventBox()
        card.get_style_context().add_class("card")
        card.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0.07, 0.07, 0.09, 0.95))
        card.set_halign(Gtk.Align.CENTER)
        card.set_valign(Gtk.Align.CENTER)
        card.connect("button-press-event", lambda w, e: True)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_size_request(340, -1)
        box.set_margin_start(24)
        box.set_margin_end(24)
        box.set_margin_top(20)
        box.set_margin_bottom(20)
        for label, cmd, rgb in (("Выключить", "poweroff", (0.80, 0.20, 0.20)),
                                ("Перезагрузить", "reboot", (0.85, 0.55, 0.15)),
                                ("Спящий режим", "suspend", (0.25, 0.45, 0.85))):
            b = Gtk.Button(label=label)
            b.get_style_context().add_class("pbtn")
            b.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(rgb[0], rgb[1], rgb[2], 1.0))
            b.override_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(1, 1, 1, 1))
            b.connect("clicked", lambda w, c=cmd: self.run(c))
            box.pack_start(b, False, False, 0)
        card.add(box)
        bg.add(card)
        self.add(bg)
        self.connect("key-press-event", self.on_key)
        self.fullscreen()
        with open(LOCK, "w") as f:
            f.write(str(os.getpid()))

    def on_key(self, w, ev):
        if Gdk.keyval_name(ev.keyval) == "Escape":
            self.quit()
            return True
        return False

    def run(self, cmd):
        subprocess.Popen(["systemctl", cmd])
        self.quit()

    def quit(self):
        try:
            os.remove(LOCK)
        except OSError:
            pass
        self.destroy()
        Gtk.main_quit()

def main():
    GLib.set_prgname("power-menu")
    GLib.set_application_name("power-menu")
    if running():
        with open(LOCK) as f:
            pid = int(f.read().strip())
        try:
            os.kill(pid, 15)
        except OSError:
            pass
        try:
            os.remove(LOCK)
        except OSError:
            pass
        return
    w = PowerMenu()
    w.connect("destroy", Gtk.main_quit)
    w.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
EOF
chmod 755 /usr/local/bin/power-menu
cat > /usr/local/bin/musicplayer <<'MPLAYER_EOF'
#!/usr/bin/env python3
import sys, os, json, shutil, subprocess, random, threading, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from PyQt6.QtCore import Qt, QTimer, QObject, pyqtSignal, QSize, QUrl, QRectF
from PyQt6.QtGui import QColor, QPixmap, QIcon, QPainter, QPainterPath, QShortcut, QKeySequence, QFontMetrics
from PyQt6.QtNetwork import QNetworkAccessManager, QNetworkRequest, QNetworkReply
from PyQt6.QtWidgets import (QApplication, QMainWindow, QFrame, QWidget, QVBoxLayout, QHBoxLayout,
                             QGridLayout, QPushButton, QLabel, QLineEdit, QListWidget, QListWidgetItem,
                             QSlider, QStackedWidget, QStyle, QMenu, QColorDialog, QFileDialog, QScrollArea)
import vlc

CFG_DIR = Path.home() / ".config" / "musicplayer"
CFG_DIR.mkdir(parents=True, exist_ok=True)
CFG_FILE = CFG_DIR / "settings.json"
FAV_FILE = CFG_DIR / "favorites.json"
HIST_FILE = CFG_DIR / "history.json"
RECS_FILE = CFG_DIR / "recs.json"
UR = Qt.ItemDataRole.UserRole
AUDIO_EXT = {".mp3", ".flac", ".ogg", ".opus", ".m4a", ".wav", ".aac", ".wma"}

THEMES = {
    "Неон":     dict(bg="#0d0b1a", panel="#17133a", text="#eae6ff", sub="#8f87c4", accent="#b06cff", accent2="#ff4fa3", radius=16, opacity=0.95),
    "Закат":    dict(bg="#1a0f12", panel="#2c161b", text="#fff0e8", sub="#c99a8a", accent="#ff7a45", accent2="#ffc15a", radius=16, opacity=0.95),
    "Океан":    dict(bg="#07131c", panel="#0d2433", text="#e4f6ff", sub="#7fb0c8", accent="#2cc4ff", accent2="#3dffc0", radius=16, opacity=0.95),
    "Лес":      dict(bg="#0c150f", panel="#14251a", text="#e8f5ea", sub="#86a98d", accent="#4cd97b", accent2="#c8f060", radius=16, opacity=0.95),
    "Сакура":   dict(bg="#1a1018", panel="#2b1827", text="#ffeaf5", sub="#c496b4", accent="#ff7eb6", accent2="#c58cff", radius=18, opacity=0.95),
    "Монохром": dict(bg="#0a0a0c", panel="#141416", text="#e6e6e6", sub="#8a8a8a", accent="#ffffff", accent2="#9a9a9a", radius=14, opacity=0.80),
    "AMOLED":   dict(bg="#000000", panel="#0c0c0c", text="#ffffff", sub="#8a8a8a", accent="#00e0a4", accent2="#00b4ff", radius=12, opacity=1.0),
    "Светлая":  dict(bg="#f3f1f8", panel="#ffffff", text="#1d1b26", sub="#6d6880", accent="#6c4cff", accent2="#ff4f8b", radius=16, opacity=1.0),
}
DEFAULT_CFG = {"theme": "Неон", "custom": {}, "font": 11, "proxy": "", "music_dir": "", "volume": 70,
               "shuffle": False, "repeat": False, "autoplay": True}
COLOR_KEYS = [("bg", "Фон"), ("panel", "Панели"), ("text", "Текст"), ("sub", "Доп. текст"),
              ("accent", "Акцент"), ("accent2", "Акцент 2")]


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path, data):
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
    except Exception:
        pass


def rgba(color, a):
    c = QColor(color)
    return "rgba(%d,%d,%d,%d)" % (c.red(), c.green(), c.blue(), int(max(0.0, min(1.0, float(a))) * 255))


def fmt(sec):
    try:
        sec = int(sec or 0)
    except Exception:
        sec = 0
    if sec <= 0:
        return "--:--"
    return "%d:%02d" % (sec // 60, sec % 60) if sec < 3600 else "%d:%02d:%02d" % (sec // 3600, sec % 3600 // 60, sec % 60)


def rounded(pm, size, radius):
    pm = pm.scaled(size, size, Qt.AspectRatioMode.KeepAspectRatioByExpanding, Qt.TransformationMode.SmoothTransformation)
    out = QPixmap(size, size)
    out.fill(Qt.GlobalColor.transparent)
    p = QPainter(out)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    path = QPainterPath()
    path.addRoundedRect(QRectF(0, 0, size, size), radius, radius)
    p.setClipPath(path)
    p.drawPixmap((size - pm.width()) // 2, (size - pm.height()) // 2, pm)
    p.end()
    return out


def placeholder(size, radius, color):
    out = QPixmap(size, size)
    out.fill(Qt.GlobalColor.transparent)
    p = QPainter(out)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    c = QColor(color)
    c.setAlpha(70)
    path = QPainterPath()
    path.addRoundedRect(QRectF(0, 0, size, size), radius, radius)
    p.fillPath(path, c)
    c.setAlpha(200)
    p.setPen(c)
    p.drawText(QRectF(0, 0, size, size), Qt.AlignmentFlag.AlignCenter, "♪")
    p.end()
    return out


def qss(t, fs):
    r = int(t["radius"])
    o = float(t["opacity"])
    bg, panel, tx, sub, a, a2 = t["bg"], t["panel"], t["text"], t["sub"], t["accent"], t["accent2"]
    grad = "qlineargradient(x1:0,y1:0,x2:1,y2:1,stop:0 %s,stop:1 %s)" % (a, a2)
    ir = max(r - 4, 0)
    return f"""
* {{ font-family: "DejaVu Sans", "Noto Sans", sans-serif; font-size: {fs}px; color: {tx}; outline: none; }}
QFrame#root {{ background: {rgba(bg, o)}; border-radius: {r + 6}px; }}
QFrame#side, QFrame#bar {{ background: {rgba(panel, o)}; border-radius: {r}px; }}
QLabel {{ background: transparent; }}
QLabel#logo {{ font-size: {fs + 7}px; font-weight: bold; color: {a}; }}
QLabel#h1 {{ font-size: {fs + 6}px; font-weight: bold; }}
QLabel#h2 {{ font-size: {fs + 1}px; font-weight: bold; color: {a}; }}
QLabel#sub {{ color: {sub}; }}
QLabel#np {{ font-size: {fs + 1}px; font-weight: bold; }}
QPushButton {{ background: {rgba(tx, 0.08)}; border: none; border-radius: {r}px; padding: 8px 16px; }}
QPushButton:hover {{ background: {rgba(tx, 0.16)}; }}
QPushButton#nav {{ text-align: left; padding: 11px 16px; background: transparent; }}
QPushButton#nav:hover {{ background: {rgba(tx, 0.09)}; }}
QPushButton#nav:checked {{ background: {grad}; color: {bg}; font-weight: bold; }}
QPushButton#ico {{ background: transparent; padding: 6px 10px; font-size: {fs + 5}px; color: {sub}; }}
QPushButton#ico:hover {{ background: {rgba(tx, 0.12)}; color: {tx}; }}
QPushButton#ico:checked {{ color: {a}; }}
QPushButton#play {{ background: {grad}; color: {bg}; border-radius: 24px; min-width: 48px; max-width: 48px;
                   min-height: 48px; max-height: 48px; padding: 0; font-size: {fs + 6}px; }}
QPushButton#play:hover {{ background: {a2}; }}
QPushButton#primary {{ background: {grad}; color: {bg}; font-weight: bold; }}
QPushButton#primary:hover {{ background: {a2}; }}
QPushButton#preset {{ font-weight: bold; padding: 14px 10px; border: 2px solid transparent; }}
QPushButton#preset:checked {{ border: 2px solid {tx}; }}
QLineEdit {{ background: {rgba(tx, 0.09)}; border: 1px solid transparent; border-radius: {r}px; padding: 9px 14px;
            selection-background-color: {a}; selection-color: {bg}; }}
QLineEdit:focus {{ border: 1px solid {a}; }}
QListWidget {{ background: transparent; border: none; }}
QListWidget::item {{ padding: 6px; border-radius: {ir}px; margin: 2px 4px; }}
QListWidget::item:hover {{ background: {rgba(tx, 0.08)}; }}
QListWidget::item:selected {{ background: {rgba(a, 0.30)}; color: {tx}; }}
QSlider::groove:horizontal {{ height: 5px; background: {rgba(tx, 0.18)}; border-radius: 2px; }}
QSlider::sub-page:horizontal {{ background: {grad}; border-radius: 2px; }}
QSlider::handle:horizontal {{ background: {tx}; width: 13px; height: 13px; margin: -4px 0; border-radius: 6px; }}
QScrollBar:vertical {{ background: transparent; width: 8px; margin: 0; }}
QScrollBar::handle:vertical {{ background: {rgba(tx, 0.28)}; border-radius: 4px; min-height: 30px; }}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{ background: transparent; }}
QScrollArea {{ background: transparent; border: none; }}
QMenu {{ background: {panel}; border: 1px solid {rgba(tx, 0.18)}; border-radius: 8px; padding: 4px; }}
QMenu::item {{ padding: 7px 20px; border-radius: 6px; }}
QMenu::item:selected {{ background: {rgba(a, 0.40)}; }}
QToolTip {{ background: {panel}; color: {tx}; border: 1px solid {a}; padding: 4px; }}
"""


def ytdlp(args, proxy="", timeout=90):
    base = ["yt-dlp", "--no-warnings"]
    if proxy:
        base += ["--proxy", proxy]
    extra = []
    for rt in ("deno", "node"):
        if shutil.which(rt):
            extra = ["--js-runtimes", rt]
            break
    attempts = [extra, []] if extra else [[]]
    last = "yt-dlp: неизвестная ошибка"
    for ex in attempts:
        try:
            p = subprocess.run(base + ex + args, capture_output=True, text=True, timeout=timeout)
        except FileNotFoundError:
            raise RuntimeError("yt-dlp не установлен")
        except subprocess.TimeoutExpired:
            raise RuntimeError("таймаут: нет ответа от YouTube (VPN включён?)")
        if p.returncode == 0:
            return p.stdout
        err = (p.stderr or "").strip()
        last = err.splitlines()[-1] if err else last
        if ex and ("no such option" in err.lower() or "unrecognized" in err.lower()):
            continue
        break
    raise RuntimeError(last)


def entry_to_track(e):
    vid = e["id"]
    return {"id": vid, "title": e.get("title") or "Без названия",
            "artist": e.get("channel") or e.get("uploader") or "YouTube",
            "duration": e.get("duration") or 0, "src": "yt",
            "url": "https://www.youtube.com/watch?v=" + vid,
            "thumb": "https://i.ytimg.com/vi/%s/mqdefault.jpg" % vid}


def mix_tracks(vid, proxy="", n=30):
    """Похожие треки: автоматический YouTube-микс (радио) от выбранного трека."""
    out = ytdlp(["--flat-playlist", "--playlist-end", str(n), "-J",
                 "https://www.youtube.com/watch?v=%s&list=RD%s" % (vid, vid)], proxy)
    data = json.loads(out)
    return [entry_to_track(e) for e in (data.get("entries") or []) if e and e.get("id")]


def compute_recs(seeds, exclude, proxy):
    """seeds: [(трек, вес)]. Трек, который всплывает в миксах нескольких любимых, получает больше очков."""
    def one(item):
        tr, w = item
        try:
            return w, mix_tracks(tr["id"], proxy), None
        except Exception as ex:
            return w, [], str(ex)
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(one, seeds))
    scores, info, errs = {}, {}, []
    for w, lst, err in results:
        if err:
            errs.append(err)
        n = max(len(lst), 1)
        for rank, t in enumerate(lst):
            if t["id"] in exclude:
                continue
            d = t.get("duration") or 0
            if d and (d < 45 or d > 720):
                continue
            scores[t["id"]] = scores.get(t["id"], 0.0) + w * (1.0 - rank / n)
            info[t["id"]] = t
    if not info and errs:
        raise RuntimeError(errs[0])
    out, per = [], {}
    for tid in sorted(scores, key=scores.get, reverse=True):
        t = info[tid]
        if per.get(t["artist"], 0) >= 3:
            continue
        per[t["artist"]] = per.get(t["artist"], 0) + 1
        out.append(t)
        if len(out) >= 40:
            break
    return out


class Bus(QObject):
    found = pyqtSignal(list)
    failed = pyqtSignal(str)
    resolved = pyqtSignal(int, str)
    recs = pyqtSignal(list)
    recfail = pyqtSignal(str)
    similar = pyqtSignal(list)
    radio = pyqtSignal(int, list)


class ClickSlider(QSlider):
    """Слайдер: клик по полосе сразу переносит ползунок."""
    def _val(self, e):
        return QStyle.sliderValueFromPosition(self.minimum(), self.maximum(), int(e.position().x()), max(self.width(), 1))

    def mousePressEvent(self, e):
        if e.button() == Qt.MouseButton.LeftButton:
            self.setValue(self._val(e))
            self.setSliderDown(True)
            e.accept()
        else:
            super().mousePressEvent(e)

    def mouseMoveEvent(self, e):
        if self.isSliderDown():
            self.setValue(self._val(e))
            e.accept()
        else:
            super().mouseMoveEvent(e)

    def mouseReleaseEvent(self, e):
        if self.isSliderDown():
            self.setSliderDown(False)
            e.accept()
        else:
            super().mouseReleaseEvent(e)


class Player(QMainWindow):
    def __init__(self):
        super().__init__()
        self.cfg = dict(DEFAULT_CFG)
        self.cfg.update(load_json(CFG_FILE, {}))
        self.favs = load_json(FAV_FILE, [])
        if not isinstance(self.favs, list):
            self.favs = []
        self.hist = load_json(HIST_FILE, {})
        if not isinstance(self.hist, dict):
            self.hist = {}
        self.recs = load_json(RECS_FILE, [])
        if not isinstance(self.recs, list):
            self.recs = []
        self.recs_started = False
        self.counted = True
        self.queue, self.idx, self.token = [], -1, 0
        self.seeking = False
        self.advanced = False
        args = ["--no-video", "--quiet"]
        if self.cfg.get("proxy", "").startswith("http"):
            args.append("--http-proxy=" + self.cfg["proxy"])
        self.vlc = vlc.Instance(*args)
        self.mp = self.vlc.media_player_new()
        self.mp.audio_set_volume(int(self.cfg.get("volume", 70)))
        self.nam = QNetworkAccessManager(self)
        self.pix = {}
        self.bus = Bus()
        self.bus.found.connect(self.on_found)
        self.bus.failed.connect(self.on_failed)
        self.bus.resolved.connect(self.on_resolved)
        self.bus.recs.connect(self.on_recs)
        self.bus.recfail.connect(self.on_recfail)
        self.bus.similar.connect(self.on_similar)
        self.bus.radio.connect(self.on_radio)
        self.apply_timer = QTimer(self)
        self.apply_timer.setSingleShot(True)
        self.apply_timer.timeout.connect(self.apply_theme)
        self.build_ui()
        self.apply_theme()
        self.goto(0)
        self.load_local()
        self.refresh_favs()
        self.fill(self.recl, self.recs)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.tick)
        self.timer.start(300)
        for key, fn in (("Space", self.toggle), ("Ctrl+Right", self.skip), ("Ctrl+Left", self.prev_track)):
            QShortcut(QKeySequence(key), self, activated=fn)

    # ---------- тема ----------
    def theme(self):
        if self.cfg["theme"] == "Свой" and self.cfg.get("custom"):
            t = dict(THEMES["Неон"])
            t.update(self.cfg["custom"])
            return t
        return dict(THEMES.get(self.cfg["theme"], THEMES["Неон"]))

    def apply_theme(self):
        t = self.theme()
        self.setStyleSheet(qss(t, int(self.cfg["font"])))
        self.ph = placeholder(56, max(int(t["radius"]) - 4, 4), t["accent"])
        if hasattr(self, "cur_label"):
            self.cur_label.setText("Сейчас: " + self.cfg["theme"])

    def schedule_apply(self):
        self.apply_timer.start(40)

    def set_custom(self, t):
        self.cfg["custom"] = {k: t[k] for k in t}
        self.cfg["theme"] = "Свой"
        for b in self.presets.values():
            b.setChecked(False)
        self.refresh_swatches()
        self.schedule_apply()
        save_json(CFG_FILE, self.cfg)

    def choose_preset(self, name):
        self.cfg["theme"] = name
        for n, b in self.presets.items():
            b.setChecked(n == name)
        self.sync_controls()
        self.apply_theme()
        save_json(CFG_FILE, self.cfg)

    def pick_color(self, key):
        t = self.theme()
        c = QColorDialog.getColor(QColor(t[key]), self, "Выбери цвет")
        if c.isValid():
            t[key] = c.name()
            self.set_custom(t)

    def refresh_swatches(self):
        t = self.theme()
        for key, b in self.swatches.items():
            c = QColor(t[key])
            fg = "#000" if c.lightness() > 140 else "#fff"
            b.setStyleSheet("QPushButton { background: %s; color: %s; border: 1px solid %s; }" % (t[key], fg, rgba("#ffffff", 0.3)))

    def sync_controls(self):
        t = self.theme()
        for s, v in ((self.s_radius, t["radius"]), (self.s_opacity, int(t["opacity"] * 100)), (self.s_font, self.cfg["font"])):
            s.blockSignals(True)
            s.setValue(int(v))
            s.blockSignals(False)
        for lab, v in ((self.l_radius, t["radius"]), (self.l_opacity, int(t["opacity"] * 100)), (self.l_font, self.cfg["font"])):
            lab.setText(str(int(v)))
        self.refresh_swatches()

    # ---------- интерфейс ----------
    def build_ui(self):
        self.setWindowTitle("Музыка")
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.root = QFrame()
        self.root.setObjectName("root")
        self.setCentralWidget(self.root)
        outer = QVBoxLayout(self.root)
        outer.setContentsMargins(12, 12, 12, 12)
        outer.setSpacing(12)
        top = QHBoxLayout()
        top.setSpacing(12)
        outer.addLayout(top, 1)

        side = QFrame()
        side.setObjectName("side")
        side.setFixedWidth(210)
        sl = QVBoxLayout(side)
        sl.setContentsMargins(12, 18, 12, 16)
        sl.setSpacing(6)
        logo = QLabel("♪  Музыка")
        logo.setObjectName("logo")
        sl.addWidget(logo)
        sl.addSpacing(12)
        self.stack = QStackedWidget()
        self.nav = []
        for i, name in enumerate(["Поиск", "Для тебя", "Моя музыка", "Любимые", "Оформление"]):
            b = QPushButton(name)
            b.setObjectName("nav")
            b.setCheckable(True)
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            b.clicked.connect(lambda _, i=i: self.goto(i))
            sl.addWidget(b)
            self.nav.append(b)
        sl.addStretch(1)
        hint = QLabel("Пробел — пауза\nCtrl+←/→ — трек")
        hint.setObjectName("sub")
        sl.addWidget(hint)
        top.addWidget(side)
        top.addWidget(self.stack, 1)

        self.stack.addWidget(self.page_search())
        self.stack.addWidget(self.page_recs())
        self.stack.addWidget(self.page_local())
        self.stack.addWidget(self.page_favs())
        self.stack.addWidget(self.page_theme())
        outer.addWidget(self.build_bar())

    def make_list(self):
        lst = QListWidget()
        lst.setIconSize(QSize(56, 56))
        lst.setVerticalScrollMode(QListWidget.ScrollMode.ScrollPerPixel)
        lst.itemActivated.connect(lambda it, l=lst: self.activate(l, it))
        lst.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        lst.customContextMenuRequested.connect(lambda pos, l=lst: self.list_menu(l, pos))
        return lst

    def page_search(self):
        w = QWidget()
        l = QVBoxLayout(w)
        l.setContentsMargins(8, 8, 8, 0)
        h = QLabel("Поиск музыки")
        h.setObjectName("h1")
        l.addWidget(h)
        row = QHBoxLayout()
        self.q = QLineEdit()
        self.q.setPlaceholderText("Исполнитель, трек или альбом…")
        self.q.returnPressed.connect(self.do_search)
        b = QPushButton("Найти")
        b.setObjectName("primary")
        b.setCursor(Qt.CursorShape.PointingHandCursor)
        b.clicked.connect(self.do_search)
        row.addWidget(self.q, 1)
        row.addWidget(b)
        l.addLayout(row)
        self.search_status = QLabel("Введи запрос и нажми Enter. Двойной клик / Enter по треку — играть, правый клик — в избранное.")
        self.search_status.setObjectName("sub")
        self.search_status.setWordWrap(True)
        l.addWidget(self.search_status)
        self.res = self.make_list()
        l.addWidget(self.res, 1)
        return w

    def page_recs(self):
        w = QWidget()
        l = QVBoxLayout(w)
        l.setContentsMargins(8, 8, 8, 0)
        h = QLabel("Для тебя")
        h.setObjectName("h1")
        l.addWidget(h)
        row = QHBoxLayout()
        self.rec_status = QLabel("Подборка строится по тому, что ты слушаешь дольше 30 секунд и добавляешь в «Любимые». Скипнутое учитывается как «не нравится».")
        self.rec_status.setObjectName("sub")
        self.rec_status.setWordWrap(True)
        b = QPushButton("Подобрать заново")
        b.setObjectName("primary")
        b.setCursor(Qt.CursorShape.PointingHandCursor)
        b.clicked.connect(self.do_recs)
        row.addWidget(self.rec_status, 1)
        row.addWidget(b)
        l.addLayout(row)
        self.recl = self.make_list()
        l.addWidget(self.recl, 1)
        return w

    def page_local(self):
        w = QWidget()
        l = QVBoxLayout(w)
        l.setContentsMargins(8, 8, 8, 0)
        h = QLabel("Моя музыка")
        h.setObjectName("h1")
        l.addWidget(h)
        row = QHBoxLayout()
        self.loc_label = QLabel("")
        self.loc_label.setObjectName("sub")
        b1 = QPushButton("Обновить")
        b1.clicked.connect(self.load_local)
        b2 = QPushButton("Выбрать папку…")
        b2.clicked.connect(self.pick_dir)
        row.addWidget(self.loc_label, 1)
        row.addWidget(b1)
        row.addWidget(b2)
        l.addLayout(row)
        self.loc = self.make_list()
        l.addWidget(self.loc, 1)
        return w

    def page_favs(self):
        w = QWidget()
        l = QVBoxLayout(w)
        l.setContentsMargins(8, 8, 8, 0)
        h = QLabel("Любимые")
        h.setObjectName("h1")
        l.addWidget(h)
        self.favl = self.make_list()
        l.addWidget(self.favl, 1)
        return w

    def page_theme(self):
        sc = QScrollArea()
        sc.setWidgetResizable(True)
        w = QWidget()
        sc.setWidget(w)
        l = QVBoxLayout(w)
        l.setContentsMargins(8, 8, 14, 8)
        l.setSpacing(10)
        h = QLabel("Оформление")
        h.setObjectName("h1")
        l.addWidget(h)
        self.cur_label = QLabel("")
        self.cur_label.setObjectName("sub")
        l.addWidget(self.cur_label)

        h2 = QLabel("Готовые темы")
        h2.setObjectName("h2")
        l.addWidget(h2)
        grid = QGridLayout()
        grid.setSpacing(10)
        self.presets = {}
        for i, (name, t) in enumerate(THEMES.items()):
            b = QPushButton(name)
            b.setObjectName("preset")
            b.setCheckable(True)
            b.setChecked(name == self.cfg["theme"])
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            fg = "#000" if QColor(t["accent"]).lightness() > 150 else "#fff"
            b.setStyleSheet(
                "QPushButton { background: qlineargradient(x1:0,y1:0,x2:1,y2:1,stop:0 %s,stop:1 %s); color: %s; border-radius: %dpx; font-weight: bold; padding: 14px 10px; }"
                "QPushButton:checked { border: 2px solid %s; }" % (t["accent"], t["accent2"], fg, int(t["radius"]), t["text"]))
            b.clicked.connect(lambda _, n=name: self.choose_preset(n))
            grid.addWidget(b, i // 4, i % 4)
            self.presets[name] = b
        l.addLayout(grid)

        h3 = QLabel("Своя настройка")
        h3.setObjectName("h2")
        l.addSpacing(8)
        l.addWidget(h3)
        cg = QGridLayout()
        cg.setSpacing(10)
        self.swatches = {}
        for i, (key, title) in enumerate(COLOR_KEYS):
            b = QPushButton(title)
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            b.clicked.connect(lambda _, k=key: self.pick_color(k))
            cg.addWidget(b, i // 3, i % 3)
            self.swatches[key] = b
        l.addLayout(cg)

        t = self.theme()
        self.s_radius, self.l_radius = self.add_slider(l, "Скругление", 0, 30, int(t["radius"]), self.on_radius)
        self.s_opacity, self.l_opacity = self.add_slider(l, "Прозрачность окна, %", 40, 100, int(t["opacity"] * 100), self.on_opacity)
        self.s_font, self.l_font = self.add_slider(l, "Размер шрифта", 9, 18, int(self.cfg["font"]), self.on_font)

        h4 = QLabel("Сеть")
        h4.setObjectName("h2")
        l.addSpacing(8)
        l.addWidget(h4)
        sub = QLabel("Прокси для YouTube (необязательно), например socks5://127.0.0.1:1080 или http://127.0.0.1:2080")
        sub.setObjectName("sub")
        sub.setWordWrap(True)
        l.addWidget(sub)
        self.proxy = QLineEdit(self.cfg.get("proxy", ""))
        self.proxy.setPlaceholderText("пусто — без прокси")
        self.proxy.editingFinished.connect(self.save_proxy)
        l.addWidget(self.proxy)
        l.addStretch(1)
        self.refresh_swatches()
        return sc

    def add_slider(self, lay, text, lo, hi, val, cb):
        row = QHBoxLayout()
        lab = QLabel(text)
        lab.setFixedWidth(200)
        s = ClickSlider(Qt.Orientation.Horizontal)
        s.setRange(lo, hi)
        s.setValue(val)
        v = QLabel(str(val))
        v.setFixedWidth(36)
        s.valueChanged.connect(lambda x: (v.setText(str(x)), cb(x)))
        row.addWidget(lab)
        row.addWidget(s, 1)
        row.addWidget(v)
        lay.addLayout(row)
        return s, v

    def on_radius(self, x):
        t = self.theme()
        t["radius"] = x
        self.set_custom(t)

    def on_opacity(self, x):
        t = self.theme()
        t["opacity"] = x / 100.0
        self.set_custom(t)

    def on_font(self, x):
        self.cfg["font"] = x
        self.schedule_apply()
        save_json(CFG_FILE, self.cfg)

    def save_proxy(self):
        self.cfg["proxy"] = self.proxy.text().strip()
        save_json(CFG_FILE, self.cfg)

    def build_bar(self):
        bar = QFrame()
        bar.setObjectName("bar")
        bar.setFixedHeight(100)
        bl = QHBoxLayout(bar)
        bl.setContentsMargins(16, 10, 16, 10)
        bl.setSpacing(14)
        self.cover = QLabel()
        self.cover.setFixedSize(64, 64)
        bl.addWidget(self.cover)
        info = QVBoxLayout()
        info.setSpacing(2)
        info.addStretch(1)
        self.title = QLabel("Ничего не играет")
        self.title.setObjectName("np")
        self.artist = QLabel("Выбери трек")
        self.artist.setObjectName("sub")
        self.title.setFixedWidth(250)
        self.artist.setFixedWidth(250)
        info.addWidget(self.title)
        info.addWidget(self.artist)
        info.addStretch(1)
        bl.addLayout(info)
        bl.addStretch(1)

        mid = QVBoxLayout()
        mid.setSpacing(4)
        ctr = QHBoxLayout()
        ctr.setSpacing(8)
        ctr.addStretch(1)
        self.b_shuffle = self.ico("⇄", "Перемешать", True)
        self.b_shuffle.setChecked(bool(self.cfg["shuffle"]))
        self.b_shuffle.toggled.connect(self.set_shuffle)
        b_prev = self.ico("◀◀", "Назад")
        b_prev.clicked.connect(self.prev_track)
        self.b_play = QPushButton("▶")
        self.b_play.setObjectName("play")
        self.b_play.setCursor(Qt.CursorShape.PointingHandCursor)
        self.b_play.clicked.connect(self.toggle)
        b_next = self.ico("▶▶", "Дальше")
        b_next.clicked.connect(self.skip)
        self.b_repeat = self.ico("↻", "Повтор списка", True)
        self.b_repeat.setChecked(bool(self.cfg["repeat"]))
        self.b_repeat.toggled.connect(self.set_repeat)
        self.b_auto = self.ico("∞", "Автоподбор: когда список закончится, включить похожие", True)
        self.b_auto.setChecked(bool(self.cfg["autoplay"]))
        self.b_auto.toggled.connect(self.set_autoplay)
        for b in (self.b_shuffle, b_prev, self.b_play, b_next, self.b_repeat, self.b_auto):
            ctr.addWidget(b)
        ctr.addStretch(1)
        mid.addLayout(ctr)
        sr = QHBoxLayout()
        self.t_cur = QLabel("0:00")
        self.t_cur.setObjectName("sub")
        self.t_all = QLabel("--:--")
        self.t_all.setObjectName("sub")
        self.seek = ClickSlider(Qt.Orientation.Horizontal)
        self.seek.setRange(0, 1000)
        self.seek.sliderPressed.connect(lambda: setattr(self, "seeking", True))
        self.seek.sliderReleased.connect(self.do_seek)
        sr.addWidget(self.t_cur)
        sr.addWidget(self.seek, 1)
        sr.addWidget(self.t_all)
        mid.addLayout(sr)
        bl.addLayout(mid, 3)
        bl.addStretch(1)

        self.b_heart = self.ico("♡", "В избранное", True)
        self.b_heart.clicked.connect(self.heart)
        bl.addWidget(self.b_heart)
        vl = QLabel("Громк.")
        vl.setObjectName("sub")
        self.vol = ClickSlider(Qt.Orientation.Horizontal)
        self.vol.setRange(0, 100)
        self.vol.setValue(int(self.cfg.get("volume", 70)))
        self.vol.setFixedWidth(110)
        self.vol.valueChanged.connect(self.set_volume)
        bl.addWidget(vl)
        bl.addWidget(self.vol)
        return bar

    def ico(self, text, tip, checkable=False):
        b = QPushButton(text)
        b.setObjectName("ico")
        b.setToolTip(tip)
        b.setCheckable(checkable)
        b.setCursor(Qt.CursorShape.PointingHandCursor)
        return b

    def goto(self, i):
        self.stack.setCurrentIndex(i)
        for k, b in enumerate(self.nav):
            b.setChecked(k == i)
        if i == 1 and not self.recs and not self.recs_started:
            self.recs_started = True
            self.do_recs()
        if i == 4:
            self.sync_controls()

    # ---------- списки ----------
    def fill(self, lst, tracks):
        gen = (lst.property("gen") or 0) + 1
        lst.setProperty("gen", gen)
        lst.clear()
        r = max(int(self.theme()["radius"]) - 4, 4)
        for tr in tracks:
            it = QListWidgetItem("%s\n%s  •  %s" % (tr["title"], tr["artist"], fmt(tr.get("duration"))))
            it.setData(UR, tr)
            it.setIcon(QIcon(self.ph))
            it.setSizeHint(QSize(0, 70))
            lst.addItem(it)
            if tr.get("thumb"):
                self.get_thumb(tr["thumb"], lambda pm, it=it, r=r: it.setIcon(QIcon(rounded(pm, 56, r))), lst, gen)

    def get_thumb(self, url, setter, lst=None, gen=None):
        def ok():
            return lst is None or lst.property("gen") == gen
        if url in self.pix:
            setter(self.pix[url])
            return
        req = QNetworkRequest(QUrl(url))
        req.setAttribute(QNetworkRequest.Attribute.RedirectPolicyAttribute, QNetworkRequest.RedirectPolicy.NoLessSafeRedirectPolicy)
        rep = self.nam.get(req)

        def done():
            try:
                if rep.error() == QNetworkReply.NetworkError.NoError:
                    pm = QPixmap()
                    if pm.loadFromData(rep.readAll()):
                        self.pix[url] = pm
                        if ok():
                            setter(pm)
            finally:
                rep.deleteLater()
        rep.finished.connect(done)

    def activate(self, lst, item):
        self.queue = [lst.item(i).data(UR) for i in range(lst.count())]
        self.play_index(lst.row(item))

    def list_menu(self, lst, pos):
        it = lst.itemAt(pos)
        if not it:
            return
        tr = it.data(UR)
        m = QMenu(self)
        a_play = m.addAction("Играть")
        a_fav = m.addAction("Убрать из любимых" if self.is_fav(tr["id"]) else "В любимые")
        a_sim = m.addAction("Похожие треки") if tr["src"] == "yt" else None
        act = m.exec(lst.viewport().mapToGlobal(pos))
        if act == a_play:
            self.activate(lst, it)
        elif act == a_fav:
            self.toggle_fav(tr)
        elif a_sim is not None and act == a_sim:
            self.find_similar(tr)

    # ---------- поиск / библиотека ----------
    def do_search(self):
        q = self.q.text().strip()
        if not q:
            return
        self.search_status.setText("Ищу «%s»…" % q)
        proxy = self.cfg.get("proxy", "")

        def work():
            try:
                out = ytdlp(["--flat-playlist", "-J", "ytsearch25:" + q], proxy)
                data = json.loads(out)
                tracks = [entry_to_track(e) for e in (data.get("entries", []) or []) if e and e.get("id")]
                self.bus.found.emit(tracks)
            except Exception as ex:
                self.bus.failed.emit(str(ex)[:300])
        threading.Thread(target=work, daemon=True).start()

    def on_found(self, tracks):
        self.search_status.setText("Найдено: %d" % len(tracks) if tracks else "Ничего не найдено")
        self.fill(self.res, tracks)

    def on_failed(self, msg):
        self.search_status.setText("Ошибка: " + msg)
        self.set_info(self.cur_title(), "Ошибка: " + msg)
        self.b_play.setText("▶")

    def music_dir(self):
        d = self.cfg.get("music_dir") or str(Path.home() / "Music")
        return Path(d)

    def pick_dir(self):
        d = QFileDialog.getExistingDirectory(self, "Папка с музыкой", str(self.music_dir()))
        if d:
            self.cfg["music_dir"] = d
            save_json(CFG_FILE, self.cfg)
            self.load_local()

    def load_local(self):
        base = self.music_dir()
        self.loc_label.setText(str(base))
        tracks = []
        if base.is_dir():
            for p in sorted(base.rglob("*")):
                if p.suffix.lower() in AUDIO_EXT and p.is_file():
                    tracks.append({"id": str(p), "title": p.stem, "artist": p.parent.name, "duration": 0,
                                   "src": "local", "url": str(p), "thumb": ""})
                    if len(tracks) >= 5000:
                        break
        self.fill(self.loc, tracks)

    # ---------- история и рекомендации ----------
    def save_hist(self):
        if len(self.hist) > 600:
            keep = sorted(self.hist.items(), key=lambda kv: kv[1].get("last", 0), reverse=True)[:500]
            self.hist = dict(keep)
        save_json(HIST_FILE, self.hist)

    def note_start(self, tr):
        if tr["src"] != "yt":
            self.counted = True
            return
        self.counted = False
        h = self.hist.setdefault(tr["id"], {"track": tr, "plays": 0, "skips": 0, "last": 0})
        h["track"] = tr

    def count_play(self):
        self.counted = True
        if 0 <= self.idx < len(self.queue):
            h = self.hist.get(self.queue[self.idx]["id"])
            if h is not None:
                h["plays"] = h.get("plays", 0) + 1
                h["last"] = time.time()
                self.save_hist()

    def mark_skip(self):
        if self.counted or not (0 <= self.idx < len(self.queue)) or self.mp.get_time() < 1000:
            return
        h = self.hist.get(self.queue[self.idx]["id"])
        if h is not None:
            h["skips"] = h.get("skips", 0) + 1
            h["last"] = time.time()
            self.counted = True
            self.save_hist()

    def pick_seeds(self):
        cand = {}
        for f in self.favs:
            if f.get("src") == "yt":
                cand[f["id"]] = [f, 3.0]
        now = time.time()
        for tid, h in self.hist.items():
            tr = h.get("track") or {}
            if tr.get("src") != "yt" or h.get("plays", 0) < 1 or h.get("skips", 0) > h.get("plays", 0):
                continue
            w = min(h["plays"], 5) * 0.6 + (1.0 if now - h.get("last", 0) < 7 * 86400 else 0.0)
            if tid in cand:
                cand[tid][1] += w
            else:
                cand[tid] = [tr, w]
        pool = list(cand.values())
        chosen = []
        for _ in range(min(4, len(pool))):
            r = random.uniform(0, sum(x[1] for x in pool))
            acc, pick = 0.0, pool[-1]
            for x in pool:
                acc += x[1]
                if acc >= r:
                    pick = x
                    break
            chosen.append((pick[0], pick[1]))
            pool.remove(pick)
        return chosen

    def do_recs(self):
        seeds = self.pick_seeds()
        if not seeds:
            self.rec_status.setText("Пока не из чего подбирать: послушай несколько треков с YouTube (дольше 30 секунд) или добавь в «Любимые» — и тут появится подборка.")
            return
        self.rec_status.setText("Подбираю по твоим трекам…")
        exclude = {f["id"] for f in self.favs} | set(self.hist.keys())
        proxy = self.cfg.get("proxy", "")

        def work():
            try:
                self.bus.recs.emit(compute_recs(seeds, exclude, proxy))
            except Exception as ex:
                self.bus.recfail.emit(str(ex)[:300])
        threading.Thread(target=work, daemon=True).start()

    def on_recs(self, tracks):
        self.recs = tracks
        save_json(RECS_FILE, tracks)
        self.rec_status.setText("Подборка готова: %d треков" % len(tracks) if tracks else "Ничего подходящего не нашлось, послушай ещё что-нибудь")
        self.fill(self.recl, tracks)

    def on_recfail(self, msg):
        self.rec_status.setText("Ошибка: " + msg)

    def find_similar(self, tr):
        self.goto(0)
        self.search_status.setText("Ищу похожее на «%s»…" % tr["title"])
        proxy = self.cfg.get("proxy", "")

        def work():
            try:
                self.bus.similar.emit([t for t in mix_tracks(tr["id"], proxy) if t["id"] != tr["id"]])
            except Exception as ex:
                self.bus.failed.emit(str(ex)[:300])
        threading.Thread(target=work, daemon=True).start()

    def on_similar(self, tracks):
        self.search_status.setText("Похожее: %d" % len(tracks) if tracks else "Похожего не нашлось")
        self.fill(self.res, tracks)

    def fetch_radio(self):
        tr = self.queue[self.idx]
        tok = self.token
        self.set_info(tr["title"], "Подбираю похожее…")
        qids = {t["id"] for t in self.queue}
        bad = {k for k, h in self.hist.items() if h.get("skips", 0) > h.get("plays", 0)}
        proxy = self.cfg.get("proxy", "")

        def work():
            try:
                lst = [t for t in mix_tracks(tr["id"], proxy)
                       if t["id"] not in qids and t["id"] not in bad and 45 <= (t.get("duration") or 60) <= 720]
                self.bus.radio.emit(tok, lst[:20])
            except Exception as ex:
                self.bus.failed.emit(str(ex)[:300])
        threading.Thread(target=work, daemon=True).start()

    def on_radio(self, tok, lst):
        if tok != self.token:
            return
        if not lst:
            self.b_play.setText("▶")
            self.set_info(self.cur_title(), "Больше ничего не нашлось")
            return
        old = len(self.queue)
        self.queue.extend(lst)
        self.play_index(old)

    # ---------- избранное ----------
    def is_fav(self, tid):
        return any(f["id"] == tid for f in self.favs)

    def toggle_fav(self, tr):
        if self.is_fav(tr["id"]):
            self.favs = [f for f in self.favs if f["id"] != tr["id"]]
        else:
            self.favs.append(tr)
        save_json(FAV_FILE, self.favs)
        self.refresh_favs()
        self.update_heart()

    def refresh_favs(self):
        self.fill(self.favl, self.favs)

    def heart(self):
        if 0 <= self.idx < len(self.queue):
            self.toggle_fav(self.queue[self.idx])
        else:
            self.b_heart.setChecked(False)

    def update_heart(self):
        on = 0 <= self.idx < len(self.queue) and self.is_fav(self.queue[self.idx]["id"])
        self.b_heart.setChecked(bool(on))
        self.b_heart.setText("♥" if on else "♡")

    # ---------- воспроизведение ----------
    def cur_title(self):
        return self.queue[self.idx]["title"] if 0 <= self.idx < len(self.queue) else "Ничего не играет"

    def set_info(self, title, sub):
        for lab, text in ((self.title, title), (self.artist, sub)):
            lab.setText(QFontMetrics(lab.font()).elidedText(text, Qt.TextElideMode.ElideRight, lab.width()))
            lab.setToolTip(text)

    def set_cover(self, tr):
        r = max(int(self.theme()["radius"]) - 2, 4)
        self.cover.setPixmap(placeholder(64, r, self.theme()["accent"]))
        if tr.get("thumb"):
            idx = self.token
            self.get_thumb(tr["thumb"], lambda pm: self.cover.setPixmap(rounded(pm, 64, r)) if idx == self.token else None)

    def play_index(self, i):
        if not self.queue:
            return
        self.mark_skip()
        self.idx = i % len(self.queue)
        tr = self.queue[self.idx]
        self.note_start(tr)
        self.token += 1
        tok = self.token
        self.mp.stop()
        self.advanced = False
        self.set_info(tr["title"], "Загрузка…" if tr["src"] == "yt" else tr["artist"])
        self.set_cover(tr)
        self.update_heart()
        self.seek.setValue(0)
        self.t_cur.setText("0:00")
        self.t_all.setText(fmt(tr.get("duration")))
        if tr["src"] == "local":
            self.start(self.vlc.media_new_path(tr["url"]))
            return
        proxy = self.cfg.get("proxy", "")

        def work():
            try:
                out = ytdlp(["-f", "bestaudio/best", "-g", "--no-playlist", tr["url"]], proxy)
                lines = [x for x in out.strip().splitlines() if x.startswith("http")]
                if not lines:
                    raise RuntimeError("не удалось получить ссылку на аудио")
                self.bus.resolved.emit(tok, lines[0])
            except Exception as ex:
                self.bus.failed.emit(str(ex)[:300])
        threading.Thread(target=work, daemon=True).start()

    def on_resolved(self, tok, url):
        if tok != self.token:
            return
        self.start(self.vlc.media_new(url))
        tr = self.queue[self.idx]
        self.set_info(tr["title"], tr["artist"])

    def start(self, media):
        self.mp.set_media(media)
        self.mp.play()
        self.b_play.setText("❚❚")

    def toggle(self):
        st = self.mp.get_state()
        if st in (vlc.State.Ended, vlc.State.Stopped, vlc.State.NothingSpecial):
            if self.queue:
                self.play_index(max(self.idx, 0))
            return
        self.mp.pause()

    def next_track(self):
        if not self.queue:
            return
        if self.cfg["shuffle"] and len(self.queue) > 1:
            n = self.idx
            while n == self.idx:
                n = random.randrange(len(self.queue))
            self.play_index(n)
        elif self.idx + 1 < len(self.queue) or self.cfg["repeat"]:
            self.play_index(self.idx + 1)
        elif self.cfg.get("autoplay", True) and self.queue[self.idx]["src"] == "yt":
            self.fetch_radio()
        else:
            self.mp.stop()
            self.b_play.setText("▶")

    def skip(self):
        self.mark_skip()
        self.next_track()

    def prev_track(self):
        if not self.queue:
            return
        if self.mp.get_time() > 4000:
            self.mp.set_time(0)
        else:
            self.play_index(self.idx - 1)

    def set_autoplay(self, on):
        self.cfg["autoplay"] = bool(on)
        save_json(CFG_FILE, self.cfg)

    def set_shuffle(self, on):
        self.cfg["shuffle"] = bool(on)
        save_json(CFG_FILE, self.cfg)

    def set_repeat(self, on):
        self.cfg["repeat"] = bool(on)
        save_json(CFG_FILE, self.cfg)

    def set_volume(self, v):
        self.mp.audio_set_volume(int(v))
        self.cfg["volume"] = int(v)

    def do_seek(self):
        self.seeking = False
        if self.mp.get_length() > 0:
            self.mp.set_position(self.seek.value() / 1000.0)

    def tick(self):
        st = self.mp.get_state()
        if st == vlc.State.Ended and not self.advanced and self.queue:
            self.advanced = True
            if not self.counted:
                self.count_play()
            self.next_track()
            return
        if st == vlc.State.Error and not self.advanced:
            self.advanced = True
            self.set_info(self.cur_title(), "Ошибка воспроизведения")
            self.b_play.setText("▶")
            return
        self.b_play.setText("❚❚" if self.mp.is_playing() else "▶")
        length, pos = self.mp.get_length(), self.mp.get_time()
        if pos > 30000 and not self.counted:
            self.count_play()
        if length > 0 and pos >= 0:
            if not self.seeking:
                self.seek.setValue(int(pos * 1000 / length))
            self.t_cur.setText(fmt(pos // 1000) if pos >= 1000 else "0:00")
            self.t_all.setText(fmt(length // 1000))

    def closeEvent(self, e):
        save_json(CFG_FILE, self.cfg)
        try:
            self.mp.stop()
        except Exception:
            pass
        super().closeEvent(e)


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setApplicationName("musicplayer")
    app.setDesktopFileName("musicplayer")
    w = Player()
    w.resize(1120, 720)
    w.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
MPLAYER_EOF
chmod 755 /usr/local/bin/musicplayer
w() {
mkdir -p "$(dirname "$1")"
if [ -f "$1" ]; then cp -f "$1" "$1.bak"; fi
cat > "$1"
}
w "$H/.config/hypr/quick-kill.sh" <<'EOF'
#!/bin/sh
# Super+Shift+Q: ~1.5 сек закрывает окно под курсором (фокус следует за мышью)
i=0
while [ "$i" -lt 4 ]; do
  hyprctl dispatch killactive >/dev/null 2>&1
  i=$((i+1))
  sleep 0.4
done
EOF
chmod 755 "$H/.config/hypr/quick-kill.sh"
w "$H/.config/hypr/hyprland.conf" <<'EOF'
monitor = , preferred, auto, 1
$mod = SUPER
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
gaps_in = 8
gaps_out = 12
border_size = 2
col.active_border = rgba(ffffffee)
col.inactive_border = rgba(ffffff55)
layout = dwindle
}
decoration {
rounding = 10
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
bind = $mod, Return, exec, kitty sh ~/.config/fastfetch/show.sh
bind = $mod, D, exec, launcher.sh
bind = $mod, B, exec, firefox-esr
bind = $mod, E, exec, files
bind = $mod, M, exec, musicplayer
bind = $mod, W, exec, sh ~/.config/hypr/wallpaper.sh next
bind = $mod, Q, killactive
bind = $mod SHIFT, Q, exec, sh ~/.config/hypr/quick-kill.sh
bind = $mod SHIFT, Escape, exec, power-menu
bind = $mod, F, fullscreen
bind = $mod, V, togglefloating
bind = $mod, left, movefocus, l
bind = $mod, right, movefocus, r
bind = $mod, up, movefocus, u
bind = $mod, down, movefocus, d
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
bind = $mod, Space, exec, hyprctl switchxkblayout all next
bind = $mod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy
bindel = , XF86AudioRaiseVolume, exec, wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindl = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindel = , XF86MonBrightnessUp, exec, brightnessctl set 5%+
bindel = , XF86MonBrightnessDown, exec, brightnessctl set 5%-
windowrule = float on, match:class ^(wofi)$
windowrule = float on, match:class ^(power-menu)$
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
"layer": "top", "height": 36, "margin-top": 10, "margin-left": 15, "margin-right": 15,
"modules-left": ["custom/launcher", "custom/files", "clock", "network", "temperature", "cpu", "memory"],
"modules-center": ["hyprland/workspaces"],
"modules-right": ["hyprland/language", "pulseaudio", "battery", "backlight", "pulseaudio#mic", "custom/power"],
"custom/launcher": { "format": "", "tooltip": false, "on-click": "launcher.sh" },
"custom/files": { "format": "", "tooltip": false, "on-click": "files" },
"custom/power": { "format": "", "tooltip": false, "on-click": "power-menu" },
"hyprland/workspaces": { "format": "{id}", "persistent-workspaces": { "*": 5 } },
"hyprland/language": { "format": "{short}" },
"clock": { "format": "{:%H:%M  |  %d %b}", "tooltip-format": "{:%d %B %Y}" },
"network": {
"format-wifi": " {essid}",
"format-ethernet": " {ifname}",
"format-disconnected": "offline"
},
"cpu": { "format": "CPU {usage}%", "interval": 3 },
"memory": { "format": "RAM {used:0.1f}G", "interval": 5 },
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
window#waybar { background: transparent; color: #d4d4d4; }
#workspaces, #clock, #network, #temperature, #cpu, #memory, #language,
#pulseaudio, #backlight, #battery,
#custom-launcher, #custom-files, #custom-power {
background: rgba(10,10,12,0.72);
border: 2px solid rgba(255,255,255,0.55);
border-radius: 20px;
padding: 0 16px;
margin: 0 4px;
}
#custom-launcher, #custom-files, #custom-power { min-width: 32px; padding: 0; }
#custom-launcher, #custom-files { color: #d8d3bd; }
#custom-power { color: #ff6b6b; border-color: rgba(255,107,107,0.55); }
#backlight { color: #a5bdff; }
#workspaces { padding: 0 6px; }
#workspaces button { color: #d4d4d4; background: transparent; padding: 0 11px; margin: 4px 0; border-radius: 14px; }
#workspaces button.active { color: #101010; background: #b4b4b4; }
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
hide_on_select=true
EOF
w "$H/.config/wofi/style.css" <<'EOF'
window { background-color: rgba(14,14,16,0.82); border: 1px solid rgba(255,255,255,0.35); border-radius: 8px; font-family: "DejaVu Sans Mono"; font-size: 12px; }
#input { background: transparent; color: #e6e6e6; border: none; margin: 4px; }
#entry { padding: 4px 8px; }
#entry:selected { background-color: rgba(255,255,255,0.18); }
#text { color: #e6e6e6; margin-left: 6px; }
EOF
w "$H/.local/share/applications/cava.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=cava
Exec=cava
NoDisplay=true
EOF
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
# Картинка для fastfetch: положи PNG в ~/.config/fastfetch/logo.png (квадратное, лучше 512x512)
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
w "$H/.local/share/applications/files.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Files
Exec=files %f
Icon=system-file-manager
Terminal=false
Categories=System;FileManager;
MimeType=inode/directory;
StartupWMClass=files
EOF
w "$H/.local/share/applications/musicplayer.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Music Player
Exec=musicplayer
Icon=audio-x-generic
Terminal=false
Categories=Audio;Music;Player;
StartupWMClass=musicplayer
EOF
w "$H/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Adwaita
EOF
w "$H/.local/share/applications/deb-install.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Установщик .deb
Exec=deb-install %f
Terminal=false
NoDisplay=true
MimeType=application/vnd.debian.binary-package;application/x-deb;
EOF
w "$H/.config/mimeapps.list" <<'EOF'
[Default Applications]
application/vnd.debian.binary-package=deb-install.desktop
application/x-deb=deb-install.desktop
inode/directory=files.desktop
image/png=firefox-esr.desktop
image/jpeg=firefox-esr.desktop
image/gif=firefox-esr.desktop
image/webp=firefox-esr.desktop
image/svg+xml=firefox-esr.desktop
application/pdf=firefox-esr.desktop
video/mp4=firefox-esr.desktop
video/webm=firefox-esr.desktop
audio/mpeg=firefox-esr.desktop
audio/ogg=firefox-esr.desktop
audio/flac=firefox-esr.desktop
audio/x-wav=firefox-esr.desktop
x-scheme-handler/http=firefox-esr.desktop
x-scheme-handler/https=firefox-esr.desktop
text/html=firefox-esr.desktop
EOF
w "$H/.config/hypr/wallpaper.sh" <<'EOF'
#!/bin/sh
# Обои: положи картинки в ~/Pictures/wall, Super+W - следующая
D="$HOME/Pictures/wall"; C="$HOME/.cache/wallpaper"
list="$(ls "$D"/*.png "$D"/*.jpg "$D"/*.jpeg "$D"/*.webp 2>/dev/null)"
pkill swaybg 2>/dev/null
[ -n "$list" ] || exec swaybg -c 0a0a12
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
grep -qF 'e[90m' "$H/.bashrc" || cat >> "$H/.bashrc" <<'EOF'
PS1='\[\e[90m\] \[\e[97m\]\u \[\e[90m\] \[\e[37m\]\w \[\e[0m\]\$ '
EOF
if ! grep -qs 'Hyprland' "$H/.bash_profile"; then
cat >> "$H/.bash_profile" <<'EOF'
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = 1 ]; then
Hyprland || exec bash
fi
EOF
fi
mkdir -p "$H/Pictures/wall"
chown -R "$U:$U" "$H/.config" "$H/Pictures" "$H/.bash_profile" "$H/.bashrc" \
"$H/.local" 2>/dev/null || true
gh_deb() {
local repo="$1" name="$2" re="$3" json url sums want have
json="$(curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=10" 2>/dev/null || true)"
url="$(printf '%s' "$json" | grep -o 'https://[^"]*\.deb' | grep -viE 'arm|aarch' | grep -iE "$re" | head -n1 || true)"
if [ -z "$url" ]; then
url="$(printf '%s' "$json" | grep -o 'https://[^"]*\.deb' | grep -viE 'arm|aarch' | head -n1 || true)"
fi
if [ -z "$url" ] || ! curl -fL -o "/tmp/$name.deb" "$url"; then
echo "!! $name не скачался автоматически. Скачай .deb (Linux x64) со страницы"
echo "!! https://github.com/$repo/releases и открой его в файловом менеджере (Super+E) двойным щелчком."
return 0
fi
sums="$(curl -fsSL "${url%/*}/SHA256SUMS.txt" 2>/dev/null || true)"
if [ -n "$sums" ]; then
want="$(printf '%s\n' "$sums" | grep -F "$(basename "$url")" | awk '{print $1}' | head -n1 || true)"
have="$(sha256sum "/tmp/$name.deb" | awk '{print $1}')"
if [ -n "$want" ] && [ "$want" != "$have" ]; then
echo "!! $name: контрольная сумма НЕ совпала, пакет не устанавливаю"
rm -f "/tmp/$name.deb"
return 0
fi
fi
apt-get install -y --no-install-recommends "/tmp/$name.deb" \
|| echo "!! $name не установился (скрипт продолжает работу)"
rm -f "/tmp/$name.deb"
}
install_deb_url() {
local url="$1" name="$2"
if ! curl -fL -o "/tmp/$name.deb" "$url"; then
echo "!! $name не скачался ($url)."
echo "!! Скачай .deb вручную с сайта разработчика и открой его двойным щелчком в Files (Super+E)."
return 0
fi
apt-get install -y --no-install-recommends "/tmp/$name.deb" \
|| echo "!! $name не установился (скрипт продолжает работу)"
rm -f "/tmp/$name.deb"
}
install_extras() {
apt-get install -y --no-install-recommends nodejs libgl1-mesa-dri openjdk-21-jre \
|| echo "!! nodejs/Java не поставились (нужны для YouTube в плеере и для Minecraft)"
apt-get install -y --no-install-recommends openjdk-17-jre >/dev/null 2>&1 \
|| echo "-- openjdk-17 нет в репозитории (нужен только для старых версий Minecraft)"
if curl -fL --retry 3 -o /usr/local/bin/yt-dlp.new https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp; then
chmod 755 /usr/local/bin/yt-dlp.new && mv -f /usr/local/bin/yt-dlp.new /usr/local/bin/yt-dlp
else
rm -f /usr/local/bin/yt-dlp.new
echo "!! свежий yt-dlp не скачался (GitHub недоступен? включи VPN), остаётся версия из apt"
fi
local P=/opt/prismlauncher
if [ ! -x "$P/squashfs-root/AppRun" ]; then
mkdir -p "$P"; rm -rf "$P/squashfs-root"
if curl -fL --retry 3 -o "$P/Prism.AppImage" https://github.com/PrismLauncher/PrismLauncher/releases/latest/download/PrismLauncher-Linux-x86_64.AppImage; then
chmod 755 "$P/Prism.AppImage"
( cd "$P" && ./Prism.AppImage --appimage-extract >/dev/null 2>&1 && rm -f Prism.AppImage ) || true
fi
fi
if [ -x "$P/squashfs-root/AppRun" ]; then
cat > /usr/local/bin/prismlauncher <<'PRISM_EOF'
#!/bin/sh
exec /opt/prismlauncher/squashfs-root/AppRun "$@"
PRISM_EOF
chmod 755 /usr/local/bin/prismlauncher
local ICON
ICON="$(find "$P/squashfs-root" -maxdepth 1 -name '*.png' 2>/dev/null | head -n1)"
cat > /usr/share/applications/prismlauncher.desktop <<DESK_EOF
[Desktop Entry]
Type=Application
Name=Prism Launcher
Comment=Minecraft launcher
Exec=prismlauncher
Icon=${ICON:-applications-games}
Terminal=false
Categories=Game;
DESK_EOF
echo "ok: Prism Launcher"
elif curl -fsSL https://prism-launcher-for-debian.github.io/repo/prismlauncher.gpg -o /usr/share/keyrings/prismlauncher-archive-keyring.gpg \
&& echo "deb [signed-by=/usr/share/keyrings/prismlauncher-archive-keyring.gpg] https://prism-launcher-for-debian.github.io/repo trixie main" > /etc/apt/sources.list.d/prismlauncher.list \
&& apt-get update && apt-get install -y prismlauncher; then
echo "ok: Prism Launcher из репозитория"
else
rm -f /etc/apt/sources.list.d/prismlauncher.list
echo "!! Prism не поставился: нет доступа к GitHub. Включи VPN (Happ) и запусти install.sh ещё раз."
fi
}
if command -v curl >/dev/null 2>&1; then
install_deb_url https://github.com/Happ-proxy/happ-desktop/releases/latest/download/Happ.linux.x64.deb happ
gh_deb storytold/photocraft photocraft 'amd64|x86_64|x64'
install_deb_url https://github.com/ONLYOFFICE/DesktopEditors/releases/latest/download/onlyoffice-desktopeditors_amd64.deb onlyoffice
install_extras
else
echo "!! curl не установился - дополнительные приложения пропущены"
fi
apt-get clean
echo
echo "Готово. ПЕРЕЗАГРУЗИСЬ (reboot)."
echo "После входа на TTY1 Hyprland запустится сам."
echo "NVIDIA: драйверы удалены и не устанавливаются - система работает на встройке."
echo "Steam: запусти из лаунчера (Super+D) уже после входа в Hyprland."
echo
echo "Горячие клавиши:"
echo "  Super+M           - Music Player"
echo "  Super+W           - следующие обои (картинки в ~/Pictures/wall)"
echo "  Super+Shift+Esc   - меню питания (повторное нажатие закрывает)"
echo "  Super+Q           - закрыть активное окно"
echo "  Super+Shift+Q     - зажать и водить курсором (закрывает окна под курсором)"
