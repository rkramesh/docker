FROM arm64v8/debian:bullseye-slim

RUN apt update && apt install -y \
  ifuse \
  tree \
  vim \
  curl \
  usbmuxd \
  libimobiledevice-utils \
  fuse \
  rsync \
  sqlite3 \
  libheif-examples \
  imagemagick \
  python3 \
  python3-pip \
  && apt clean \
  && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir pillow pillow-heif

WORKDIR /

