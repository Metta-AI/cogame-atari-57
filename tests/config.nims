# Mummy requires --threads:on, and `src/lane/server.nim` is under test here.
# Scoped to tests/ so the emscripten replay-viewer build (which must stay
# single-threaded) is untouched.
switch("threads", "on")
