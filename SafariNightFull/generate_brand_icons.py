#!/usr/bin/env python3
"""智夜 Z 星标：原创 App、扩展按钮以及 iOS 浅色/深色/着色图标。"""
import json, math, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

SIZE=1024
S=2
P=SIZE*S

def background(a,b):
    im=Image.new("RGB",(SIZE,SIZE))
    d=ImageDraw.Draw(im)
    for y in range(SIZE):
        t=(1-math.cos(math.pi*y/(SIZE-1)))*.5
        c=tuple(round(a[i]*(1-t)+b[i]*t) for i in range(3))
        d.line((0,y,SIZE,y),fill=c)
    return im.convert("RGBA")

def zmark(d, color, sx=0, sy=0):
    pts=[(287*S+sx,308*S+sy),(739*S+sx,308*S+sy),
         (287*S+sx,731*S+sy),(739*S+sx,731*S+sy)]
    w=112*S
    for a,b in zip(pts,pts[1:]):
        d.line((a,b),fill=color,width=w,joint="curve")
    for x,y in pts:
        r=w//2
        d.ellipse((x-r,y-r,x+r,y+r),fill=color)

def star(d,color):
    x,y=795*S,228*S
    r=52*S
    d.polygon([(x,y-r),(x+r*.20,y-r*.20),(x+r,y),
               (x+r*.20,y+r*.20),(x,y+r),
               (x-r*.20,y+r*.20),(x-r,y),
               (x-r*.20,y-r*.20)],fill=color)

def icon(variant):
    if variant=="light":
        bg=background((247,249,255),(206,220,252))
        ink=(39,60,137,255); shadow=(76,87,165,95); glow=(255,170,74,255)
    elif variant=="dark":
        bg=background((14,20,49),(38,30,91))
        ink=(220,230,255,255); shadow=(6,10,45,120); glow=(255,203,105,255)
    else:
        bg=background((24,28,36),(40,43,51))
        ink=(247,248,252,255); shadow=(0,0,0,55); glow=(247,248,252,255)
    layer=Image.new("RGBA",(P,P))
    d=ImageDraw.Draw(layer)
    zmark(d,shadow,7*S,13*S)
    layer=layer.filter(ImageFilter.GaussianBlur(24*S))
    bg=Image.alpha_composite(bg,layer.resize((SIZE,SIZE),Image.Resampling.LANCZOS))
    layer=Image.new("RGBA",(P,P))
    d=ImageDraw.Draw(layer)
    zmark(d,ink)
    star(d,glow)
    return Image.alpha_composite(bg,layer.resize((SIZE,SIZE),Image.Resampling.LANCZOS)).convert("RGB")

def main():
    stage=Path(sys.argv[1]).resolve()
    assets=Path(sys.argv[2]).resolve()
    appset=assets/"AppIcon.appiconset"
    appset.mkdir(parents=True,exist_ok=True)
    stage.mkdir(parents=True,exist_ok=True)
    images={name:icon(name) for name in ("light","dark","tinted")}
    for name,img in images.items():
        img.save(appset/f"AppIcon-{name}.png",optimize=True)
    contents={"images":[
        {"filename":"AppIcon-light.png","idiom":"universal","platform":"ios","size":"1024x1024"},
        {"filename":"AppIcon-dark.png","idiom":"universal","platform":"ios","size":"1024x1024",
         "appearances":[{"appearance":"luminosity","value":"dark"}]},
        {"filename":"AppIcon-tinted.png","idiom":"universal","platform":"ios","size":"1024x1024",
         "appearances":[{"appearance":"luminosity","value":"tinted"}]}
        ],"info":{"author":"xcode","version":1}}
    (appset/"Contents.json").write_text(json.dumps(contents,ensure_ascii=False,indent=2)+"\n")
    # Dark Reader 在后台脚本中动态切换这些固定文件路径；
    # 逐一替换资源本身，杜绝主屏幕已经换图标但 Safari 工具栏仍是旧图标。
    originals=[
      ("dr_16.png",16,"light"),("dr_48.png",48,"light"),("dr_128.png",128,"light"),
      ("dr_active_19.png",19,"dark"),("dr_active_38.png",38,"dark"),
      ("dr_active_light_19.png",19,"light"),("dr_active_light_38.png",38,"light")
    ]
    folder=stage/"icons"
    folder.mkdir(parents=True,exist_ok=True)
    for name,size,variant in originals:
        images[variant].resize((size,size),Image.Resampling.LANCZOS).save(folder/name,optimize=True)
    for size in (16,19,32,38,48,64,96,128,256,512):
        images["dark"].resize((size,size),Image.Resampling.LANCZOS).save(stage/f"icon-{size}.png",optimize=True)
    images["light"].resize((256,256),Image.Resampling.LANCZOS).save(stage/"AppIcon-Preview.png",optimize=True)
    images["dark"].resize((256,256),Image.Resampling.LANCZOS).save(stage/"AppIcon-Preview-Dark.png",optimize=True)
    pop=stage/"ui"/"popup"
    pop.mkdir(parents=True,exist_ok=True)
    images["dark"].resize((96,96),Image.Resampling.LANCZOS).save(pop/"zhiye-logo.png",optimize=True)
    print("智夜 Z 星标、原生浅色/深色/着色图标、Safari 工具栏 7 种图标已生成")

if __name__=="__main__":
    main()
