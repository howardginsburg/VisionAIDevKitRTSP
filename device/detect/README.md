# Object detection

`vaidk-detect.service` runs [detect.sh](detect.sh), which starts `vaidk-detect`: the camera's own
object detector. Qualcomm's video analytics manager (VAM) runs the vendor's built-in model on the
camera's DSP, on frames from the camera program. Detection is off until it is turned on in the setup
page's **Object detection** section (`DETECT=1`). How the two programs work together, and how the
boxes are drawn: [camd/README.md](../../camd/README.md#object-detection).

| File | What it is |
|---|---|
| [detect.sh](detect.sh) | Prepares the vendor's video analytics for the add-on and starts the detector with the settings. With `DETECT=0` it puts the vendor's files back and exits |
| `vaidk-detect` | The detector, built from [camd/detect.cpp](../../camd/detect.cpp) |
| [objects.txt](objects.txt) | The 80 objects the built-in model can report; the setup page offers these |
| [vaidk-detect.service](vaidk-detect.service) | systemd unit: starts once `/data` is mounted, and again 10 s after a failure, up to 5 times in 5 minutes |

## The model

The vendor's: SSD MobileNet v1 trained on COCO's 80 objects, converted for SNPE 1.19
(`mobilenet-SSD.dlc`, 27 MB, 32-bit float, 300x300 input), with COCO's labels file. Microsoft shipped
it in the Vision AI DevKit's vision sample, a Docker image (`visionsamplemodule:1.1.3-arm32v7`).

- **Copied once.** The first time detection starts, `detect.sh` copies the model and its labels to
  `/data/misc/vaidk/models/builtin`: from the sample's image in Docker's storage or, if that is gone,
  from the copy of the image that the firmware keeps on its read-only system partition,
  `/etc/Preload_container/visionsamplemodule.tar` (the vendor's factory reset deletes the first, never
  the second). It checks both files against their SHA-256 before it uses them. The add-on never
  distributes the model.
- **Microsoft's settings.** VAM's engine configuration is the vision sample's: blue, green and red
  means of 104, 117 and 123, scaled by 128, on the DSP. The vendor's own configuration (means of 128,
  scaled by 255) found a seated person with a median confidence of 53%, where the sample's gives 75%.
  The lowest confidence reported (`DETECT_CONFIDENCE`) is also the engine's threshold.
- **The DSP, not the processor.** On the processor the same model took 1.6 s a frame and more than a
  whole core; on the DSP, 30 ms.

## How it starts

VAM looks for its configuration and model in fixed places: `/data/misc/camera/va-snpe-engine-library_config.json`,
the files that configuration names in `/data/misc/camera`, and a database in `/data/misc/vam`
(`vamsession_<start time>/events.db`).
With `DETECT=1`, `detect.sh`:

1. **Checks the sub stream** is on at 640x360: the detector works from copies of its frames, which are
   readable only at that size. If it isn't, the status says so and the script exits.
2. **Copies the model**, if it isn't there yet (above).
3. **Writes the engine configuration** in RAM, `/run/vaidk/detect/engine.json`, with the chosen
   confidence.
4. **Points VAM at it.** The vendor's configuration is set aside, once, as
   `va-snpe-engine-library_config.json.vendor`; in its place, and as `vaidk-mobilenet-SSD.dlc` and
   `vaidk-coco_labels.txt`, `/data/misc/camera` gets links to the add-on's files. A link is written
   only when it changes.
5. **Keeps VAM's database in RAM:** `/data/misc/vam` links to `/run/vaidk/detect/vam`, a 4 MB RAM file
   system of its own, emptied each time the detector starts. VAM opens a new session folder there at
   every start; the add-on sets no VAM rules, so each holds an empty 20 KB database. Whatever VAM
   writes, it can't take more of the camera's memory than that.
6. **Sets the DSP's restart level** to `RELATED`, so that a DSP crash restarts only the DSP (and the
   detector) rather than the whole camera, as the vendor's `SYSTEM` would.
7. **Starts `vaidk-detect`**, with `ADSP_LIBRARY_PATH` including `/usr/lib`, where SNPE's half that
   runs on the DSP (`libsnpe_dsp_*_skel.so`) is kept.

