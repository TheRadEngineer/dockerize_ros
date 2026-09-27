#!/usr/bin/env bash
# =============================================================================
# install-anscer-simulation-docker.sh
#
# Ubuntu 20.04 / ROS Noetic / ANSCER Gazebo simulation
#
# IMPORTANT:
#   Run this INSIDE the Ubuntu 20.04 Docker container as the normal user.
#   Do NOT run this script as root.
#
# Host:
#   Fedora 44 KDE is fine; host OS does not affect the packages installed here.
#
# This script consolidates the dependency work from the original ANSCER
# distrobox installer, adapted for direct Docker use.
#
# It intentionally does NOT install hardware-only drivers.
# It also does NOT rely on distrobox-specific behavior.
#
# Usage (inside the ros1 container, i.e. after typing `1`):
#   bash /opt/ros-setup/install-deps-simulation.sh
#
# ros-containers changes: MongoDB server is NOT installed here (it runs as the
# ros1-mongo container); only mongosh + database tools are.
#
# Re-run:
#   The source/build directories are reused where possible.
#   Existing installations are detected and skipped.
# =============================================================================

set -uo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Do not run this script as root."
    echo "Run it as your normal container user with sudo access."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------
GRPC_VERSION="v1.61.1"
MONGO_C_VERSION="1.22.1"
MONGO_CXX_VERSION="r3.7.1"
PAHO_C_VERSION="v1.3.8"
PAHO_CPP_VERSION="v1.2.0"
NVM_VERSION="v0.39.7"
NODE_VERSION="20"

BUILD_DIR="/opt/deps"
GRPC_INSTALL_DIR="/opt/grpc"
CARTO_DIR="$BUILD_DIR/carto_ws"
NVM_DIR="$HOME/.config/nvm"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { echo -e "\n[INFO] $*"; }
ok()   { echo -e "[ OK ] $*"; }
warn() { echo -e "[WARN] $*"; }
fail() { echo -e "\n[FAIL] $*" >&2; exit 1; }

run() {
    "$@" || fail "Command failed: $*"
}

# ---------------------------------------------------------------------------
# 1. Bootstrap + base packages
# ---------------------------------------------------------------------------
info "Installing bootstrap and build tools..."

echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 >/dev/null

run sudo apt-get update

run sudo apt-get install -y \
    lsb-release software-properties-common curl gnupg2 ca-certificates \
    wget dirmngr apt-transport-https git build-essential \
    htop vim net-tools inetutils-ping python3-pip python-is-python3 \
    nmap fping dialog smartmontools libmodbus-dev libudev-dev \
    autoconf libtool pkg-config cmake ninja-build stow doxygen libssl-dev \
    libpthread-stubs0-dev python3-wstool python3-rosdep python3-vcstool \
    mesa-utils sshfs \
    nlohmann-json3-dev libsdl-image1.2-dev libsdl-dev libfmt-dev libceres-dev \
    liblua5.3-dev libdxflib-dev libspdlog-dev libgeographic-dev \
    libcurl4-openssl-dev libprotobuf-dev protobuf-compiler libcairo2-dev \
    python3-tornado python3-pymongo

# ---------------------------------------------------------------------------
# 2. ROS Noetic
# ---------------------------------------------------------------------------
info "Checking ROS Noetic..."

if [[ ! -f /opt/ros/noetic/setup.bash ]]; then
    cd /tmp

    if [[ ! -f ros_install_noetic.sh ]]; then
        run wget -c \
            https://raw.githubusercontent.com/qboticslabs/ros_install_noetic/master/ros_install_noetic.sh
    fi

    chmod +x ros_install_noetic.sh

    # The installer is old and can interact badly with nounset.
    bash -c 'set +u; ./ros_install_noetic.sh' ||
        fail "ROS Noetic installation failed."
fi

[[ -f /opt/ros/noetic/setup.bash ]] ||
    fail "ROS Noetic setup.bash was not found."

set +u
source /opt/ros/noetic/setup.bash
set -u

ok "ROS Noetic is available."

