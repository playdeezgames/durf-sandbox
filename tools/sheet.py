# Contact sheet of a tileset region with (col,row) labels: sheet.py c0 c1 r0 r1 out.png
import sys
from PIL import Image, ImageDraw
c0,c1,r0,r1=map(int,sys.argv[1:5]); out=sys.argv[5]
im=Image.open("assets/tileset.png").convert("RGB")
S=4; cell=12*S+2; lab=14
W=(c1-c0)*cell; H=(r1-r0)*(cell+lab)
o=Image.new("RGB",(W,H),(30,30,40)); d=ImageDraw.Draw(o)
for r in range(r0,r1):
    for c in range(c0,c1):
        t=im.crop((13*c+1,13*r+1,13*c+13,13*r+13)).resize((12*S,12*S),Image.NEAREST)
        x=(c-c0)*cell; y=(r-r0)*(cell+lab)
        o.paste(t,(x,y+lab)); d.text((x+1,y+1),f"{c},{r}",fill=(255,255,0))
o.save(out)
