"""Generates plug icons for the UniFi_Controller driver and patches its driver.xml.
Run from the Control4-Drivers repo root: python tools/make_unifi_icons.py
"""
import os
import re
from PIL import Image, ImageDraw

ROOT = os.path.join("drivers", "unifi-controller")
XML = os.path.join(ROOT, "UniFi_Controller_driver.xml")


def draw(size):
    s = 1024
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((32, 32, s - 32, s - 32), radius=200, fill=(18, 94, 196, 255))
    w = (255, 255, 255, 255)
    d.rounded_rectangle((350, 170, 420, 400), radius=30, fill=w)
    d.rounded_rectangle((604, 170, 674, 400), radius=30, fill=w)
    d.rounded_rectangle((280, 380, 744, 640), radius=90, fill=w)
    d.rectangle((452, 620, 572, 760), fill=w)
    d.rounded_rectangle((472, 740, 552, 900), radius=40, fill=w)
    return im.resize((size, size), Image.LANCZOS)


os.makedirs(os.path.join(ROOT, "icons"), exist_ok=True)
os.makedirs(os.path.join(ROOT, "www", "icons", "device", "outlets"), exist_ok=True)
for name, sz in (("device_sm.png", 16), ("device_lg.png", 32)):
    draw(sz).save(os.path.join(ROOT, "icons", name))
    draw(sz).save(os.path.join(ROOT, "www", "icons", name))
for sz in (70, 90, 300, 512, 1024):
    draw(sz).save(os.path.join(ROOT, "www", "icons", "device", "outlets", "experience_%d.png" % sz))


def icon_lines(indent):
    return "\n".join(
        '%s<Icon width="%d" height="%d">controller://driver/UniFi_PDU_Controls/icons/device/outlets/experience_%d.png</Icon>'
        % (indent, s, s, s)
        for s in (70, 90, 300, 512, 1024)
    )


block = (
    "\t<capabilities>\n"
    '\t\t<web_view_url proxybindingid="5001">controller://driver/UniFi_PDU_Controls/outlets1.html</web_view_url>\n'
    "\t\t<mobile_web_view_enabled>true</mobile_web_view_enabled>\n"
    '\t\t<navigator_display_option proxybindingid="5001">\n'
    "\t\t\t<display_icons>\n" + icon_lines("\t\t\t\t") + "\n"
    '\t\t\t\t<state id="Default">\n' + icon_lines("\t\t\t\t\t") + "\n"
    "\t\t\t\t</state>\n"
    "\t\t\t</display_icons>\n"
    "\t\t</navigator_display_option>\n"
    "\t</capabilities>"
)

with open(XML, "r", encoding="utf-8", newline="") as f:
    x = f.read()
nl = "\r\n" if "\r\n" in x else "\n"
x = x.replace("\r\n", "\n")
assert "<capabilities />" in x
x = x.replace("\t<capabilities />\n", "", 1)
x, n = re.subn(
    r'\t<web_view_url proxybindingid="5001">[^\n]*\n\t<mobile_web_view_enabled>true</mobile_web_view_enabled>\n',
    block + "\n",
    x,
    count=1,
)
assert n == 1 and "<navigator_display_option" in x
x = x.replace("<default>1.0.4</default>", "<default>1.0.5</default>").replace("<version>5</version>", "<version>6</version>")
with open(XML, "w", encoding="utf-8", newline="") as f:
    f.write(x.replace("\n", nl))
print("ok")
