# Multi-stage unified 8mb.local container — CPU-only, ARM64 (aarch64) build.
# Difference vs upstream: NVIDIA/CUDA base images swapped for plain Ubuntu, and
# the NVENC/CUDA pieces removed from the FFmpeg build. All CPU encoders (x264,
# x265, SVT-AV1, VP8/9, AV1, Opus) are unchanged, so the app behaves the same.

# ── Stage 1: Build FFmpeg with CPU encoders only ───────────────────────────────
FROM ubuntu:22.04 AS ffmpeg-build

ENV DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential nasm yasm cmake pkg-config git wget ca-certificates \
    libnuma-dev libx264-dev libx265-dev libvpx-dev libopus-dev \
    libaom-dev libdav1d-dev

WORKDIR /build

# SVT-AV1: Ubuntu 22.04's packaged libsvtav1 is too old for FFmpeg 6.1's glue.
# Build a current release from source (has ARM NEON support). Must stay on the
# SVT-AV1 2.x API that FFmpeg 6.1.x targets (3.x changes break the build).
ARG SVTAV1_VERSION=v2.2.1
RUN git clone --depth 1 --branch ${SVTAV1_VERSION} https://gitlab.com/AOMediaCodec/SVT-AV1.git && \
    cd SVT-AV1/Build && \
    cmake .. -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local && \
    cmake --build . -j"$(nproc)" && cmake --install . && ldconfig && \
    cd /build && rm -rf SVT-AV1

# Build FFmpeg 6.1.1 with CPU encoders (no CUDA / NVENC).
RUN wget -q https://ffmpeg.org/releases/ffmpeg-6.1.1.tar.xz && \
    tar xf ffmpeg-6.1.1.tar.xz && cd ffmpeg-6.1.1 && \
    ./configure \
      --enable-gpl \
      --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus \
      --enable-libaom --enable-libsvtav1 --enable-libdav1d \
      --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages && \
    make -j"$(nproc)" && make install && ldconfig && \
    strip --strip-all /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    cd .. && rm -rf ffmpeg-6.1.1 ffmpeg-6.1.1.tar.xz /build

# ── Stage 2: Build Frontend (unchanged; node:20-alpine is multi-arch) ─────────
FROM node:20-alpine AS frontend-build

WORKDIR /frontend
COPY frontend/package.json frontend/package-lock.json* ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci

COPY frontend/ ./
ENV PUBLIC_BACKEND_URL=""
RUN npm run build && \
    find build -name "*.map" -delete && \
    find build -name "*.ts" -delete

# ── Stage 3: Runtime (CPU-only, no CUDA) ──────────────────────────────────────
FROM ubuntu:22.04

ARG BUILD_VERSION=137
ENV APP_VERSION=${BUILD_VERSION}
ARG BUILD_COMMIT=unknown
ENV BUILD_COMMIT=${BUILD_COMMIT}

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    python3.10 python3-pip supervisor redis-server \
    libopus0 libx264-163 libx265-199 libvpx7 libnuma1 \
    libaom3 libdav1d5 \
    && apt-get clean && rm -rf /tmp/*

# Copy the FFmpeg we built (binaries + its shared libs, incl. SVT-AV1).
COPY --from=ffmpeg-build /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg-build /usr/local/bin/ffprobe /usr/local/bin/ffprobe
COPY --from=ffmpeg-build /usr/local/lib/libSvtAv1Enc.so* /usr/local/lib/
COPY --from=ffmpeg-build /usr/local/lib/libavcodec.so* /usr/local/lib/
COPY --from=ffmpeg-build /usr/local/lib/libavformat.so* /usr/local/lib/
COPY --from=ffmpeg-build /usr/local/lib/libavutil.so* /usr/local/lib/
COPY --from=ffmpeg-build /usr/local/lib/libavfilter.so* /usr/local/lib/
COPY --from=ffmpeg-build /usr/local/lib/libswscale.so* /usr/local/lib/
COPY --from=ffmpeg-build /usr/local/lib/libswresample.so* /usr/local/lib/
COPY --from=ffmpeg-build /usr/local/lib/libavdevice.so* /usr/local/lib/
RUN ldconfig

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    pip3 install --no-cache-dir -r /app/requirements.txt && \
    rm /app/requirements.txt && \
    find /usr/local/lib/python3.10 -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true && \
    find /usr/local/lib/python3.10 -type f -name '*.pyc' -delete && \
    find /usr/local/lib/python3.10 -type f -name '*.pyo' -delete

COPY backend-api/app /app/backend
COPY worker/app /app/worker
COPY --from=frontend-build /frontend/build /app/frontend-build

RUN echo "Version: ${APP_VERSION}" > /app/VERSION && \
    echo "Commit: ${BUILD_COMMIT}" >> /app/VERSION && \
    echo -n "Built: " >> /app/VERSION && date -u +%FT%TZ >> /app/VERSION && \
    echo "FFmpeg: $(ffmpeg -version | head -n1)" >> /app/VERSION

RUN mkdir -p /app/uploads /app/outputs /var/log/supervisor /var/lib/redis /var/log/redis

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 8001

ENTRYPOINT ["/app/entrypoint.sh"]
