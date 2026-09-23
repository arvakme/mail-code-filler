#!/usr/bin/env python3
"""Fetch official App Store artwork or first-party touch icons into the asset catalog."""

from __future__ import annotations

import argparse
import base64
import io
import json
import re
import sys
import time
from html.parser import HTMLParser
from pathlib import Path
from urllib.error import URLError
from urllib.parse import urlencode, urljoin, urlparse
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
APPLE_API_HOST = "itunes.apple.com"
APPLE_ART_HOSTS = {"is-assets.mzstatic.com"} | {
    f"is{number}-ssl.mzstatic.com" for number in range(1, 6)
}
APPLE_ART_HOST = re.compile(r"^is(?:[1-5]-ssl|[-]assets)\.mzstatic\.com$", re.IGNORECASE)
SCALES = (("1x", 32), ("2x", 64), ("3x", 96))


class RedirectPolicy(HTTPRedirectHandler):
    def __init__(self, allowed_hosts: set[str]):
        super().__init__()
        self.allowed_hosts = allowed_hosts

    def host_is_allowed(self, host: str) -> bool:
        return any(host == allowed or host.endswith("." + allowed) for allowed in self.allowed_hosts)

    def redirect_request(self, request, response, code, message, headers, new_url):
        host = (urlparse(new_url).hostname or "").lower()
        if not self.host_is_allowed(host):
            raise URLError(f"Redirect outside approved hosts: {host}")
        return super().redirect_request(request, response, code, message, headers, new_url)


class TouchIconParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links: list[tuple[int, str, str]] = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "link":
            return
        values = {key.lower(): value for key, value in attrs if key and value}
        rel = set((values.get("rel") or "").lower().split())
        href = values.get("href")
        if not href:
            return
        sizes = []
        for size in (values.get("sizes") or "").lower().split():
            match = re.fullmatch(r"(\d+)x(\d+)", size)
            if match and match.group(1) == match.group(2):
                sizes.append(int(match.group(1)))
        if any(value == "apple-touch-icon" or value.startswith("apple-touch-icon-") for value in rel):
            kind = "apple-touch-icon-precomposed" if "apple-touch-icon-precomposed" in rel else "apple-touch-icon"
            self.links.append((max(sizes, default=180), href, kind))
        elif "icon" in rel:
            kind = "embedded-favicon" if href.startswith("data:image/") else "favicon"
            self.links.append((max(sizes, default=0), href, kind))


def official_hosts(brand: dict) -> set[str]:
    hosts = set()
    for value in [brand.get("brandWebsiteURL"), *brand.get("officialIconHosts", [])]:
        parsed = urlparse(value or "")
        if parsed.hostname:
            hosts.add(parsed.hostname.lower().rstrip("."))
    for domain in brand.get("domains", []) + brand.get("knownSendingSubdomains", []):
        hosts.add(domain.lower().rstrip("."))
    return hosts


def within_site(host: str, brand: dict) -> bool:
    host = host.lower().rstrip(".")
    return any(host == allowed or host.endswith("." + allowed) for allowed in official_hosts(brand))


def fetch(url: str, allowed_hosts: set[str], limit: int = 8_000_000) -> tuple[bytes, str, str]:
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or not any(host == allowed or host.endswith("." + allowed) for allowed in allowed_hosts):
        raise ValueError(f"Unapproved HTTPS host: {host or 'missing'}")
    opener = build_opener(RedirectPolicy(allowed_hosts))
    request = Request(url, headers={"User-Agent": "MailCodeFiller sender icon source refresh"})
    with opener.open(request, timeout=30) as response:
        final_url = response.geturl()
        final_host = (urlparse(final_url).hostname or "").lower()
        if not any(final_host == allowed or final_host.endswith("." + allowed) for allowed in allowed_hosts):
            raise ValueError(f"Final URL is outside approved hosts: {final_host}")
        content_type = response.headers.get_content_type()
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"Image or page exceeded {limit} bytes: {url}")
    return data, final_url, content_type