# ---------------------------------------------------------------------------
# 3. ROS simulation packages
# ---------------------------------------------------------------------------
info "Installing ROS Noetic simulation packages..."

run sudo apt-get install -y \
    ros-noetic-navigation \
    ros-noetic-move-base \
    ros-noetic-move-base-msgs \
    ros-noetic-mbf-costmap-core \
    ros-noetic-mbf-msgs \
    ros-noetic-costmap-converter \
    ros-noetic-sob-layer \
    ros-noetic-teb-local-planner \
    ros-noetic-dwa-local-planner \
    ros-noetic-ompl \
    ros-noetic-rviz-visual-tools \
    ros-noetic-tf2-sensor-msgs \
    ros-noetic-geographic-msgs \
    ros-noetic-joy \
    ros-noetic-sound-play \
    ros-noetic-pybind11-catkin \
    ros-noetic-gtsam \
    ros-noetic-mcl-3dl-msgs \
    ros-noetic-ackermann-msgs \
    ros-noetic-apriltag \
    ros-noetic-behaviortree-cpp-v3 \
    ros-noetic-rosbridge-server \
    ros-noetic-bondcpp \
    ros-noetic-rqt-gui \
    ros-noetic-rqt-gui-py \
    ros-noetic-rqt-gui-cpp \
    ros-noetic-pcl-ros \
    ros-noetic-cmake-modules \
    ros-noetic-ddynamic-reconfigure \
    ros-noetic-filters \
    ros-noetic-eigen-conversions \
    ros-noetic-ros-control \
    ros-noetic-ros-controllers \
    ros-noetic-xacro \
    ros-noetic-rosbash \
    ros-noetic-gazebo-ros \
    ros-noetic-gazebo-ros-pkgs \
    ros-noetic-joint-state-publisher \
    ros-noetic-robot-state-publisher \
    ros-noetic-tf2-web-republisher \
    ros-noetic-depthai \
    ros-noetic-depthai-descriptions \
    ros-noetic-velodyne-simulator \
    ros-noetic-velodyne-gazebo-plugins

run python3 -m pip install --user pymongo tornado

# ---------------------------------------------------------------------------
# 4. Build directory
# ---------------------------------------------------------------------------
info "Preparing /opt/deps..."

run sudo mkdir -p "$BUILD_DIR"
run sudo chown -R "$(id -u):$(id -g)" "$BUILD_DIR"

mkdir -p "$GRPC_INSTALL_DIR"
run sudo chown -R "$(id -u):$(id -g)" "$GRPC_INSTALL_DIR"

# ---------------------------------------------------------------------------
# 5. OpenCV legacy include symlinks
#
# This does NOT install OpenCV. It only creates compatibility include paths.
# ---------------------------------------------------------------------------
info "Setting OpenCV legacy include paths..."

if [[ -d /usr/include/opencv4/opencv2 ]]; then
    sudo ln -sfn /usr/include/opencv4/opencv2 /usr/include/opencv
    sudo ln -sfn /usr/include/opencv4/opencv2 /usr/include/opencv2
    ok "OpenCV compatibility symlinks created."
else
    warn "OpenCV4 headers not found; skipping compatibility symlinks."
fi

# ---------------------------------------------------------------------------
# 6. LibSerial
# ---------------------------------------------------------------------------
info "Installing LibSerial..."

cd "$BUILD_DIR"

if [[ ! -d libserial ]]; then
    run git clone https://github.com/crayzeewulf/libserial.git
fi

cd libserial
mkdir -p build
cd build

run cmake \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DBUILD_DOCS=OFF \
    ..

run make -j"$(nproc)"
run sudo make install
run sudo ldconfig

[[ -e /usr/lib/x86_64-linux-gnu/libserial.so ]] ||
    fail "LibSerial installation could not be verified."

ok "LibSerial installed."

# ---------------------------------------------------------------------------
# 7. gRPC
#
# IMPORTANT: gRPC git tag is v1.61.1, not 1.61.1.
# ---------------------------------------------------------------------------
info "Installing gRPC $GRPC_VERSION..."

cd "$BUILD_DIR"

