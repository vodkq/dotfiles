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
cat > /usr/local/bin/files <<'EOF'
#!/usr/bin/env python3
import json, os, re, shutil, subprocess, sys, threading, time, gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango
HOME = os.path.expanduser("~")
TRASH = os.path.join(HOME, ".local", "share", "Trash")
CSS = b"""
* { font-family: "DejaVu Sans Mono", monospace; font-size: 11px; }
window { background-color: rgba(16,16,18,0.80); color: #e6e6e6; }
.bar { padding: 8px 10px 4px 10px; }
button { background-image: none; background-color: rgba(255,255,255,0.06); color: #e6e6e6; border: 1px solid rgba(255,255,255,0.28); border-radius: 14px; box-shadow: none; padding: 2px 10px; min-height: 0; min-width: 0; }
button:hover { background-color: rgba(255,255,255,0.16); }
button:checked { background-color: rgba(255,255,255,0.28); }
entry { background-image: none; background-color: rgba(255,255,255,0.06); color: #e6e6e6; border: 1px solid rgba(255,255,255,0.28); border-radius: 14px; box-shadow: none; padding: 2px 12px; min-height: 0; }
entry:focus { border-color: rgba(255,255,255,0.65); }
.side { background-color: rgba(255,255,255,0.04); border-right: 1px solid rgba(255,255,255,0.12); }
.side row { padding: 5px 10px; margin: 1px 8px; border-radius: 10px; background: transparent; }
.side row:hover { background-color: rgba(255,255,255,0.08); }
.side row:selected { background-color: rgba(255,255,255,0.20); color: #ffffff; }
.sect { color: #8a8a8a; font-size: 9px; padding: 10px 18px 2px 18px; }
treeview.view { background-color: transparent; color: #e6e6e6; }
treeview.view:hover { background-color: rgba(255,255,255,0.07); }
treeview.view:selected { background-color: rgba(255,255,255,0.22); color: #ffffff; }
treeview header button { background-color: transparent; border: none; border-radius: 0; border-bottom: 1px solid rgba(255,255,255,0.15); color: #8a8a8a; padding: 3px 8px; }
scrolledwindow, viewport { background-color: transparent; }
scrollbar slider { background-color: rgba(255,255,255,0.30); border-radius: 4px; min-width: 6px; min-height: 6px; }
scrollbar { background: transparent; border: none; }
.status { color: #8a8a8a; padding: 3px 14px 6px 14px; }
.err { color: #ff8a80; }
menu, .menu { background-color: rgb(24,24,28); color: #e6e6e6; border: 1px solid rgba(255,255,255,0.25); border-radius: 8px; padding: 4px; }
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
out = subprocess.run(["lsblk", "-J", "-o", "NAME,LABEL,SIZE,FSTYPE,MOUNTPOINT,PATH"], capture_output=True, text=True, timeout=5).stdout
data = json.loads(out)
except Exception: return []
res = []
def walk(nodes):
for n in nodes:
mp = n.get("mountpoint") or next((m for m in (n.get("mountpoints") or []) if m), None)
fs = n.get("fstype")
if fs and fs not in ("swap", "crypto_LUKS") and (not mp or mp.startswith(("/media", "/run/media", "/mnt"))):
res.append(dict(path=n.get("path"), label=n.get("label") or n.get("name"), size=n.get("size") or "", fstype=fs, mp=mp))
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
self.cwd, self.hist, self.fwd, self.hidden, self.sort, self.clip, self.dev_rows, self.sizes = None, [], [], False, ("name", False), ([], False), [], {}
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
for w in (self.b_back, self.b_fwd, self.b_up): bar.pack_start(w, False, False, 0)
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
try: prov.load_from_data(rule)
except GLib.Error: continue
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
if os.path.isdir(path): self.side.add(self.side_row(icon, name, ("dir", path)))
self.side.add(self.side_row("user-trash-symbolic", "Корзина", ("dir", os.path.join(TRASH, "files"))))
self.dev_head = self.side_section("ДИСКИ")
self.head_added = False
def refresh_devices(self):
threading.Thread(target=lambda: GLib.idle_add(self.show_devices, list_devices()), daemon=True).start()
def on_timer(self):
if self.is_active(): self.refresh_devices()
return True
def show_devices(self, devs):
for r in self.dev_rows: self.side.remove(r)
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
if not data: return
kind, val = data
if kind == "dir":
if val.startswith(TRASH): os.makedirs(val, exist_ok=True)
self.load(val)
else: self.mount_and_open(val)
def on_side_click(self, box, ev):
if ev.button != 3: return False
row = box.get_row_at_y(int(ev.y))
data = getattr(row, "fm_data", None) if row else None
if not data or data[0] != "dev": return False
d = data[1]
menu = Gtk.Menu()
it = Gtk.MenuItem(label="Отключить" if d["mp"] else "Подключить")
it.connect("activate", lambda *_: self.unmount(d) if d["mp"] else self.mount_and_open(d))
menu.append(it)
menu.show_all()
menu.popup_at_pointer(ev)
return True
def say(self, text, err=False):
ctx = self.status.get_style_context()
if err: ctx.add_class("err")
else: ctx.remove_class("err")
self.status.set_text(text)
return False
def read_dir(self, path):
attrs = "standard::name,standard::type,standard::size,standard::symbolic-icon,standard::icon,time::modified"
items = []
en = Gio.File.new_for_path(path).enumerate_children(attrs, Gio.FileQueryInfoFlags.NONE, None)
while True:
info = en.next_file(None)
if info is None: break
name = info.get_name()
if not self.hidden and name.startswith("."): continue
icon = info.get_symbolic_icon() or info.get_icon()
items.append(Item(name, os.path.join(path, name), info.get_file_type() == Gio.FileType.DIRECTORY, info.get_size(), info.get_attribute_uint64("time::modified"), icon))
en.close(None)
return items
def sort_items(self, items):
key, rev = self.sort
if key == "size": kf = lambda i: (i.size, i.name.lower())
elif key == "date": kf = lambda i: (i.mtime, i.name.lower())
else: kf = lambda i: i.name.lower()
dirs = sorted([i for i in items if i.isdir], key=kf, reverse=rev)
files = sorted([i for i in items if not i.isdir], key=kf, reverse=rev)
return dirs + files
def load(self, path, push=True, select=None):
path = os.path.realpath(os.path.expanduser(path))
try: items = self.read_dir(path)
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
self.store.append([it.icon, it.name, "" if it.isdir else human(it.size), time.strftime("%d.%m.%Y %H:%M", time.localtime(it.mtime)), it.isdir, it.path])
shown = path.replace(HOME, "~", 1) if path.startswith(HOME) else path
self.entry.set_text(shown)
self.set_title(os.path.basename(path) or "/")
self.b_back.set_sensitive(bool(self.hist))
self.b_fwd.set_sensitive(bool(self.fwd))
self.b_up.set_sensitive(path != "/")
self.side.unselect_all()
for row in self.side.get_children():
data = getattr(row, "fm_data", None)
if data and data[0] == "dir" and data[1] == path: self.side.select_row(row)
if select: self.select_name(select)
self.update_status()
self.view.grab_focus()
return False
def reload(self, select=None): self.load(self.cwd, push=False, select=select)
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
if total_size: text += f"  ·  {human(total_size)}"
self.say(text)
else: self.say(f"{total} элементов" if total else "Папка пуста")
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
if parent != self.cwd: self.load(parent, select=os.path.basename(self.cwd))
def on_entry(self, entry):
p = os.path.expanduser(entry.get_text().strip())
if os.path.isdir(p): self.load(p)
elif os.path.exists(p): self.load(os.path.dirname(p), select=os.path.basename(p))
else: self.say("Нет такого пути: " + p, True)
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
if row[4]: self.load(row[5])
else: self.open_path(row[5])
def open_path(self, path):
if path.lower().endswith(".deb") and shutil.which("deb-install"):
subprocess.Popen(["deb-install", path], start_new_session=True)
self.say("Устанавливаю: " + os.path.basename(path))
return
try:
if Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(path).get_uri(), None): return
except GLib.Error: pass
ctype, _ = Gio.content_type_guess(path, None)
try:
if Gio.content_type_is_a(ctype, "text/plain") and shutil.which("nano"): subprocess.Popen(["kitty", "nano", path], start_new_session=True)
else: subprocess.Popen(["firefox-esr", path], start_new_session=True)
except Exception as e: self.say(f"Нечем открыть ({ctype}): {e}", True)
def selected_rows(self):
_, rows = self.view.get_selection().get_selected_rows()
return rows
def selected_paths(self): return [self.store[r][5] for r in self.selected_rows()]
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
if os.path.isdir(src) and (dst + os.sep).startswith(src + os.sep): raise OSError("нельзя вставить папку саму в себя")
if cut: shutil.move(src, dst)
elif os.path.isdir(src): shutil.copytree(src, dst, symlinks=True)
else: shutil.copy2(src, dst)
except Exception as e: errs.append(str(e))
GLib.idle_add(self.after_paste, cut, errs)
self.say("Копирую…")
threading.Thread(target=work, daemon=True).start()
def after_paste(self, cut, errs):
if cut: self.clip = ([], False)
self.reload()
if errs: self.say("Ошибка: " + errs[0], True)
return False
def trash(self):
paths = self.selected_paths()
if not paths: return
in_trash = self.cwd.startswith(os.path.join(TRASH, "files"))
if in_trash:
dlg = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION, buttons=Gtk.ButtonsType.YES_NO, text=f"Удалить навсегда ({len(paths)})?")
resp = dlg.run()
dlg.destroy()
if resp != Gtk.ResponseType.YES: return
errs = []
for p in paths:
try:
if in_trash:
shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.remove(p)
info = os.path.join(TRASH, "info", os.path.basename(p) + ".trashinfo")
if os.path.exists(info): os.remove(info)
else: Gio.File.new_for_path(p).trash(None)
except Exception as e: errs.append(getattr(e, "message", str(e)))
self.reload()
if errs: self.say("Ошибка: " + errs[0], True)
def start_rename(self):
rows = self.selected_rows()
if len(rows) != 1: return
self.name_r.set_property("editable", True)
self.view.set_cursor(rows[0], self.name_col, True)
def on_edited(self, renderer, path, text):
renderer.set_property("editable", False)
old = self.store[path][1]
text = text.strip()
if not text or text == old or "/" in text: return
try: os.rename(os.path.join(self.cwd, old), os.path.join(self.cwd, text))
except OSError as e:
self.say("Ошибка: " + e.strerror, True)
return
self.reload(select=text)
def new_folder(self):
path = unique(self.cwd, "Новая папка")
try: os.mkdir(path)
except OSError as e:
self.say("Ошибка: " + e.strerror, True)
return
self.reload(select=os.path.basename(path))
self.start_rename()
def on_view_click(self, view, ev):
if ev.button != 3: return False
hit = view.get_path_at_pos(int(ev.x), int(ev.y))
sel = view.get_selection()
if hit:
if not sel.path_is_selected(hit[0]):
sel.unselect_all()
sel.select_path(hit[0])
else: sel.unselect_all()
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
if typing: return False
if alt and key == "Left": self.go_back()
elif alt and key == "Right": self.go_forward()
elif (alt and key == "Up") or key == "BackSpace": self.go_up()
elif key == "F5": self.reload()
elif key == "F2": self.start_rename()
elif key == "Delete": self.trash()
elif ctrl and shift and key in ("n", "N"): self.new_folder()
elif ctrl and key in ("c", "C"): self.copy(False)
elif ctrl and key in ("x", "X"): self.copy(True)
elif ctrl and key in ("v", "V"): self.paste()
elif ctrl and key in ("h", "H"): self.b_hidden.set_active(not self.b_hidden.get_active())
else: return False
return True
def main():
GLib.set_prgname("files")
GLib.set_application_name("Files")
start, select = HOME, None
if len(sys.argv) > 1:
p = os.path.abspath(os.path.expanduser(sys.argv[1]))
if os.path.isdir(p): start = p
elif os.path.exists(p): start, select = os.path.dirname(p), os.path.basename(p)
win = FilesWindow(start, select)
win.connect("destroy", Gtk.main_quit)
win.show_all()
Gtk.main()
if __name__ == "__main__": main()
EOF
chmod 755 /usr/local/bin/files
cat > /usr/local/bin/power-menu <<'EOF'
#!/usr/bin/env python3
import gi, os, sys, subprocess
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
with open(LOCK) as f: pid = int(f.read().strip())
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
if visual: self.set_visual(visual)
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
for label, cmd, rgb in (("Выключить", "poweroff", (0.80, 0.20, 0.20)), ("Перезагрузить", "reboot", (0.85, 0.55, 0.15)), ("Спящий режим", "suspend", (0.25, 0.45, 0.85))):
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
with open(LOCK, "w") as f: f.write(str(os.getpid()))
def on_key(self, w, ev):
if Gdk.keyval_name(ev.keyval) == "Escape":
self.quit()
return True
return False
def run(self, cmd):
subprocess.Popen(["systemctl", cmd])
self.quit()
def quit(self):
try: os.remove(LOCK)
except OSError: pass
self.destroy()
Gtk.main_quit()
def main():
GLib.set_prgname("power-menu")
GLib.set_application_name("power-menu")
if running():
with open(LOCK) as f: pid = int(f.read().strip())
try: os.kill(pid, 15)
except OSError: pass
try: os.remove(LOCK)
except OSError: pass
return
w = PowerMenu()
w.connect("destroy", Gtk.main_quit)
w.show_all()
Gtk.main()
if __name__ == "__main__": main()
EOF
chmod 755 /usr/local/bin/power-menu
cat > /usr/local/bin/musicplayer <<'MPLAYER_EOF'
#!/usr/bin/env python3
import sys, json, sqlite3
from pathlib import Path
from datetime import datetime
from typing import List, Dict, Optional
from PyQt6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QPushButton, QLabel, QLineEdit, QListWidget, QListWidgetItem, QSlider, QInputDialog, QStackedWidget)
from PyQt6.QtCore import Qt, QThread, pyqtSignal, QTimer
from PyQt6.QtGui import QFont
import vlc
import yt_dlp

CONFIG_DIR = Path.home() / ".config" / "musicplayer"
CACHE_DIR = Path.home() / ".cache" / "musicplayer"
DB_PATH = CONFIG_DIR / "music.db"
CONFIG_PATH = CONFIG_DIR / "config.json"
CONFIG_DIR.mkdir(parents=True, exist_ok=True)
CACHE_DIR.mkdir(parents=True, exist_ok=True)

class Database:
def __init__(self):
self.conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
self.cursor = self.conn.cursor()
self.cursor.execute('CREATE TABLE IF NOT EXISTS tracks (id TEXT PRIMARY KEY, title TEXT, artist TEXT, source TEXT, url TEXT, duration INTEGER, thumbnail TEXT, added_at TIMESTAMP)')
self.cursor.execute('CREATE TABLE IF NOT EXISTS playlists (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, created_at TIMESTAMP)')
self.cursor.execute('CREATE TABLE IF NOT EXISTS playlist_tracks (playlist_id INTEGER, track_id TEXT, FOREIGN KEY (playlist_id) REFERENCES playlists(id), FOREIGN KEY (track_id) REFERENCES tracks(id))')
self.cursor.execute('CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY AUTOINCREMENT, track_id TEXT, played_at TIMESTAMP, FOREIGN KEY (track_id) REFERENCES tracks(id))')
self.conn.commit()
def add_track(self, track: Dict):
try:
self.cursor.execute('INSERT OR REPLACE INTO tracks (id, title, artist, source, url, duration, thumbnail, added_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
(track['id'], track['title'], track['artist'], track['source'], track['url'], track.get('duration', 0), track.get('thumbnail', ''), datetime.now().isoformat()))
self.conn.commit()
except Exception as e: print(f"Ошибка добавления трека: {e}")
def create_playlist(self, name: str) -> int:
try:
self.cursor.execute('INSERT INTO playlists (name, created_at) VALUES (?, ?)', (name, datetime.now().isoformat()))
self.conn.commit()
return self.cursor.lastrowid
except Exception: return -1
def get_playlists(self) -> List[Dict]:
self.cursor.execute('SELECT id, name FROM playlists ORDER BY name')
return [{'id': row[0], 'name': row[1]} for row in self.cursor.fetchall()]
def get_playlist_tracks(self, playlist_id: int) -> List[Dict]:
self.cursor.execute('SELECT t.* FROM tracks t JOIN playlist_tracks pt ON t.id = pt.track_id WHERE pt.playlist_id = ?', (playlist_id,))
columns = [col[0] for col in self.cursor.description]
return [dict(zip(columns, row)) for row in self.cursor.fetchall()]
def add_to_history(self, track_id: str):
try:
self.cursor.execute('INSERT INTO history (track_id, played_at) VALUES (?, ?)', (track_id, datetime.now().isoformat()))
self.conn.commit()
except Exception: pass
def get_history(self, limit: int = 50) -> List[Dict]:
self.cursor.execute('SELECT t.* FROM tracks t JOIN history h ON t.id = h.track_id ORDER BY h.played_at DESC LIMIT ?', (limit,))
columns = [col[0] for col in self.cursor.description]
return [dict(zip(columns, row)) for row in self.cursor.fetchall()]

class YouTubeClient:
def __init__(self):
self.ydl_opts = {'format': 'bestaudio/best', 'quiet': True, 'no_warnings': True, 'extract_flat': False}
def search(self, query: str, limit: int = 20) -> List[Dict]:
try:
with yt_dlp.YoutubeDL(self.ydl_opts) as ydl:
info = ydl.extract_info(f"ytsearch{limit}:{query}", download=False)
return [{'id': entry['id'], 'title': entry.get('title', 'Unknown'), 'artist': entry.get('uploader', 'Unknown'), 'source': 'youtube', 'url': entry.get('webpage_url', ''), 'duration': entry.get('duration', 0), 'thumbnail': entry.get('thumbnail', '')} for entry in info.get('entries', []) if entry]
except Exception as e:
print(f"Ошибка поиска YouTube: {e}")
return []
def get_stream_url(self, url: str) -> Optional[str]:
try:
with yt_dlp.YoutubeDL(self.ydl_opts) as ydl:
info = ydl.extract_info(url, download=False)
if 'entries' in info: info = info['entries'][0]
audio_formats = [f for f in info.get('formats', []) if f.get('acodec') != 'none']
return audio_formats[-1].get('url') if audio_formats else info.get('url')
except Exception: return None

class AudioPlayer:
def __init__(self):
self.instance = vlc.Instance('--quiet')
self.player = self.instance.media_player_new()
self.current_track: Optional[Dict] = None
self.is_playing: bool = False
def play(self, track: Dict):
self.current_track = track
stream_url = YouTubeClient().get_stream_url(track['url']) if track['source'] == 'youtube' else track['url']
if stream_url:
self.player.set_media(self.instance.media_new(stream_url))
self.player.play()
self.is_playing = True
def pause(self):
if self.is_playing: self.player.pause(); self.is_playing = False
else: self.player.play(); self.is_playing = True
def set_volume(self, volume: int): self.player.audio_set_volume(volume)
def get_position(self) -> float: return self.player.get_position()
def set_position(self, position: float): self.player.set_position(position)
def get_duration(self) -> int: return self.player.get_length() // 1000
def get_time(self) -> int: return self.player.get_time() // 1000

class ThemeManager:
def __init__(self):
self.themes = {
"dark": {"bg": "#1e1e1e", "fg": "#ffffff", "primary": "#3b82f6", "accent": "#8b5cf6", "border": "#374151"},
"nord": {"bg": "#2e3440", "fg": "#eceff4", "primary": "#88c0d0", "accent": "#b48ead", "border": "#3b4252"},
"dracula": {"bg": "#282a36", "fg": "#f8f8f2", "primary": "#bd93f9", "accent": "#ff79c6", "border": "#44475a"}
}
self.current_theme = {"theme": "dark", "border_radius": 8, "font_size": 14}
if CONFIG_PATH.exists():
with open(CONFIG_PATH, 'r') as f: self.current_theme = json.load(f)
def save_config(self):
with open(CONFIG_PATH, 'w') as f: json.dump(self.current_theme, f, indent=2)
def get_stylesheet(self) -> str:
c = self.themes[self.current_theme["theme"]]
r, fs = self.current_theme.get("border_radius", 8), self.current_theme.get("font_size", 14)
return f"""
QMainWindow, QWidget {{ background-color: {c['bg']}; color: {c['fg']}; font-size: {fs}px; }}
QPushButton {{ background-color: {c['primary']}; color: white; border: none; border-radius: {r}px; padding: 8px 16px; font-weight: bold; }}
QPushButton:hover {{ background-color: {c['accent']}; }}
QLineEdit {{ background-color: {c['bg']}; color: {c['fg']}; border: 2px solid {c['border']}; border-radius: {r}px; padding: 8px; }}
QListWidget {{ background-color: {c['bg']}; color: {c['fg']}; border: none; border-radius: {r}px; }}
QListWidget::item:selected {{ background-color: {c['primary']}; }}
QSlider::groove:horizontal {{ background: {c['border']}; height: 6px; border-radius: 3px; }}
QSlider::handle:horizontal {{ background: {c['primary']}; width: 16px; margin: -5px 0; border-radius: 8px; }}
"""

class SearchWorker(QThread):
finished = pyqtSignal(list)
def __init__(self, query: str):
super().__init__()
self.query = query
def run(self):
self.finished.emit(YouTubeClient().search(self.query))

class MainWindow(QMainWindow):
def __init__(self):
super().__init__()
self.db, self.player, self.theme_manager = Database(), AudioPlayer(), ThemeManager()
self.setWindowTitle("Music Player")
self.setMinimumSize(1000, 700)
self._create_ui()
self._apply_theme()
self.progress_timer = QTimer()
self.progress_timer.timeout.connect(self._update_progress)
self.progress_timer.start(1000)
def _create_ui(self):
central = QWidget()
self.setCentralWidget(central)
layout = QHBoxLayout(central)
layout.setContentsMargins(0, 0, 0, 0)
sidebar = QWidget()
sidebar.setFixedWidth(200)
slayout = QVBoxLayout(sidebar)
logo = QLabel("Music Player")
logo.setFont(QFont("DejaVu Sans", 16, QFont.Weight.Bold))
logo.setAlignment(Qt.AlignmentFlag.AlignCenter)
slayout.addWidget(logo)
for text, cb in [("Главная", self._show_home), ("Поиск", self._show_search), ("Плейлисты", self._show_playlists)]:
btn = QPushButton(text); btn.setCheckable(True); btn.clicked.connect(cb); slayout.addWidget(btn)
layout.addWidget(sidebar)
self.stack = QStackedWidget()
layout.addWidget(self.stack, 1)
home = QWidget(); h_l = QVBoxLayout(home)
h_title = QLabel("Недавно прослушано")
h_title.setFont(QFont("DejaVu Sans", 16, QFont.Weight.Bold))
h_l.addWidget(h_title)
self.history_list = QListWidget(); self.history_list.itemDoubleClicked.connect(self._play_from_list); h_l.addWidget(self.history_list)
self.stack.addWidget(home)
search = QWidget(); s_l = QVBoxLayout(search)
s_layout = QHBoxLayout()
self.search_input = QLineEdit(); self.search_input.setPlaceholderText("Поиск трека..."); self.search_input.returnPressed.connect(self._perform_search); s_layout.addWidget(self.search_input)
s_btn = QPushButton("Поиск"); s_btn.clicked.connect(self._perform_search); s_layout.addWidget(s_btn)
s_l.addLayout(s_layout)
self.search_results = QListWidget(); self.search_results.itemDoubleClicked.connect(self._play_from_list); s_l.addWidget(self.search_results)
self.stack.addWidget(search)
playlists = QWidget(); p_l = QVBoxLayout(playlists)
p_title = QLabel("Мои плейлисты")
p_title.setFont(QFont("DejaVu Sans", 16, QFont.Weight.Bold))
p_l.addWidget(p_title)
create_btn = QPushButton("+ Создать плейлист"); create_btn.clicked.connect(self._create_playlist); p_l.addWidget(create_btn)
self.playlists_list = QListWidget(); self.playlists_list.itemDoubleClicked.connect(self._open_playlist); p_l.addWidget(self.playlists_list)
self.stack.addWidget(playlists)
bar = QWidget(); bar.setFixedHeight(90); b_l = QHBoxLayout(bar)
self.track_title = QLabel("Нет трека")
self.track_title.setFont(QFont("DejaVu Sans", 12, QFont.Weight.Bold))
self.track_artist = QLabel("")
info_l = QVBoxLayout(); info_l.addWidget(self.track_title); info_l.addWidget(self.track_artist); b_l.addLayout(info_l)
ctrl_l = QHBoxLayout()
self.play_pause_btn = QPushButton(">"); self.play_pause_btn.clicked.connect(self._toggle_play_pause); ctrl_l.addWidget(self.play_pause_btn)
b_l.addLayout(ctrl_l)
prog_l = QVBoxLayout()
self.progress_slider = QSlider(Qt.Orientation.Horizontal); self.progress_slider.setRange(0, 100); self.progress_slider.sliderMoved.connect(self._seek); prog_l.addWidget(self.progress_slider)
time_l = QHBoxLayout()
self.current_time = QLabel("0:00"); time_l.addWidget(self.current_time)
time_l.addStretch()
self.total_time = QLabel("0:00"); time_l.addWidget(self.total_time)
prog_l.addLayout(time_l)
b_l.addLayout(prog_l, 1)
vol_l = QHBoxLayout()
self.volume_slider = QSlider(Qt.Orientation.Horizontal); self.volume_slider.setRange(0, 100); self.volume_slider.setValue(70); self.volume_slider.valueChanged.connect(self._change_volume); self.volume_slider.setFixedWidth(100)
vol_l.addWidget(self.volume_slider)
b_l.addLayout(vol_l)
layout.addWidget(bar)
self._load_history()
self._load_playlists()
def _show_home(self): self.stack.setCurrentIndex(0)
def _show_search(self): self.stack.setCurrentIndex(1)
def _show_playlists(self): self.stack.setCurrentIndex(2)
def _perform_search(self):
q = self.search_input.text().strip()
if not q: return
self.search_results.clear()
self.search_results.addItem("Поиск...")
self.worker = SearchWorker(q)
self.worker.finished.connect(self._on_search_finished)
self.worker.start()
def _on_search_finished(self, results):
self.search_results.clear()
if not results: self.search_results.addItem("Ничего не найдено"); return
for t in results:
item = QListWidgetItem(f"{t['title']} - {t['artist']}")
item.setData(Qt.ItemDataRole.UserRole, t)
self.search_results.addItem(item)
self.db.add_track(t)
def _play_from_list(self, item):
t = item.data(Qt.ItemDataRole.UserRole)
if t: self._play_track(t)
def _play_track(self, t):
self.player.play(t)
self.track_title.setText(t['title'])
self.track_artist.setText(t['artist'])
self.play_pause_btn.setText("||")
self.db.add_to_history(t['id'])
self._load_history()
def _toggle_play_pause(self):
if self.player.current_track:
self.player.pause()
self.play_pause_btn.setText("||" if self.player.is_playing else ">")
def _seek(self, pos): self.player.set_position(pos / 100.0)
def _change_volume(self, vol): self.player.set_volume(vol)
def _update_progress(self):
if self.player.current_track and self.player.is_playing:
self.progress_slider.setValue(int(self.player.get_position() * 100))
self.current_time.setText(f"{self.player.get_time() // 60}:{self.player.get_time() % 60:02d}")
self.total_time.setText(f"{self.player.get_duration() // 60}:{self.player.get_duration() % 60:02d}")
def _load_history(self):
self.history_list.clear()
for t in self.db.get_history():
item = QListWidgetItem(f"{t['title']} - {t['artist']}")
item.setData(Qt.ItemDataRole.UserRole, t)
self.history_list.addItem(item)
def _create_playlist(self):
name, ok = QInputDialog.getText(self, "Плейлист", "Название:")
if ok and name:
self.db.create_playlist(name)
self._load_playlists()
def _load_playlists(self):
self.playlists_list.clear()
for p in self.db.get_playlists():
item = QListWidgetItem(p['name'])
item.setData(Qt.ItemDataRole.UserRole, p)
self.playlists_list.addItem(item)
def _open_playlist(self, item):
p = item.data(Qt.ItemDataRole.UserRole)
tracks = self.db.get_playlist_tracks(p['id'])
if tracks: self._play_track(tracks[0])
def _apply_theme(self):
self.setStyleSheet(self.theme_manager.get_stylesheet())

def main():
app = QApplication(sys.argv)
win = MainWindow()
win.show()
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
#!/usr/bin/env python3
import subprocess, json, time
def get_cursor():
try:
out = subprocess.run(['hyprctl', 'cursorpos', '-j'], capture_output=True, text=True, timeout=1).stdout
data = json.loads(out)
return data['x'], data['y']
except Exception: return None, None
def get_window_at(x, y):
try:
out = subprocess.run(['hyprctl', 'clients', '-j'], capture_output=True, text=True, timeout=1).stdout
for c in json.loads(out):
cx, cy = c['at']
cw, ch = c['size']
if cx <= x <= cx + cw and cy <= y <= cy + ch:
return c['address']
except Exception: pass
return None
def main():
end_time = time.time() + 1.5
last_kill = 0
while time.time() < end_time:
now = time.time()
if now - last_kill < 0.4:
time.sleep(0.05)
continue
x, y = get_cursor()
if x is None: break
addr = get_window_at(x, y)
if addr:
subprocess.run(['hyprctl', 'dispatch', 'closewindow', f'address:{addr}'], capture_output=True, timeout=1)
last_kill = now
time.sleep(0.05)
if __name__ == '__main__': main()
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
bind = $mod, D, exec, bash -c 'pkill wofi 2>/dev/null; sleep 0.1; wofi --show drun'
bind = $mod, B, exec, firefox-esr
bind = $mod, E, exec, files
bind = $mod, M, exec, musicplayer
bind = $mod, W, exec, sh ~/.config/hypr/wallpaper.sh
bind = $mod, Q, killactive
bind = $mod SHIFT, Q, exec, ~/.config/hypr/quick-kill.sh
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
windowrulev2 = float,class:^(wofi)$
windowrulev2 = noanim,class:^(wofi)$
windowrulev2 = float,class:^(power-menu)$
windowrulev2 = pin,class:^(power-menu)$
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
"modules-left": ["custom/launcher", "custom/files", "clock", "network", "temperature"],
"modules-center": ["hyprland/workspaces"],
"modules-right": ["hyprland/language", "pulseaudio", "battery", "backlight", "pulseaudio#mic", "custom/power"],
"custom/launcher": { "format": "", "tooltip": false, "on-click": "wofi --show drun" },
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
"format-icons": ["", "", "", "", ""]
}
}
EOF
w "$H/.config/waybar/style.css" <<'EOF'
* { font-family: "DejaVu Sans Mono", "FontAwesome"; font-size: 11px; border: none; min-height: 0; }
window#waybar { background: transparent; color: #d4d4d4; }
#workspaces, #clock, #network, #temperature, #language,
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
# Обои: положи картинку в ~/Pictures/wall/wall.png (или wall.jpg) и нажми Super+W
w "$H/.config/hypr/wallpaper.sh" <<'EOF'
#!/bin/sh
f="$(ls "$HOME"/Pictures/wall/wall.* 2>/dev/null | head -n1)"
pkill swaybg 2>/dev/null
if [ -n "$f" ]; then exec swaybg -i "$f" -m fill; else exec swaybg -c 0a0a12; fi
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
if command -v curl >/dev/null 2>&1; then
install_deb_url https://github.com/Happ-proxy/happ-desktop/releases/latest/download/Happ.linux.x64.deb happ
gh_deb storytold/photocraft photocraft 'amd64|x86_64|x64'
install_deb_url https://github.com/ONLYOFFICE/DesktopEditors/releases/latest/download/onlyoffice-desktopeditors_amd64.deb onlyoffice
apt-get install -y --no-install-recommends prismlauncher \
|| gh_deb PrismLauncher/PrismLauncher prismlauncher 'amd64' \
|| echo "!! PrismLauncher не установился - поставь вручную из репозитория: apt install prismlauncher"
else
echo "!! curl не установился - дополнительные приложения пропущены"
fi
if apt-get install -y --no-install-recommends \
linux-headers-amd64 nvidia-driver nvidia-vulkan-icd; then
apt-get install -y --no-install-recommends nvidia-driver-libs-i386 \
|| echo "!! 32-битные библиотеки NVIDIA не установились - Steam будет работать на встройке"
apt-get install -y --no-install-recommends nvidia-vulkan-icd:i386 \
|| echo "!! 32-битный Vulkan NVIDIA не установился - часть игр пойдёт на встройке"
else
echo "!! NVIDIA не установилась - система продолжит работу на встройке"
dpkg --configure -a || true
fi
apt-get clean
echo
echo "Готово. ПЕРЕЗАГРУЗИСЬ (reboot): драйвер NVIDIA и группы пользователя подхватятся только так."
echo "После входа на TTY1 Hyprland запустится сам."
echo "Проверка NVIDIA после перезагрузки:  nvidia-smi"
echo "Steam: запусти из лаунчера (Super+D) уже после входа в Hyprland - он докачает клиент при первом запуске."
echo "Игры на 1650M: в Steam -> Свойства игры -> Параметры запуска:"
echo "  __NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only __GLX_VENDOR_LIBRARY_NAME=nvidia %command%"
echo
echo "Горячие клавиши:"
echo "  Super+M           - Music Player"
echo "  Super+Shift+Esc   - меню питания (повторное нажатие закрывает)"
echo "  Super+Q           - закрыть активное окно"
echo "  Super+Shift+Q     - зажать и водить курсором (закрывает окна под курсором)"