def lookup_artwork(brand: dict, delay_seconds: float) -> tuple[str, dict]:
    track_id = brand.get("appStoreTrackId")
    country = brand.get("appStoreCountry")
    if not isinstance(track_id, int) or not country:
        raise ValueError("app-store source requires appStoreTrackId and appStoreCountry")
    if delay_seconds:
        time.sleep(delay_seconds)
    query = urlencode({"id": track_id, "country": country})
    api_url = f"https://{APPLE_API_HOST}/lookup?{query}"
    body, _, _ = fetch(api_url, {APPLE_API_HOST}, limit=2_000_000)
    response = json.loads(body)
    matches = [item for item in response.get("results", []) if item.get("trackId") == track_id]
    if len(matches) != 1:
        raise ValueError(f"iTunes lookup returned {len(matches)} records for trackId {track_id}")
    item = matches[0]
    for key, actual_key in (
        ("appStoreBundleId", "bundleId"),
        ("appStoreSellerName", "sellerName"),
    ):
        expected = brand.get(key)
        actual = item.get(actual_key)
        if not expected or str(actual).casefold() != str(expected).casefold():
            raise ValueError(
                f"{key} mismatch for {brand['name']}: expected {expected!r}, received {actual!r}"
            )
    artwork = item.get("artworkUrl512")
    host = (urlparse(artwork or "").hostname or "").lower()
    if not artwork or not APPLE_ART_HOST.fullmatch(host):
        raise ValueError(f"Unexpected App Store artwork host for {brand['name']}: {host or 'missing'}")
    return artwork, item


def discover_touch_icons(brand: dict) -> list[tuple[str, str, str]]:
    website = brand.get("brandWebsiteURL")
    if not website:
        raise ValueError("touch-icon source requires brandWebsiteURL")
    allowed_hosts = official_hosts(brand)
    body, final_url, content_type = fetch(website, allowed_hosts, limit=3_000_000)
    if "html" not in content_type:
        raise ValueError(f"Official site did not return HTML: {final_url}")
    parser = TouchIconParser()
    parser.feed(body.decode("utf-8", errors="replace"))
    choices = sorted(parser.links, key=lambda link: link[0], reverse=True)
    candidates: list[tuple[str, str, str]] = []
    for _, href, source_kind in choices:
        if not source_kind.startswith("apple-touch-icon"):
            continue
        candidate = urljoin(final_url, href)
        host = (urlparse(candidate).hostname or "").lower()
        if within_site(host, brand):
            candidates.append((candidate, final_url, source_kind))
    convention = urljoin(final_url, "/apple-touch-icon.png")
    if all(candidate[0] != convention for candidate in candidates):
        candidates.append((convention, final_url, "apple-touch-icon-convention"))
    for _, href, source_kind in choices:
        if source_kind.startswith("apple-touch-icon"):
            continue
        if source_kind == "embedded-favicon":
            candidates.append((href, final_url, source_kind))
            continue
        candidate = urljoin(final_url, href)
        host = (urlparse(candidate).hostname or "").lower()
        if within_site(host, brand):
            candidates.append((candidate, final_url, source_kind))
    return candidates


def decode_raster(data: bytes):
    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except Exception as error:
        raise ValueError(f"Source is not a decodable raster image: {error}") from error
    return image


