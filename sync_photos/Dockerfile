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
  && apt clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /
