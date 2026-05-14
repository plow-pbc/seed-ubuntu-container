FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      sudo \
 && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 ships a pre-existing `ubuntu` user at UID 1000. Reusing it
# (instead of creating a `seed` user at 1001) means bind-mounted host paths
# owned by a typical Linux developer (also UID 1000) are read+write inside
# the sandbox without sudo — matching the README's writable-mount contract.
RUN echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu \
 && chmod 0440 /etc/sudoers.d/ubuntu

USER ubuntu
WORKDIR /home/ubuntu

CMD ["sleep", "infinity"]
