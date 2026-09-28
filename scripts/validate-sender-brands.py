#!/usr/bin/env python3
"""Validate sender catalog provenance and any optional local avatar assets."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Sources/Core/Resources/sender-brands.json"
ASSETS = ROOT / "Sources/App/Assets.xcassets"
HEX_PATTERN = re.compile(r"^[0-9A-Fa-f]{6}$")
HOST_PATTERN = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$")
APPLE_ART_HOST = re.compile(r"^is(?:[1-5]-ssl|[-]assets)\.mzstatic\.com$", re.IGNORECASE)
PERSONAL_MAILBOX_DOMAINS = {
    "gmail.com", "googlemail.com", "qq.com", "foxmail.com", "163.com", "126.com", "yeah.net",
    "vip.163.com", "vip.126.com", "outlook.com", "outlook.cn", "hotmail.com", "hotmail.co.uk",
    "hotmail.fr", "live.com", "live.co.uk", "msn.com", "icloud.com", "me.com", "mac.com",
    "yahoo.com", "yahoo.net", "yahoo.co.jp", "yahoo.co.uk", "yahoo.com.cn", "ymail.com",
    "rocketmail.com", "proton.me", "protonmail.com", "protonmail.ch", "pm.me", "aol.com",
    "fastmail.com", "tuta.com", "tutanota.com",
}
PNG_SCALES = {"1x": ("sender-1x.png", 32), "2x": ("sender-2x.png", 64), "3x": ("sender-3x.png", 96)}


def is_https_url(value: object) -> bool:
    if not isinstance(value, str):
        return False
    parsed = urlparse(value)
    return parsed.scheme == "https" and bool(parsed.hostname)


def under_official_host(host: str, brand: dict) -> bool:
    host = host.lower().rstrip(".")
    allowed = set()
    for value in [brand.get("brandWebsiteURL"), *brand.get("officialIconHosts", [])]:
        parsed = urlparse(value or "")
        if parsed.hostname:
            allowed.add(parsed.hostname.lower().rstrip("."))
    allowed.update(domain.lower().rstrip(".") for domain in brand.get("domains", []))
    allowed.update(domain.lower().rstrip(".") for domain in brand.get("knownSendingSubdomains", []))
    return any(host == base or host.endswith("." + base) for base in allowed)


def image_dimensions(path: Path) -> tuple[int, int]:
    try:
        from PIL import Image
    except ImportError as error:
        raise ValueError("Pillow is required; install scripts/requirements-sender-icons.txt") from error
    with Image.open(path) as image:
        image.load()
        if image.format != "PNG":
            raise ValueError(f"expected PNG, found {image.format}")
        return image.size


def validate() -> tuple[list[str], list[dict[str, object]], list[dict[str, object]]]:
    errors: list[str] = []
    try:
        brands = json.loads(CATALOG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return [f"Unable to read {CATALOG}: {error}"], [], []
    if not isinstance(brands, list):
        return ["Catalog root must be a JSON array."], [], []
    if len(brands) < 100:
        errors.append(f"Catalog has {len(brands)} brands; expected at least 100.")

    mapped_domains: dict[str, str] = {}
    referenced_assets: set[str] = set()
    unreviewed: list[dict[str, object]] = []
    seasonal_warnings: list[dict[str, object]] = []
    seen_names: set[str] = set()
    for index, brand in enumerate(brands):
        label = brand.get("name", f"entry {index}") if isinstance(brand, dict) else f"entry {index}"
        if not isinstance(brand, dict):
            errors.append(f"{label}: entry must be an object.")
            continue
        if not isinstance(brand.get("name"), str) or not brand["name"].strip():
            errors.append(f"{label}: name must be a nonempty string.")
        elif brand["name"] in seen_names:
            errors.append(f"Duplicate brand name: {brand['name']}.")
        else:
            seen_names.add(brand["name"])

        for required in (
            "domains", "knownSendingSubdomains", "colorHex", "colorSource", "colorSourceURL",
            "colorMissingReason", "iconSource", "iconAssetName", "iconPresentation", "iconSourceURL",
            "brandAssetSourceURL", "simpleIconsSlug", "simpleIconsVersion", "license", "licenseURL",
            "guidelinesURL", "publicReleaseReviewed", "seasonalCheckedAt",
        ):
            if required not in brand:
                errors.append(f"{label}: missing required field {required}.")

        domains, subdomains = brand.get("domains"), brand.get("knownSendingSubdomains")
        if not isinstance(domains, list):
            errors.append(f"{label}: domains must be an array.")
            domains = []
        if not isinstance(subdomains, list):
            errors.append(f"{label}: knownSendingSubdomains must be an array.")
            subdomains = []
        if not domains and not subdomains:
            errors.append(f"{label}: at least one exact sender domain is required.")
        for domain in domains + subdomains:
            if not isinstance(domain, str) or not HOST_PATTERN.fullmatch(domain):
                errors.append(f"{label}: invalid domain {domain!r}.")
                continue
            if domain.lower() in PERSONAL_MAILBOX_DOMAINS:
                errors.append(f"{label}: consumer mailbox domain must not map to a brand: {domain}.")
            if domain != domain.lower():
                errors.append(f"{label}: domains must be lowercase ({domain}).")
            previous = mapped_domains.get(domain)
            if previous:
                errors.append(f"Duplicate domain {domain}: {previous} and {label}.")
            else:
                mapped_domains[domain] = str(label)

        color_hex = brand.get("colorHex")
        if color_hex is None:
            reason = brand.get("colorMissingReason")
            if not isinstance(reason, str) or len(reason.strip()) < 20:
                errors.append(f"{label}: null colorHex requires a specific colorMissingReason.")
            if not is_https_url(brand.get("colorSourceURL")):
                errors.append(f"{label}: missing-color rows require the checked official colorSourceURL.")
        else:
            if not isinstance(color_hex, str) or not HEX_PATTERN.fullmatch(color_hex):
                errors.append(f"{label}: colorHex must be six hexadecimal digits or null.")
            if not isinstance(brand.get("colorSource"), str) or not brand["colorSource"].strip():
                errors.append(f"{label}: sourced colors require colorSource.")
            if not is_https_url(brand.get("colorSourceURL")):
                errors.append(f"{label}: sourced colors require an HTTPS colorSourceURL.")

        if not isinstance(brand.get("publicReleaseReviewed"), bool):
            errors.append(f"{label}: publicReleaseReviewed must be boolean.")
        elif brand["publicReleaseReviewed"] is False:
            unreviewed.append(brand)

        checked_at = brand.get("seasonalCheckedAt")
        try:
            if not isinstance(checked_at, str) or date.fromisoformat(checked_at).isoformat() != checked_at:
                raise ValueError("expected YYYY-MM-DD")
        except ValueError:
            errors.append(f"{label}: seasonalCheckedAt must be an ISO YYYY-MM-DD date.")
        warning = brand.get("possibleSeasonalWarning")
        if warning is not None:
            if not isinstance(warning, str) or not warning.strip():
                errors.append(f"{label}: possibleSeasonalWarning must be a nonempty string when present.")
            else:
                seasonal_warnings.append(brand)
        if brand.get("name") in {"Alibaba.com", "天猫", "拼多多"}:
            reason = brand.get("iconCorrectionReason")
            if not isinstance(reason, str) or len(reason.strip()) < 20:
                errors.append(f"{label}: reviewed icon correction requires an explicit iconCorrectionReason.")

        source = brand.get("iconSource")
        asset_name = brand.get("iconAssetName")
        if source == "monogram":
            if asset_name is not None or brand.get("iconPresentation") is not None:
                errors.append(f"{label}: monogram rows must not reference an image asset.")
            if not isinstance(brand.get("iconSourceFailureReason"), str) or not brand["iconSourceFailureReason"].strip():
                errors.append(f"{label}: monogram requires the reason no official image was kept.")
            if any(brand.get(key) is not None for key in ("iconSourceURL", "brandAssetSourceURL", "guidelinesURL")):
                errors.append(f"{label}: monogram source URLs must be null.")
            if brand.get("license") != "none" or brand.get("simpleIconsVersion") != "none":
                errors.append(f"{label}: monogram source/license metadata must be none.")
            continue
        if source not in {"app-store", "touch-icon"}:
            errors.append(f"{label}: iconSource must be app-store, touch-icon, or monogram.")
            continue
        if not isinstance(asset_name, str) or not re.fullmatch(r"Sender[A-Za-z0-9]+", asset_name):
            errors.append(f"{label}: invalid iconAssetName {asset_name!r}.")
            continue
        referenced_assets.add(asset_name)
        if brand.get("iconPresentation") != "original":
            errors.append(f"{label}: official raster icons must use original iconPresentation.")
        for key in ("iconSourceURL", "brandAssetSourceURL", "guidelinesURL"):
            if not is_https_url(brand.get(key)):
                errors.append(f"{label}: icon rows require an HTTPS {key}.")
        if brand.get("simpleIconsVersion") != "none" or brand.get("simpleIconsSlug") != "none":
            errors.append(f"{label}: official raster icons must record simpleIconsVersion/Slug as none.")
        if brand.get("license") != "none" or brand.get("licenseURL") != "none":
            errors.append(f"{label}: official image license must be none when no SPDX license was supplied.")
        if brand.get("guidelinesURLSource") != "official-brand-site":
            errors.append(f"{label}: icon guidelines must point to the official brand site/guidelines.")

        width, height = brand.get("iconSourcePixelWidth"), brand.get("iconSourcePixelHeight")
        if not isinstance(width, int) or not isinstance(height, int) or min(width, height) < 64:
            errors.append(f"{label}: source image must record dimensions of at least 64×64.")
        if source == "app-store":
            for key in ("appStoreTrackId", "appStoreBundleId", "appStoreSellerName", "appStoreCountry", "appStoreArtworkURL", "appStoreTrackViewURL"):
                if not brand.get(key):
                    errors.append(f"{label}: app-store source is missing {key}.")
            if not isinstance(brand.get("appStoreTrackId"), int):
                errors.append(f"{label}: appStoreTrackId must be an integer.")
            artwork_host = (urlparse(brand.get("appStoreArtworkURL", "")).hostname or "").lower()
            source_host = (urlparse(brand.get("iconSourceURL", "")).hostname or "").lower()
            if not APPLE_ART_HOST.fullmatch(artwork_host) or not APPLE_ART_HOST.fullmatch(source_host):
                errors.append(f"{label}: App Store artwork must come from Apple's approved mzstatic CDN hosts.")
            track_host = (urlparse(brand.get("appStoreTrackViewURL", "")).hostname or "").lower()
            if track_host not in {"apps.apple.com", "itunes.apple.com"}:
                errors.append(f"{label}: App Store track page must use apps.apple.com or itunes.apple.com.")
        else:
            kind = brand.get("touchIconKind")
            if not isinstance(kind, str) or not kind:
                errors.append(f"{label}: touch icon source requires a recorded touchIconKind.")
            elif kind.startswith("apple-touch-icon"):
                exception = brand.get("iconSourceQualityException")
                minimum = 64 if isinstance(exception, str) and len(exception.strip()) >= 20 else 120
                if width != height or not isinstance(width, int) or min(width, height) < minimum:
                    errors.append(f"{label}: Apple touch icon must be square and at least {minimum}×{minimum}.")
            elif kind == "brand-logo-left-mark":
                center = brand.get("iconCropCenter")
                if (
                    not isinstance(center, list)
                    or len(center) != 2
                    or any(not isinstance(value, (int, float)) or not 0 <= value <= 1 for value in center)
                ):
                    errors.append(f"{label}: website logo crop requires iconCropCenter with two values from 0 to 1.")
            elif kind in {"favicon", "embedded-favicon"}:
                if (
                    isinstance(width, int)
                    and isinstance(height, int)
                    and min(width, height) > 0
                    and max(width, height) / min(width, height) > 1.25
                ):
                    errors.append(f"{label}: favicon source must be close to square for a centered avatar crop.")
            else:
                errors.append(f"{label}: unsupported touchIconKind {kind!r}.")
            host = (urlparse(brand.get("iconSourceURL", "")).hostname or "").lower()
            if host and not under_official_host(host, brand):
                errors.append(f"{label}: touch icon URL host is not a brand official host: {host}.")
            page_url = brand.get("touchIconPageURL") or brand.get("brandAssetSourceURL")
            if not is_https_url(page_url):
                errors.append(f"{label}: touch icon requires its first-party HTML page URL.")

        imageset = ASSETS / f"{asset_name}.imageset"
        if not imageset.exists():
            continue
        contents_path = imageset / "Contents.json"
        try:
            contents = json.loads(contents_path.read_text(encoding="utf-8"))
            if not isinstance(contents, dict):
                raise ValueError("Contents.json must be an object")
            entries = contents.get("images", [])
            if not isinstance(entries, list) or any(not isinstance(image, dict) for image in entries):
                raise ValueError("Contents.json images must be an array of objects")
            if any(
                not isinstance(image.get("scale"), str) or not isinstance(image.get("filename"), str)
                for image in entries
            ):
                raise ValueError("PNG entries must have string scale and filename values")
            by_scale = {image.get("scale"): image.get("filename") for image in entries}
            if len(entries) != len(PNG_SCALES) or set(by_scale) != set(PNG_SCALES):
                errors.append(f"{label}: Contents.json must include exactly the 1x, 2x and 3x PNG scales.")
            if any(image.get("idiom") != "universal" for image in entries):
                errors.append(f"{label}: PNG entries must use the universal idiom.")
            for scale, (filename, pixels) in PNG_SCALES.items():
                if by_scale.get(scale) != filename:
                    errors.append(f"{label}: {scale} must reference {filename}.")
                    continue
                dimensions = image_dimensions(imageset / filename)
                if dimensions != (pixels, pixels):
                    errors.append(f"{label}: {filename} must be {pixels}×{pixels}, found {dimensions}.")
            if list(imageset.glob("*.svg")):
                errors.append(f"{label}: legacy Simple Icons SVG asset remains in {asset_name}.")
        except (OSError, json.JSONDecodeError, ValueError) as error:
            errors.append(f"{label}: incomplete or invalid PNG asset {asset_name}: {error}.")

    on_disk_assets = {path.name.removesuffix(".imageset") for path in ASSETS.glob("Sender*.imageset")}
    for unused in sorted(on_disk_assets - referenced_assets):
        errors.append(f"Unmapped sender icon asset has no catalog source record: {unused}.")
    return errors, unreviewed, seasonal_warnings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list-unreviewed", action="store_true", help="Print brands awaiting public-release trademark review.")
    args = parser.parse_args()
    errors, unreviewed, seasonal_warnings = validate()
    brands = json.loads(CATALOG.read_text(encoding="utf-8")) if CATALOG.exists() else []
    domain_count = sum(len(row.get("domains", [])) + len(row.get("knownSendingSubdomains", [])) for row in brands)
    source_counts = {source: sum(row.get("iconSource") == source for row in brands) for source in ("app-store", "touch-icon", "monogram")}
    print(
        f"Sender brands: {len(brands)}; domains: {domain_count}; "
        f"App Store icons: {source_counts['app-store']}; website icons: {source_counts['touch-icon']}; "
        f"monograms: {source_counts['monogram']}"
    )
    print(f"Brands awaiting public-release trademark review: {len(unreviewed)}")
    for brand in unreviewed:
        print(f"  {brand['name']}: {brand.get('iconSource')} · {brand.get('guidelinesURL') or 'no artwork'}")
    print("Possibly seasonal artwork (manual-review warning list):")
    if seasonal_warnings:
        for brand in seasonal_warnings:
            print(f"  {brand['name']}: {brand['possibleSeasonalWarning']}")
    else:
        print("  none")
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    if not args.list_unreviewed:
        missing_colors = [row["name"] for row in brands if row.get("colorHex") is None]
        print("Brands without sourced primary color: " + (", ".join(missing_colors) or "none"))
        print("Sender brand catalog and any optional local raster assets are valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
