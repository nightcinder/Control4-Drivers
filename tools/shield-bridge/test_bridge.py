"""Unit tests for shield-bridge Plex fallback and cover art retry logic."""
from __future__ import annotations

import asyncio
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import art  # noqa: E402
import bridge  # noqa: E402


DUMPSYS_SPOTIFY_PAUSED = """\
  Sessions Stack - have 2 sessions:
    androidx.media3.session.id. com.spotify.tv.android/androidx.media3.session.id.
      package=com.spotify.tv.android
      state=PlaybackState {state=2, position=46772, speed=0.0}
      metadata: size=22, description=how it starts, elijah, null
    Netflix media session com.netflix.ninja/Netflix media session
      package=com.netflix.ninja
      state=null
      metadata: null
"""

DUMPSYS_TWO_PAUSED = DUMPSYS_SPOTIFY_PAUSED + """\
    package=com.plexapp.android
      state=PlaybackState {state=2, position=1200, speed=0.0}
      metadata: size=4, description=My Movie, Director, Studio
"""

PLEX_EPISODE_SESSION = {
    "MediaContainer": {
        "size": 1,
        "Metadata": [
            {
                "type": "episode",
                "title": "The Cost of Chaos",
                "grandparentTitle": "The Witcher",
                "parentTitle": "Season 3",
                "parentIndex": 3,
                "index": 3,
                "thumb": "/library/metadata/101/thumb/1",
                "parentThumb": "/library/metadata/100/thumb/1",
                "grandparentThumb": "/library/metadata/99/thumb/1",
                "Player": {
                    "title": "SHIELD",
                    "product": "Plex for Android (TV)",
                    "state": "playing",
                    "address": "73.154.57.22",
                    "machineIdentifier": "c4a4513162927419-com-plexapp-android",
                },
            }
        ],
    }
}

PLEX_MOVIE_SESSION = {
    "MediaContainer": {
        "size": 1,
        "Metadata": [
            {
                "type": "movie",
                "title": "Dune",
                "year": 2021,
                "tagline": "It begins.",
                "thumb": "/library/metadata/55/thumb/1",
                "Player": {
                    "title": "Downstairs Shield",
                    "product": "Plex for Android (TV)",
                    "state": "paused",
                    "address": "192.0.2.20",
                    "machineIdentifier": "abc-com-plexapp-android",
                },
            }
        ],
    }
}

PLEX_TRACK_SESSION = {
    "MediaContainer": {
        "size": 1,
        "Metadata": [
            {
                "type": "track",
                "title": "Time",
                "grandparentTitle": "Pink Floyd",
                "parentTitle": "The Dark Side of the Moon",
                "parentThumb": "/library/metadata/77/thumb/1",
                "thumb": "/library/metadata/78/thumb/1",
                "Player": {
                    "title": "SHIELD",
                    "product": "Plex for Android (TV)",
                    "state": "buffering",
                    "address": "192.0.2.20",
                    "machineIdentifier": "abc-com-plexapp-android",
                },
            }
        ],
    }
}


def _make_shield(tmp: Path, with_plex: bool = True) -> bridge.Shield:
    art_cfg = {"plex_url": "http://192.0.2.10:32400", "plex_token": "tok"} if with_plex else {}
    cfg = bridge.Config(
        listen_host="127.0.0.1",
        listen_port=8790,
        token="secret",
        shields={"Downstairs": bridge.ShieldConfig("Downstairs", "192.0.2.20", 5555)},
        cert=str(tmp / "cert.pem"),
        key=str(tmp / "key.pem"),
        adbkey=str(tmp / "adbkey"),
        poll_seconds=2.0,
        art=art_cfg,
    )
    return bridge.Shield(cfg.shields["Downstairs"], cfg)


class ParseMediaSessionTests(unittest.TestCase):
    def test_paused_spotify_without_foreground_match_returns_spotify(self) -> None:
        got = bridge.parse_media_session(DUMPSYS_SPOTIFY_PAUSED, "com.plexapp.android")
        self.assertEqual(
            got,
            {
                "app": "com.spotify.tv.android",
                "state": "paused",
                "title": "how it starts",
                "artist": "elijah",
                "album": None,
            },
        )

    def test_paused_prefers_foreground_app(self) -> None:
        got = bridge.parse_media_session(DUMPSYS_TWO_PAUSED, "com.plexapp.android")
        self.assertEqual(got["app"], "com.plexapp.android")
        self.assertEqual(got["title"], "My Movie")


