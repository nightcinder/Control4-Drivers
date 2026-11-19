"""Cover art for the Shield bridge.

Order: Plex poster (only if art.plex_url and art.plex_token are set in config.json),
then an Apple (iTunes Search) lookup for music, then the open app's own icon
(pulled from its APK over ADB), then a generic streaming-box picture (shield_tile). Images are served by the bridge
at /art/<id>; ids are random per image, so the URL carries no secret.

With art.spotify_client_id and art.spotify_client_secret set, a Spotify catalogue lookup runs
before the iTunes one.
"""
from __future__ import annotations

import asyncio
import hashlib
import io
import logging
import re
import secrets
import time
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
PLEX_PACKAGE = "com.plexapp.android"
LAUNCHER_PACKAGE = "com.google.android.tvlauncher"  # Shield home screen: never pull an APK for it
ICON_CACHE_VERSION = "v3"  # bump when the fallback art changes so old cached icons are ignored
SHIELD_BG = (28, 28, 30)
FALLBACK_TTL = 15  # seconds a fallback (app icon) answer is reused before Plex/iTunes are tried again


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


def shield_image(size: int, background: tuple[int, int, int, int], ss: int = 4) -> Any:
    """A drawing of a Shield TV Pro style set-top box (flat black slab, green light) on a background."""
    from PIL import Image, ImageDraw, ImageFilter

    big = size * ss

    def pt(x: float, y: float) -> tuple[int, int]:
        return (int(x * big), int(y * big))

    canvas = Image.new("RGBA", (big, big), background)
    shadow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse((pt(0.08, 0.68), pt(0.94, 0.80)), fill=(0, 0, 0, 120))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(big * 0.012)))
    draw = ImageDraw.Draw(canvas)
    front = [pt(0.10, 0.58), pt(0.90, 0.58), pt(0.90, 0.69), pt(0.86, 0.72), pt(0.14, 0.72), pt(0.10, 0.69)]
    draw.polygon(front, fill=(14, 14, 16, 255))
    top = [pt(0.10, 0.58), pt(0.90, 0.58), pt(0.78, 0.30), pt(0.22, 0.30)]
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(top, fill=255)
    grad = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(grad)
    y0, y1 = int(0.30 * big), int(0.58 * big)
    for y in range(y0, y1):
        t = (y - y0) / max(1, y1 - y0)
        c = int(64 - 36 * t)  # lighter at the back edge, darker toward the front
        gdraw.line((0, y, big, y), fill=(c, c, c + 3, 255))
    canvas.paste(grad, (0, 0), mask)
    draw = ImageDraw.Draw(canvas)
    edge = (104, 104, 110, 255)
    draw.line([pt(0.10, 0.58), pt(0.22, 0.30), pt(0.78, 0.30), pt(0.90, 0.58), pt(0.10, 0.58)], fill=edge, width=max(2, 2 * ss))
    draw.line([pt(0.10, 0.60), pt(0.90, 0.60)], fill=(70, 70, 76, 255), width=max(1, ss))
    draw.line([pt(0.34, 0.575), pt(0.40, 0.31)], fill=(46, 46, 52, 255), width=max(1, ss))  # facet line
    cx, cy = int(0.50 * big), int(0.45 * big)
    rx, ry = int(0.060 * big), int(0.030 * big)
    glow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((cx - rx * 2, cy - ry * 2, cx + rx * 2, cy + ry * 2), fill=(118, 185, 0, 90))
    canvas.alpha_composite(glow.filter(ImageFilter.GaussianBlur(big * 0.015)))
    draw = ImageDraw.Draw(canvas)
    draw.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=(118, 185, 0, 255))
    draw.ellipse((cx - rx // 2, cy - ry // 2, cx + rx // 2, cy + ry // 2), fill=(10, 14, 6, 255))
    return canvas.resize((size, size), Image.LANCZOS)


def shield_tile() -> bytes:
    """The no-icon fallback: a 512x512 PNG of the generic streaming box on the dark tile background."""
    out = io.BytesIO()
    shield_image(TILE, (*SHIELD_BG, 255)).convert("RGB").save(out, "PNG")
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
        self._fallback_until: dict[str, tuple[str, float]] = {}
        self._spotify_token_cache: tuple[str, float] | None = None
        self._dir.mkdir(parents=True, exist_ok=True)

    def get(self, art_id: str) -> tuple[bytes, str] | None:
        return self._images.get(art_id)

    def _put(self, data: bytes, ctype: str) -> str:
        art_id = secrets.token_urlsafe(9)
        self._images[art_id] = (data, ctype)
        while len(self._images) > MAX_CACHED:
            old, _ = self._images.popitem(last=False)
            for k in [k for k, v in self._keys.items() if v == old]:
                del self._keys[k]
            for k in [k for k, (v, _) in self._fallback_until.items() if v == old]:
                del self._fallback_until[k]
        return art_id

    def _store(self, key: str, data: bytes, ctype: str) -> str:
        art_id = self._put(data, ctype)
        self._keys[key] = art_id
        return art_id

    def fallback_expired(self, package: str, title: str, artist: str) -> bool:
        """Return True unless permanent art or an unexpired fallback image is cached."""
        key = f"{package}|{title}|{artist}"
        if key in self._keys and self._keys[key] in self._images:
            return False
        fallback = self._fallback_until.get(key)
        if fallback:
            art_id, until = fallback
            return time.monotonic() >= until or art_id not in self._images
        return True

    async def resolve(
        self, package: str, title: str, artist: str, album: str, thumb: str = ""
    ) -> str | None:
        key = f"{package}|{title}|{artist}"
        fallback = self._fallback_until.get(key)
        if fallback:
            art_id, until = fallback
            if time.monotonic() < until and art_id in self._images:
                return art_id
            del self._fallback_until[key]
        if key in self._keys and self._keys[key] in self._images:
            return self._keys[key]
        finders: list[tuple[str, Callable[[], Awaitable[bytes | None]]]] = []
        if thumb:
            finders.append(("_plex_thumb", lambda: self._plex_thumb(thumb)))
        finders.append(("_plex", lambda: self._plex(title, artist, album)))
        # Spotify's own catalogue beats a title-and-artist guess in Apple's when Spotify is playing.
        if self._cfg.get("spotify_client_id") and self._cfg.get("spotify_client_secret"):
            finders.append(("_spotify", lambda: self._spotify(title, artist, album)))
        finders.append(("_itunes", lambda: self._itunes(title, artist, album)))
        for label, attempt in finders:
            try:
                found = await asyncio.wait_for(attempt(), HTTP_TIMEOUT + 4)
            except Exception as exc:  # noqa: BLE001
                log.debug("art %s: %s", label, exc)
                found = None
            if found:
                return self._store(key, _square(found), "image/png")
        icon = await self._app_icon(package)
        if not icon:
            return None
        # Fallback only: not cached permanently, so a Plex session listed a moment later is still picked up.
        art_id = self._put(icon, "image/png")
        self._fallback_until[key] = (art_id, time.monotonic() + FALLBACK_TTL)
        return art_id

    async def _fetch(self, url: str, headers: dict[str, str] | None = None) -> bytes | None:
        import aiohttp

        timeout = aiohttp.ClientTimeout(total=HTTP_TIMEOUT)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(url, headers=headers) as resp:
                if resp.status != 200:
                    return None
                return await resp.read()

    async def _plex_thumb(self, thumb: str) -> bytes | None:
        base, token = self._cfg.get("plex_url"), self._cfg.get("plex_token")
        if not base or not token or not thumb:
            return None
        headers = {"X-Plex-Token": str(token), "Accept": "application/json"}
        path = thumb if thumb.startswith("/") else f"/{thumb}"
        return await self._fetch(f"{str(base).rstrip('/')}{path}", headers)

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
            if (
                str(item.get("title", "")).strip().lower() != want
                and str(item.get("grandparentTitle", "")).strip().lower() != want
            ):
                continue
            kind = item.get("type")
            path = (item.get("grandparentThumb") if kind == "episode"
                    else item.get("parentThumb") if kind == "track" else None) or item.get("thumb")
            if path:
                return await self._fetch(f"{str(base).rstrip('/')}{path}", headers)
        return None

    async def _spotify_token(self) -> str | None:
        """Client-credentials token for the Spotify Web API, cached until a minute before expiry."""
        cid = str(self._cfg.get("spotify_client_id") or "").strip()
        secret = str(self._cfg.get("spotify_client_secret") or "").strip()
        if not cid or not secret:
            return None
        now = time.monotonic()
        if self._spotify_token_cache and now < self._spotify_token_cache[1]:
            return self._spotify_token_cache[0]
        import base64

        import aiohttp

        basic = base64.b64encode(f"{cid}:{secret}".encode()).decode()
        timeout = aiohttp.ClientTimeout(total=HTTP_TIMEOUT)
        try:
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.post(
                    "https://accounts.spotify.com/api/token",
                    data={"grant_type": "client_credentials"},
                    headers={"Authorization": f"Basic {basic}"},
                ) as resp:
                    if resp.status != 200:
                        log.debug("spotify token: HTTP %s", resp.status)
                        return None
                    body = await resp.json()
        except Exception as exc:  # noqa: BLE001
            log.debug("spotify token: %s", exc)
            return None
        token = str(body.get("access_token") or "")
        if not token:
            return None
        ttl = float(body.get("expires_in") or 3600)
        self._spotify_token_cache = (token, now + max(60.0, ttl - 60.0))
        return token

    async def _spotify(self, title: str, artist: str, album: str) -> bytes | None:
        """Album art straight from Spotify's catalogue, which is the app actually playing the track.

        Needs an app in the Spotify developer dashboard (development mode requires Premium on
        the app owner). Without spotify_client_id/spotify_client_secret this finder is skipped.
        """
        if not title or not artist:
            return None
        token = await self._spotify_token()
        if not token:
            return None
        from urllib.parse import quote

        query = quote(f'track:"{title}" artist:"{artist}"')
        raw = await self._fetch(
            f"https://api.spotify.com/v1/search?type=track&limit=5&q={query}",
            {"Authorization": f"Bearer {token}"},
        )
        if not raw:
            # Expired or rejected token: drop it so the next poll mints a fresh one.
            self._spotify_token_cache = None
            return None
        import json

        try:
            items = (json.loads(raw).get("tracks") or {}).get("items") or []
        except ValueError:
            return None
        want_artist = artist.strip().lower()
        for hit in items:
            hit_artists = " ".join(str(a.get("name", "")) for a in hit.get("artists") or [])
            if want_artist not in hit_artists.lower():
                continue
            for image in (hit.get("album") or {}).get("images") or []:
                url = str(image.get("url") or "")
                if not url:
                    continue
                found = await self._fetch(url)
                if found:
                    return found
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
        if package in (PLEX_PACKAGE, LAUNCHER_PACKAGE):
            return shield_tile()
        cached = self._dir / f"{package}.{ICON_CACHE_VERSION}.png"
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
            icon = shield_tile()
        cached.write_bytes(icon)
        return icon