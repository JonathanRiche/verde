from pathlib import Path
import base64, subprocess
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
root=Path(__file__).resolve().parent.parent
out=Path(__file__).resolve().parent
logo=base64.b64encode((root/'packages/mobile_android/app/src/main/res/drawable-nodpi/verde_logo.png').read_bytes()).decode()
fonts=root/'packages/desktop/src/assets/fonts'
def text(s,x,y,size,color='#f0f0f5',display=False):
 f=TTFont(fonts/('CalSans-Regular.ttf' if display else 'NotoSans-Regular.ttf')); gs=f.getGlyphSet(); cm=f.getBestCmap(); scale=size/f['head'].unitsPerEm; pos=0; paths=[]
 for ch in s:
  n=cm[ord(ch)]; p=SVGPathPen(gs);gs[n].draw(p)
  paths.append(f'<path transform="translate({pos} 0)" d="{p.getCommands()}"/>');pos+=f['hmtx'][n][0]
 return f'<g fill="{color}" transform="translate({x} {y}) scale({scale} {-scale})">'+''.join(paths)+'</g>'
def mark(x,y,w,h):
 return f'<image x="{x}" y="{y}" width="{w}" height="{h}" href="data:image/png;base64,{logo}" filter="url(#green)"/>'
def save(name,w,h,body):
 svg=f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}"><defs><filter id="green" color-interpolation-filters="sRGB"><feFlood flood-color="#50c878"/><feComposite in2="SourceAlpha" operator="in"/></filter></defs><rect width="100%" height="100%" fill="#0d1213"/>'+body+'</svg>'
 p=out/(name+'.svg');p.write_text(svg)
 subprocess.run(['rsvg-convert',str(p),'-o',str(out/(name+'.png'))],check=True)
save('app-icon-512',512,512,mark(124,103,264,306))
body='<path d="M680 0V500M736 0V500M792 0V500M848 0V500M904 0V500M960 0V500M640 82H1024M640 138H1024M640 194H1024M640 250H1024M640 306H1024M640 362H1024M640 418H1024" stroke="#202d29" stroke-width="1"/>'
body+=text('Verde',64,125,58,display=True)+text('Your coding workspace.',64,225,48,display=True)+text('Within reach.',64,281,48,'#50c878',True)
body+=text('Follow chats. Review changes. Keep moving.',66,345,21,'#b9bbc3')+text('The Android companion for your Verde host',66,426,16,'#b9bbc3')
body+=mark(725,105,218,253)
save('feature-graphic-1024x500',1024,500,body)
print('Rendered icon and feature graphic')