if [[ ! -d grpc ]]; then
    run git clone \
        --branch "$GRPC_VERSION" \
        --jobs "$(nproc)" \
        --depth 1 \
        --recurse-submodules \
        --shallow-submodules \
        https://github.com/grpc/grpc
fi

cd grpc
git fetch --tags --quiet || true

mkdir -p cmake/build
cd cmake/build

run cmake ../.. \
    -DgRPC_INSTALL=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$GRPC_INSTALL_DIR" \
    -DgRPC_ABSL_PROVIDER=module \
    -DgRPC_CARES_PROVIDER=module \
    -DgRPC_PROTOBUF_PROVIDER=module \
    -DgRPC_RE2_PROVIDER=module \
    -DgRPC_SSL_PROVIDER=module \
    -DgRPC_ZLIB_PROVIDER=module

run sudo make -j"$(nproc)" install
run sudo ldconfig

[[ -e "$GRPC_INSTALL_DIR/lib/libgrpc.a" ]] ||
    fail "gRPC installation could not be verified."

ok "gRPC installed in $GRPC_INSTALL_DIR."

# ---------------------------------------------------------------------------
# 8. MongoDB C driver
# ---------------------------------------------------------------------------
info "Installing MongoDB C driver $MONGO_C_VERSION..."

cd "$BUILD_DIR"

if [[ ! -d mongo-c-driver ]]; then
    run git clone https://github.com/mongodb/mongo-c-driver.git
fi

cd mongo-c-driver

run git fetch --tags --quiet || true
run git checkout "$MONGO_C_VERSION"

python3 build/calc_release_version.py > VERSION_CURRENT

mkdir -p cmake-build
cd cmake-build

run cmake \
    -DENABLE_AUTOMATIC_INIT_AND_CLEANUP=OFF \
    ..

run sudo cmake --build . --target install -- -j"$(nproc)"
run sudo ldconfig

[[ -e /usr/local/lib/libmongoc-1.0.so ]] ||
    fail "MongoDB C driver installation could not be verified."

ok "MongoDB C driver installed."

# ---------------------------------------------------------------------------
# 9. MongoDB C++ driver
# ---------------------------------------------------------------------------
info "Installing MongoDB C++ driver $MONGO_CXX_VERSION..."

cd "$BUILD_DIR"

if [[ ! -f "mongo-cxx-driver-${MONGO_CXX_VERSION}.tar.gz" ]]; then
    run curl -fL -o \
        "mongo-cxx-driver-${MONGO_CXX_VERSION}.tar.gz" \
        "https://github.com/mongodb/mongo-cxx-driver/releases/download/${MONGO_CXX_VERSION}/mongo-cxx-driver-${MONGO_CXX_VERSION}.tar.gz"
fi

if [[ ! -d "mongo-cxx-driver-${MONGO_CXX_VERSION}" ]]; then
    run tar -xzf "mongo-cxx-driver-${MONGO_CXX_VERSION}.tar.gz"
fi

cd "mongo-cxx-driver-${MONGO_CXX_VERSION}"

mkdir -p build
cd build

run cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local

run sudo cmake --build . --target EP_mnmlstc_core
run cmake --build . -- -j"$(nproc)"
run sudo cmake --build . --target install
run sudo ldconfig

[[ -e /usr/local/lib/libmongocxx.so ]] ||
    fail "MongoDB C++ driver installation could not be verified."

ok "MongoDB C++ driver installed."

# ---------------------------------------------------------------------------
# 10. Paho MQTT C
# ---------------------------------------------------------------------------
info "Installing Paho MQTT C $PAHO_C_VERSION..."

cd "$BUILD_DIR"

if [[ ! -d paho.mqtt.c ]]; then
    run git clone https://github.com/eclipse/paho.mqtt.c.git
fi

cd paho.mqtt.c
run git fetch --tags --quiet || true
run git checkout "$PAHO_C_VERSION"

mkdir -p build
cd build

run cmake \
    -DPAHO_WITH_SSL=ON \
    -DPAHO_BUILD_SAMPLES=OFF \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    ..

run make -j"$(nproc)"
run sudo make install
run sudo ldconfig

