#!/usr/bin/env bash
# Ignore hardware-only ROS packages for an ANSCER simulation workspace.
# Can be run from any directory. Optionally pass a workspace path:
#   ./ignore-simulation-hardware.sh
#   ./ignore-simulation-hardware.sh /home/kd/anscer_ws

set -uo pipefail

WS="${1:-$HOME/anscer_ws}"
SRC="$WS/src"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: Workspace source directory not found: $SRC" >&2
  echo "Usage: $0 [path-to-anscer_ws]" >&2
  exit 1
fi

PACKAGES=(
  "anscer_sensors/zed_driver"
  "anscer_sensors/zed_nodelets"
  "anscer_sensors/zed-ros-interfaces"
  "anscer_sensors/zed_wrapper"
  "anscer_sensors/phidgets_drivers"
  "anscer_sensors/livox_ros_driver2"
)

failed=0

for rel in "${PACKAGES[@]}"; do
  pkg="$SRC/$rel"

  if [[ ! -d "$pkg" ]]; then
    printf '[NOT FOUND] %s\n' "$rel"
    continue
  fi

  if [[ -e "$pkg/CATKIN_IGNORE" ]]; then
    printf '[ALREADY IGNORED] %s\n' "$rel"
  else
    if touch "$pkg/CATKIN_IGNORE"; then
      printf '[IGNORED] %s\n' "$rel"
    else
      printf '[ERROR] Could not create %s/CATKIN_IGNORE\n' "$rel" >&2
      failed=1
      continue
    fi
  fi
done

echo
if ((failed)); then
  echo "Finished with errors. Check permissions and paths." >&2
  exit 1
fi

echo "Done. No source files or package.xml files were changed."
echo "Workspace: $WS"
echo "Rebuild from that workspace when ready: cd \"$WS\" && catkin_make"
