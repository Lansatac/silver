FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive

# clang/llvm/lld are the backend's toolchain (`ptr` IR syntax needs LLVM 15+).
# strace, time, hyperfine and valgrind (callgrind) are for finding where time goes; perf is left
# out because it has to match WSL2's custom kernel. Python is for the scripts agents write.
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
    strace \
    time \
    hyperfine \
    valgrind \
    bc \
    jq \
    ripgrep \
    python3 \
    python3-venv \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# The Windows clone, which setup.sh clones and fetches from, is owned by root as mounted. Cloning
# or fetching from a path checks its .git directory, and working in it checks the tree.
RUN git config --system --add safe.directory /mnt/windows-silver \
    && git config --system --add safe.directory /mnt/windows-silver/.git

# Pinned to match the Windows host, so both sides see the same compiler behaviour.
ARG DMD_VERSION=2.113.0
RUN curl -fsS https://dlang.org/install.sh | bash -s install "dmd-${DMD_VERSION}" -p /opt/dlang \
    && DMD_DIR=/opt/dlang/dmd-${DMD_VERSION} \
    && ln -s ${DMD_DIR}/linux/bin64/dmd /usr/local/bin/dmd \
    && ln -s ${DMD_DIR}/linux/bin64/dub /usr/local/bin/dub \
    && ln -s ${DMD_DIR}/linux/bin64/rdmd /usr/local/bin/rdmd \
    && echo "${DMD_DIR}/linux/lib64" > /etc/ld.so.conf.d/dlang.conf && ldconfig \
    && chmod -R a+rX /opt/dlang

# LDC, for optimized builds. Pinned to the release on dmd's frontend, druntime and Phobos, so the
# two compilers accept the same code. dub stays dmd's; `dub --compiler=ldc2` selects this one.
ARG LDC_VERSION=1.43.0
RUN curl -fsS https://dlang.org/install.sh | bash -s install "ldc-${LDC_VERSION}" -p /opt/dlang \
    && LDC_DIR=/opt/dlang/ldc-${LDC_VERSION} \
    && ln -s ${LDC_DIR}/bin/ldc2 /usr/local/bin/ldc2 \
    && ln -s ${LDC_DIR}/bin/ldmd2 /usr/local/bin/ldmd2 \
    && chmod -R a+rX /opt/dlang

# redub, which runTests.sh builds and tests with, from Jason's fork: upstream's `redub test` doesn't
# generate the dub_test_root silver.testrunner needs, and its builds drop dub.selections.json's
# entries. Pinned to a commit on the fork's test-root branch; bump it to upgrade.
ARG REDUB_COMMIT=c66790d5f6f1de7b1036bcc733a30ed0f7571e78
RUN git clone --quiet https://github.com/Lansatac/redub.git /opt/redub \
    && cd /opt/redub \
    && git checkout --quiet ${REDUB_COMMIT} \
    && dub build --quiet \
    && ln -s /opt/redub/build/redub /usr/local/bin/redub \
    && rm -rf /root/.dub \
    && chmod -R a+rX /opt/redub

# Beads (`bd`), the issue tracker. Pinned like dmd; bump the version to upgrade.
ARG BEADS_VERSION=1.3.4
RUN ARCH=$(dpkg --print-architecture) \
    && TARBALL=beads_${BEADS_VERSION}_linux_${ARCH}.tar.gz \
    && BASE=https://github.com/gastownhall/beads/releases/download/v${BEADS_VERSION} \
    && TMP=$(mktemp -d) && cd "$TMP" \
    && curl -fsSLO "${BASE}/${TARBALL}" \
    && curl -fsSL "${BASE}/checksums.txt" | grep " ${TARBALL}\$" | sha256sum -c - \
    && tar -xzf "${TARBALL}" \
    && install -m 0755 "$(find . -type f -name bd | head -n1)" /usr/local/bin/bd \
    && ln -s bd /usr/local/bin/beads \
    && cd / && rm -rf "$TMP"

# Ubuntu's image ships an `ubuntu` user with UID 1000; replace it with `dev`.
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
