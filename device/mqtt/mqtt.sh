#!/bin/sh
# Vision AI DevKit RTSP add-on: starts the MQTT service (mqttd.py), which publishes what the object
# detector sees to your MQTT broker. It exits unless MQTT is on, a broker is set and object detection is
# on: without detection there is nothing to publish.
. /opt/vaidk/common.sh
load_settings
mkdir -p "$RUN_DIR"
if [ "$MQTT" != 1 ] || [ -z "$MQTT_HOST" ] || [ "$DETECT" != 1 ]; then
    rm -f "$RUN_DIR/mqtt.state" "$RUN_DIR/events.sock"
    exit 0
fi
export MQTT_HOST MQTT_PORT MQTT_USER MQTT_DISCOVERY NAME DETECT_OBJECTS
export MQTT_TOPIC="${MQTT_TOPIC:-vaidk/$NAME}" MQTT_PASSWORD_FILE="$DATA_DIR/mqtt-password"
export MQTT_DISCOVERY_FILE="$DATA_DIR/mqtt-discovery" MQTT_EVENTS="$RUN_DIR/events.sock"
export MQTT_STATE="$RUN_DIR/mqtt.state" DETECT_STATE="$RUN_DIR/detect.state"
exec /usr/bin/python3 "$VAIDK_DIR/mqtt/mqttd.py"