def get_icon_image(brand: dict, delay_seconds: float) -> tuple[str, object, int, int]:
    source_type = brand.get("iconSource")
    if source_type == "app-store":
        source_url, api_record = lookup_artwork(brand, delay_seconds)
        data, final_url, _ = fetch(source_url, APPLE_ART_HOSTS)
        brand["appStoreArtworkURL"] = source_url
        brand["appStoreTrackViewURL"] = api_record.get("trackViewUrl") or brand.get("appStoreTrackViewURL")
        brand["appStoreTrackName"] = api_record.get("trackName")
        brand["appStoreArtistName"] = api_record.get("artistName")
        brand["iconSourceURL"] = final_url
        brand["brandAssetSourceURL"] = brand["appStoreTrackViewURL"]
    elif source_type == "touch-icon":
        for key in (
            "appStoreTrackId", "appStoreBundleId", "appStoreSellerName", "appStoreCountry",
            "appStoreArtworkURL", "appStoreTrackViewURL", "appStoreTrackName", "appStoreArtistName",
        ):
            brand.pop(key, None)
        if brand.get("touchIconKind") == "embedded-favicon":
            candidates = [
                candidate for candidate in discover_touch_icons(brand) if candidate[2] == "embedded-favicon"
            ]
        elif brand.get("iconSourceURL"):
            candidates = [(
                brand["iconSourceURL"],
                brand.get("touchIconPageURL") or brand.get("brandWebsiteURL"),
                brand.get("touchIconKind") or "apple-touch-icon",
            )]
        else:
            candidates = discover_touch_icons(brand)
        failures = []
        image = None
        width = height = 0
        for source_url, page_url, source_kind in candidates:
            try:
                if source_kind == "embedded-favicon":
                    match = re.fullmatch(r"data:image/[^;,]+;base64,([A-Za-z0-9+/=]+)", source_url)
                    if not match:
                        raise ValueError("Embedded favicon is not a base64 image data URL")
                    data = base64.b64decode(match.group(1), validate=True)
                    final_url = page_url
                else:
                    host = (urlparse(source_url).hostname or "").lower()
                    if not within_site(host, brand):
                        raise ValueError(f"unapproved touch icon host {host or 'missing'}")
                    data, final_url, _ = fetch(source_url, official_hosts(brand))
                candidate_image = decode_raster(data)
                candidate_width, candidate_height = candidate_image.size
                is_touch_icon = source_kind.startswith("apple-touch-icon")
                is_brand_mark_crop = source_kind == "brand-logo-left-mark"
                quality_exception = brand.get("iconSourceQualityException")
                minimum = 120 if is_touch_icon and not quality_exception else 64
                if candidate_width < minimum or candidate_height < minimum:
                    raise ValueError(
                        f"Icon source requires at least {minimum}px per dimension; got {candidate_width}×{candidate_height}"
                    )
                if is_touch_icon and candidate_width != candidate_height:
                    raise ValueError(f"Touch icon source must be square; got {candidate_width}×{candidate_height}")
                if is_touch_icon and quality_exception and min(candidate_width, candidate_height) < 64:
                    raise ValueError(f"Quality-exception touch icon is below 64 pixels: {candidate_width}×{candidate_height}")
                if source_kind == "favicon" and max(candidate_width, candidate_height) / min(candidate_width, candidate_height) > 1.25:
                    raise ValueError(f"Favicon is too far from square for a centered avatar crop: {candidate_width}×{candidate_height}")
                if is_brand_mark_crop and not isinstance(brand.get("iconCropCenter"), list):
                    raise ValueError("A website logo mark crop requires a recorded iconCropCenter")
                image = candidate_image
                width, height = candidate_width, candidate_height
                brand["touchIconPageURL"] = page_url
                brand["touchIconKind"] = source_kind
                brand["iconSourceURL"] = page_url if source_kind == "embedded-favicon" else final_url
                brand["brandAssetSourceURL"] = page_url or brand.get("brandWebsiteURL")
                break
            except Exception as error:
                failures.append(str(error))
        if image is None:
            raise ValueError("No first-party icon met the quality checks: " + "; ".join(failures))
    else:
        raise ValueError(f"Icon source must be app-store or touch-icon, received {source_type!r}")

    if source_type == "app-store":
        image = decode_raster(data)
        width, height = image.size
        if width < 64 or height < 64:
            raise ValueError(f"Icon source is below 64 pixels: {width}×{height}")
    else:
        rgba = image.convert("RGBA")
        if rgba.getchannel("A").getextrema()[0] < 255:
            tile = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
            tile.alpha_composite(rgba)
            image = tile
    square = ImageOps.fit(
        image.convert("RGBA"),
        (96, 96),
        method=Image.Resampling.LANCZOS,
        centering=tuple(brand.get("iconCropCenter", (0.5, 0.5))),
    )
    brand["iconSourcePixelWidth"] = width
    brand["iconSourcePixelHeight"] = height
    brand["iconPresentation"] = "original"
    brand["simpleIconsSlug"] = "none"
    brand["simpleIconsVersion"] = "none"
    brand["license"] = "none"
    brand["licenseURL"] = "none"
    brand["guidelinesURL"] = brand.get("guidelinesURL") or brand.get("brandWebsiteURL")
    brand["guidelinesURLSource"] = "official-brand-site"
    return final_url, square, width, height


