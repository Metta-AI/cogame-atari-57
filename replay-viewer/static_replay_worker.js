'use strict';

// broadcast_core.js is shared with the native Window client and its vendored
// Snappy module publishes through `window`. A classic Worker can provide that
// alias without introducing a second implementation or bundle step.
self.window = self;

var Module = {};
var runtimeReady = false;
var initMessage = null;
var runtimeLoaded = false;
var core = null;
var failed = false;
var disposed = false;

function stageNote() {
  // The fixed progress buffer survives an ABORTING_MALLOC failure even though
  // the Emscripten call stack does not.
  try {
    var length = Module._atari57_stage_len ? Module._atari57_stage_len() : 0;
    if (!length) return '';
    var pointer = Module._atari57_stage_ptr();
    return new TextDecoder().decode(
      Module.HEAPU8.slice(pointer, pointer + length));
  } catch (ignored) {
    return '';
  }
}

function runtimeError() {
  var length = Module._atari57_error_len();
  if (!length) {
    var stage = stageNote();
    return stage
      ? 'Replay runtime failed while: ' + stage
      : 'Replay runtime rejected the replay';
  }
  var pointer = Module._atari57_error_ptr();
  return new TextDecoder().decode(
    Module.HEAPU8.slice(pointer, pointer + length));
}

function reportFailure(error) {
  if (failed || disposed) return;
  failed = true;
  postMessage({
    type: 'error',
    message: error && error.message ? error.message : String(error),
    stage: stageNote()
  });
}

function copyIntoRuntime(bytes, callback) {
  var pointer = Module._malloc(bytes.length);
  try {
    Module.HEAPU8.set(bytes, pointer);
    return callback(pointer, bytes.length);
  } finally {
    Module._free(pointer);
  }
}

function ingestPacket() {
  var length = Module._atari57_packet_len();
  if (!length) throw new Error('Replay runtime produced an empty frame');
  var pointer = Module._atari57_packet_ptr();
  // BroadcastCore parses synchronously and copies any retained compressed
  // sprite bytes, so it can read the WASM heap view directly. This avoids a
  // full packet allocation/copy on every replay frame.
  core.ingest(Module.HEAPU8.subarray(pointer, pointer + length));
}

function sendRuntimeInput(bytes) {
  if (!runtimeLoaded) return;
  copyIntoRuntime(bytes, function (pointer, length) {
    Module._atari57_input(pointer, length);
  });
}

function createBroadcastCore(message) {
  core = self.BroadcastCore.create({
    canvas: message.canvas,
    websocket: false,
    playoutBuffer: false,
    viewportWidth: message.width,
    viewportHeight: message.height,
    devicePixelRatio: message.dpr,
    onText: function (text) {
      postMessage({ type: 'text', text: text });
    },
    onStatus: function (status) {
      postMessage({ type: 'status', status: status });
    },
    onFirstFrame: function () {
      postMessage({ type: 'firstFrame' });
    },
    onTransform: function (transform) {
      postMessage({ type: 'transform', transform: transform });
    },
    onSendPacket: sendRuntimeInput
  });
  core.start();
}

async function start() {
  if (!runtimeReady || !initMessage || runtimeLoaded || failed || disposed) return;
  var message = initMessage;
  initMessage = null;
  try {
    createBroadcastCore(message);
    var response = await fetch(message.replayUrl, {
      credentials: 'omit',
      mode: 'cors'
    });
    if (!response.ok) {
      throw new Error('Replay request returned HTTP ' + response.status);
    }
    var bytes = new Uint8Array(await response.arrayBuffer());
    if (!bytes.length) throw new Error('Replay response was empty');
    var loaded = copyIntoRuntime(bytes, function (pointer, length) {
      return Module._atari57_load_replay(pointer, length);
    });
    if (!loaded) throw new Error(runtimeError());
    runtimeLoaded = true;
    ingestPacket();
    postMessage({
      type: 'loaded',
      mismatchTick: Module._atari57_mismatch_tick()
    });
  } catch (error) {
    reportFailure(error);
  }
}

function applyInputNow() {
  // A viewer input (transport command, scrubber seek, board click) only takes
  // effect at the top of the next presentation frame, and the main thread only
  // asks for one on its next rAF -- behind whatever advance batch is already
  // queued. On a long replay that made a mid-replay seek arrive seconds after
  // the click (the hosted 50 % scrub read identically to 0 %). Run ONE frame
  // right here instead, so the input is applied and drawn as soon as the
  // message is processed. `advanced` is not posted: the main thread's
  // advance-in-flight bookkeeping is not ours to touch.
  if (!runtimeLoaded || failed || disposed) return;
  try {
    if (Module._atari57_frame() < 0) throw new Error(runtimeError());
    ingestPacket();
    postMessage({
      type: 'inputApplied',
      mismatchTick: Module._atari57_mismatch_tick()
    });
  } catch (error) {
    reportFailure(error);
  }
}

function advance(frames) {
  if (!runtimeLoaded || failed || disposed) return;
  try {
    var count = Math.max(1, Math.min(6, Number(frames) || 1));
    for (var i = 0; i < count; i++) {
      if (Module._atari57_frame() < 0) throw new Error(runtimeError());
      ingestPacket();
    }
    postMessage({
      type: 'advanced',
      mismatchTick: Module._atari57_mismatch_tick(),
      // Presentation stat for the page (the core draws over here, a thread
      // away): total frames blitted, so the page can read draws-per-second.
      draws: core ? core.getPaceStats().draws : 0
    });
  } catch (error) {
    reportFailure(error);
  }
}

Module.locateFile = function (path) {
  return new URL(path, self.location.href).toString();
};
Module.onAbort = function (what) {
  var stage = stageNote();
  reportFailure(new Error('Replay runtime ran out of memory (' + what +
    ') — wasm32 is limited to 2 GB' +
    (stage ? '. Failed while: ' + stage : '')));
};
Module.onRuntimeInitialized = function () {
  runtimeReady = true;
  start();
};
self.Module = Module;

self.onmessage = function (event) {
  var message = event.data || {};
  try {
    if (message.type === 'init') {
      initMessage = message;
      start();
    } else if (message.type === 'advance') {
      advance(message.frames);
    } else if (message.type === 'command' && core) {
      core.sendCommand(message.text || '');
      applyInputNow();
    } else if (message.type === 'click' && core) {
      core.clickMap(Number(message.x) || 0, Number(message.y) || 0);
      applyInputNow();
    } else if (message.type === 'input' && runtimeLoaded) {
      sendRuntimeInput(new Uint8Array(message.bytes));
      applyInputNow();
    } else if (message.type === 'resize' && core) {
      core.setViewportSize(message.width, message.height, message.dpr);
    // No view or minimap message arrives: the fixed arena removed #viewpanel
    // and every zoom/pan handler with it, so nothing on the main thread can ask
    // this core to zoom, pan or draw a minimap. The transform echoed back for
    // click mapping stays the single source of truth.
    } else if (message.type === 'dispose') {
      disposed = true;
      if (core) core.stop();
      close();
    }
  } catch (error) {
    reportFailure(error);
  }
};

importScripts('./wire_constants.js', './broadcast_core.js', './atari57_replay.js');
