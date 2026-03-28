# Antithesis build of TON validator-engine
# Based on the project's root Dockerfile with Antithesis SDK assertions
# and coverage instrumentation for intelligent exploration.
#
# NOTE: Submodules must be initialized on the host before building.
# Run: git submodule update --init --recursive

FROM ubuntu:22.04 AS builder
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
        rm /var/lib/dpkg/info/libc-bin.* && \
        apt-get clean && \
        apt-get update && \
        apt install libc-bin && \
        apt-get install -y build-essential cmake clang gperf wget git \
        ninja-build pkg-config autoconf automake libtool perl \
        libjemalloc-dev lsb-release software-properties-common gnupg ccache

RUN wget https://apt.llvm.org/llvm.sh && \
    chmod +x llvm.sh && \
    ./llvm.sh 21 all && \
    ln -sf /usr/bin/ld.lld-21 /usr/bin/ld.lld && \
    rm -rf /var/lib/apt/lists/*

ENV CC=/usr/bin/clang-21
ENV CXX=/usr/bin/clang++-21
ENV CCACHE_DIR=/ccache
ENV CCACHE_MAXSIZE=5G

WORKDIR /
RUN mkdir ton
WORKDIR /ton

COPY ./ ./

RUN test -f /ton/third-party/openssl/Configure || \
    (echo "ERROR: submodules not initialized. Run: git submodule update --init --recursive" && exit 1)

# Pre-compile Antithesis coverage callbacks into a reusable object so every
# executable gets the __sanitizer_cov_trace_pc_guard implementation.
RUN echo '#include "antithesis_instrumentation.h"' | \
    clang++-21 -std=c++20 -c -I/ton/third-party/antithesis-sdk-cpp \
    -o /ton/antithesis_instrumentation.o -xc++ -

RUN --mount=type=cache,target=/ton/build \
    --mount=type=cache,target=/ccache \
    cd /ton/build && \
    cmake -GNinja -DCMAKE_BUILD_TYPE=Release -DPORTABLE=1 -DTON_ARCH= -DTON_USE_JEMALLOC=ON -DMEMPROF= \
          -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
          -DCMAKE_C_FLAGS="-fsanitize-coverage=trace-pc-guard -g" \
          -DCMAKE_CXX_FLAGS="-fsanitize-coverage=trace-pc-guard -g" \
          -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld -Wl,--build-id /ton/antithesis_instrumentation.o" \
          -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld -Wl,--build-id" .. && \
    ninja validator-engine generate-random-id lite-client func create-state gen_fif && \
    mkdir -p /build-out && \
    cp validator-engine/validator-engine utils/generate-random-id lite-client/lite-client \
       crypto/create-state /build-out/

# ---------------------------------------------------------------------------
# Runtime image: validator-engine (SUT)
# ---------------------------------------------------------------------------
FROM ubuntu:22.04 AS validator
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y openssl libatomic1 libsodium-dev libmicrohttpd-dev liblz4-dev libjemalloc-dev \
                       wget curl net-tools netcat jq && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/ton-work/db /var/ton-work/scripts /symbols

COPY --from=builder /build-out/validator-engine /usr/local/bin/
COPY --from=builder /build-out/generate-random-id /usr/local/bin/
COPY --from=builder /build-out/create-state /usr/local/bin/

# Expose debug symbols for Antithesis symbolization
RUN ln -s /usr/local/bin/validator-engine /symbols/validator-engine

# Fift interpreter library files (standard library + smart contract definitions).
# create-state preloads Fift.fif and CreateState.fif from these paths at startup.
COPY --from=builder /ton/crypto/fift/lib /usr/local/share/ton/fift/lib
COPY --from=builder /ton/crypto/smartcont /usr/local/share/ton/smartcont

COPY antithesis/antithesis-zerostate.fif /usr/local/share/ton/antithesis-zerostate.fif

COPY antithesis/setup-complete.sh /usr/local/bin/setup-complete.sh
RUN chmod +x /usr/local/bin/setup-complete.sh

COPY antithesis/entrypoint-validator.sh /usr/local/bin/entrypoint-validator.sh
RUN chmod +x /usr/local/bin/entrypoint-validator.sh

WORKDIR /var/ton-work/db
ENTRYPOINT ["/usr/local/bin/entrypoint-validator.sh"]

# ---------------------------------------------------------------------------
# Workload image: test driver
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS workload
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y curl netcat-openbsd jq bash && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/antithesis/test/v1/ton

COPY antithesis/test/v1/ton/ /opt/antithesis/test/v1/ton/

COPY --from=builder /build-out/lite-client /usr/local/bin/

COPY antithesis/setup-complete.sh /usr/local/bin/setup-complete.sh
RUN chmod +x /usr/local/bin/setup-complete.sh

COPY antithesis/entrypoint-workload.sh /usr/local/bin/entrypoint-workload.sh
RUN chmod +x /usr/local/bin/entrypoint-workload.sh

ENTRYPOINT ["/usr/local/bin/entrypoint-workload.sh"]
