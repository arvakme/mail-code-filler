#!/usr/bin/env python3
"""Generate optional local sender icons from the catalog's recorded official URLs."""

from __future__ import annotations

import argparse
import base64
import io
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener

try:
    from PIL import Image, ImageOps
except ImportError as error:  # pragma: no cover - reported to the script caller
    raise SystemExit(
        "Install the icon-fetch helper dependency with "
        "python3 -m pip install -r scripts/requirements-sender-icons.txt"
    ) from error


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Sources/Core/Resources/sender-brands.json"
ASSETS = ROOT / "Sources/App/Assets.xcassets"
APPLE_ART_HOSTS = {"is-assets.mzstatic.com"} | {
    f"is{number}-ssl.mzstatic.com" for number in range(1, 6)
}
SCALES = (("1x", 32), ("2x", 64), ("3x", 96))


def approved_url(url: str, allowed_hosts: set[str]) -> bool:
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower().rstrip(".")
    return parsed.scheme == "https" and any(
        host == allowed or host.endswith("." + allowed) for allowed in allowed_hosts
    )


class RedirectPolicy(HTTPRedirectHandler):
    def __init__(self, allowed_hosts: set[str]):
        super().__init__()
        self.allowed_hosts = allowed_hosts

    def redirect_request(self, request, response, code, message, headers, new_url):
        if not approved_url(new_url, self.allowed_hosts):
            raise URLError(f"Redirect outside approved HTTPS sources: {new_url}")
        return super().redirect_request(request, response, code, message, headers, new_url)


class EmbeddedIconParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.icons: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "link":
            return
        values = {key.lower(): value for key, value in attrs if key and value}
        rel = set((values.get("rel") or "").lower().split())
        href = values.get("href") or ""
        if "icon" in rel and href.startswith("data:image/"):
            self.icons.append(href)


def official_hosts(brand: dict) -> set[str]:
    hosts = set()
    website = urlparse(brand.get("brandWebsiteURL") or "")
    if website.scheme == "https" and website.hostname:
        hosts.add(website.hostname.lower().rstrip(".").removeprefix("www."))
    for value in brand.get("officialIconHosts", []):
        parsed = urlparse(value)
        if parsed.scheme == "https" and parsed.hostname:
            hosts.add(parsed.hostname.lower().rstrip("."))
    return hosts


def fetch(url: str, allowed_hosts: set[str], limit: int = 8_000_000) -> tuple[bytes, str]:
    if not approved_url(url, allowed_hosts):
        raise ValueError(f"Unapproved HTTPS source: {url}")
    opener = build_opener(RedirectPolicy(allowed_hosts))
    request = Request(url, headers={"User-Agent": "MailCodeFiller local sender icons"})
    with opener.open(request, timeout=30) as response:
        if not approved_url(response.geturl(), allowed_hosts):
            raise ValueError(f"Final URL is outside approved HTTPS sources: {response.geturl()}")
        content_type = response.headers.get_content_type()
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"Image or page exceeded {limit} bytes: {url}")
    return data, content_type


def decode_raster(data: bytes) -> Image.Image:
    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except Exception as error:
        raise ValueError(f"Source is not a decodable raster image: {error}") from error
    return image


