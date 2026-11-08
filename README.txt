CS2 RECORDER
============

Records your chosen CS2 frags from a demo, automatically, as separate layers for editing.

INSTALL (once)
1. Right-click the downloaded zip and choose "Extract All...", then "Extract".
   (Do not run anything from inside the zip without extracting it.)
2. In the extracted folder, double-click INSTALL.bat.
   Windows may ask if you really want to run it: choose "Run"
   (or "More info" > "Run anyway").
3. The tool is copied to C:\cs2-recorder and a "CS2 Recorder" icon appears
   on your Desktop and in the Start menu. The recorder opens right away.
4. You can now delete the zip and the extracted folder.

USE
- Double-click the "CS2 Recorder" icon and follow the steps. Every step explains itself.

UPDATE
- Download the new zip and install it the same way. Your settings and recordings are kept.

UNINSTALL
- Delete the folder C:\cs2-recorder and the "CS2 Recorder" icons (Desktop and Start menu).

WHAT YOU NEED (the tool checks all of this and helps you install what is missing)
- Windows 10 or 11
- Steam + Counter-Strike 2
- CS Demo Manager 3.20.1 or newer (free, cs-demo-manager.com) with its PostgreSQL database
- About 2-5 minutes of internet the first time (the tool installs a small demo reader)
- HLAE and FFmpeg are installed by CS Demo Manager by itself

WHAT YOU GET (default folder C:\cs2-recorder\recordings)
  <demo>_<date>\
    clip01_r16_4k\
      pov\  video_killfeed_audio.mp4   normal first-person video with killfeed and sound
            clean.mp4, hud.mov, depth.mov, players.mov, ...   the layers you ticked
      cam\  video_camera.mp4 + camera layers (if you chose the camera shot)
      campath.xml, pov_cfg.txt, cam_cfg.txt   (what was sent to the game)
    RESULT.txt         kill times inside each file (for editing) + list of files
    MANUAL_STEPS.txt   how to do the same by hand in CS Demo Manager, if ever needed
    log_pov.txt / log_cam.txt   recording logs

GOOD TO KNOW
- Do not use the PC while CS2 is recording. CS2 opens and closes by itself.
- Use a separate Steam account for recording (the tool explains why).
- Very old demos (from an older CS2 update) can crash the game when they load. Use newer demos then.
- depth.mov looks almost black. That is normal; brighten it in your editor.
- The camera shot is computed without 3D map data, so it can sometimes clip through a wall or object. Check it.
- Problems? Look at C:\cs2-recorder\data\wizard.log and the log_*.txt files in the recording folder.
