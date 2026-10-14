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
SECOND_SCREEN_MPV = ["mpv", "--fs", "--no-osc", "--no-input-default-bindings", "--vo=wlshm", "--cursor-autohide=always"] + SCRIPTS
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


# --- screen off, lid and power button (the music player) -----------------

EV_SW, SW_LID, KEY_POWER = 5, 0, 116
EVIOCGSW = 0x8008451B   # the switches' states, 8 bytes
SCREEN_NOTE = "/run/cmp-screen-off"  # backlights turned off, for es/Music.sh to restore
UNLOCK_HOLD = 1.0   # s Y is held to unlock
STOPPED_GRACE = 3.0  # s the music may be stopped (a track change) before it counts
WAKE_TAPS_WITHIN = 0.5  # s between the two taps that wake the dark second screen


def input_devices():
    """[{"name", "event", "KEY", "SW", ...}] from /proc/bus/input/devices;
    KEY and SW are the capability bitmasks as ints."""
    devices, cur = [], {}
    try:
        with open("/proc/bus/input/devices") as f:
            lines = f.read().splitlines() + [""]
    except OSError:
        return []
    for line in lines:
        if not line.strip():
            if cur.get("event"):
                devices.append(cur)
            cur = {}
        elif line.startswith("N: Name="):
            cur["name"] = line[8:].strip().strip('"')
        elif line.startswith("H: Handlers="):
            events = [h for h in line[12:].split() if h.startswith("event")]
            if events:
                cur["event"] = "/dev/input/" + events[0]
        elif line.startswith("B: ") and "=" in line:
            key, _, value = line[3:].partition("=")
            words = value.split()  # most significant first, 64 bits each
            try:
                cur[key] = sum(int(w, 16) << (64 * i) for i, w in enumerate(reversed(words)))
            except ValueError:
                pass
    return devices


