#!/usr/bin/env python3
"""Rebuilds every icon file the app ships from Resources/AppIcon.icon.

Run it after changing the icon (in Icon Composer, or with draw_icon.py), then
commit the results. Builds only copy these files; the Command Line Tools
toolchain has neither tool used here.

Writes, in Resources/:
  Assets.car                        the layered Liquid Glass icon macOS draws
  AppIcon.icns                      the flat fallback
  MacRemoteConnectorIcon{,128,64}.png, Favicon.png, Favicon.ico
                                    what connected apps and browsers are served
  MacRemoteConnectorIcon256.png     256 px and under 10 KB, for ChatGPT's icon upload
and docs/images/banner.png, the README banner.

Needs Xcode 26 or later (asset compiler and Icon Composer's renderer), Pillow,
and the pngquant and oxipng command line tools.
"""
import io
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageCms, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "Resources"
DOCUMENT = RESOURCES / "AppIcon.icon"
RENDERER = "Applications/Icon Composer.app/Contents/Executables/ictool"
BANNER = ROOT / "docs" / "images" / "banner.png"
SYSTEM_FONT = "/System/Library/Fonts/SFNS.ttf"


def find_xcode():
    """Returns the Developer folder of an Xcode that has Icon Composer."""
    selected = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
    for candidate in (os.environ.get("DEVELOPER_DIR"), selected,
                      "/Applications/Xcode.app/Contents/Developer",
                      "/Applications/Xcode-beta.app/Contents/Developer"):
        if candidate and (Path(candidate).parent / RENDERER).exists():
            return Path(candidate)
    sys.exit("error: no Xcode with Icon Composer found. Install Xcode 26 or later.")


def compile_catalog(developer_dir, work):
    """Compiles the document into Assets.car and AppIcon.icns."""
    subprocess.run(
        ["xcrun", "actool", str(DOCUMENT), "--compile", str(work), "--platform", "macosx",
         "--target-device", "mac", "--minimum-deployment-target", "26.0", "--app-icon", "AppIcon",
         "--output-partial-info-plist", str(work / "partial.plist")],
        check=True, capture_output=True, env={**os.environ, "DEVELOPER_DIR": str(developer_dir)})
    for name in ("Assets.car", "AppIcon.icns"):
        shutil.copyfile(work / name, RESOURCES / name)


def render(developer_dir, work, size):
    """Renders the default appearance at one size, as an 8-bit sRGB image.

    The renderer writes 16-bit Display P3. Browsers and connected apps get the
    smaller, plainer file; transparent corners are kept.
    """
    out = work / f"{size}.png"
    subprocess.run(
        [str(developer_dir.parent / RENDERER), str(DOCUMENT), "--export-image", "--output-file", str(out),
         "--platform", "macOS", "--rendition", "Default", "--width", str(size), "--height", str(size),
         "--scale", "1", "--design-generation", "27"],
        check=True, capture_output=True)
    image = Image.open(out)
    profile = image.info.get("icc_profile")
    image = image.convert("RGBA")
    if profile:
        colour = ImageCms.profileToProfile(
            image.convert("RGB"), ImageCms.ImageCmsProfile(io.BytesIO(profile)),
            ImageCms.createProfile("sRGB"), outputMode="RGB")
        colour.putalpha(image.getchannel("A"))
        image = colour
    return image


