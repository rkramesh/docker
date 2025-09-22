FROM arm32v7/debian:bullseye-slim

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
  libheif-examples\
  && apt clean

WORKDIR /