class Guard:
    """While music plays, the lid and the power button turn the screen off
    instead of putting the handheld to sleep, and Y does the same from the
    player. The buttons are locked while the screen is off: the power button,
    opening the lid or holding Y turns it back on. When the music stops with
    the screen off (the sleep timer, the end of the queue), the handheld
    goes to sleep after all.

    logind normally suspends on the lid and the power button; a "block"
    inhibitor (systemd-inhibit) held only while music plays or the screen is
    off keeps it from doing so, and logind takes over again, as before, the
    moment it is let go (with the lid shut, it then suspends at once)."""

    def __init__(self, second_screen=None):
        self.second = second_screen
        self.fds = {}  # fd -> "lid" | "power"
        for d in input_devices():
            kind = "lid" if d.get("SW", 0) >> SW_LID & 1 else "power" if d.get("KEY", 0) >> KEY_POWER & 1 else None
            if kind:
                try:
                    self.fds[os.open(d["event"], os.O_RDONLY | os.O_NONBLOCK)] = kind
                except OSError:
                    pass
        self.lid_closed = any(self._lid_shut(fd) for fd, k in self.fds.items() if k == "lid")
        self.inhibitor = None
        self.locked = False
        self.playing = False
        self.stopped_at = None
        self.tell = lambda on: None  # set by the player: tells mpv the screen is on or off

    @staticmethod
    def _lid_shut(fd):
        bits = bytearray(8)
        try:
            fcntl.ioctl(fd, EVIOCGSW, bits)
        except OSError:
            return False
        return bool(bits[0] >> SW_LID & 1)

    def _backlights(self):
        """The main screen's backlights: every one but the second screen's."""
        try:
            names = sorted(os.listdir(BACKLIGHTS))
        except OSError:
            return []
        return [b for b in names if not (self.second and b == self.second.backlight)]

    def _screen(self, on):
        names = self._backlights()
        for b in names:
            try:
                with open(f"{BACKLIGHTS}/{b}/bl_power", "w") as f:
                    f.write("0" if on else "4")  # FB_BLANK_UNBLANK / FB_BLANK_POWERDOWN
            except OSError:
                pass
        try:
            if on:
                os.remove(SCREEN_NOTE)
            else:
                with open(SCREEN_NOTE, "w") as f:
                    f.write(" ".join(names))
        except OSError:
            pass
        if self.second:
            if on:
                self.second.on()
            else:
                self.second.sleep()
        self.tell(on)

    def lock(self):
        if not self.locked and self.playing:
            self.locked = True
            self._hold(True)
            self._screen(False)

    def unlock(self):
        if self.locked:
            self.locked = False
            self._screen(True)

    def _hold(self, want):
        if self.inhibitor and self.inhibitor.poll() is not None:
            self.inhibitor = None
        if want and not self.inhibitor:
            try:
                self.inhibitor = subprocess.Popen(
                    ["systemd-inhibit", "--what=handle-lid-switch:handle-power-key", "--who=CMP",
                     "--why=Music is playing", "--mode=block", "sleep", "infinity"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError:
                self.inhibitor = None
        elif not want and self.inhibitor:
            self.inhibitor.terminate()
            try:
                self.inhibitor.wait(2)
            except subprocess.TimeoutExpired:
                self.inhibitor.kill()
            self.inhibitor = None

    def read(self, fd):
        try:
            data = os.read(fd, EVENT.size * 16)
        except BlockingIOError:
            return
        except OSError:
            os.close(fd)
            self.fds.pop(fd, None)
            return
        for i in range(0, len(data) - EVENT.size + 1, EVENT.size):
            _, _, etype, code, value = EVENT.unpack_from(data, i)
            if etype == EV_SW and code == SW_LID:
                self.lid_closed = bool(value)
                if value:
                    self.lock()  # (not playing: logind is suspending)
                else:
                    self.unlock()
            elif etype == EV_KEY and code == KEY_POWER and value == 1 and not self.lid_closed:
                # only seen here while held back from logind: music plays or the screen is off
                if self.locked:
                    self.unlock()
                elif self.playing and self.inhibitor:
                    self.lock()

    def set_playing(self, playing):
        self.playing = playing
        self.update()

    def update(self):
        """Hold logind back while music plays or the screen is off; sleep
        once the music has stopped with the screen off."""
        if self.locked and not self.playing:
            now = time.monotonic()
            if self.stopped_at is None:
                self.stopped_at = now
            elif now - self.stopped_at >= STOPPED_GRACE:
                self.stopped_at = None
                self.unlock()
                self._hold(False)
                if not self.lid_closed:  # (with the lid shut, logind suspends by itself now)
                    subprocess.Popen(["systemctl", "suspend"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return
        else:
            self.stopped_at = None
        self._hold(self.playing or self.locked)

    def timeout(self):
        return 1.0 if self.locked and not self.playing else None

    def close(self):
        self.unlock()
        self._hold(False)
        for fd in self.fds:
            os.close(fd)
        self.fds = {}


SW_HEADPHONE_INSERT = 2


class HeadphoneJack:
    """Notices headphones being pulled out, so the player can pause rather
    than carry on from the speaker."""

    def __init__(self):
        self.fds = []
        for d in input_devices():
            if d.get("SW", 0) >> SW_HEADPHONE_INSERT & 1:
                try:
                    self.fds.append(os.open(d["event"], os.O_RDONLY | os.O_NONBLOCK))
                except OSError:
                    pass

    def unplugged(self, fd):
        """True when what came in on fd says the headphones came out."""
        try:
            data = os.read(fd, EVENT.size * 16)
        except BlockingIOError:
            return False
        except OSError:
            os.close(fd)
            self.fds.remove(fd)
            return False
        out = False
        for i in range(0, len(data) - EVENT.size + 1, EVENT.size):
            _, _, etype, code, value = EVENT.unpack_from(data, i)
            if etype == EV_SW and code == SW_HEADPHONE_INSERT:
                out = value == 0
        return out

    def close(self):
        for fd in self.fds:
            os.close(fd)
        self.fds = []


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
    314: "select", 315: "start", 317: "l3", 318: "r3",
    544: "up", 545: "down", 546: "left", 547: "right",
}
# Analog triggers as L2/R2: InputPlumber's virtual pad (ROCKNIX next) sends the
# triggers only as ABS_Z / ABS_RZ, never as buttons. An axis counts as a
# trigger when it rests at its low end (a stick rests in the middle).
TRIGGERS = {2: "l2", 5: "r2"}
STICKS = {0: ("lstick_left", "lstick_right"), 1: ("lstick_up", "lstick_down"),
          3: ("rstick_left", "rstick_right"), 4: ("rstick_up", "rstick_down")}
HATS = {16: ("left", "right"), 17: ("up", "down")}
REPEATING = {"up", "down", "left", "right"} | {k for pair in STICKS.values() for k in pair}
# L1 and R1 also work together ("l1+r1"), and so do Select and Start
# ("select+start", quit, as in RetroArch): each of them is sent when it is
# let go rather than when it is pressed, unless the other one joined it
SHOULDERS = {"l1": "r1", "r1": "l1", "select": "start", "start": "select"}
COMBOS = {"l1": "l1+r1", "r1": "l1+r1", "select": "select+start", "start": "select+start"}

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


def find_pads(skip=()):
    """Every joystick nobody else has grabbed: the pad itself, or the virtual
    controller InputPlumber makes from it. Without InputPlumber some pads are
    several devices (the RG DS Plus: buttons in gpio-keys-control, sticks in
    adc-joystick), so all of them are read."""
    pads = []
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
        if path not in skip and not grabbed_elsewhere(path):
            pads.append(path)
    return pads


class TouchWatch:
    """Notices a finger on the touchscreen. Read alongside sway, not grabbed:
    sway does not deliver touches to a screen that is powered off, so the hub
    wakes the remote itself."""

    def __init__(self):
        path = find_input("ID_INPUT_TOUCHSCREEN")
        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK) if path else None

    def touched(self):
        """How many fingers came down since the last read."""
        try:
            data = os.read(self.fd, EVENT.size * 64)
        except BlockingIOError:
            return 0
        except OSError:
            self.close()  # the device went away
            return 0
        downs = 0
        for i in range(0, len(data) - EVENT.size + 1, EVENT.size):
            _, _, etype, code, value = EVENT.unpack_from(data, i)
            if etype == EV_KEY and code == 330 and value == 1:  # BTN_TOUCH down
                downs += 1
        return downs

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
        self.fd = None


class Pad:
    """Turns pad events into key names; held directions repeat."""

    def __init__(self, send):
        self.send = send   # send(key, repeat)
        self.devices = {}    # fd -> (key code -> name, axis -> (min, max)), one per pad device
        self.paths = {}      # fd -> its /dev/input path
        self.triggers = {}   # fd -> analog trigger axis -> (min, max), read as L2/R2
        self.pulled = set()  # (fd, axis) of triggers pressed now
        self.last_l2r2 = {}  # "l2"/"r2" -> when it was last pressed, from a button or an axis
        self.held = {}       # key -> next repeat time
        self.stick_dir = {}  # (fd, axis) -> key held by that axis
        self.shoulders = {}  # shoulder held -> whether it still sends itself on release
        self.down = {}       # button -> when it went down
        self.next_look = 0

    @property
    def fds(self):
        return list(self.devices)

    def open(self):
        # looked for again now and then, also with a pad open: one of its
        # devices may come up later than the other
        if time.monotonic() < self.next_look:
            return
        self.next_look = time.monotonic() + (3 if self.devices else 1)
        for path in find_pads(skip=set(self.paths.values())):
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                continue
            try:
                with open(f"/sys/class/input/{os.path.basename(path)}/device/name") as f:
                    name = f.read().strip()
            except OSError:
                name = ""
            mapped = es_buttons(fd, name)
            # ES's names for its buttons; the fixed table for anything ES leaves out
            buttons = {**{c: k for c, k in BUTTONS.items() if k not in (mapped or {}).values()}, **(mapped or {})}
            ranges, triggers = {}, {}
            for code in list(STICKS) + list(TRIGGERS):
                buf = bytearray(24)
                try:
                    fcntl.ioctl(fd, 0x80184540 + code, buf)  # EVIOCGABS(code)
                except OSError:
                    continue
                value, lo, hi, _, _, _ = struct.unpack("6i", buf)
                if hi <= lo:
                    continue
                if code in TRIGGERS:
                    if value - lo <= (hi - lo) * 0.1:
                        triggers[code] = (lo, hi)
                    continue
                ranges[code] = (lo, hi)
            self.devices[fd] = (buttons, ranges)
            self.triggers[fd] = triggers
            self.paths[fd] = path

    def close(self):
        for fd in self.devices:
            os.close(fd)
        self.devices, self.paths, self.held, self.stick_dir, self.shoulders, self.down = {}, {}, {}, {}, {}, {}
        self.triggers, self.pulled = {}, set()

    def timeout(self):
        return max(0.0, min(self.held.values()) - time.monotonic()) if self.held else None

    def _press(self, key):
        if key in ("l2", "r2"):
            # a pad may send a trigger both as a button and as an axis: count it once
            now = time.monotonic()
            if now - self.last_l2r2.get(key, 0) < 0.15:
                return
            self.last_l2r2[key] = now
        if key in SHOULDERS:
            if SHOULDERS[key] in self.shoulders:
                self.shoulders[key] = self.shoulders[SHOULDERS[key]] = False  # (the other pair keeps its state)
                self.send(COMBOS[key], False)
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

    def read(self, fd):
        try:
            data = os.read(fd, EVENT.size * 64)
        except BlockingIOError:
            return
        except OSError:
            self.close()  # pad went away, look for it again
            return
        buttons, ranges = self.devices[fd]
        for i in range(0, len(data) - EVENT.size + 1, EVENT.size):
            _, _, etype, code, value = EVENT.unpack_from(data, i)
            if etype == EV_KEY and code in buttons:
                if value == 1:
                    self.down[buttons[code]] = time.monotonic()
                    self._press(buttons[code])
                elif value == 0:
                    self.down.pop(buttons[code], None)
                    self._release(buttons[code])
            elif etype == EV_ABS and code in STICKS and code in ranges:
                lo, hi = ranges[code]
                centre, half = (lo + hi) / 2, (hi - lo) / 2
                pos = (value - centre) / half if half else 0
                key = STICKS[code][0] if pos < -0.55 else STICKS[code][1] if pos > 0.55 else None
                axis = (fd, code)
                if pos and abs(pos) > 0.35 and key is None and axis in self.stick_dir:
                    continue  # hysteresis: keep the held direction until the stick comes back
                if self.stick_dir.get(axis) != key:
                    if axis in self.stick_dir:
                        self._release(self.stick_dir.pop(axis))
                    if key:
                        self.stick_dir[axis] = key
                        self._press(key)
            elif etype == EV_ABS and code in self.triggers.get(fd, {}):
                lo, hi = self.triggers[fd][code]
                pos, axis, key = (value - lo) / (hi - lo), (fd, code), TRIGGERS[code]
                if pos > 0.5 and axis not in self.pulled:
                    self.pulled.add(axis)
                    self.down[key] = time.monotonic()
                    self._press(key)
                elif pos < 0.25 and axis in self.pulled:
                    self.pulled.discard(axis)
                    self.down.pop(key, None)
                    self._release(key)
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
    # when to ask sway again whether the second screen came on with the remote:
    # something else (an ES reload, a helper that powers it off while only the
    # player's window is open) can turn it off just after the hub turned it on
    rechecks = []

    # Both screens should come up together: the remote starts at once, beside
    # the player rather than after it, and powers the second screen on while
    # both are still loading (the one slow switch, about a second of sway).
    if second:
        # the player's window opens on the screen with the focus: make that the
        # main one (a touch on the second screen just before would take it there)
        sway.run(f"focus output {main_out}")
        start_remote()
        remote_started = time.monotonic()
    if screen:
        screen.on()

    # the music player's own hub also turns the screen off (see Guard)
    guard = Guard(screen) if main_sock != MAIN_SOCK else None
    if guard:
        guard.tell = lambda on: main.send(["script-message", "handheld-screen", "on" if on else "off"])

    jack = HeadphoneJack()

    def locked():
        return guard is not None and guard.locked

    # The player's window belongs on the main screen, filling it: it opens on
    # the screen with the focus, which a touch on the second screen moves there.
    def place_main():
        sway.run(f'[app_id="mpv"] move container to output {main_out}, fullscreen enable, focus')
        if proc:
            sway.run(f'[app_id="{REMOTE_ID}"] move container to output {second}, fullscreen enable')
        sway.run(f"focus output {main_out}")

    def send_key(key, repeat):
        if locked():
            return  # buttons are locked while the screen is off
        main.send(["script-message", "handheld", key] + (["repeat"] if repeat else []))
        # in the music player a button wakes the second screen too, or keeps it on
        # (not Y: it turns the screens off). Over a video the buttons only drive
        # the video: seeking would light the touch screen every time.
        if guard and second and remote.sock and not repeat and key != "y":
            remote_lit()

    def wake_remote():
        nonlocal awake
        awake = True
        remote.send(["script-message", "handheld-wake"])
        if state:
            remote.send(["script-message", "handheld-state", state])

    def remote_lit():
        """Show the second screen, or start its turn-off timer again if it shows.
        Whether it shows is asked of sway, not kept here: something else (an
        ES reload) can turn the output off behind the hub's back."""
        nonlocal awake
        if awake and sway.powered(second) is not False:
            remote.send(["script-message", "handheld-wake", "poke"])
            return
        awake = True
        screen.on()
        remote.send(["script-message", "handheld-wake"])
        if state:
            remote.send(["script-message", "handheld-state", state])

    last_tap = 0.0  # the first tap of the double tap that wakes the dark second screen
    wake_taps = 1   # the players' "Wake the touch screen with" setting (1 or 2), from their state

    pad = Pad(send_key)

    def main_connected(m):
        m.send(["observe_property", 1, "user-data/handheld/state"])
        m.send(["observe_property", 3, "user-data/handheld/req"])
    main.on_connect = main_connected
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
                if second and not seen_main:
                    place_main()  # (its window may have opened before this hub listened)
                seen_main = True
            if second and main.sock and proc is None and time.monotonic() - remote_started > 5:
                start_remote()  # it crashed (at most every 5 s)
                remote_started = time.monotonic()
            if proc and not remote.sock:
                remote.connect()

            fds = pad.fds + [f for f in (main.sock, remote.sock, events, touch and touch.fd) if f is not None]
            fds += (list(guard.fds) if guard else []) + jack.fds
            waits = [t for t in (pad.timeout(), guard and guard.timeout()) if t is not None]
            if locked() and "y" in pad.down:
                waits.append(max(0.0, pad.down["y"] + UNLOCK_HOLD - time.monotonic()))
            if not main.sock or (proc and not remote.sock):
                waits.append(0.1)  # still starting
            if not pad.devices or (second and main.sock and proc is None):
                waits.append(1.0)  # look for the pad again; restart the remote
            waits.append(3.0)  # (and for a pad device that came up late, see Pad.open)
            if rechecks:
                waits.append(max(0.0, rechecks[0] - time.monotonic()))
            ready, _, _ = select.select(fds, [], [], min(waits) if waits else None)
            if rechecks and time.monotonic() >= rechecks[0]:
                rechecks.pop(0)
                if awake and remote.sock and not locked() and sway.powered(second) is False:
                    screen.on()

            for f in ready:
                if f in pad.devices:
                    pad.read(f)
                elif f in jack.fds:
                    if jack.unplugged(f):
                        main.send(["set_property", "pause", True])  # headphones out: not on the speaker
                elif guard and f in guard.fds:
                    was = guard.locked
                    guard.read(f)
                    if was and not guard.locked and second:
                        wake_remote()
                elif touch and f == touch.fd:
                    # only needed when the output is off: sway then keeps touches to itself.
                    # A tap wakes it, or a double tap when the players say so (then a hand resting on the dark screen does not).
                    downs = touch.touched()
                    if downs and not locked() and remote.sock and sway.powered(second) is False:
                        now = time.monotonic()
                        if wake_taps == 1 or downs > 1 or now - last_tap <= WAKE_TAPS_WITHIN:
                            last_tap = 0.0
                            awake = False
                            remote_lit()
                        else:
                            last_tap = now
                elif f is main.sock:
                    evs = main.read()
                    if evs is None:
                        stop_remote()  # the video ended
                        if main_sock != MAIN_SOCK:
                            return  # the music player's own hub ends with it
                        continue
                    for ev in evs:
                        if ev.get("event") == "property-change" and ev.get("id") == 3:
                            try:
                                req = json.loads(ev.get("data") or "{}")
                            except ValueError:
                                req = {}
                            if req.get("lock") and guard:
                                guard.lock()
                                awake = False
                            elif req.get("wake") and second and remote.sock and not locked():
                                # the pad picks something shown on the second screen (the queue)
                                if awake:  # already on: it starts its turn-off timer again
                                    remote.send(["script-message", "handheld-wake", "poke"])
                                else:
                                    awake = True
                                    screen.on()
                                    remote.send(["script-message", "handheld-wake"])
                                    if state:
                                        remote.send(["script-message", "handheld-state", state])
                        if ev.get("event") == "property-change" and ev.get("id") == 1:
                            state = ev.get("data")
                            try:
                                info = json.loads(state) if state else {}
                                keep = info.get("keep_on")
                            except (ValueError, AttributeError):
                                info, keep = {}, None
                            if guard and isinstance(info, dict) and "paused" in info:
                                guard.set_playing(not info["paused"])
                            if isinstance(info, dict) and info.get("wake_taps") in (1, 2):
                                wake_taps = info["wake_taps"]
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
                        if locked():
                            continue  # the second screen stays dark and does nothing meanwhile
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
                    if app == "mpv" and change == "new":
                        place_main()
                    elif app == REMOTE_ID and change == "new":
                        # shown for a few seconds when the player opens, so people
                        # learn it is there; it then sleeps like after any use
                        sway.run(f'[app_id="{REMOTE_ID}"] move container to output {second}, fullscreen enable')
                        screen.on()
                        sway.run(f"focus output {main_out}")
                        awake = True
                        remote.send(["script-message", "handheld-wake", "intro"])
                        if state:
                            remote.send(["script-message", "handheld-state", state])
                        rechecks = [time.monotonic() + 1.5, time.monotonic() + 4.0]
                    elif app == REMOTE_ID and change == "focus":
                        sway.run(f"focus output {main_out}")  # keep the main screen focused
            if pad.devices:
                pad.repeat()
            if locked() and "y" in pad.down and time.monotonic() - pad.down["y"] >= UNLOCK_HOLD:
                pad.down.pop("y")
                guard.unlock()
                if second:
                    wake_remote()
            if guard:
                guard.update()
            if seen_main and proc and proc.poll() is not None:
                proc = None  # remote crashed; started again on the next loop
                remote.close()
    finally:
        if guard:
            guard.close()
        jack.close()
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
    jack = HeadphoneJack()
    mapped = False
    drastic = False  # DraStic started: it owns the second screen now
    next_check = 0
    park_at = None  # when to park lowerdeck (see LOWERDECK_SETTLE)
    try:
        while proc.poll() is None:
            if mapped and not mpv.sock:
                mpv.connect()
            wait = 1.0 if park_at is None else min(1.0, max(0.0, park_at - time.monotonic()))
            ready, _, _ = select.select([f for f in (events, mpv.sock) if f] + jack.fds, [], [], wait)
            for f in ready:
                if f in jack.fds and jack.unplugged(f):
                    mpv.send(["set_property", "pause", True])  # headphones out: not on the speaker
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
        jack.close()
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
                # The video player's hub (mpv.service) stays out of the way of the
                # music player's own: two hubs would both read the pad and both
                # open a touch remote on the second screen.
                while sock == MAIN_SOCK and unit_active("handheld-music"):
                    time.sleep(1)
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
