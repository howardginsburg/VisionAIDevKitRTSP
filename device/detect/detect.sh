#!/bin/sh
# Vision AI DevKit RTSP add-on: starts the object detector (vaidk-detect) with the saved settings.
# The detector is the camera's own: Qualcomm's video analytics manager (VAM) runs the vendor's built-in
# model (SSD MobileNet v1, COCO) on the DSP. VAM reads its engine configuration and the model from
# /data/misc/camera and keeps a database in /data/misc/vam. While detection is on, those point at the
# add-on's own: the configuration and the database in RAM, the model copied once to /data. With
# DETECT=0 the vendor's files are put back and the script exits.
#   detect.sh          start vaidk-detect (vaidk-detect.service runs this)
#   detect.sh restore  put the vendor's files back (detection off, or uninstalling)
. /opt/vaidk/common.sh
load_settings

CAM_DIR=/data/misc/camera
ENGINE_CONFIG=$CAM_DIR/va-snpe-engine-library_config.json
VAM_DIR=/data/misc/vam
MODEL_DIR=$DATA_DIR/models/builtin
WORK=$RUN_DIR/detect
# The built-in model and its labels, as the vendor's vision sample (image 1.1.3-arm32v7) has them.
MODEL=mobilenet-SSD.dlc
MODEL_SHA256=88adb6cf651edc0cae17e1a74243b7945a9cf1c8a35995956a1994e08e08637c
LABELS=coco_labels.txt
LABELS_SHA256=6c96454d929c64692d39173cee33908a366bfd053f4799a43c94217bf7598e5d
PRELOAD=/etc/Preload_container/visionsamplemodule.tar

state() { # state STATUS [ERROR]: what the setup page shows while vaidk-detect isn't running
    printf 'status=%s\nerror=%s\n' "$1" "$2" > "$RUN_DIR/detect.state.tmp" && mv "$RUN_DIR/detect.state.tmp" "$RUN_DIR/detect.state"
}

# What a DSP crash does: RELATED restarts only the DSP; SYSTEM (the vendor's choice) restarts the camera.
cdsp_restart_level() {
    for d in /sys/bus/msm_subsys/devices/subsys*; do
        if [ "$(cat "$d/name" 2>/dev/null)" = cdsp ]; then echo "$1" > "$d/restart_level" 2>/dev/null; fi
    done
    return 0
}

link_to() { # link_to TARGET LINK: points LINK at TARGET, writing to the flash only when that changes
    if [ "$(readlink "$2" 2>/dev/null)" != "$1" ]; then rm -f "$2" && ln -s "$1" "$2"; fi
}

restore() {
    if [ -L "$ENGINE_CONFIG" ]; then rm -f "$ENGINE_CONFIG"; fi
    if [ -f "$ENGINE_CONFIG.vendor" ] && [ ! -e "$ENGINE_CONFIG" ]; then mv "$ENGINE_CONFIG.vendor" "$ENGINE_CONFIG"; fi
    for f in "$CAM_DIR/vaidk-$MODEL" "$CAM_DIR/vaidk-$LABELS" "$VAM_DIR"; do
        if [ -L "$f" ]; then rm -f "$f"; fi
    done
    cdsp_restart_level SYSTEM
    umount "$WORK/vam" 2>/dev/null
    rm -rf "$WORK" "$RUN_DIR/detect.state" "$RUN_DIR/detect.recent"
}

