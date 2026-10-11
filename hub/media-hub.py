#!/usr/bin/python3
"""Input and window hub for mpv on ROCKNIX handhelds, dual-screen aware.

  media-hub.py player [SOCKET]
      Runs next to the player EmulationStation launches: as mpv.service for
      videos (see /storage/.config/system.d/mpv.service.d/override.conf), in
      its own unit for the music player (es/Music.sh), SOCKET being that
      player's IPC socket. Reads the pad from evdev, so it works whatever
      window has focus, and sends key names to the player's handheld script.
      On a dual-screen device it also runs the touch remote on the second
      screen and relays between the two.

  media-hub.py bottom FILE
  media-hub.py bottom-music
      Plays FILE (or the music player's queue) on the second screen, touch
      only, so a game can run on the main screen at the same time. "Play on
      bottom screen" / "Play in background" start this in a transient unit
      (handheld-bottom), outside EmulationStation's launch.

All behaviour (what a key or a touch does) lives in the mpv scripts in
scripts/handheld next to this file; this file only moves events around.
"""

import fcntl
import json
import os
import select
import signal
import socket
import struct
import subprocess
import sys
import time
import xml.etree.ElementTree as ElementTree

RUNTIME = "/var/run/0-runtime-dir"
os.environ.setdefault("HOME", "/storage")
os.environ.setdefault("XDG_RUNTIME_DIR", RUNTIME)
os.environ.setdefault("WAYLAND_DISPLAY", "wayland-1")
os.environ.setdefault("SWAYSOCK", RUNTIME + "/sway-ipc.0.sock")

MAIN_SOCK = "/tmp/mpvsocket"
REMOTE_SOCK = "/tmp/mpv-remote"
BOTTOM_SOCK = "/tmp/mpv-bottom"
REMOTE_ID = "handheld-remote"
BOTTOM_ID = "handheld-bottom"
BOTTOM_UNIT = "handheld-bottom"
LOWERDECK = "lowerdeck"  # ROCKNIX's second-screen panel for RetroArch games
# lowerdeck reads its window size once, as it starts, and lays itself out for
# good; parked before that it gets a 1x1 window and stays a speck in a corner
# when it comes back. So it is left on screen this long before it is parked.
LOWERDECK_SETTLE = 1.0
MUSIC_SESSION = "/storage/.config/mpv/handheld-music.json"
MUSIC_QUEUE = "/storage/.config/mpv/handheld-music.m3u"

HERE = os.path.dirname(os.path.abspath(__file__))
# mpv loads the scripts of its own config dir by itself (naming them again
# would load them twice); installed anywhere else they are passed by path
# (and --load-scripts=no keeps a full install's copy there from loading too)
SCRIPTS = [] if HERE == os.path.join(os.environ["HOME"], ".config/mpv") else \
    ["--load-scripts=no", f"--script={os.path.join(HERE, 'scripts', 'handheld')}"]
HUB_OPT = f"handheld-hub={os.path.abspath(__file__)}"
# vo=wlshm: the second-screen windows draw in software, which works on every
# ROCKNIX device (the RK3566's Vulkan output shows no picture)
SECOND_SCREEN_MPV = ["mpv", "--fs", "--no-osc", "--no-input-default-bindings", "--vo=wlshm"] + SCRIPTS
# where a player about to start leaves a note, so the bottom player handing
# over to it keeps the second screen on (see player_follows)
FOLLOWS = "/run/handheld-follows"