[[ -e /usr/local/lib/libpaho-mqtt3as.so ]] ||
    fail "Paho MQTT C installation could not be verified."

ok "Paho MQTT C installed."

# ---------------------------------------------------------------------------
# 11. Paho MQTT C++
# ---------------------------------------------------------------------------
info "Installing Paho MQTT C++ $PAHO_CPP_VERSION..."

cd "$BUILD_DIR"

if [[ ! -d paho.mqtt.cpp ]]; then
    run git clone https://github.com/eclipse/paho.mqtt.cpp.git
fi

cd paho.mqtt.cpp
run git fetch --tags --quiet || true
run git checkout "$PAHO_CPP_VERSION"

mkdir -p build
cd build

run cmake \
    -DPAHO_BUILD_DOCUMENTATION=OFF \
    -DPAHO_BUILD_SAMPLES=OFF \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    ..

run make -j"$(nproc)"
run sudo make install
run sudo ldconfig

[[ -e /usr/local/lib/libpaho-mqttpp3.so ]] ||
    fail "Paho MQTT C++ library could not be verified."

# This is the file your current catkin_make error is looking for.
PAHO_CPP_CONFIG="$(find /usr/local -type f \
    \( -name 'PahoMqttCppConfig.cmake' -o -name 'pahomqttcpp-config.cmake' \) \
    2>/dev/null | head -1)"

[[ -n "$PAHO_CPP_CONFIG" ]] ||
    fail "PahoMqttCppConfig.cmake could not be found after installation."

ok "Paho MQTT C++ installed."
ok "Found: $PAHO_CPP_CONFIG"

# ---------------------------------------------------------------------------
# 12. rosdep
# ---------------------------------------------------------------------------
info "Initializing/updating rosdep..."

if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
    sudo rosdep init 2>/dev/null || true
fi

run rosdep update

ok "rosdep ready."

# ---------------------------------------------------------------------------
# 13. Cartographer ROS
# ---------------------------------------------------------------------------
info "Installing Cartographer ROS..."

mkdir -p "$CARTO_DIR"
cd "$CARTO_DIR"

rm -rf abseil-cpp

if [[ ! -d src ]]; then
    run wstool init src
    run wstool merge -t src \
        https://raw.githubusercontent.com/cartographer-project/cartographer_ros/master/cartographer_ros.rosinstall
    run wstool update -t src
fi

set +u
rosdep install \
    --from-paths src \
    --ignore-src \
    --rosdistro=noetic \
    -y \
    --skip-keys=libabsl-dev || \
    warn "Some Cartographer rosdep keys were skipped."

src/cartographer/scripts/install_abseil.sh ||
    fail "Cartographer Abseil installation failed."

catkin_make_isolated --install --use-ninja ||
    fail "Cartographer build failed."

set -u

rm -rf src devel_isolated build_isolated abseil-cpp

[[ -f "$CARTO_DIR/install_isolated/setup.bash" ]] ||
    fail "Cartographer installation could not be verified."

ok "Cartographer installed."

# ---------------------------------------------------------------------------
# 14. MongoDB 6.0 client tools
#
# ros-containers: the MongoDB *server* runs as its own container (ros1-mongo,
# see compose.mongo.yaml) at mongodb://localhost:27017. Only the client tools
# are installed here: mongosh and mongodump/mongorestore.
# ---------------------------------------------------------------------------
info "Installing MongoDB 6.0 client tools..."

if [[ ! -f /etc/apt/sources.list.d/mongodb-org-6.0.list ]]; then
    curl -fsSL \
        https://www.mongodb.org/static/pgp/server-6.0.asc |
        sudo apt-key add - || fail "MongoDB repository key installation failed."

    echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/6.0 multiverse" |
        sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list >/dev/null

    run sudo apt-get update
fi

run sudo apt-get install -y mongodb-mongosh mongodb-database-tools

[[ -x /usr/bin/mongosh ]] ||
    fail "MongoDB shell could not be verified."

ok "MongoDB client tools installed."