def get_icon_image(brand: dict) -> Image.Image:
    source_type = brand.get("iconSource")
    source_url = brand.get("iconSourceURL")
    if not isinstance(source_url, str) or not source_url:
        raise ValueError("Missing recorded iconSourceURL")
    if source_type == "app-store":
        allowed_hosts = APPLE_ART_HOSTS
    elif source_type == "touch-icon":
        allowed_hosts = official_hosts(brand)
    else:
        raise ValueError(f"Unsupported iconSource: {source_type!r}")
    data, content_type = fetch(source_url, allowed_hosts)
    kind = brand.get("touchIconKind", "")
    if source_type == "touch-icon" and kind == "embedded-favicon":
        if "html" not in content_type:
            raise ValueError("Recorded embedded-favicon source did not return HTML")
        parser = EmbeddedIconParser()
        parser.feed(data.decode("utf-8", errors="replace"))
        image = None
        for icon in parser.icons:
            match = re.fullmatch(r"data:image/[^;,]+;base64,([A-Za-z0-9+/=]+)", icon)
            if match:
                try:
                    image = decode_raster(base64.b64decode(match.group(1), validate=True))
                    break
                except ValueError:
                    continue
        if image is None:
            raise ValueError("No decodable embedded favicon in the recorded official page")
    else:
        image = decode_raster(data)

    width, height = image.size
    is_touch_icon = source_type == "touch-icon" and kind.startswith("apple-touch-icon")
    quality_exception = brand.get("iconSourceQualityException")
    minimum = 120 if is_touch_icon and not quality_exception else 64
    if min(width, height) < minimum:
        raise ValueError(f"Source must be at least {minimum}px per dimension; got {width}×{height}")
    if is_touch_icon and width != height:
        raise ValueError(f"Touch icon source must be square; got {width}×{height}")
    if kind in {"favicon", "embedded-favicon"} and max(width, height) / min(width, height) > 1.25:
        raise ValueError(f"Favicon source must be close to square; got {width}×{height}")
    if kind == "brand-logo-left-mark":
        center = brand.get("iconCropCenter")
        if (
            not isinstance(center, list)
            or len(center) != 2
            or any(not isinstance(value, (int, float)) or not 0 <= value <= 1 for value in center)
        ):
            raise ValueError("Website logo crop requires a recorded iconCropCenter")
    image = image.convert("RGBA")
    if source_type == "touch-icon" and image.getchannel("A").getextrema()[0] < 255:
        tile = Image.new("RGBA", image.size, (255, 255, 255, 255))
        tile.alpha_composite(image)
        image = tile
    return ImageOps.fit(
        image,
        (96, 96),
        method=Image.Resampling.LANCZOS,
        centering=tuple(brand.get("iconCropCenter", (0.5, 0.5))),
    )


def write_assets(brand: dict, square: Image.Image) -> None:
    asset_name = brand.get("iconAssetName")
    if not isinstance(asset_name, str) or not re.fullmatch(r"Sender[A-Za-z0-9]+", asset_name):
        raise ValueError(f"Invalid iconAssetName: {asset_name!r}")
    imageset = ASSETS / f"{asset_name}.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    images = []
    for scale, pixels in SCALES:
        filename = f"sender-{scale}.png"
        output = square.resize((pixels, pixels), Image.Resampling.LANCZOS)
        output.save(imageset / filename, format="PNG", optimize=True)
        images.append({"filename": filename, "idiom": "universal", "scale": scale})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (imageset / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", action="append", default=[], help="Limit to this exact brand name; repeatable.")
    parser.add_argument("--check-only", action="store_true", help="Check recorded sources without writing assets.")
    args = parser.parse_args()
    try:
        brands = json.loads(CATALOG.read_text(encoding="utf-8"))
        if not isinstance(brands, list) or any(not isinstance(brand, dict) for brand in brands):
            raise ValueError("Catalog must be an array of brand objects")
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"Unable to load {CATALOG}: {error}", file=sys.stderr)
        return 1
    selected = [brand for brand in brands if not args.only or brand.get("name") in args.only]
    missing = set(args.only) - {brand.get("name") for brand in selected}
    if missing:
        print("Unknown brand(s): " + ", ".join(sorted(missing)), file=sys.stderr)
        return 1
    generated = 0
    errors = []
    for brand in selected:
        if brand.get("iconSource") == "monogram":
            continue
        try:
            image = get_icon_image(brand)
            if not args.check_only:
                write_assets(brand, image)
            generated += 1
            print(f"{brand['name']}: {brand['iconSource']} {brand['iconSourceURL']}")
        except Exception as error:
            errors.append(f"{brand.get('name')}: {error}")
    print(f"Official raster icons {'checked' if args.check_only else 'generated'}: {generated}")
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    # Network failures leave the source catalog and other local icons unchanged.
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
