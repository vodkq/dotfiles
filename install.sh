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
telegram-desktop curl
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
import os
import re
import subprocess
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GLib, Gtk

LOCK = "/tmp/power-menu.pid"
CSS = b"""
* { font-family: "DejaVu Sans Mono", "FontAwesome", monospace; }
window { background-color: rgba(6,6,8,0.60); }
.card { background-color: rgba(14,14,16,0.80); border: 1px solid rgba(255,255,255,0.40);
border-radius: 20px; padding: 22px 24px 14px 24px; }
button { background-image: none; background-color: rgba(255,255,255,0.05); color: #e6e6e6;
border: 1px solid rgba(255,255,255,0.28); border-radius: 16px; box-shadow: none; padding: 0; }
button:hover, button:focus { background-color: rgba(255,255,255,0.16); border-color: rgba(255,255,255,0.80); }
button.danger { color: #ff8a80; border-color: rgba(255,107,107,0.45); }
button.danger:hover, button.danger:focus { background-color: rgba(255,107,107,0.22); border-color: rgba(255,107,107,0.90); }
.icon { font-size: 30px; }
.name { font-size: 11px; }
.key { color: #8a8a8a; font-size: 9px; }
.hint { color: #6f6f6f; font-size: 9px; }
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
        os.kill(pid, 0)
        return pid
    except Exception:
        return 0

class PowerMenu(Gtk.Window):
    def __init__(self):
        super().__init__()
        self.set_decorated(False)
        self.set_app_paintable(True)
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
        with open(LOCK, "w") as f:
            f.write(str(os.getpid()))

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
        if cmd == "exit":
            subprocess.Popen(["hyprctl", "dispatch", "exit"])
        else:
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
    pid = running()
    if pid:
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
    w.buttons[0].grab_focus()
    Gtk.main()

if __name__ == "__main__":
    main()
EOF
chmod 755 /usr/local/bin/power-menu
w() {
mkdir -p "$(dirname "$1")"
if [ -f "$1" ]; then cp -f "$1" "$1.bak"; fi
cat > "$1"
}
rm -f "$H/.config/hypr/quick-kill.sh"
w "$H/.config/hypr/hyprland.conf" <<'EOF'
monitor = , preferred, auto, 1
$mod = SUPER
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = sh ~/.config/hypr/wallpaper.sh
exec-once = waybar
exec-once = lxqt-policykit-agent
input {
kb_layout = us,ru
follow_mouse = 1
repeat_rate = 40
repeat_delay = 250
kb_options = grp:alt_shift_toggle
touchpad {
natural_scroll = true
}
}
general {
gaps_in = 6
gaps_out = 10
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
focus_on_close = 1
disable_hyprland_logo = true
disable_splash_rendering = true
}
bind = $mod, Return, exec, kitty sh ~/.config/fastfetch/show.sh
bind = $mod, D, exec, launcher.sh
bind = $mod, B, exec, firefox-esr
bind = $mod, E, exec, files
bind = $mod, M, exec, limusic
bind = $mod, W, exec, sh ~/.config/hypr/wallpaper.sh next
bind = $mod, Q, killactive
binde = $mod SHIFT, Q, killactive
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
"layer": "top", "height": 24, "margin-top": 5, "margin-left": 8, "margin-right": 8,
"modules-left": ["hyprland/workspaces", "hyprland/window"],
"modules-center": ["custom/launcher", "custom/files", "hyprland/language", "clock", "cpu", "memory", "temperature"],
"modules-right": ["network", "pulseaudio", "pulseaudio#mic", "backlight", "battery", "custom/power"],
"custom/launcher": { "format": "", "tooltip": false, "on-click": "launcher.sh" },
"custom/files": { "format": "", "tooltip": false, "on-click": "files" },
"custom/power": { "format": "", "tooltip": false, "on-click": "power-menu" },
"hyprland/workspaces": { "format": "{id}", "persistent-workspaces": { "*": 5 } },
"hyprland/window": { "format": "{title}", "max-length": 30, "separate-outputs": true },
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
* { font-family: "DejaVu Sans Mono", "FontAwesome"; font-size: 10px; border: none; min-height: 0; }
window#waybar { background: transparent; color: #d4d4d4; }
#workspaces, #window, #clock, #network, #temperature, #cpu, #memory, #language,
#pulseaudio, #backlight, #battery,
#custom-launcher, #custom-files, #custom-power {
background: rgba(10,10,12,0.72);
border: 1px solid rgba(255,255,255,0.5);
border-radius: 12px;
padding: 0 9px;
margin: 0 2px;
}
#custom-launcher, #custom-files, #custom-power { min-width: 22px; padding: 0; }
#custom-launcher, #custom-files { color: #d8d3bd; }
#custom-power { color: #ff6b6b; border-color: rgba(255,107,107,0.55); }
#backlight { color: #a5bdff; }
#window { color: #b4b4b4; }
window#waybar.empty #window { background: transparent; border-color: transparent; }
#workspaces { padding: 0 3px; }
#workspaces button { color: #d4d4d4; background: transparent; padding: 0 7px; margin: 2px 0; border-radius: 9px; }
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
install_limusic() {
local json url
json="$(curl -fsSL https://api.github.com/repos/SimoHypers/limusic/releases/latest 2>/dev/null || true)"
url="$(printf '%s' "$json" | grep -o 'https://[^"]*\.deb' | grep -iE 'amd64|x86_64' | head -n1 || true)"
if [ -n "$url" ] && curl -fL --retry 3 -o /tmp/limusic.deb "$url" && apt-get install -y --no-install-recommends /tmp/limusic.deb; then
echo "ok: Limusic установлен (Super+M)"
else
echo "!! Limusic не поставился (нет доступа к GitHub?). Включи VPN и запусти скрипт ещё раз,"
echo "   либо скачай .deb вручную: https://github.com/SimoHypers/limusic/releases/latest  и  sudo apt install ./файл.deb"
fi
rm -f /tmp/limusic.deb
}
install_extras() {
apt-get install -y --no-install-recommends libgl1-mesa-dri openjdk-21-jre \
|| echo "!! Java не поставилась (нужна для Minecraft)"
apt-get install -y --no-install-recommends openjdk-17-jre >/dev/null 2>&1 \
|| echo "-- openjdk-17 нет в репозитории (нужен только для старых версий Minecraft)"
rm -f /usr/local/bin/musicplayer; rm -rf "$H/.local/share/musicplayer" "$H/.local/share/applications/musicplayer.desktop"
install_limusic
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
echo "=== Чистка мусора ==="
apt-get autoremove -y --purge || true
rc="$(dpkg -l | awk '/^rc/ {print $2}')"
[ -z "$rc" ] || apt-get purge -y $rc || true
apt-get clean
journalctl --vacuum-size=50M >/dev/null 2>&1 || true
rm -f /tmp/*.deb /tmp/power-menu.pid
rm -rf "$H/.cache/thumbnails"
echo
echo "Готово. ПЕРЕЗАГРУЗИСЬ (reboot)."
echo "После входа на TTY1 Hyprland запустится сам."
echo "NVIDIA: драйверы удалены и не устанавливаются - система работает на встройке."
echo "Steam: запусти из лаунчера (Super+D) уже после входа в Hyprland."
echo
echo "Горячие клавиши:"
echo "  Super+M           - Limusic (YouTube Music)"
echo "  Super+W           - следующие обои (картинки в ~/Pictures/wall)"
echo "  Super+Shift+Esc   - меню питания (повторное нажатие закрывает)"
echo "  Super+Q           - закрыть активное окно"
echo "  Super+Shift+Q     - зажми и води курсором: окна под ним закрываются подряд"
