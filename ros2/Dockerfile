#
# ros2 - host-integrated development image.
#
# This image only provides the plumbing that makes the container feel like the
# host: your user, sudo, locale, GL/Vulkan userspace, name resolution and the
# Docker CLI. ROS 2 Jazzy and project dependencies are installed by you inside
# the running container and kept by the auto-commit on stop.
#
# Build with ./build.sh (arguments come from .env).

ARG BASE_IMAGE=ubuntu:24.04

# Static Docker CLI + compose/buildx plugins, taken from the official image.
FROM docker:cli AS docker-cli

FROM ${BASE_IMAGE}

ARG USERNAME=kd
ARG USER_UID=1000
ARG USER_GID=1000
ARG CONTAINER_NAME=ros2
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base packages:
#   sudo, locales, tzdata, bash-completion ... a usable shell
#   libnss-myhostname  resolve the host's hostname (ROS needs this)
#   libnss-mdns        resolve robot.local names via the host's avahi-daemon
#   mesa / libglvnd    OpenGL, EGL and Vulkan on the AMD iGPU (NVIDIA libs are
#                      injected at runtime by the NVIDIA container toolkit)
#   /etc/localtime     made a plain file so the host's copy can be mounted
#                      over it (same time zone as the host)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        sudo locales tzdata ca-certificates curl gnupg2 lsb-release \
        bash-completion less nano iproute2 iputils-ping \
        libnss-myhostname libnss-mdns \
        libgl1 libegl1 libglx-mesa0 libegl-mesa0 libgl1-mesa-dri mesa-vulkan-drivers \
 && sed -i 's/^hosts:.*/hosts:          files mdns4_minimal [NOTFOUND=return] dns myhostname/' /etc/nsswitch.conf \
 && locale-gen en_US.UTF-8 \
 && rm -f /etc/localtime /etc/timezone && touch /etc/localtime \
 && rm -rf /var/lib/apt/lists/*

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins

# Your user, with the same name/UID/GID as on the host, and passwordless sudo.
# Any existing user holding that UID (e.g. "ubuntu" in newer bases) is removed.
RUN existing="$(getent passwd "${USER_UID}" | cut -d: -f1 || true)" \
 && if [ -n "${existing}" ] && [ "${existing}" != "${USERNAME}" ]; then userdel -r "${existing}" 2>/dev/null || userdel "${existing}"; fi \
 && if ! getent group "${USER_GID}" >/dev/null; then groupadd -g "${USER_GID}" "${USERNAME}"; fi \
 && useradd -m -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" \
        -G sudo,adm,dialout,video,audio,plugdev "${USERNAME}" \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" \
 && chmod 0440 "/etc/sudoers.d/${USERNAME}" \
 && echo "${CONTAINER_NAME}" > /etc/debian_chroot

COPY --chmod=0755 entrypoint.sh /usr/local/sbin/container-entrypoint

ENV LANG=en_US.UTF-8 \
    CONTAINER_NAME=${CONTAINER_NAME} \
    CONTAINER_USER=${USERNAME}

WORKDIR /home/${USERNAME}

# The entrypoint runs as root (it maps host device groups, then idles).
# Shells are opened as your user by the `2` command.
ENTRYPOINT ["/usr/local/sbin/container-entrypoint"]
CMD ["sleep", "infinity"]
