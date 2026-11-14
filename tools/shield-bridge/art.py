"""Cover art for the Shield bridge.

Order: Plex poster (only if art.plex_url and art.plex_token are set in config.json),
then an Apple (iTunes Search) lookup for music, then the open app's own icon
(pulled from its APK over ADB, or a generated tile). Images are served by the bridge
at /art/<id>; ids are random per image, so the URL carries no secret.
"""
from __future__ import annotations

import asyncio
import hashlib
import io
import logging
import re
import secrets
import zipfile
from collections import OrderedDict
from pathlib import Path
from typing import Any, Awaitable, Callable

log = logging.getLogger("shield-bridge.art")

TILE = 512
MAX_CACHED = 80
HTTP_TIMEOUT = 8
APP_LABELS = {
    "com.plexapp.android": "Plex",
    "com.google.android.youtube.tv": "YouTube",
    "com.spotify.tv.android": "Spotify",
    "com.netflix.ninja": "Netflix",
    "org.jellyfin.androidtv": "Jellyfin",
}
PNG_RE = re.compile(r"^res/.*(banner|ic_launcher|app_icon|icon).*\.png$", re.I)


def app_label(package: str) -> str:
    if package in APP_LABELS:
        return APP_LABELS[package]
    last = package.split(".")[-1] or package
    return last[:1].upper() + last[1:]


def _square(png_or_jpeg: bytes) -> bytes:
    """Centre an image on a dark 512x512 tile (banners are wide)."""
    from PIL import Image

    img = Image.open(io.BytesIO(png_or_jpeg)).convert("RGBA")
    img.thumbnail((TILE, TILE))
    canvas = Image.new("RGBA", (TILE, TILE), (28, 28, 30, 255))
    canvas.paste(img, ((TILE - img.width) // 2, (TILE - img.height) // 2), img)
    out = io.BytesIO()
    canvas.convert("RGB").save(out, "PNG")
    return out.getvalue()


def generated_tile(package: str) -> bytes:
    """A plain coloured tile with the app name, used when no icon can be pulled."""
    from PIL import Image, ImageDraw, ImageFont

    digest = hashlib.sha256(package.encode()).digest()
    colour = (40 + digest[0] % 140, 40 + digest[1] % 140, 40 + digest[2] % 140)
    img = Image.new("RGB", (TILE, TILE), colour)
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.load_default(size=72)
    except TypeError:
        font = ImageFont.load_default()
    label = app_label(package)
    box = draw.textbbox((0, 0), label, font=font)
    draw.text(((TILE - (box[2] - box[0])) / 2, (TILE - (box[3] - box[1])) / 2 - box[1]),
              label, fill=(255, 255, 255), font=font)
    out = io.BytesIO()
    img.save(out, "PNG")
    return out.getvalue()


def icon_from_apk(apk: bytes) -> bytes | None:
    """Largest PNG whose path looks like a banner or launcher icon, or None."""
    try:
        with zipfile.ZipFile(io.BytesIO(apk)) as z:
            best, best_size = None, 0
            for info in z.infolist():
                if PNG_RE.match(info.filename) and info.file_size > best_size:
                    best, best_size = info.filename, info.file_size
            return z.read(best) if best else None
    except Exception as exc:  # noqa: BLE001 - a bad APK just means "no icon"
        log.debug("apk icon: %s", exc)
        return None


class ArtResolver:
    """Resolves now-playing details to an image id, caching bytes in memory and icons on disk."""

    def __init__(self, cfg: dict[str, Any], cache_dir: Path,
                 pull_apk: Callable[[str], Awaitable[bytes | None]]) -> None:
        self._cfg = cfg
        self._dir = cache_dir
        self._pull_apk = pull_apk
        self._images: OrderedDict[str, tuple[bytes, str]] = OrderedDict()
        self._keys: dict[str, str] = {}
        self._dir.mkdir(parents=True, exist_ok=True)

    def get(self, art_id: str) -> tuple[bytes, str] | None:
        return self._images.get(art_id)

    def _store(self, key: str, data: bytes, ctype: str) -> str:
        art_id = secrets.token_urlsafe(9)
        self._images[art_id] = (data, ctype)
        self._keys[key] = art_id
        while len(self._images) > MAX_CACHED:
            old, _ = self._images.popitem(last=False)
            for k in [k for k, v in self._keys.items() if v == old]:
                del self._keys[k]
        return art_id

    async def resolve(self, package: str, title: str, artist: str, album: str) -> str | None:
        key = f"{package}|{title}|{artist}"
        if key in self._keys and self._keys[key] in self._images:
            return self._keys[key]
        for finder in (self._plex, self._itunes):
            try:
                found = await asyncio.wait_for(finder(title, artist, album), HTTP_TIMEOUT + 4)
            except Exception as exc:  # noqa: BLE001
                log.debug("art %s: %s", finder.__name__, exc)
                found = None
            if found:
                return self._store(key, _square(found), "image/png")
        icon = await self._app_icon(package)
        return self._store(key, icon, "image/png") if icon else None

    async def _fetch(self, url: str, headers: dict[str, str] | None = None) -> bytes | None:
        import aiohttp

        timeout = aiohttp.ClientTimeout(total=HTTP_TIMEOUT)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(url, headers=headers) as resp:
                if resp.status != 200:
                    return None
                return await resp.read()

    async def _plex(self, title: str, artist: str, album: str) -> bytes | None:
        base, token = self._cfg.get("plex_url"), self._cfg.get("plex_token")
        if not base or not token or not title:
            return None
        headers = {"X-Plex-Token": str(token), "Accept": "application/json"}
        raw = await self._fetch(f"{str(base).rstrip('/')}/status/sessions", headers)
        if not raw:
            return None
        import json

        items = (json.loads(raw).get("MediaContainer") or {}).get("Metadata") or []
        want = title.strip().lower()
        for item in items:
            if str(item.get("title", "")).strip().lower() != want:
                continue
            kind = item.get("type")
            path = (item.get("grandparentThumb") if kind == "episode"
                    else item.get("parentThumb") if kind == "track" else None) or item.get("thumb")
            if path:
                return await self._fetch(f"{str(base).rstrip('/')}{path}", headers)
        return None

    async def _itunes(self, title: str, artist: str, album: str) -> bytes | None:
        if not title or not artist:
            return None
        from urllib.parse import quote

        raw = await self._fetch(
            f"https://itunes.apple.com/search?entity=song&limit=5&term={quote(title + ' ' + artist)}")
        if not raw:
            return None
        import json

        for hit in json.loads(raw).get("results", []):
            if (artist.lower() in str(hit.get("artistName", "")).lower()
                    and title.lower() in str(hit.get("trackName", "")).lower()):
                url = str(hit.get("artworkUrl100", "")).replace("100x100", "600x600")
                return await self._fetch(url) if url else None
        return None

    async def _app_icon(self, package: str) -> bytes | None:
        if not re.fullmatch(r"[A-Za-z0-9_.]+", package or ""):
            return None
        cached = self._dir / f"{package}.png"
        if cached.exists():
            return cached.read_bytes()
        icon = None
        try:
            apk = await self._pull_apk(package)
            raw = icon_from_apk(apk) if apk else None
            icon = _square(raw) if raw else None
        except Exception as exc:  # noqa: BLE001
            log.debug("app icon pull %s: %s", package, exc)
        if icon is None:
            icon = generated_tile(package)
        cached.write_bytes(icon)
        return icon