class PlexNowPlayingTests(unittest.IsolatedAsyncioTestCase):
    async def test_poll_once_enriches_episode_from_plex(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            shield = _make_shield(Path(td))
            shield.adb.up = True

            async def fake_adb(cmd: str) -> str:
                if "mWakefulness" in cmd:
                    return "  mWakefulness=Awake\n"
                if "mCurrentFocus" in cmd:
                    return "  mCurrentFocus=Window{1a2 u0 com.plexapp.android/com.plexapp.plex.Main}\n"
                if "media_session" in cmd:
                    return DUMPSYS_SPOTIFY_PAUSED
                raise AssertionError(f"unexpected adb command: {cmd}")

            shield.adb_shell = fake_adb  # type: ignore[method-assign]
            shield._fetch_plex_sessions = AsyncMock(  # type: ignore[method-assign]
                return_value=json.dumps(PLEX_EPISODE_SESSION).encode()
            )
            shield.art.resolve = AsyncMock(return_value="poster123")  # type: ignore[method-assign]

            await shield.poll_once()
            if shield._art_task is not None:
                await shield._art_task

            self.assertEqual(shield.app, "com.plexapp.android")
            self.assertEqual(
                shield.now_playing,
                {
                    "state": "playing",
                    "title": "The Witcher",
                    "artist": "S03E03 · The Cost of Chaos",
                    "album": "Season 3",
                    "app": "com.plexapp.android",
                },
            )
            self.assertEqual(shield._plex_thumb, "/library/metadata/99/thumb/1")
            self.assertEqual(shield.art_path, "/art/poster123")
            shield.art.resolve.assert_awaited_once_with(
                "com.plexapp.android",
                "The Witcher",
                "S03E03 · The Cost of Chaos",
                "Season 3",
                thumb="/library/metadata/99/thumb/1",
            )

    async def test_plex_movie_and_track_formatting(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            shield = _make_shield(Path(td))

            shield._fetch_plex_sessions = AsyncMock(  # type: ignore[method-assign]
                return_value=json.dumps(PLEX_MOVIE_SESSION).encode()
            )
            movie_res = await shield._plex_now_playing()
            self.assertEqual(
                movie_res,
                (
                    {
                        "state": "paused",
                        "title": "Dune",
                        "artist": "2021",
                        "album": "It begins.",
                        "app": "com.plexapp.android",
                    },
                    "/library/metadata/55/thumb/1",
                ),
            )

            shield._fetch_plex_sessions = AsyncMock(  # type: ignore[method-assign]
                return_value=json.dumps(PLEX_TRACK_SESSION).encode()
            )
            track_res = await shield._plex_now_playing()
            self.assertEqual(
                track_res,
                (
                    {
                        "state": "playing",
                        "title": "Time",
                        "artist": "Pink Floyd",
                        "album": "The Dark Side of the Moon",
                        "app": "com.plexapp.android",
                    },
                    "/library/metadata/77/thumb/1",
                ),
            )


class ArtResolverTests(unittest.IsolatedAsyncioTestCase):
    async def test_plex_matches_grandparent_title_for_episodes(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            resolver = art.ArtResolver(
                {"plex_url": "http://192.0.2.10:32400", "plex_token": "tok"},
                Path(td),
                AsyncMock(return_value=None),
            )
            calls: list[str] = []

            async def fake_fetch(url: str, headers: dict[str, str] | None = None) -> bytes | None:
                calls.append(url)
                if url.endswith("/status/sessions"):
                    return json.dumps(PLEX_EPISODE_SESSION).encode()
                if url.endswith("/library/metadata/99/thumb/1"):
                    return b"FAKE_PNG_POSTER"
                return None

            resolver._fetch = fake_fetch  # type: ignore[method-assign]
            with patch.object(art, "_square", side_effect=lambda b: b):
                art_id = await resolver.resolve(
                    "com.plexapp.android", "The Witcher", "S03E03 · The Cost of Chaos", "Season 3"
                )

            self.assertIsNotNone(art_id)
            assert art_id is not None
            self.assertEqual(resolver.get(art_id), (b"FAKE_PNG_POSTER", "image/png"))
            self.assertIn("http://192.0.2.10:32400/library/metadata/99/thumb/1", calls)

    def test_shield_tile_is_512_png(self) -> None:
        import io

        from PIL import Image

        data = art.shield_tile()
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        img = Image.open(io.BytesIO(data))
        self.assertEqual(img.size, (512, 512))
        self.assertEqual(img.getpixel((2, 2)), (28, 28, 30))

    async def test_unknown_package_without_apk_icon_gets_shield_tile(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            pull = AsyncMock(return_value=None)
            resolver = art.ArtResolver({}, Path(td), pull)
            icon = await resolver._app_icon("com.example.unknownapp")
            self.assertEqual(icon, art.shield_tile())
            self.assertTrue((Path(td) / "com.example.unknownapp.v3.png").exists())

    async def test_launcher_returns_shield_tile_without_apk_pull(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            pull = AsyncMock(return_value=b"APK")
            resolver = art.ArtResolver({}, Path(td), pull)
            icon = await resolver._app_icon("com.google.android.tvlauncher")
            self.assertEqual(icon, art.shield_tile())
            pull.assert_not_awaited()

    async def test_direct_plex_thumb_short_circuits_session_lookup(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            resolver = art.ArtResolver(
                {"plex_url": "http://192.0.2.10:32400", "plex_token": "tok"},
                Path(td),
                AsyncMock(return_value=None),
            )
            calls: list[str] = []

            async def fake_fetch(url: str, headers: dict[str, str] | None = None) -> bytes | None:
                calls.append(url)
                if url.endswith("/library/metadata/99/thumb/1"):
                    return b"DIRECT_THUMB"
                return None

            resolver._fetch = fake_fetch  # type: ignore[method-assign]
            with patch.object(art, "_square", side_effect=lambda b: b):
                art_id = await resolver.resolve(
                    "com.plexapp.android",
                    "The Witcher",
                    "S03E03 · The Cost of Chaos",
                    "Season 3",
                    thumb="/library/metadata/99/thumb/1",
                )

            self.assertIsNotNone(art_id)
            self.assertEqual(calls, ["http://192.0.2.10:32400/library/metadata/99/thumb/1"])

    async def test_spotify_finder_runs_before_itunes_when_credentials_set(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            resolver = art.ArtResolver(
                {"spotify_client_id": "cid", "spotify_client_secret": "secret"},
                Path(td),
                AsyncMock(return_value=None),
            )
            resolver._plex = AsyncMock(return_value=None)  # type: ignore[method-assign]
            resolver._spotify = AsyncMock(return_value=b"SPOTIFY_JPG")  # type: ignore[method-assign]
            resolver._itunes = AsyncMock(return_value=b"ITUNES_JPG")  # type: ignore[method-assign]
            with patch.object(art, "_square", side_effect=lambda b: b):
                art_id = await resolver.resolve(
                    "com.spotify.tv.android", "Dead Man Walking", "Against The Current", "")
            self.assertIsNotNone(art_id)
            resolver._spotify.assert_awaited_once()  # type: ignore[attr-defined]
            resolver._itunes.assert_not_awaited()  # type: ignore[attr-defined]

    async def test_spotify_finder_skipped_without_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            resolver = art.ArtResolver({}, Path(td), AsyncMock(return_value=None))
            resolver._plex = AsyncMock(return_value=None)  # type: ignore[method-assign]
            resolver._spotify = AsyncMock(return_value=b"SPOTIFY_JPG")  # type: ignore[method-assign]
            resolver._itunes = AsyncMock(return_value=b"ITUNES_JPG")  # type: ignore[method-assign]
            with patch.object(art, "_square", side_effect=lambda b: b):
                art_id = await resolver.resolve(
                    "com.spotify.tv.android", "Dead Man Walking", "Against The Current", "")
            self.assertIsNotNone(art_id)
            resolver._spotify.assert_not_awaited()  # type: ignore[attr-defined]
            resolver._itunes.assert_awaited_once()  # type: ignore[attr-defined]

    async def test_spotify_token_is_cached_between_lookups(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            resolver = art.ArtResolver(
                {"spotify_client_id": "cid", "spotify_client_secret": "secret"},
                Path(td),
                AsyncMock(return_value=None),
            )
            resolver._spotify_token_cache = ("tok", time.monotonic() + 600)
            calls: list[str] = []

            async def fake_fetch(url: str, headers: dict[str, str] | None = None) -> bytes | None:
                calls.append(url)
                if "api.spotify.com/v1/search" in url:
                    self.assertEqual((headers or {}).get("Authorization"), "Bearer tok")
                    return json.dumps({"tracks": {"items": [
                        {"artists": [{"name": "Against The Current"}],
                         "album": {"images": [{"url": "http://192.0.2.20/cover.jpg"}]}}]}}).encode()
                return b"COVER"

            resolver._fetch = fake_fetch  # type: ignore[method-assign]
            found = await resolver._spotify("Dead Man Walking", "Against The Current", "")
            self.assertEqual(found, b"COVER")
            self.assertEqual(calls[0].split("?")[0], "https://api.spotify.com/v1/search")

    async def test_itunes_prefers_original_album_over_karaoke_or_remix(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            resolver = art.ArtResolver({}, Path(td), AsyncMock(return_value=None))
            fetched: list[str] = []

            async def fake_fetch(url: str, headers: dict[str, str] | None = None) -> bytes | None:
                fetched.append(url)
                if "itunes.apple.com/search" in url:
                    return json.dumps({"results": [
                        {
                            "trackName": "Alive (Karaoke Version)",
                            "artistName": "Example Band",
                            "collectionName": "Karaoke Hits",
                            "artworkUrl100": "http://192.0.2.20/karaoke_100x100.jpg",
                        },
                        {
                            "trackName": "Alive (Remix)",
                            "artistName": "Example Band",
                            "collectionName": "Alive Remixes",
                            "artworkUrl100": "http://192.0.2.20/remix_100x100.jpg",
                        },
                        {
                            "trackName": "Alive",
                            "artistName": "Example Band",
                            "collectionName": "Night Visions",
                            "artworkUrl100": "http://192.0.2.20/original_100x100.jpg",
                        },
                    ]}).encode()
                if url == "http://192.0.2.20/original_600x600.jpg":
                    return b"ORIGINAL_JPG"
                return b"WRONG_JPG"

            resolver._fetch = fake_fetch  # type: ignore[method-assign]
            found = await resolver._itunes("Alive", "Example Band", "Night Visions")
            self.assertEqual(found, b"ORIGINAL_JPG")
            self.assertIn("http://192.0.2.20/original_600x600.jpg", fetched)
            self.assertNotIn("http://192.0.2.20/karaoke_600x600.jpg", fetched)
            self.assertNotIn("http://192.0.2.20/remix_600x600.jpg", fetched)

    async def test_spotify_prefers_exact_title_and_album_over_remix(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            resolver = art.ArtResolver(
                {"spotify_client_id": "cid", "spotify_client_secret": "secret"},
                Path(td),
                AsyncMock(return_value=None),
            )
            resolver._spotify_token_cache = ("tok", time.monotonic() + 600)
            fetched: list[str] = []

            async def fake_fetch(url: str, headers: dict[str, str] | None = None) -> bytes | None:
                fetched.append(url)
                if "api.spotify.com/v1/search" in url:
                    return json.dumps({"tracks": {"items": [
                        {
                            "name": "Dead Man Walking - Live Remix",
                            "artists": [{"name": "Against The Current"}],
                            "album": {
                                "name": "Live Sessions",
                                "images": [{"url": "http://192.0.2.20/remix.jpg"}],
                            },
                        },
                        {
                            "name": "Dead Man Walking",
                            "artists": [{"name": "Against The Current"}],
                            "album": {
                                "name": "Past Lives",
                                "images": [{"url": "http://192.0.2.20/original.jpg"}],
                            },
                        },
                    ]}}).encode()
                if url == "http://192.0.2.20/original.jpg":
                    return b"ORIGINAL_SPOTIFY"
                return b"WRONG_SPOTIFY"

            resolver._fetch = fake_fetch  # type: ignore[method-assign]
            found = await resolver._spotify("Dead Man Walking", "Against The Current", "Past Lives")
            self.assertEqual(found, b"ORIGINAL_SPOTIFY")
            self.assertIn("http://192.0.2.20/original.jpg", fetched)
            self.assertNotIn("http://192.0.2.20/remix.jpg", fetched)

    async def test_spotify_missing_creds_warns_once(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            resolver = art.ArtResolver({}, Path(td), AsyncMock(return_value=None))
            resolver._plex = AsyncMock(return_value=None)  # type: ignore[method-assign]
            resolver._itunes = AsyncMock(return_value=b"ITUNES_JPG")  # type: ignore[method-assign]
            with patch.object(art, "_square", side_effect=lambda b: b):
                with self.assertNoLogs("shield-bridge.art", level="WARNING"):
                    await resolver.resolve("com.google.android.youtube.tv", "Video", "Channel", "")
                with self.assertLogs("shield-bridge.art", level="WARNING") as cm:
                    first = await resolver.resolve("com.spotify.tv.android", "Song A", "Artist A", "")
                self.assertIsNotNone(first)
                self.assertEqual(len(cm.output), 1)
                self.assertIn("spotify_client_id", cm.output[0])
                with self.assertNoLogs("shield-bridge.art", level="WARNING"):
                    second = await resolver.resolve("com.spotify.tv.android", "Song B", "Artist A", "")
                self.assertIsNotNone(second)

    async def test_update_art_retries_after_fallback_ttl_expires(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            shield = _make_shield(Path(td))
            resolver = shield.art
            resolver._plex = AsyncMock(return_value=None)  # type: ignore[method-assign]
            resolver._itunes = AsyncMock(return_value=None)  # type: ignore[method-assign]
            resolver._app_icon = AsyncMock(return_value=b"FALLBACK_ICON")  # type: ignore[method-assign]

            shield.app = "com.plexapp.android"
            shield.now_playing = {
                "app": "com.plexapp.android",
                "state": "playing",
                "title": "The Witcher",
                "artist": "S03E03 · The Cost of Chaos",
                "album": "Season 3",
            }
            shield._update_art()
            assert shield._art_task is not None
            await shield._art_task
            first_path = shield.art_path
            self.assertTrue(first_path.startswith("/art/"))

            # Before TTL expires, _update_art should NOT start another resolution task.
            key = ("com.plexapp.android", "The Witcher", "S03E03 · The Cost of Chaos", "Season 3")
            first_task = shield._art_task
            shield._update_art()
            self.assertIs(shield._art_task, first_task)

            # Simulate TTL expiry and Plex session poster becoming available.
            cache_key = "com.plexapp.android|The Witcher|S03E03 · The Cost of Chaos"
            art_id, _ = resolver._fallback_until[cache_key]
            resolver._fallback_until[cache_key] = (art_id, 0.0)
            resolver._plex = AsyncMock(return_value=b"REAL_POSTER")  # type: ignore[method-assign]

            with patch.object(art, "_square", side_effect=lambda b: b):
                shield._update_art()
                assert shield._art_task is not None
                self.assertIsNot(shield._art_task, first_task)
                await shield._art_task

            self.assertTrue(shield.art_path.startswith("/art/"))
            self.assertNotEqual(shield.art_path, first_path)
            self.assertFalse(resolver.fallback_expired("com.plexapp.android", "The Witcher", "S03E03 · The Cost of Chaos"))

    async def test_update_art_resolves_app_icon_when_awake_without_title(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            shield = _make_shield(Path(td))
            resolver = shield.art
            resolver._app_icon = AsyncMock(return_value=b"NETFLIX_ICON")  # type: ignore[method-assign]

            shield.awake = True
            shield.app = "com.netflix.ninja"
            shield.now_playing = {"app": None, "state": None, "title": None, "artist": None, "album": None}

            shield._update_art()
            assert shield._art_task is not None
            await shield._art_task

            self.assertEqual(shield._art_key, ("com.netflix.ninja", "", "", ""))
            self.assertTrue(shield.art_path.startswith("/art/"))
            resolver._app_icon.assert_awaited_once_with("com.netflix.ninja")

            # Even if fallback TTL would have elapsed, app-only idle tiles stay pinned without churning.
            cache_key = "com.netflix.ninja||"
            art_id, _ = resolver._fallback_until[cache_key]
            resolver._fallback_until[cache_key] = (art_id, 0.0)
            first_task = shield._art_task
            shield._update_art()
            self.assertIs(shield._art_task, first_task)

            # Sleeping clears the art path.
            shield.awake = False
            shield._update_art()
            self.assertEqual(shield.art_path, "")
            self.assertIsNone(shield._art_key)

    async def test_poll_once_prefers_plex_over_bare_plex_media_session(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            shield = _make_shield(Path(td))
            shield.adb.up = True

            dumpsys_bare_plex = """\
  Sessions Stack - have 1 sessions:
    package=com.plexapp.android
      state=PlaybackState {state=3, position=1200, speed=1.0}
      metadata: size=2, description=The Cost of Chaos, null, null
"""

            async def fake_adb(cmd: str) -> str:
                if "mWakefulness" in cmd:
                    return "  mWakefulness=Awake\n"
                if "mCurrentFocus" in cmd:
                    return "  mCurrentFocus=Window{1a2 u0 com.plexapp.android/com.plexapp.plex.Main}\n"
                if "media_session" in cmd:
                    return dumpsys_bare_plex
                raise AssertionError(f"unexpected adb command: {cmd}")

            shield.adb_shell = fake_adb  # type: ignore[method-assign]
            shield._fetch_plex_sessions = AsyncMock(  # type: ignore[method-assign]
                return_value=json.dumps(PLEX_EPISODE_SESSION).encode()
            )
            shield.art.resolve = AsyncMock(return_value="poster456")  # type: ignore[method-assign]

            await shield.poll_once()
            if shield._art_task is not None:
                await shield._art_task

            self.assertEqual(shield.now_playing["title"], "The Witcher")
            self.assertEqual(shield.now_playing["artist"], "S03E03 · The Cost of Chaos")
            self.assertEqual(shield.now_playing["album"], "Season 3")
            self.assertEqual(shield._plex_thumb, "/library/metadata/99/thumb/1")

    async def test_multi_shield_netflix_never_pulls_other_shield_plex(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            cfg = bridge.Config(
                listen_host="127.0.0.1",
                listen_port=8790,
                token="secret",
                shields={
                    "Downstairs": bridge.ShieldConfig("Downstairs", "192.0.2.20", 5555),
                    "Upstairs": bridge.ShieldConfig("Upstairs", "192.0.2.21", 5555),
                },
                cert=str(tmp / "cert.pem"),
                key=str(tmp / "key.pem"),
                adbkey=str(tmp / "adbkey"),
                poll_seconds=2.0,
                art={"plex_url": "http://192.0.2.10:32400", "plex_token": "tok"},
            )
            upstairs = bridge.Shield(cfg.shields["Upstairs"], cfg)
            upstairs.adb.up = True

            async def fake_adb(cmd: str) -> str:
                if "mWakefulness" in cmd:
                    return "  mWakefulness=Awake\n"
                if "mCurrentFocus" in cmd:
                    return "  mCurrentFocus=Window{1a2 u0 com.netflix.ninja/com.netflix.ninja.MainActivity}\n"
                if "media_session" in cmd:
                    return DUMPSYS_SPOTIFY_PAUSED
                raise AssertionError(f"unexpected adb command: {cmd}")

            upstairs.adb_shell = fake_adb  # type: ignore[method-assign]
            upstairs._fetch_plex_sessions = AsyncMock(  # type: ignore[method-assign]
                return_value=json.dumps(PLEX_EPISODE_SESSION).encode()
            )
            upstairs.art.resolve = AsyncMock(return_value="nf_icon")  # type: ignore[method-assign]

            await upstairs.poll_once()
            if upstairs._art_task is not None:
                await upstairs._art_task

            upstairs._fetch_plex_sessions.assert_not_awaited()
            self.assertEqual(upstairs.app, "com.netflix.ninja")
            self.assertEqual(upstairs.now_playing["app"], "com.spotify.tv.android")

    async def test_multi_shield_plex_machine_id_pins_and_excludes(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            cfg = bridge.Config(
                listen_host="127.0.0.1",
                listen_port=8790,
                token="secret",
                shields={
                    "Downstairs": bridge.ShieldConfig(
                        "Downstairs", "192.0.2.20", 5555,
                        plex_machine_id="c4a4513162927419-com-plexapp-android",
                    ),
                    "Upstairs": bridge.ShieldConfig("Upstairs", "192.0.2.21", 5555),
                },
                cert=str(tmp / "cert.pem"),
                key=str(tmp / "key.pem"),
                adbkey=str(tmp / "adbkey"),
                poll_seconds=2.0,
                art={"plex_url": "http://192.0.2.10:32400", "plex_token": "tok"},
            )
            downstairs = bridge.Shield(cfg.shields["Downstairs"], cfg)
            upstairs = bridge.Shield(cfg.shields["Upstairs"], cfg)

            raw = json.dumps(PLEX_EPISODE_SESSION).encode()
            downstairs._fetch_plex_sessions = AsyncMock(return_value=raw)  # type: ignore[method-assign]
            upstairs._fetch_plex_sessions = AsyncMock(return_value=raw)  # type: ignore[method-assign]

            ds_res = await downstairs._plex_now_playing()
            us_res = await upstairs._plex_now_playing()
            self.assertIsNotNone(ds_res)
            assert ds_res is not None
            self.assertEqual(ds_res[0]["title"], "The Witcher")
            self.assertIsNone(us_res)


class V2WatchdogTests(unittest.IsolatedAsyncioTestCase):
    @staticmethod
    def _fake_remote_module(
        remotes: list[object],
        events: list[tuple[str, int]],
        state: dict[str, int],
        connect_hook: object = None,
    ) -> object:
        import types

        class FakeRemote:
            def __init__(self, client_name: str, cert: str, key: str, host: str) -> None:
                self.idx = len(remotes)
                self.client_name = client_name
                self.cert = cert
                self.key = key
                self.host = host
                self.is_available = True
                self.disconnected = False
                self.disconnect_calls = 0
                self.keys_sent: list[tuple[str, str]] = []
                remotes.append(self)

            async def async_generate_cert_if_missing(self) -> None:
                await asyncio.sleep(0)

            async def async_connect(self) -> None:
                state["live"] += 1
                state["max_live"] = max(state["max_live"], state["live"])
                try:
                    if connect_hook is not None:
                        await connect_hook(self)  # type: ignore[misc]
                except BaseException:
                    raise
                events.append(("connect", self.idx))

            def disconnect(self) -> None:
                self.disconnect_calls += 1
                if not self.disconnected:
                    self.disconnected = True
                    state["live"] = max(0, state["live"] - 1)
                    events.append(("disconnect", self.idx))

            def send_key_command(self, key: str, direction: str = "SHORT") -> None:
                if self.disconnected or not self.is_available:
                    raise RuntimeError("disconnected")
                self.keys_sent.append((key, direction))

        mod = types.ModuleType("androidtvremote2")
        mod.AndroidTVRemote = FakeRemote  # type: ignore[attr-defined]
        return mod

    @staticmethod
    async def _wait_until(pred: object, timeout: float = 1.5) -> None:
        deadline = time.monotonic() + timeout
        while not pred():  # type: ignore[operator]
            if time.monotonic() >= deadline:
                raise TimeoutError("condition not met before timeout")
            await asyncio.sleep(0.005)

    async def test_adb_reconnect_forces_v2_clean_reconnect(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            shield = _make_shield(Path(td), with_plex=False)
            remotes: list[object] = []
            events: list[tuple[str, int]] = []
            state = {"live": 0, "max_live": 0}
            mod = self._fake_remote_module(remotes, events, state)

            adb_state = {"up": False}

            async def fake_adb_connect() -> None:
                adb_state["up"] = True

            async def fake_adb_close() -> None:
                adb_state["up"] = False

            shield.adb._connect = fake_adb_connect
            shield.adb._close = fake_adb_close
            shield.adb._healthy = lambda: adb_state["up"]

            with patch.dict(sys.modules, {"androidtvremote2": mod}):
                shield._tasks = [
                    asyncio.create_task(shield.v2.run()),
                    asyncio.create_task(shield.adb.run()),
                ]
                try:
                    await self._wait_until(lambda: shield.v2.up and shield.adb.up)
                    self.assertEqual(len(remotes), 1)
                    self.assertFalse(remotes[0].disconnected)  # type: ignore[attr-defined]

                    st1 = shield.status()
                    self.assertTrue(st1["v2_connected"])
                    self.assertEqual(st1["v2_reconnects"], 0)
                    self.assertIsNotNone(st1["v2_last_ok"])
                    for key in (
                        "shield", "v2_connected", "adb_connected", "awake",
                        "app", "now_playing", "art", "version",
                    ):
                        self.assertIn(key, st1)
                    first_last_ok = st1["v2_last_ok"]

                    # Shield power cycle: ADB drops and recovers while v2 still looks available.
                    shield.adb.fail("connection lost")
                    await self._wait_until(lambda: len(remotes) >= 2 and shield.v2.up and shield.adb.up)

                    self.assertTrue(remotes[0].disconnected)  # type: ignore[attr-defined]
                    self.assertFalse(remotes[1].disconnected)  # type: ignore[attr-defined]
                    self.assertLess(
                        events.index(("disconnect", 0)),
                        events.index(("connect", 1)),
                    )
                    st2 = shield.status()
                    self.assertTrue(st2["v2_connected"])
                    self.assertEqual(st2["v2_reconnects"], 1)
                    self.assertIsNotNone(st2["v2_last_ok"])
                    self.assertGreaterEqual(st2["v2_last_ok"], first_last_ok)
                finally:
                    await shield.stop()

    async def test_probe_timeout_marks_status_down_and_reconnects(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            shield = _make_shield(Path(td), with_plex=False)
            shield.v2.probe_interval = 0.02
            shield.v2.probe_timeout = 0.03
            remotes: list[object] = []
            events: list[tuple[str, int]] = []
            state = {"live": 0, "max_live": 0}
            allow_reconnect = asyncio.Event()

            async def connect_hook(remote: object) -> None:
                if remote.idx == 1:  # type: ignore[attr-defined]
                    await allow_reconnect.wait()

            mod = self._fake_remote_module(remotes, events, state, connect_hook=connect_hook)

            probe_calls = 0
            probe_cancelled = False

            async def fake_probe() -> bool:
                nonlocal probe_calls, probe_cancelled
                probe_calls += 1
                if probe_calls == 1:
                    try:
                        await asyncio.sleep(10.0)
                    except asyncio.CancelledError:
                        probe_cancelled = True
                        raise
                return True

            shield._v2_probe = fake_probe  # type: ignore[method-assign]

            with patch.dict(sys.modules, {"androidtvremote2": mod}):
                shield._tasks = [asyncio.create_task(shield.v2.run())]
                try:
                    await self._wait_until(lambda: len(remotes) == 1 and shield.v2.up)
                    await self._wait_until(lambda: remotes[0].disconnected)  # type: ignore[attr-defined]

                    self.assertTrue(probe_cancelled)
                    st_down = shield.status()
                    self.assertFalse(st_down["v2_connected"])
                    with self.assertRaises(bridge.LinkDown):
                        shield.send_key("HOME")

                    allow_reconnect.set()
                    await self._wait_until(lambda: len(remotes) >= 2 and shield.v2.up)
                    st_up = shield.status()
                    self.assertTrue(st_up["v2_connected"])
                    self.assertEqual(st_up["v2_reconnects"], 1)
                finally:
                    allow_reconnect.set()
                    await shield.stop()

    async def test_backoff_schedule_and_no_reconnect_storm(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            shield = _make_shield(Path(td), with_plex=False)
            remotes: list[object] = []
            events: list[tuple[str, int]] = []
            state = {"live": 0, "max_live": 0}

            async def fail_connect(_remote: object) -> None:
                raise OSError("host unreachable")

            mod = self._fake_remote_module(remotes, events, state, connect_hook=fail_connect)
            delays: list[float] = []

            async def fake_sleep(seconds: float) -> None:
                delays.append(seconds)
                shield.v2.fail("extra noise during backoff")
                await asyncio.sleep(0)
                if len(delays) >= 4:
                    raise asyncio.CancelledError

            shield.v2._sleep_backoff = fake_sleep  # type: ignore[method-assign]

            with patch.dict(sys.modules, {"androidtvremote2": mod}):
                task = asyncio.create_task(shield.v2.run())
                try:
                    try:
                        await asyncio.wait_for(task, timeout=0.5)
                    except asyncio.CancelledError:
                        pass
                    self.assertEqual(delays, [5.0, 15.0, 60.0, 60.0])
                    self.assertEqual(len(remotes), 4)
                    self.assertTrue(all(r.disconnected for r in remotes))  # type: ignore[attr-defined]
                    st = shield.status()
                    self.assertFalse(st["v2_connected"])
                    self.assertEqual(st["v2_reconnects"], 0)
                    self.assertIsNone(st["v2_last_ok"])
                finally:
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
                    await shield.v2.close()

        # Real _sleep_backoff must ignore fail() calls so rapid failures cannot storm.
        attempts = 0

        async def always_fail() -> None:
            nonlocal attempts
            attempts += 1
            raise OSError("refused")

        link = bridge.Link(
            "storm-check v2",
            always_fail,
            AsyncMock(),
            lambda: True,
            backoffs=(0.25, 0.5),
        )
        task = asyncio.create_task(link.run())
        try:
            await self._wait_until(lambda: attempts == 1)
            for _ in range(5):
                link.fail("spam")
                await asyncio.sleep(0.01)
            self.assertEqual(attempts, 1)
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            await link.close()

    async def test_clean_teardown_closes_old_client_and_leaks_no_tasks(self) -> None:
        before = set(asyncio.all_tasks())
        with tempfile.TemporaryDirectory() as td:
            shield = _make_shield(Path(td), with_plex=False)
            shield.v2.connect_timeout = 0.03
            shield.v2._backoffs = (0.01, 0.01)
            shield.poll_once = AsyncMock()  # type: ignore[method-assign]

            adb_state = {"up": False}

            async def fake_adb_connect() -> None:
                adb_state["up"] = True

            async def fake_adb_close() -> None:
                adb_state["up"] = False

            shield.adb._connect = fake_adb_connect
            shield.adb._close = fake_adb_close
            shield.adb._healthy = lambda: adb_state["up"]

            remotes: list[object] = []
            events: list[tuple[str, int]] = []
            state = {"live": 0, "max_live": 0}

            async def connect_hook(remote: object) -> None:
                if remote.idx == 1:  # type: ignore[attr-defined]
                    await asyncio.sleep(10.0)

            mod = self._fake_remote_module(remotes, events, state, connect_hook=connect_hook)

            with patch.dict(sys.modules, {"androidtvremote2": mod}):
                shield.start()
                try:
                    await self._wait_until(lambda: len(remotes) == 1 and shield.v2.up)
                    shield.v2.fail("stale")
                    await self._wait_until(lambda: len(remotes) >= 3 and shield.v2.up, timeout=2.0)

                    self.assertEqual(state["max_live"], 1)
                    self.assertTrue(remotes[0].disconnected)  # type: ignore[attr-defined]
                    self.assertTrue(remotes[1].disconnected)  # type: ignore[attr-defined]
                    self.assertFalse(remotes[2].disconnected)  # type: ignore[attr-defined]
                finally:
                    await shield.stop()

            self.assertTrue(remotes[2].disconnected)  # type: ignore[attr-defined]
            self.assertIsNone(shield._remote)
            self.assertFalse(shield.status()["v2_connected"])
            await asyncio.sleep(0)
            self.assertEqual(set(asyncio.all_tasks()) - before, set())

    async def test_power_state_wake_requests_immediate_v2_probe(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            shield = _make_shield(Path(td), with_plex=False)
            shield.awake = False
            shield.adb.up = True
            shield.v2.up = True
            shield.v2.probe_interval = 60.0

            async def fake_adb(cmd: str) -> str:
                if "mWakefulness" in cmd:
                    return "  mWakefulness=Awake\n"
                if "mCurrentFocus" in cmd:
                    return "  mCurrentFocus=null\n"
                if "media_session" in cmd:
                    return ""
                raise AssertionError(f"unexpected adb command: {cmd}")

            shield.adb_shell = fake_adb  # type: ignore[method-assign]
            await shield.poll_once()

            self.assertTrue(shield.awake)
            self.assertTrue(shield.v2._probe_now.is_set())


if __name__ == "__main__":
    unittest.main()