With `DETECT=0`, and when the add-on is uninstalled (`detect.sh restore`), it removes the links, puts
the vendor's configuration back, sets the restart level back to `SYSTEM`, and unmounts and deletes its
files in RAM. The copied model stays until the camera is reset or the add-on is removed.

## Status

`vaidk-detect` rewrites `/run/vaidk/detect.state` every second, as `key=value` lines, for the setup
page:

| Key | Meaning |
|---|---|
| `status` | `waiting` (for frames), `starting` (VAM), `running`, `error` or `stopped`; `detect.sh` writes `preparing` while it copies the model, and `error` when detection can't start |
| `error` | Why it stopped |
| `snpe` | SNPE's version and runtimes, such as `SNPE 1.25.0 (287), DSP available, CPU available` |
| `runtime`, `model` | From the engine configuration: `DSP`, `vaidk-mobilenet-SSD.dlc` |
| `since` | When it started (Unix time) |
| `analysed` | Frames analysed since then |
| `rate`, `latency_ms` | Analyses a second over the last 10 s, and the average time per analysis over the last 50 |
| `refused` | Frames VAM turned away |
| `present` | What is in view now, with counts: `person 1,car 2` |
| `seen` | A line per object seen since it started: `label\|Unix time\|confidence` |

`/run/vaidk/detect.recent` holds the last 20 arrivals in view, newest first, as
`Unix time|label|confidence`. An object counts as in view until 3 s after it was last seen.

## Settings it uses

| Setting | Default | Meaning |
|---|---|---|
| `DETECT` | `0` | `1`: detection on. The camera service creates the detection track, so turning it on or off restarts the streams |
| `DETECT_OBJECTS` | `person,bicycle,car,motorcycle,bus,truck,bird,cat,dog` | What to report, from [objects.txt](objects.txt), with an underscore for a space |
| `DETECT_CONFIDENCE` | `60` | The lowest confidence reported, 10 to 99 percent |
| `DETECT_FPS` | `5` | Analyses a second, at most the sub stream's frame rate. The camera service applies it while streaming |
| `DETECT_BOXES` | `1` | Boxes on the main stream. Applied while streaming |
| `SUB_ENABLED`, `SUB_WIDTH`, `SUB_HEIGHT` | `1`, `640`, `360` | Detection needs these; the setup page sets and keeps them while detection is on |

`DETECT_OBJECTS` and `DETECT_CONFIDENCE` apply when the detector restarts; the setup page restarts it
when they change.

## Cost

Measured with the streams at their defaults (1080p main stream, 640x360 sub stream at 5 fps),
analysing 5 frames a second:

| | Without detection | With detection |
|---|---|---|
| Processor (4 cores) | 35% busy | 37–39% busy: the detector takes 6.5% of a core, `vaidk-camd` 1.5% more |
| Memory in use | 625 MB | About 785 MB, of which the detector holds 92 MB |
| Temperatures | | 1.5 to 2 °C warmer |
| Flash writes | None | None |
| Time per analysis | | 30 ms on average, under 60 ms |

Over 50 minutes and 15,177 analyses no frame was refused or dropped, nothing restarted, and the
memory of the detector, `vaidk-camd` and `qmmf-server` stayed flat. At 10 analyses a second the
processor was 39% busy, the detector taking 12% of a core.

## Logs and checks

```sh
journalctl -u vaidk-detect --no-pager -n 20          # SNPE, VAM's start, a summary each minute, errors
cat /run/vaidk/detect.state /run/vaidk/detect.recent
ls -l /data/misc/camera /data/misc/vam               # the links, while detection is on
journalctl -u vaidk-camera | grep -E 'detector|object detection'   # the camera program's side
```

| Log line | Meaning |
|---|---|
| `VAM started in 714 ms` | Running |
| `queued 1519, results 1518 (4.9/s), refused 0, dropped 0; latency avg 31 ms, max 51 ms` | The summary, every minute |
| `vaidk-camd connected`, `vaidk-camd disconnected` | The camera program connected, or went away (it restarted) |
| `VAM didn't start (...)` | The engine couldn't load the model: look for its `MLWrapper` lines around it |
| `VAM stopped answering; restarting` | VAM held a frame for 20 s: the DSP hung. systemd starts the detector again |

In the camera service's log: `connected to the object detector`, `lost the object detector`, and
`object detection needs the sub stream on at 640x360; streaming without it`.