def write_assets(brand: dict, square: object) -> None:
    asset_name = brand.get("iconAssetName")
    if not isinstance(asset_name, str) or not asset_name.startswith("Sender"):
        raise ValueError(f"Invalid iconAssetName for {brand['name']}: {asset_name!r}")
    imageset = ASSETS / f"{asset_name}.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    images = []
    for scale, pixels in SCALES:
        filename = f"sender-{scale}.png"
        output = square.resize((pixels, pixels), Image.Resampling.LANCZOS)
        output.save(imageset / filename, format="PNG", optimize=True)
        images.append({"filename": filename, "idiom": "universal", "scale": scale})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (imageset / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    for legacy in imageset.glob("sender.svg"):
        legacy.unlink()


def make_monogram(brand: dict, reason: str) -> None:
    brand["iconSource"] = "monogram"
    brand["iconAssetName"] = None
    brand["iconPresentation"] = None
    brand["iconSourceURL"] = None
    brand["brandAssetSourceURL"] = None
    brand["simpleIconsSlug"] = "none"
    brand["simpleIconsVersion"] = "none"
    brand["license"] = "none"
    brand["licenseURL"] = "none"
    brand["guidelinesURL"] = None
    brand["guidelinesURLSource"] = None
    brand["iconSourceFailureReason"] = reason
    for key in (
        "appStoreTrackId", "appStoreBundleId", "appStoreSellerName", "appStoreCountry",
        "appStoreArtworkURL", "appStoreTrackViewURL", "appStoreTrackName", "appStoreArtistName",
        "touchIconPageURL", "touchIconKind", "iconSourcePixelWidth", "iconSourcePixelHeight",
        "iconCropCenter", "iconSourceQualityException",
    ):
        brand.pop(key, None)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", action="append", default=[], help="Limit to this exact brand name; repeatable.")
    parser.add_argument("--check-only", action="store_true", help="Check sources and image quality without writing assets.")
    parser.add_argument("--request-delay", type=float, default=1.1, help="Seconds between iTunes lookup requests.")
    args = parser.parse_args()
    if args.request_delay < 0:
        parser.error("--request-delay must be nonnegative")
    try:
        brands = json.loads(CATALOG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"Unable to load {CATALOG}: {error}", file=sys.stderr)
        return 1

    selected = [brand for brand in brands if not args.only or brand.get("name") in args.only]
    if args.only:
        missing = set(args.only) - {brand.get("name") for brand in selected}
        if missing:
            print("Unknown brand(s): " + ", ".join(sorted(missing)), file=sys.stderr)
            return 1
    refreshed = 0
    fallback_count = 0
    errors = []
    for brand in selected:
        source_type = brand.get("iconSource")
        if source_type == "monogram":
            brand["iconAssetName"] = None
            brand["iconPresentation"] = None
            continue
        if source_type not in {"app-store", "touch-icon"}:
            errors.append(f"{brand.get('name')}: missing explicit iconSource; choose app-store, touch-icon, or monogram")
            continue
        try:
            final_url, image, _, _ = get_icon_image(brand, args.request_delay)
            if not args.check_only:
                write_assets(brand, image)
            refreshed += 1
            print(f"{brand['name']}: {source_type} {final_url}")
        except Exception as error:
            if source_type == "touch-icon":
                make_monogram(brand, f"官网 apple-touch-icon/favicon 不存在或未达 120px 方形要求：{error}")
                fallback_count += 1
                print(f"{brand['name']}: monogram fallback ({error})")
            else:
                errors.append(f"{brand.get('name')}: {error}")

    if not args.check_only:
        CATALOG.write_text(json.dumps(brands, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        referenced = {brand.get("iconAssetName") for brand in brands if brand.get("iconAssetName")}
        for imageset in ASSETS.glob("Sender*.imageset"):
            if imageset.name.removesuffix(".imageset") not in referenced:
                for child in imageset.iterdir():
                    child.unlink()
                imageset.rmdir()
    print(
        f"Official raster icons checked/refreshed: {refreshed}; "
        f"monogram fallbacks: {sum(b.get('iconSource') == 'monogram' for b in selected)} "
        f"(new fallback decisions: {fallback_count})"
    )
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