def draw_banner(icon):
    """Draws the README banner: the icon on its own indigo, then the name and tagline.

    Uses the icon's background gradient, a cyan glow, and faint arches that echo
    the tunnel. Drawn at 2x for a 1200-point-wide README column.
    """
    width, height, size = 2400, 840, 600
    top, bottom = (38, 23, 143), (13, 7, 70)
    cx, cy = 150 + size // 2, height // 2

    column = Image.new("RGB", (1, height))
    for y in range(height):
        t = y / (height - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    banner = column.resize((width, height)).convert("RGBA")

    arches = Image.new("RGBA", banner.size)
    pen = ImageDraw.Draw(arches)
    for i, r in enumerate(range(400, 1500, 150)):
        pen.rounded_rectangle((cx - r, cy - r, cx + r, cy + 3 * r), radius=r,
                              outline=(110, 120, 255, max(0, 80 - 11 * i)), width=4)
    banner = Image.alpha_composite(banner, arches.filter(ImageFilter.GaussianBlur(2)))

    glow = Image.new("RGBA", banner.size)
    ImageDraw.Draw(glow).ellipse((cx - 330, cy - 300, cx + 330, cy + 360), fill=(40, 200, 255, 150))
    banner = Image.alpha_composite(banner, glow.filter(ImageFilter.GaussianBlur(120)))

    icon = icon.resize((size, size), Image.LANCZOS)
    origin = (cx - size // 2, cy - size // 2)
    shadow = Image.new("RGBA", banner.size)
    shadow.paste((0, 0, 20, 150), (origin[0], origin[1] + 30), icon.getchannel("A"))
    banner = Image.alpha_composite(banner, shadow.filter(ImageFilter.GaussianBlur(40)))
    banner.alpha_composite(icon, origin)

    def font(points, weight):
        face = ImageFont.truetype(SYSTEM_FONT, points)
        face.set_variation_by_axes([100, 96, 400, weight])  # width, optical size, grade, weight
        return face

    pen = ImageDraw.Draw(banner)
    x = origin[0] + size + 120
    pen.text((x, cy - 40), "MacRemote", font=font(220, 700), fill=(255, 255, 255), anchor="ls")
    pen.text((x + 6, cy + 70), "Let your AI apps use your Mac.", font=font(76, 500),
             fill=(200, 225, 255), anchor="ls")
    pen.text((x + 6, cy + 165), "Only the parts you choose.", font=font(76, 500),
             fill=(120, 225, 255), anchor="ls")

    corners = Image.new("L", banner.size)
    ImageDraw.Draw(corners).rounded_rectangle((0, 0, width - 1, height - 1), radius=56, fill=255)
    banner.putalpha(ImageChops.multiply(banner.getchannel("A"), corners))
    BANNER.parent.mkdir(parents=True, exist_ok=True)
    banner.save(BANNER, optimize=True)


def save_upload_icon(image):
    """Writes the 256 px icon people upload to ChatGPT, which accepts PNG files up to 10 KB.

    A full-color PNG of the icon is about 60 KB, so this one uses a fixed
    palette without dithering: dithering noise makes the file larger.
    """
    target = RESOURCES / "MacRemoteConnectorIcon256.png"
    for tool in ("pngquant", "oxipng"):
        if not shutil.which(tool):
            sys.exit(f"error: {tool} is not installed (brew install {tool}).")
    with tempfile.TemporaryDirectory(prefix="macremote-icon") as tmp:
        source = Path(tmp) / "icon.png"
        image.resize((256, 256), Image.LANCZOS).save(source)
        subprocess.run(["pngquant", "--force", "--nofs", "--speed", "1", "--strip", "104",
                        "--output", str(target), str(source)], check=True)
    subprocess.run(["oxipng", "-q", "-o", "max", "--strip", "all", str(target)], check=True)
    if target.stat().st_size >= 10_000:
        sys.exit(f"error: {target.name} is {target.stat().st_size} bytes; ChatGPT accepts up to 10 KB.")


def main():
    if not DOCUMENT.is_dir():
        sys.exit(f"error: {DOCUMENT} is missing. Run Tools/icon/draw_icon.py first.")
    developer_dir = find_xcode()
    with tempfile.TemporaryDirectory(prefix="macremote-icon") as tmp:
        work = Path(tmp)
        compile_catalog(developer_dir, work)
        images = {size: render(developer_dir, work, size) for size in (1024, 512, 128, 64, 48, 32, 16)}
    images[512].save(RESOURCES / "MacRemoteConnectorIcon.png", optimize=True)
    images[128].save(RESOURCES / "MacRemoteConnectorIcon128.png", optimize=True)
    images[64].save(RESOURCES / "MacRemoteConnectorIcon64.png", optimize=True)
    save_upload_icon(images[512])
    images[32].save(RESOURCES / "Favicon.png", optimize=True)
    images[48].save(RESOURCES / "Favicon.ico", format="ICO", sizes=[(16, 16), (32, 32), (48, 48)],
                    append_images=[images[16], images[32]])
    draw_banner(images[1024])
    print("Rebuilt the icon files in Resources/ and the README banner — commit them.")


if __name__ == "__main__":
    main()