# ---------------------------------------------------------------------------
# 15. Node.js 20 through NVM
# ---------------------------------------------------------------------------
info "Installing Node.js $NODE_VERSION through NVM..."

export NVM_DIR

if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    mkdir -p "$NVM_DIR"

    PROFILE=/dev/null bash -c \
        "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash" ||
        fail "NVM installation failed."
fi

[[ -s "$NVM_DIR/nvm.sh" ]] ||
    fail "NVM installation could not be found."

set +u
. "$NVM_DIR/nvm.sh"
set -u

run nvm install "$NODE_VERSION"
run nvm alias default "$NODE_VERSION"
run nvm use "$NODE_VERSION"

ok "Node $(node --version) + npm $(npm --version)"

# ---------------------------------------------------------------------------
# 19. Mission Control UI npm dependencies (original Phase 19)
#
# This environment already has the ANSCER workspace; only install the UI
# dependencies here. Workspace cloning/configuration is intentionally omitted.
# ---------------------------------------------------------------------------
info "Installing Mission Control UI npm dependencies..."

UI_DIR="$HOME/anscer_ws/src/anscer_iui/mission_control_ui"

if [[ -d "$UI_DIR" ]]; then
    export NVM_DIR="$HOME/.config/nvm"
    set +u
    . "$NVM_DIR/nvm.sh"
    set -u

    run nvm use "$NODE_VERSION"
    cd "$UI_DIR"
    run rm -rf node_modules package-lock.json
    run npm install
    ok "Mission Control UI npm dependencies installed."
else
    fail "Mission Control UI directory not found: $UI_DIR"
fi

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------
info "Running final dependency verification..."

checks=(
    "/opt/ros/noetic/setup.bash|ROS Noetic"
    "/usr/lib/x86_64-linux-gnu/libserial.so|LibSerial"
    "$GRPC_INSTALL_DIR/lib/libgrpc.a|gRPC"
    "/usr/local/lib/libmongoc-1.0.so|MongoDB C driver"
    "/usr/local/lib/libmongocxx.so|MongoDB C++ driver"
    "/usr/local/lib/libpaho-mqtt3as.so|Paho MQTT C"
    "/usr/local/lib/libpaho-mqttpp3.so|Paho MQTT C++"
    "$CARTO_DIR/install_isolated/setup.bash|Cartographer"
    "/usr/bin/mongosh|MongoDB shell"
)

PASS=true

for item in "${checks[@]}"; do
    path="${item%%|*}"
    name="${item#*|}"

    if [[ -e "$path" ]]; then
        ok "$name"
    else
        warn "$name MISSING: $path"
        PASS=false
    fi
done

set +u
. "$NVM_DIR/nvm.sh" 2>/dev/null || true
set -u

if command -v node >/dev/null 2>&1; then
    ok "Node.js $(node --version)"
else
    warn "Node.js missing"
    PASS=false
fi

if [[ "$PASS" != true ]]; then
    fail "One or more dependency checks failed."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
echo "=================================================================="
echo " ANSCER SIMULATION DEPENDENCIES INSTALLED"
echo "=================================================================="
echo
echo "ROS:          $(rosversion -d 2>/dev/null || echo unknown)"
echo "Node:         $(node --version)"
echo "npm:          $(npm --version)"
echo "MongoDB:      server in the ros1-mongo container, mongosh $(mongosh --version 2>/dev/null)"
echo "gRPC:         $GRPC_INSTALL_DIR"
echo "Cartographer: $CARTO_DIR/install_isolated"
echo "Paho C++:     $PAHO_CPP_CONFIG"
echo
echo "Next:"
echo "  source /opt/ros/noetic/setup.bash"
echo "  source $CARTO_DIR/install_isolated/setup.bash"
echo "  cd ~/anscer_ws"
echo "  rosdep install --from-paths src --ignore-src --rosdistro=noetic -y --skip-keys=libabsl-dev"
echo "  catkin_make"
echo
echo "MongoDB runs as the ros1-mongo container (mongodb://localhost:27017)."
echo "Do not start mongod inside this container."
echo
echo "Save everything into the image (on the HOST):"
echo "  sudo systemctl restart ros1"
echo
