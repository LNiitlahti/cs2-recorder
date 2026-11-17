# Real-PC checklist (things no automated test here can prove)

Run `START-NEW.bat`. The old wizard stays available as `START-CLASSIC.bat` until all of this is ticked.

## Verified on this PC already (Nov 17, headless Edge + real demo)
- Setup check reads the real installs; the venv fixer built the demo reader (70 s).
- Demo read (4 s), kills, presets, clips, estimate (3840x2024 accepted) and preflight on a real demo; main account blocked.
- UI screens 1-4 render and run with no JS errors (screen 3 -> 4 driven with a STUBBED recording API: progress, -insecure status line, done screen). A real recording is not verified.

## UI and app
- [ ] Window opens (Edge/Chrome `--app`), looks right at normal and small sizes, keyboard works.
- [ ] Closing the window stops the server and any helper processes.
- [ ] Browse buttons (server-side file/folder dialogs) work; drag-and-drop finds the demo.
- [ ] "Copy report" and "Save report" produce logs with the Windows user name replaced by `USER`.

## Setup engine (best on a clean PC or VM)
- [ ] CSDM silent install: installer asset name pattern, `/S` works, install location found.
- [ ] Whether the CSDM release asset publishes a SHA256 digest (otherwise only the `MZ` check applies).
- [ ] Stopped PostgreSQL service: the elevated Start-Service UAC prompt works.
- [ ] `psql` PATH fix works in a fresh shell; CSDM no longer says "PSQL binary not found".
- [ ] Python 3.12 install via winget and via the python.org fallback (signature check).
- [ ] venv creation and pip install (demoparser2, zstandard, numpy, pandas).
- [ ] HLAE + FFmpeg download/extract into `%USERPROFILE%\.csdm` (FFmpeg about 185 MB), `_old_` rename when present.
- [ ] `Find-Python` ignores the Microsoft Store placeholder.

## Preflight
- [x] Real `cs2_video.txt` parsing and key names `setting.mat_vsync` / `setting.videocfg_fsr_detail` confirmed on this PC (Nov 17).
- [ ] Add the max VALUES of the other graphics settings to `tool/data/graphics_max.json` (shadow, texture, particle, AO, HDR, shader, MSAA), then set `"verified": true`.
- [x] Demo header carries the patch in `patch_version` (seen: 14173); the 14192 block matches that key. [ ] Still untested with a real 14192 demo.
- [ ] Steam path lookup, free-space check, process name `cs2`.

## Recording
- [ ] Real `csdm.cmd analyze` / `video` runs with the generated config; output file naming (`sequence-N-tick-*.mp4`) and move into `video_killfeed_audio.mp4`.
- [ ] `-insecure` safety stop: start CS2 without it and confirm CS2 + HLAE are killed.
- [ ] Stop button kills the whole process tree and CS2.
- [ ] Camera pass (campath) works.
- [ ] 3840x2024 recording renders cleanly.
- [ ] CS2 build with the CSDM plugin hook bug (CSDM issue #1458): compare builds between PCs.

## Tuning
- [ ] "Minutes" estimate uses 1.5 min x clips x (1 + layers), invented by the build agent; adjust to real timings.
- [ ] Preset `clutch` is not offered (kill data has no alive counts).
