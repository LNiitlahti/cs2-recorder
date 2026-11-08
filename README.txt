CS2 RECORDER
============

Records your chosen CS2 frags from a demo, automatically, as separate layers for editing.

HOW TO USE
1. Unzip this folder somewhere simple, for example C:\CS2Recorder
   (not inside OneDrive, and no special letters like a/o with dots in the path).
2. Double-click START.bat.
3. Follow the steps in the window. Every step explains itself.

WHAT YOU NEED (the tool checks all of this and helps you install what is missing)
- Windows 10 or 11
- Steam + Counter-Strike 2
- CS Demo Manager 3.20.1 or newer (free, cs-demo-manager.com) with its PostgreSQL database
- About 2-5 minutes of internet the first time (the tool installs a small demo reader)
- HLAE and FFmpeg are installed by CS Demo Manager by itself

WHAT YOU GET (in the folder you choose)
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
- Problems? Look at data\wizard.log and the log_*.txt files in the output folder.
