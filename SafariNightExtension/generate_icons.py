#!/usr/bin/env python3
"""Reproducible Safari and iOS 18+ Light / Dark / Tinted app icons."""
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024

def color_mix(a, b, t):
    return tuple(round(a[i] * (1-t) + b[i] * t) for i in range(3))

def build_variant(variant):
    light = variant == "light"
    tint = variant == "tinted"
    bg_top = (242, 247, 255) if light else ((36, 40, 51) if tint else (9, 15, 29))
    bg_bottom = (192, 214, 255) if light else ((6, 8, 14) if tint else (24, 29, 58))
    img = Image.new("RGB", (SIZE, SIZE))
    pix = img.load()
    for y in range(SIZE):
        for x in range(SIZE):
            f = min(1, max(0, .58 * (y / SIZE) + .42 * (x / SIZE)))
            pix[x,y] = color_mix(bg_top, bg_bottom, f)

    art = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(art)

    # Main recognizable symbol: one rounded page and a crescent moon.
    if light:
        page = (41, 74, 146, 255)
        outline = (26, 52, 110, 255)
        moon = (243, 169, 40, 255)
        cutout = (242, 247, 255, 255)
        accent = (76, 126, 235, 255)
    elif tint:
        page = (230, 233, 238, 255)
        outline = (230, 233, 238, 255)
        moon = (236, 239, 243, 255)
        cutout = (36, 40, 51, 255)
        accent = (156, 161, 170, 255)
    else:
        page = (179, 205, 255, 255)
        outline = (100, 145, 254, 255)
        moon = (255, 222, 125, 255)
        cutout = (12, 19, 34, 255)
        accent = (119, 155, 242, 255)

    shadow = Image.new("RGBA", (SIZE,SIZE), (0,0,0,0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((205, 183, 695, 844), radius=118, fill=(0,0,0,75))
    shadow = shadow.filter(ImageFilter.GaussianBlur(38))
    art.alpha_composite(shadow)

    d = ImageDraw.Draw(art)
    d.rounded_rectangle((184, 154, 678, 823), radius=116, fill=page, outline=outline, width=14)
    d.rounded_rectangle((261, 263, 554, 305), radius=22, fill=accent)
    d.rounded_rectangle((261, 351, 504, 389), radius=19, fill=accent)
    d.rounded_rectangle((261, 438, 455, 473), radius=17, fill=accent)
    # Moon sits in the right area and stays visible on both icons.
    d.ellipse((470, 316, 865, 711), fill=moon)
    d.ellipse((592, 221, 953, 625), fill=cutout)
    if not tint:
        d.ellipse((721, 746, 755, 780), fill=moon)
        d.ellipse((768, 775, 789, 796), fill=moon)
    return Image.alpha_composite(img.convert("RGBA"), art).convert("RGB")

def save_png(img, name, size):
    path = Path(name)
    img.resize((size,size),Image.Resampling.LANCZOS).save(path,"PNG",optimize=True)

def main():
    stage = Path(sys.argv[1]).resolve()
    asset = Path(sys.argv[2]).resolve()
    appset = asset / "AppIcon.appiconset"
    appset.mkdir(parents=True,exist_ok=True)
    stage.mkdir(parents=True,exist_ok=True)
    images = {
        "light": build_variant("light"),
        "dark": build_variant("dark"),
        "tinted": build_variant("tinted"),
    }
    for name, image in images.items():
        image.save(appset / f"AppIcon-{name}.png", "PNG", optimize=True)
    contents = {
        "images":[
            {"filename":"AppIcon-light.png","idiom":"universal","platform":"ios","size":"1024x1024"},
            {"filename":"AppIcon-dark.png","idiom":"universal","platform":"ios","size":"1024x1024",
              "appearances":[{"appearance":"luminosity","value":"dark"}]},
            {"filename":"AppIcon-tinted.png","idiom":"universal","platform":"ios","size":"1024x1024",
              "appearances":[{"appearance":"luminosity","value":"tinted"}]},
        ],
        "info":{"author":"xcode","version":1}
    }
    (appset/"Contents.json").write_text(json.dumps(contents,ensure_ascii=False,indent=2)+"\n",encoding="utf8")
    icons = images["dark"]
    for size in [16,19,32,38,48,64,96,128,256,512]:
        save_png(icons,stage/f"icon-{size}.png",size)
    save_png(images["light"], stage/"AppIcon-Preview.png", 256)
    save_png(images["dark"], stage/"AppIcon-Preview-Dark.png", 256)
    print("Generated Light, Dark and Tinted asset catalog variants.")

if __name__ == "__main__":
    main()