def screens():
    """(main, second) output names, from the device's SDL display priority."""
    prio = os.environ.get("SDL_VIDEO_DISPLAY_PRIORITY")
    if not prio:
        try:
            prio = subprocess.run(
                ["sh", "-c", ". /etc/profile >/dev/null 2>&1; echo $SDL_VIDEO_DISPLAY_PRIORITY"],
                capture_output=True, text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            prio = ""
    if prio:
        os.environ["SDL_VIDEO_DISPLAY_PRIORITY"] = prio  # for the mpvs started from here
    names = [n for n in prio.split(",") if n]
    return (names[0], names[1]) if len(names) >= 2 else (None, None)


def unit_active(unit):
    return subprocess.run(["systemctl", "is-active", "--quiet", unit]).returncode == 0


# --- sway IPC -------------------------------------------------------------

def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise OSError("closed")
        data += chunk
    return data


class Sway:
    HDR = struct.Struct("<6sII")
    RUN, SUBSCRIBE, OUTPUTS = 0, 2, 3
    WINDOW_EVENT = 0x80000003

    def __init__(self):
        self.sock = None

    def _connect(self):
        s = socket.socket(socket.AF_UNIX)
        s.connect(os.environ["SWAYSOCK"])
        return s

    def _send(self, s, kind, payload=b""):
        s.sendall(self.HDR.pack(b"i3-ipc", len(payload), kind) + payload)

    def read(self, s):
        _, n, kind = self.HDR.unpack(recv_exact(s, self.HDR.size))
        return kind, json.loads(recv_exact(s, n))

    def request(self, kind, payload=""):
        for _ in range(2):
            try:
                if self.sock is None:
                    self.sock = self._connect()
                self._send(self.sock, kind, payload.encode())
                return self.read(self.sock)[1]
            except (OSError, ValueError):
                self.sock = None
        return None

    def run(self, command):
        return self.request(self.RUN, command)

    def powered(self, output):
        for o in self.request(self.OUTPUTS) or []:
            if o.get("name") == output:
                return o.get("power", o.get("dpms", True))
        return None

    def has_app(self, app_id):
        stack = [self.request(4) or {}]  # GET_TREE
        while stack:
            node = stack.pop()
            if node.get("app_id") == app_id:
                return True
            stack += node.get("nodes", []) + node.get("floating_nodes", [])
        return False

    def subscribe(self, events):
        s = self._connect()
        self._send(s, self.SUBSCRIBE, json.dumps(events).encode())
        self.read(s)
        return s


# --- second screen --------------------------------------------------------

BACKLIGHTS = "/sys/class/backlight"
BACKLIGHT_NOTE = "/run/handheld-second-backlight"


class SecondScreen:
    """Lights the second screen up and down.

    Switching the output itself (sway's `output X power`) re-initialises the
    DSI panel and stalls sway for about a second, which freezes the video on the
    main screen. So the output is switched on once, and sleeping and waking
    then only switch the panel's backlight."""

    def __init__(self, sway, name):
        self.sway, self.name = sway, name
        self.backlight = self._find()

    @staticmethod
    def _bl_power(b):
        try:
            with open(f"{BACKLIGHTS}/{b}/bl_power") as f:
                return f.read().strip()
        except OSError:
            return None

    def _find(self):
        try:
            with open(BACKLIGHT_NOTE) as f:
                b = f.read().strip()
            if b and os.path.isdir(f"{BACKLIGHTS}/{b}"):
                return b
        except OSError:
            pass
        if self.sway.powered(self.name) is not False:
            return None
        # with the output off its panel has blanked its backlight: that one is ours
        try:
            blanked = [b for b in sorted(os.listdir(BACKLIGHTS)) if self._bl_power(b) == "4"]
        except OSError:
            return None
        if len(blanked) != 1:
            return None
        try:
            with open(BACKLIGHT_NOTE, "w") as f:
                f.write(blanked[0])
        except OSError:
            pass
        return blanked[0]

    def _set_backlight(self, on):
        want = "0" if on else "4"  # FB_BLANK_UNBLANK / FB_BLANK_POWERDOWN
        if self._bl_power(self.backlight) == want:
            return True
        try:
            with open(f"{BACKLIGHTS}/{self.backlight}/bl_power", "w") as f:
                f.write(want)
            return True
        except OSError:
            return False

    def on(self):
        if self.sway.powered(self.name) is False:
            self.sway.run(f"output {self.name} power on")  # enabling the panel unblanks its backlight
        elif self.backlight:
            self._set_backlight(True)

    def sleep(self):
        if not (self.backlight and self._set_backlight(False)):
            self.sway.run(f"output {self.name} power off")

    def off(self):
        self.sway.run(f"output {self.name} power off")


# --- mpv IPC --------------------------------------------------------------

class Mpv:
    def __init__(self, path):
        self.path = path
        self.sock = None
        self.buf = b""
        self.on_connect = None

    def connect(self):
        if self.sock:
            return True
        try:
            s = socket.socket(socket.AF_UNIX)
            s.connect(self.path)
            s.setblocking(False)
        except OSError:
            return False
        self.sock, self.buf = s, b""
        if self.on_connect:
            self.on_connect(self)
        return True

    def close(self):
        if self.sock:
            self.sock.close()
        self.sock = None

    def send(self, command):
        if not self.connect():
            return False
        try:
            self.sock.sendall(json.dumps({"command": command}).encode() + b"\n")
            return True
        except OSError:
            self.close()
            return False

    def read(self):
        """Events received, or None once the connection closed."""
        try:
            data = self.sock.recv(65536)
        except BlockingIOError:
            return []
        except OSError:
            data = b""
        if not data:
            self.close()
            return None
        self.buf += data
        lines = self.buf.split(b"\n")
        self.buf = lines.pop()
        out = []
        for line in lines:
            try:
                out.append(json.loads(line.decode("utf-8", errors="replace")))
            except ValueError:
                pass
        return out


# --- pad ------------------------------------------------------------------

EVENT = struct.Struct("llHHi")
EV_KEY, EV_ABS = 1, 3
BUTTONS = {
    304: "b", 305: "a", 307: "x", 308: "y",          # SOUTH EAST NORTH WEST (Nintendo labels)
    310: "l1", 311: "r1", 312: "l2", 313: "r2",
    314: "select", 315: "start",
    544: "up", 545: "down", 546: "left", 547: "right",
}
STICKS = {0: ("lstick_left", "lstick_right"), 1: ("lstick_up", "lstick_down"),
          3: ("rstick_left", "rstick_right"), 4: ("rstick_up", "rstick_down")}
HATS = {16: ("left", "right"), 17: ("up", "down")}
REPEATING = {"up", "down", "left", "right"} | {k for pair in STICKS.values() for k in pair}
# L1 and R1 also work together ("l1+r1"), so each is sent when it is let go
# rather than when it is pressed, unless the other one joined it meanwhile
SHOULDERS = {"l1": "r1", "r1": "l1"}

# EmulationStation's own button mapping, per pad: drivers disagree on which
# code the X and Y buttons send (the RG SP's H700 pad swaps them against the
# DS Plus), but ES knows which button carries which label.
ES_INPUT = "/storage/.config/emulationstation/es_input.cfg"
ES_NAMES = {"a": "a", "b": "b", "x": "x", "y": "y", "leftshoulder": "l1", "rightshoulder": "r1",
            "lefttrigger": "l2", "righttrigger": "r2", "select": "select", "start": "start",
            "up": "up", "down": "down", "left": "left", "right": "right"}


def es_buttons(fd, name):
    """{key code: name} from es_input.cfg for the pad called `name`, or None.
    ES numbers buttons the way SDL does: the pad's key codes from BTN_JOYSTICK
    up, then those below it."""
    try:
        config = next((c for c in ElementTree.parse(ES_INPUT).getroot().findall("inputConfig")
                       if c.get("deviceName") == name), None)
        bits = bytearray(96)
        fcntl.ioctl(fd, 0x80604521, bits)  # EVIOCGBIT(EV_KEY, 96)
    except (OSError, ElementTree.ParseError):
        return None
    if config is None:
        return None
    codes = [c for c in range(768) if bits[c // 8] >> (c % 8) & 1]
    order = [c for c in codes if c >= 0x120] + [c for c in codes if c < 0x120]
    buttons = {}
    for i in config.findall("input"):
        key, index = ES_NAMES.get(i.get("name")), i.get("id", "")
        if key and i.get("type") == "button" and index.isdigit() and int(index) < len(order):
            buttons[order[int(index)]] = key
    return buttons if {"a", "b"} <= set(buttons.values()) else None
FIRST_REPEAT, NEXT_REPEAT = 0.45, 0.18


def find_input(prop):
    for name in sorted(os.listdir("/dev/input")):
        if not name.startswith("event"):
            continue
        try:
            with open(f"/run/udev/data/c13:{64 + int(name[5:])}") as f:
                if f"E:{prop}=1" in f.read():
                    return f"/dev/input/{name}"
        except (OSError, ValueError):
            pass
    return None


EVIOCGRAB = 0x40044590


def grabbed_elsewhere(path):
    """True when another process holds an exclusive grab on the device.

    On ROCKNIX builds with InputPlumber (RK3566 since late 2026) the physical
    buttons are grabbed by InputPlumber, which offers a virtual controller
    instead; reading the grabbed device would get nothing."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return True
    try:
        fcntl.ioctl(fd, EVIOCGRAB, 1)
        fcntl.ioctl(fd, EVIOCGRAB, 0)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def find_pad():
    """The first joystick nobody else has grabbed: the pad itself, or the
    virtual controller InputPlumber makes from it."""
    for name in sorted(os.listdir("/dev/input"), key=lambda n: int(n[5:]) if n[5:].isdigit() else 0):
        if not name.startswith("event"):
            continue
        try:
            with open(f"/run/udev/data/c13:{64 + int(name[5:])}") as f:
                if "E:ID_INPUT_JOYSTICK=1" not in f.read():
                    continue
        except (OSError, ValueError):
            continue
        path = f"/dev/input/{name}"
        if not grabbed_elsewhere(path):
            return path
    return None


class TouchWatch:
    """Notices a finger on the touchscreen. Read alongside sway, not grabbed:
    sway does not deliver touches to a screen that is powered off, so the hub
    wakes the remote itself."""

    def __init__(self):
        path = find_input("ID_INPUT_TOUCHSCREEN")
        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK) if path else None

    def touched(self):
        try:
            data = os.read(self.fd, EVENT.size * 64)
        except BlockingIOError:
            return False
        except OSError:
            self.close()  # the device went away
            return False
        for i in range(0, len(data) - EVENT.size + 1, EVENT.size):
            _, _, etype, code, value = EVENT.unpack_from(data, i)
            if etype == EV_KEY and code == 330 and value == 1:  # BTN_TOUCH down
                return True
        return False

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
        self.fd = None


class Pad:
    """Turns pad events into key names; held directions repeat."""

    def __init__(self, send):
        self.send = send   # send(key, repeat)
        self.fd = None
        self.ranges = {}
        self.held = {}       # key -> next repeat time
        self.stick_dir = {}  # axis -> key held by that axis
        self.shoulders = {}  # shoulder held -> whether it still sends itself on release
        self.buttons = BUTTONS
        self.next_look = 0

    def open(self):
        if self.fd is not None or time.monotonic() < self.next_look:
            return
        self.next_look = time.monotonic() + 1
        path = find_pad()
        if not path:
            return
        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            with open(f"/sys/class/input/{os.path.basename(path)}/device/name") as f:
                name = f.read().strip()
        except OSError:
            name = ""
        mapped = es_buttons(self.fd, name)
        # ES's names for its buttons; the fixed table for anything ES leaves out
        self.buttons = {**{c: k for c, k in BUTTONS.items() if k not in (mapped or {}).values()}, **(mapped or {})}
        self.ranges = {}
        for code in STICKS:
            buf = bytearray(24)
            try:
                fcntl.ioctl(self.fd, 0x80184540 + code, buf)  # EVIOCGABS(code)
            except OSError:
                continue
            _, lo, hi, _, _, _ = struct.unpack("6i", buf)
            self.ranges[code] = (lo, hi)

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
        self.fd, self.held, self.stick_dir, self.shoulders = None, {}, {}, {}

    def timeout(self):
        return max(0.0, min(self.held.values()) - time.monotonic()) if self.held else None

    def _press(self, key):
        if key in SHOULDERS:
            if SHOULDERS[key] in self.shoulders:
                self.shoulders = {key: False, SHOULDERS[key]: False}
                self.send("l1+r1", False)
            else:
                self.shoulders[key] = True
            return
        self.send(key, False)
        if key in REPEATING:
            self.held[key] = time.monotonic() + FIRST_REPEAT

    def _release(self, key):
        if key in SHOULDERS:
            if self.shoulders.pop(key, False):
                self.send(key, False)
            return
        self.held.pop(key, None)

    def read(self):
        try:
            data = os.read(self.fd, EVENT.size * 64)
        except BlockingIOError:
            return
        except OSError:
            self.close()  # pad went away, look for it again
            return
        for i in range(0, len(data) - EVENT.size + 1, EVENT.size):
            _, _, etype, code, value = EVENT.unpack_from(data, i)
            if etype == EV_KEY and code in self.buttons:
                if value == 1:
                    self._press(self.buttons[code])
                elif value == 0:
                    self._release(self.buttons[code])
            elif etype == EV_ABS and code in STICKS and code in self.ranges:
                lo, hi = self.ranges[code]
                centre, half = (lo + hi) / 2, (hi - lo) / 2
                pos = (value - centre) / half if half else 0
                key = STICKS[code][0] if pos < -0.55 else STICKS[code][1] if pos > 0.55 else None
                if pos and abs(pos) > 0.35 and key is None and code in self.stick_dir:
                    continue  # hysteresis: keep the held direction until the stick comes back
                if self.stick_dir.get(code) != key:
                    if code in self.stick_dir:
                        self._release(self.stick_dir.pop(code))
                    if key:
                        self.stick_dir[code] = key
                        self._press(key)
            elif etype == EV_ABS and code in HATS:
                for key in HATS[code]:
                    self._release(key)
                if value:
                    self._press(HATS[code][0] if value < 0 else HATS[code][1])

    def repeat(self):
        now = time.monotonic()
        for key, due in list(self.held.items()):
            if now >= due:
                self.send(key, True)
                self.held[key] = now + NEXT_REPEAT


# --- roles ----------------------------------------------------------------

class Stop(Exception):
    pass


def on_term(*_):
    raise Stop()


def window_event(sway, sock):
    try:
        kind, ev = sway.read(sock)
    except ValueError:
        return None, None  # (OSError: sway went away; the caller starts over)
    if kind != Sway.WINDOW_EVENT:
        return None, None
    return ev.get("change"), (ev.get("container") or {}).get("app_id")


def run_player(main_sock=MAIN_SOCK):
    main_out, second = screens()
    if second and unit_active(BOTTOM_UNIT):
        subprocess.run(["systemctl", "stop", BOTTOM_UNIT])  # one video at a time

    sway = Sway()
    main = Mpv(main_sock)
    remote = Mpv(REMOTE_SOCK)
    events = sway.subscribe(["window"]) if second else None
    screen = SecondScreen(sway, second) if second else None
    proc = None
    awake = False
    state = None
    last_keep = None
    seen_main = False

    def start_remote():
        nonlocal proc
        proc = subprocess.Popen(
            SECOND_SCREEN_MPV + [
                "--idle=yes", "--force-window=yes", "--title=Touch remote", f"--wayland-app-id={REMOTE_ID}",
                f"--fs-screen-name={second}", "--audio=no", "--save-position-on-quit=no",
                f"--input-ipc-server={REMOTE_SOCK}", f"--script-opts=handheld-role=remote,{HUB_OPT}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    touch = TouchWatch() if second else None
    remote_started = 0.0

    # Both screens should come up together: the remote starts at once, beside
    # the player rather than after it, and powers the second screen on while
    # both are still loading (the one slow switch, about a second of sway).
    if second:
        start_remote()
        remote_started = time.monotonic()
    if screen:
        screen.on()

    def send_key(key, repeat):
        main.send(["script-message", "handheld", key] + (["repeat"] if repeat else []))

    pad = Pad(send_key)
    main.on_connect = lambda m: m.send(["observe_property", 1, "user-data/handheld/state"])
    remote.on_connect = lambda m: m.send(["observe_property", 2, "user-data/handheld/req"])

    def stop_remote():
        nonlocal proc, awake
        remote.close()
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(2)
            except subprocess.TimeoutExpired:
                proc.kill()
        proc, awake = None, False
        if screen:
            if unit_active(BOTTOM_UNIT):
                screen.on()  # the video or music moved down there
            else:
                screen.off()

    try:
        while True:
            pad.open()
            if not main.sock and main.connect():
                seen_main = True
            if second and main.sock and proc is None and time.monotonic() - remote_started > 5:
                start_remote()  # it crashed (at most every 5 s)
                remote_started = time.monotonic()
            if proc and not remote.sock:
                remote.connect()

            fds = [f for f in (pad.fd, main.sock, remote.sock, events, touch and touch.fd) if f is not None]
            waits = [t for t in (pad.timeout(),) if t is not None]
            if not main.sock or (proc and not remote.sock):
                waits.append(0.1)  # still starting
            if pad.fd is None or (second and main.sock and proc is None):
                waits.append(1.0)  # look for the pad again; restart the remote
            ready, _, _ = select.select(fds, [], [], min(waits) if waits else None)

            for f in ready:
                if f == pad.fd:
                    pad.read()
                elif touch and f == touch.fd:
                    # only needed when the output is off: sway then keeps touches to itself
                    if touch.touched() and not awake and remote.sock and sway.powered(second) is False:
                        awake = True
                        screen.on()
                        remote.send(["script-message", "handheld-wake"])
                        if state:
                            remote.send(["script-message", "handheld-state", state])
                elif f is main.sock:
                    evs = main.read()
                    if evs is None:
                        stop_remote()  # the video ended
                        if main_sock != MAIN_SOCK:
                            return  # the music player's own hub ends with it
                        continue
                    for ev in evs:
                        if ev.get("event") == "property-change" and ev.get("id") == 1:
                            state = ev.get("data")
                            try:
                                keep = json.loads(state).get("keep_on") if state else None
                            except (ValueError, AttributeError):
                                keep = None
                            # asleep, the remote only needs to hear that "Stay on" changed
                            if state and (awake or keep != last_keep):
                                remote.send(["script-message", "handheld-state", state])
                            last_keep = keep
                elif f is remote.sock:
                    evs = remote.read() or []
                    for ev in evs:
                        if ev.get("event") != "property-change" or ev.get("id") != 2 or not ev.get("data"):
                            continue
                        try:
                            req = json.loads(ev["data"])
                        except ValueError:
                            continue
                        if req.get("wake"):
                            awake = True
                            screen.on()
                            if state:
                                remote.send(["script-message", "handheld-state", state])
                        elif req.get("sleep"):
                            awake = False
                            screen.sleep()
                        elif req.get("cmd"):
                            main.send(req["cmd"])
                elif f is events:
                    change, app = window_event(sway, events)
                    if app == REMOTE_ID and change == "new":
                        # shown for a few seconds when the player opens, so people
                        # learn it is there; it then sleeps like after any use
                        sway.run(f'[app_id="{REMOTE_ID}"] move container to output {second}, fullscreen enable')
                        screen.on()
                        sway.run(f"focus output {main_out}")
                        awake = True
                        remote.send(["script-message", "handheld-wake", "intro"])
                        if state:
                            remote.send(["script-message", "handheld-state", state])
                    elif app == REMOTE_ID and change == "focus":
                        sway.run(f"focus output {main_out}")  # keep the main screen focused
            if pad.fd is not None:
                pad.repeat()
            if seen_main and proc and proc.poll() is not None:
                proc = None  # remote crashed; started again on the next loop
                remote.close()
    finally:
        pad.close()
        if touch:
            touch.close()
        stop_remote()


def run_bottom(path, extra=()):
    main_out, second = screens()
    if not second:
        sys.exit("no second screen")
    sway = Sway()
    events = sway.subscribe(["window"])
    screen = SecondScreen(sway, second)
    mpv = Mpv(BOTTOM_SOCK)
    # the music player can let the screen go dark when idle (wake/sleep requests)
    mpv.on_connect = lambda m: m.send(["observe_property", 2, "user-data/handheld/req"])
    asleep = False
    proc = subprocess.Popen(
        SECOND_SCREEN_MPV + [
            # the sway config sends windows titled "Bottom" to the second screen and powers it on
            "--title=Bottom", f"--wayland-app-id={BOTTOM_ID}", f"--fs-screen-name={second}",
            f"--input-ipc-server={BOTTOM_SOCK}", f"--script-opts=handheld-role=bottom,{HUB_OPT}", *extra, path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    mapped = False
    drastic = False  # DraStic started: it owns the second screen now
    next_check = 0
    park_at = None  # when to park lowerdeck (see LOWERDECK_SETTLE)
    try:
        while proc.poll() is None:
            if mapped and not mpv.sock:
                mpv.connect()
            wait = 1.0 if park_at is None else min(1.0, max(0.0, park_at - time.monotonic()))
            ready, _, _ = select.select([f for f in (events, mpv.sock) if f], [], [], wait)
            if mpv.sock in ready:
                for ev in mpv.read() or []:
                    if ev.get("event") == "property-change" and ev.get("id") == 2 and ev.get("data"):
                        try:
                            req = json.loads(ev["data"])
                        except ValueError:
                            continue
                        if req.get("sleep"):
                            asleep = True
                            screen.sleep()
                        elif req.get("wake"):
                            asleep = False
                            screen.on()
            if events in ready:
                change, app = window_event(sway, events)
                if app == BOTTOM_ID and change == "new":
                    mapped = True
                    sway.run(f'[app_id="{BOTTOM_ID}"] move container to output {second}, fullscreen enable')
                    screen.on()
                    sway.run(f"focus output {main_out}")
                elif app == BOTTOM_ID and change == "focus":
                    # a touch focused the video; give the game or the menu its focus back
                    sway.run(f"focus output {main_out}")
                elif app == "drastic" and change == "new":
                    drastic = True
                    mpv.send(["quit"])  # DS games need both screens
                elif app == LOWERDECK and change == "new":
                    # ROCKNIX's RetroArch panel would cover the video; park it once it has laid itself out
                    park_at = time.monotonic() + LOWERDECK_SETTLE
                elif app == LOWERDECK and change == "close":
                    park_at = None
                    sway.run(f'[app_id="{BOTTOM_ID}"] fullscreen enable')
            if park_at is not None and time.monotonic() >= park_at:
                park_at = None
                sway.run(f'[app_id="{LOWERDECK}"] move scratchpad')
                sway.run(f'[app_id="{BOTTOM_ID}"] fullscreen enable')
            # games turn the second screen off when they exit; keep it on (dark if asleep)
            if mapped and time.monotonic() >= next_check and not (asleep and not screen.backlight):
                next_check = time.monotonic() + 1
                if sway.powered(second) is False:
                    screen.on()
                    if asleep:
                        screen.sleep()
                elif not asleep:
                    screen.on()
    except Stop:
        mpv.send(["quit"])  # quit cleanly so the position is saved
        try:
            proc.wait(3)
        except subprocess.TimeoutExpired:
            proc.terminate()
    finally:
        if proc.poll() is None:
            proc.kill()
        if sway.has_app(LOWERDECK):  # a game is still running: give its panel back
            sway.run(f'[app_id="{LOWERDECK}"] scratchpad show')
            sway.run(f'[app_id="{LOWERDECK}"] move container to output {second}, fullscreen enable')
        elif not drastic and not player_follows():
            screen.off()


def player_follows(wait=4.0):
    """True when the main player starts right after us ("Move to top" / "Open
    player"): leave the screen on so it does not flash off and back on."""
    end = time.monotonic() + wait
    while time.monotonic() < end:
        if os.path.exists(FOLLOWS):
            try:
                os.remove(FOLLOWS)
            except OSError:
                pass
            return True
        if unit_active("mpv") or unit_active("handheld-music"):
            return True
        time.sleep(0.2)
    return False


def main():
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    role = sys.argv[1] if len(sys.argv) > 1 else "player"
    try:
        if role == "bottom" and len(sys.argv) > 2:
            run_bottom(sys.argv[2])
        elif role == "bottom-music":
            # the music player wrote its queue and position before quitting
            try:
                with open(MUSIC_SESSION) as f:
                    index = int(json.load(f).get("index", 1)) - 1
            except (OSError, ValueError, TypeError, AttributeError):
                index = 0
            # --idle: picking from its touch library replaces the queue, which
            # would otherwise end the player for a moment and quit it
            run_bottom(MUSIC_QUEUE, ("--idle=yes", "--force-window=yes", "--audio-display=no", f"--playlist-start={index}",
                                     "--save-position-on-quit=no", "--resume-playback=no",
                                     "--script-opts-append=handheld-kind=music"))
        else:
            sock = sys.argv[2] if role == "player" and len(sys.argv) > 2 else MAIN_SOCK
            while True:
                try:
                    run_player(sock)
                    if sock != MAIN_SOCK:
                        break  # the music player ended: so does its hub
                except OSError:
                    time.sleep(1)  # sway or a socket went away; start over
    except Stop:
        pass


if __name__ == "__main__":
    main()
