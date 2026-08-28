# Build Docker. ONE image, TWO entrypoints: /bin/atari-57 (the cabinet server,
# which also runs the decision layer) and /bin/atari-57-player (the thin seat
# registrar). The policy set is env-switched inside this same image
# (PLAYER_PROMPT vs PLAYER_SCRIPTED), which is what keeps a champion and a
# scripted filler byte-identical apart from their environment.
#
# Nim module names may not contain `-`, so the SOURCES are src/atari57*.nim
# while the BINARIES are /bin/atari-57 and /bin/atari-57-player, which is what
# every manifest, compose and slug string says.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/atari57
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# The committed nim.cfg pins the AUTHOR's machine package paths; rebuild it
# from THIS container's package tree, exactly as ci.yml does.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && \
  cat nim.cfg

ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --threads:on \
  --nimcache:/tmp/atari-57-nimcache \
  --out:atari-57 \
  src/atari57.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/atari-57-player-nimcache \
  --out:atari-57-player \
  src/atari57_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/atari57
COPY --from=build /workspace/atari57/atari-57 /bin/atari-57
COPY --from=build /workspace/atari57/atari-57-player /bin/atari-57-player
COPY --from=build /workspace/atari57/*.json ./
COPY --from=build /workspace/atari57/data ./data
COPY --from=build /workspace/atari57/client ./client

CMD ["/bin/atari-57"]