matches() { [ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$2" ]; } # matches FILE SHA256

# Copies the built-in model to /data, once, from the vendor's vision sample: its Docker image, or the copy
# of that image the firmware keeps on the system partition (which the vendor's factory reset leaves).
install_model() {
    if [ -s "$MODEL_DIR/$MODEL" ] && [ -s "$MODEL_DIR/$LABELS" ]; then return 0; fi
    state preparing
    new=$MODEL_DIR.new
    rm -rf "$new" && mkdir -p "$new" || return 1
    for dir in /data/misc/docker/overlay2/*/diff/app/model; do
        if matches "$dir/$MODEL" $MODEL_SHA256 && matches "$dir/$LABELS" $LABELS_SHA256; then
            cp "$dir/$MODEL" "$dir/$LABELS" "$new/" && break
        fi
    done
    if [ ! -s "$new/$MODEL" ] && [ -f "$PRELOAD" ]; then
        for layer in $(tar -tf "$PRELOAD" | grep '/layer\.tar$'); do
            if tar -xOf "$PRELOAD" "$layer" | tar -tf - 2>/dev/null | grep -qxF "app/model/$MODEL"; then
                tar -xOf "$PRELOAD" "$layer" | tar -xf - -C "$new" "app/model/$MODEL" "app/model/$LABELS" &&
                    mv "$new/app/model/$MODEL" "$new/app/model/$LABELS" "$new/"
                rm -rf "$new/app"
                break
            fi
        done
    fi
    if ! matches "$new/$MODEL" $MODEL_SHA256 || ! matches "$new/$LABELS" $LABELS_SHA256; then
        rm -rf "$new"
        return 1
    fi
    chmod 644 "$new/$MODEL" "$new/$LABELS"
    sync
    rm -rf "$MODEL_DIR" && mv "$new" "$MODEL_DIR"
}

mkdir -p "$RUN_DIR"
if [ "$1" = restore ] || [ "$DETECT" != 1 ]; then
    restore
    exit 0
fi
# The detector works from copies of the sub stream's frames, which are readable only at 640x360.
if [ "$SUB_ENABLED" != 1 ] || [ "$SUB_WIDTH" != 640 ] || [ "$SUB_HEIGHT" != 360 ]; then
    restore
    state error "it needs the sub stream on at 640x360"
    exit 0
fi
if ! install_model; then
    restore
    state error "the built-in model isn't on this camera: the vendor's vision sample image is gone"
    exit 0
fi

conf=$DETECT_CONFIDENCE
case "$conf" in [1-9][0-9]) ;; *) conf=60 ;; esac
mkdir -p "$WORK" "$CAM_DIR"
# Microsoft's settings for this model, from its vision sample (the vendor's default normalisation costs
# accuracy). The engine leaves out results below the chosen confidence.
cat > "$WORK/engine.json" <<EOF
{
    "Engine":1,
    "NetworkIO":0,
    "ScaleWidth":300,
    "ScaleHeight":300,
    "PixelNorm":128,
    "BlueMean":104,
    "GreenMean":117,
    "RedMean":123,
    "TargetFPS":30,
    "ConfThreshold":0.$conf,
    "DLC_NAME":"vaidk-$MODEL",
    "LABELS_NAME":"vaidk-$LABELS",
    "InputLayers":"Preprocessor/sub:0",
    "OutputLayers":["add_6", "Postprocessor/BatchMultiClassNonMaxSuppression"],
    "ResultLayers":["Postprocessor/BatchMultiClassNonMaxSuppression_scores", "Postprocessor/BatchMultiClassNonMaxSuppression_boxes", "detection_classes:0"],
    "Runtime":1
}
EOF
# VAM reads its configuration from a fixed place: the vendor's goes aside until detection is off.
if [ -f "$ENGINE_CONFIG" ] && [ ! -L "$ENGINE_CONFIG" ]; then mv -f "$ENGINE_CONFIG" "$ENGINE_CONFIG.vendor"; fi
link_to "$WORK/engine.json" "$ENGINE_CONFIG"
link_to "$MODEL_DIR/$MODEL" "$CAM_DIR/vaidk-$MODEL"
link_to "$MODEL_DIR/$LABELS" "$CAM_DIR/vaidk-$LABELS"
# VAM's database stays in RAM, in a small space of its own, emptied at every start: VAM opens a new
# session folder each time it starts, and whatever it writes can't take more of the camera's memory.
umount "$WORK/vam" 2>/dev/null
mkdir -p "$WORK/vam" && mount -t tmpfs -o size=4m,mode=0755 vaidk-vam "$WORK/vam"
if [ -L "$VAM_DIR" ] || [ ! -e "$VAM_DIR" ]; then link_to "$WORK/vam" "$VAM_DIR"; fi
cdsp_restart_level RELATED

export DETECT_SOCKET="$RUN_DIR/detect.sock" DETECT_STATE="$RUN_DIR/detect.state" DETECT_RECENT="$RUN_DIR/detect.recent"
export DETECT_ENGINE_CONFIG="$WORK/engine.json" DETECT_OBJECTS DETECT_CONFIDENCE="$conf"
# What it sees also goes to the MQTT service (mqtt/mqttd.py), when that is running.
export DETECT_EVENTS="$RUN_DIR/events.sock"
# SNPE's DSP half (libsnpe_dsp_*_skel.so) is in /usr/lib, outside the DSP loader's default search path.
export ADSP_LIBRARY_PATH="/usr/lib;/usr/lib/rfsa/adsp;/dsp"
exec "$VAIDK_DIR/detect/vaidk-detect"
