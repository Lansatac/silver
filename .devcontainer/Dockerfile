FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive

# clang/llvm/lld are the backend's toolchain (LLVM 18 on 24.04; `ptr` IR syntax needs 15+).
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    gdb \
    gnupg \
    xz-utils \
    build-essential \
    zlib1g-dev \
    clang \
    llvm \
    lld \
    && rm -rf /var/lib/apt/lists/*

RUN git config --system --add safe.directory /code

# Pinned to match the Windows host, so both sides see the same compiler behaviour.
ARG DMD_VERSION=2.113.0
RUN curl -fsS https://dlang.org/install.sh | bash -s install "dmd-${DMD_VERSION}" -p /opt/dlang \
    && DMD_DIR=/opt/dlang/dmd-${DMD_VERSION} \
    && ln -s ${DMD_DIR}/linux/bin64/dmd /usr/local/bin/dmd \
    && ln -s ${DMD_DIR}/linux/bin64/dub /usr/local/bin/dub \
    && ln -s ${DMD_DIR}/linux/bin64/rdmd /usr/local/bin/rdmd \
    && echo "${DMD_DIR}/linux/lib64" > /etc/ld.so.conf.d/dlang.conf && ldconfig \
    && chmod -R a+rX /opt/dlang

# 24.04 ships an `ubuntu` user with UID 1000; replace it with `dev`.
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=$USER_UID
RUN userdel -r ubuntu \
    && groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    && mkdir -p /code /home/$USERNAME/.dub \
    && chown -R $USERNAME:$USERNAME /code /home/$USERNAME

WORKDIR /code
USER $USERNAME
