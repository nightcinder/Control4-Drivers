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
import json
import logging
import re
import secrets
import time
import zipfile
from collections import OrderedDict
from pathlib import Path
from typing import Any, Awaitable, Callable
from urllib.parse import quote, urlparse

log = logging.getLogger("shield-bridge.art")

TILE = 512
MAX_CACHED = 80
HTTP_TIMEOUT = 8
MAX_FETCH_BYTES = 10 * 1024 * 1024  # 10 MiB cap on external art/API responses
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
_JUNK_RELEASE_RE = re.compile(
    r"\b(?:karaoke|tribute|instrumental|8-bit|lullaby|cover|remix|live)\b"
)


def _score_music_match(
    want_title: str,
    want_artist: str,
    want_album: str,
    hit_title: str,
    hit_artist: str,
    hit_album: str,
    *,
    require_title: bool = True,
) -> int | None:
    """Rank a music search candidate, returning None when required fields do not match."""
    wt = want_title.strip().lower()
    wa = want_artist.strip().lower()
    wb = want_album.strip().lower()
    ht = hit_title.strip().lower()
    ha = hit_artist.strip().lower()
    hb = hit_album.strip().lower()
    if not wa or wa not in ha:
        return None
    parts = [p.strip() for p in wt.split(", ") if p.strip()] if ", " in wt else []
    co_artists = parts[1:] if len(parts) >= 2 and all(p in ha for p in parts[1:]) else []
    if require_title:
        direct_ok = bool(wt and wt in ht)
        split_ok = bool(co_artists and parts[0] in ht)
        if not direct_ok and not split_ok:
            return None

    def _title_score(cand_wt: str) -> int:
        if not (cand_wt and ht):
            return 0
        if ht == cand_wt:
            return 100
        if cand_wt in ht:
            return 60
        if ht in cand_wt:
            return 40
        return -60

    score = _title_score(wt)
    eff_wt = wt
    if co_artists:
        split_score = _title_score(parts[0]) + 25 * len(co_artists)
        if split_score > score:
            score = split_score
            eff_wt = parts[0]
    if ha == wa:
        score += 20
    if wb and hb:
        if hb == wb:
            score += 30
        elif wb in hb or hb in wb:
            score += 15

    wanted_junk = set(_JUNK_RELEASE_RE.findall(f"{eff_wt} {wb}"))
    hit_junk = set(_JUNK_RELEASE_RE.findall(f"{ht} {hb}"))
    score -= 40 * len(hit_junk - wanted_junk)
    return score


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
        self._warned_no_spotify: bool = False
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
        has_spotify = bool(
            str(self._cfg.get("spotify_client_id") or "").strip()
            and str(self._cfg.get("spotify_client_secret") or "").strip()
        )
        if has_spotify:
            finders.append(("_spotify", lambda: self._spotify(title, artist, album)))
        elif package == "com.spotify.tv.android" and not self._warned_no_spotify:
            self._warned_no_spotify = True
            log.warning(
                "Spotify credentials unset in art config (spotify_client_id/spotify_client_secret); "
                "falling back to iTunes"
            )
        finders.append(("_itunes", lambda: self._itunes(title, artist, album)))
        for label, attempt in finders:
            try:
                found = await asyncio.wait_for(attempt(), HTTP_TIMEOUT + 4)
                squared = await asyncio.to_thread(_square, found) if found else None
            except Exception as exc:  # noqa: BLE001
                log.debug("art %s: %s", label, exc)
                squared = None
            if squared:
                log.info("art resolved via %s for %s: %r - %r", label, package, title, artist)
                return self._store(key, squared, "image/png")
        icon = await self._app_icon(package)
        if not icon:
            return None
        # Fallback only: not cached permanently, so a Plex session listed a moment later is still picked up.
        art_id = self._put(icon, "image/png")
        self._fallback_until[key] = (art_id, time.monotonic() + FALLBACK_TTL)
        return art_id

    async def _fetch(self, url: str, headers: dict[str, str] | None = None) -> bytes | None:
        if urlparse(url).scheme not in ("http", "https"):
            return None
        import aiohttp

        timeout = aiohttp.ClientTimeout(total=HTTP_TIMEOUT)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(url, headers=headers, max_redirects=3) as resp:
                if resp.status != 200:
                    return None
                if resp.content_length and resp.content_length > MAX_FETCH_BYTES:
                    return None
                chunks: list[bytes] = []
                total = 0
                while True:
                    chunk = await resp.content.read(MAX_FETCH_BYTES + 1 - total)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > MAX_FETCH_BYTES:
                        return None
                    chunks.append(chunk)
                return b"".join(chunks)

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

    async def _fetch_ranked(
        self,
        title: str,
        artist: str,
        album: str,
        hits: list[dict[str, Any]],
        extract: Callable[[dict[str, Any]], tuple[str, str, str, list[str]]],
        *,
        require_title: bool,
    ) -> bytes | None:
        """Rank candidate hits with _score_music_match and return the first fetched image."""
        candidates: list[tuple[int, list[str]]] = []
        for hit in hits:
            hit_title, hit_artist, hit_album, urls = extract(hit)
            score = _score_music_match(
                title, artist, album, hit_title, hit_artist, hit_album,
                require_title=require_title,
            )
            if score is not None and urls:
                candidates.append((score, urls))
        candidates.sort(key=lambda pair: -pair[0])
        for _, urls in candidates:
            for url in urls:
                found = await self._fetch(url)
                if found:
                    return found
        return None

    async def _spotify_search(self, token: str, query_str: str) -> list[dict[str, Any]] | None:
        raw = await self._fetch(
            f"https://api.spotify.com/v1/search?type=track&limit=5&q={quote(query_str)}",
            {"Authorization": f"Bearer {token}"},
        )
        if raw is None:
            return None
        try:
            return (json.loads(raw).get("tracks") or {}).get("items") or []
        except ValueError:
            return []

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
        items = await self._spotify_search(token, f'track:"{title}" artist:"{artist}"')
        if items is None:
            # Expired or rejected token: drop it so the next poll mints a fresh one.
            self._spotify_token_cache = None
            return None

        def extract(hit: dict[str, Any]) -> tuple[str, str, str, list[str]]:
            hit_artists = " ".join(str(a.get("name", "")) for a in hit.get("artists") or [])
            album_obj = hit.get("album") or {}
            urls = [u for u in (str(img.get("url") or "") for img in album_obj.get("images") or []) if u]
            return str(hit.get("name") or ""), hit_artists, str(album_obj.get("name") or ""), urls

        found = await self._fetch_ranked(title, artist, album, items, extract, require_title=False)
        if found:
            return found
        fallback_items = await self._spotify_search(token, f"{title} {artist}")
        if fallback_items:
            return await self._fetch_ranked(title, artist, album, fallback_items, extract, require_title=False)
        return None

    async def _itunes(self, title: str, artist: str, album: str) -> bytes | None:
        if not title or not artist:
            return None
        raw = await self._fetch(
            f"https://itunes.apple.com/search?entity=song&limit=5&term={quote(title + ' ' + artist)}")
        if not raw:
            return None
        try:
            results = json.loads(raw).get("results", [])
        except ValueError:
            return None

        def extract(hit: dict[str, Any]) -> tuple[str, str, str, list[str]]:
            url = str(hit.get("artworkUrl100") or "").replace("100x100", "600x600")
            return (
                str(hit.get("trackName") or ""),
                str(hit.get("artistName") or ""),
                str(hit.get("collectionName") or ""),
                [url] if url else [],
            )

        return await self._fetch_ranked(title, artist, album, results, extract, require_title=True)

    async def _app_icon(self, package: str) -> bytes | None:
        if not re.fullmatch(r"[A-Za-z0-9_.]+", package or ""):
            return None
        if package in (PLEX_PACKAGE, LAUNCHER_PACKAGE):
            return await asyncio.to_thread(shield_tile)
        cached = self._dir / f"{package}.{ICON_CACHE_VERSION}.png"
        if cached.exists():
            return cached.read_bytes()
        icon = None
        try:
            apk = await self._pull_apk(package)
            raw = await asyncio.to_thread(icon_from_apk, apk) if apk else None
            icon = await asyncio.to_thread(_square, raw) if raw else None
        except Exception as exc:  # noqa: BLE001
            log.debug("app icon pull %s: %s", package, exc)
        if icon is None:
            icon = await asyncio.to_thread(shield_tile)
        cached.write_bytes(icon)
        return icon