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


if __name__ == "__main__":
    unittest.main()
