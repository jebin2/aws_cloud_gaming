# The game PC's desktop help picture: black, pale green, flat colours only.
# Draws lib/assets/gamepc-help.png (needs Pillow and the DejaVu fonts, on a
# developer's machine only - the box is sent the finished picture):
#     python3 -I tools/draw-wallpaper.py lib/assets/gamepc-help.png
# Flat fills and no gradient on purpose: a stream at a low bitrate bands a gradient
# and smears fine detail, while flat black with sharp, large text stays clean.
from PIL import Image, ImageDraw, ImageFont
import sys
W, H = 1920, 1080
D = "/usr/share/fonts/truetype/dejavu/"
f = lambda n, s: ImageFont.truetype(D + n, s)
mono, monob = "DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf"

BG = (0, 0, 0)
GREEN = (170, 255, 170)      # the text
BRIGHT = (210, 255, 210)     # headings and keys
DIM = (96, 168, 96)          # the quieter lines
img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

PX0, PY0, PX1, PY1 = 700, 60, 1860, 868
d.rectangle((PX0, PY0, PX1, PY1), outline=GREEN, width=2)
x = PX0 + 48
y = PY0 + 30

d.text((x, y), "> your game PC_", font=f(monob, 44), fill=BRIGHT)
y += 82

def head(text):
    global y
    d.text((x, y), "# " + text.upper(), font=f(monob, 24), fill=BRIGHT)
    d.line((x, y + 36, PX1 - 48, y + 36), fill=DIM, width=2)
    y += 50

def key(k, words):
    global y
    kf = f(monob, 26)
    d.rectangle((x, y - 4, x + 40, y + 36), outline=GREEN, width=2)
    d.text((x + 20, y + 16), k, font=kf, fill=BRIGHT, anchor="mm")
    d.text((x + 72, y + 2), words, font=f(mono, 24), fill=GREEN)
    y += 45

def line(words, color=GREEN, size=24, gap=34):
    global y
    d.text((x, y), words, font=f(mono, size), fill=color)
    y += gap

head("moonlight keys   hold Ctrl + Alt + Shift, then press")
key("Z", "release the mouse and keyboard, again to give them back")
key("X", "fullscreen or windowed")
key("D", "minimise the stream")
key("Q", "stop the stream (the game keeps running here)")
y += 2
line("while the stream has focus, Super and Windows shortcuts go to", DIM, 21, 28)
line("this PC; press Z to use your own. on a Mac: Command + Option.", DIM, 21, 28)
y += 12

head("added a disk?")
line("Steam > Settings > Storage > Add Drive > pick the drive named cgextra")
y += 10

head("before you delete this machine")
# the one warning, inverted so it stands out without a second colour
d.rectangle((x - 8, y - 4, PX1 - 40, y + 36), fill=GREEN)
d.text((x + 4, y + 2), "games still downloading are NOT saved. let them finish.", font=f(monob, 25), fill=BG)
y += 52
line("finished games are saved for the next machine you build.")
y += 10

head("it switches itself off")
line("after 15 minutes with no stream, download or install.")
line("on spot that deletes the machine; finished games are saved first.", DIM, 21, 30)

out = sys.argv[1] if len(sys.argv) > 1 else "wallpaper.png"
img.save(out, optimize=True)
print(out, "content ends", y, "panel ends", PY1)
