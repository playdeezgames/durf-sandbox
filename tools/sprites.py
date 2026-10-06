# Contact sheet of every sprite the game assigns (parsed from src/web.odin), labelled by name:
#   python3 tools/sprites.py out.png
import re, sys
from PIL import Image, ImageDraw
src = open("src/web.odin").read()
tiles = {}
for m in re.finditer(r"^SPR_(\w+)\s*:: Tile\{(\d+), (\d+)\}", src, re.M):
    tiles["SPR_" + m.group(1)] = (int(m.group(2)), int(m.group(3)))
block = src[src.index("MOB_SPRITES"):]
block = block[:block.index("\n}")]
for m in re.finditer(r"\.(\w+)\s*=\s*\{(\d+), (\d+)\}", block):
    tiles[m.group(1)] = (int(m.group(2)), int(m.group(3)))
im = Image.open("assets/tileset.png").convert("RGBA")
S, cell, lab = 6, 12 * 6 + 8, 14
cols = 6
rows = (len(tiles) + cols - 1) // cols
out = Image.new("RGB", (cols * (cell + 40), rows * (cell + lab)), (20, 20, 30))
d = ImageDraw.Draw(out)
for i, (name, (c, r)) in enumerate(tiles.items()):
    t = im.crop((13 * c + 1, 13 * r + 1, 13 * c + 13, 13 * r + 13)).resize((12 * S, 12 * S), Image.NEAREST)
    x, y = (i % cols) * (cell + 40), (i // cols) * (cell + lab)
    out.paste(t, (x, y + lab))
    d.text((x, y), f"{name} ({c},{r})", fill=(255, 255, 0))
out.save(sys.argv[1])
