FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      sudo \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash --uid 1000 seed \
 && echo "seed ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/seed \
 && chmod 0440 /etc/sudoers.d/seed

USER seed
WORKDIR /home/seed

CMD ["sleep", "infinity"]
