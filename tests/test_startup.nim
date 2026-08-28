## The entrypoints: a bad config is a CLEAN non-zero exit, not a traceback; the
## seed is randomised when unpinned and honoured when pinned; and the image
## really does carry both binaries.

import std/[json, os, osproc, strformat, strutils]
import lane_helpers

proc buildEntrypoint(): string =
  ## Compiles the real `/bin/atari-57` entrypoint and returns its path. The
  ## behaviour under test is the process's, so the process is what is run.
  result = getTempDir() / "atari57-startup-probe"
  let (output, code) = execCmdEx(
    "nim c --hints:off --threads:on --path:" & (repoRoot() / "src") &
    " -o:" & result & " " & (repoRoot() / "src" / "atari57.nim"))
  check(code == 0, &"the entrypoint did not compile:\n{output}")
  check(fileExists(result), "the entrypoint binary is missing")

proc runEntrypoint(
  env: seq[(string, string)], capSeconds = 0
): tuple[code: int, output: string] =
  ## `capSeconds` caps a run that would otherwise serve to completion: the
  ## startup line under test is printed before the listener even opens, and
  ## the server's own bounded shutdown grace is 20 s per run.
  var command = ""
  for (key, value) in env:
    command.add(key & "='" & value & "' ")
  if capSeconds > 0:
    command.add("timeout " & $capSeconds & " ")
  command.add(getTempDir() / "atari57-startup-probe")
  let (output, code) = execCmdEx(command)
  (code, output)

proc testMissingConfigExitsCleanly() =
  let outcome = runEntrypoint(@[("COGAME_HOST", "127.0.0.1"),
                                ("COGAME_PORT", "8799"),
                                ("COGAME_CONFIG_URI", "file:///nonexistent.json")])
  check(outcome.code != 0, "an unreadable config exited 0")
  check(not outcome.output.contains("Traceback"),
        &"an unreadable config printed a traceback:\n{outcome.output}")
  check(not outcome.output.contains("SIGSEGV"), "the entrypoint crashed")
  report("an unreadable COGAME_CONFIG_URI: non-zero, no traceback")

proc testUnparseableConfigExitsCleanly() =
  let path = getTempDir() / "atari57-bad-config.json"
  writeFile(path, "{not json at all")
  let outcome = runEntrypoint(@[("COGAME_HOST", "127.0.0.1"),
                                ("COGAME_PORT", "8799"),
                                ("COGAME_CONFIG_URI", "file://" & path)])
  check(outcome.code != 0, "an unparseable config exited 0")
  check(outcome.output.contains("bad game config") or
        outcome.output.contains("not valid JSON"),
        &"no clean message for an unparseable config:\n{outcome.output}")
  check(not outcome.output.contains("Traceback"),
        "an unparseable config printed a traceback")
  report("an unparseable config: non-zero, a clean message, no traceback")

proc testUnknownRomExitsCleanly() =
  let path = getTempDir() / "atari57-bad-rom.json"
  writeFile(path, """{"rom":"pitfall","num_agents":4}""")
  let outcome = runEntrypoint(@[("COGAME_HOST", "127.0.0.1"),
                                ("COGAME_PORT", "8799"),
                                ("COGAME_CONFIG_URI", "file://" & path)])
  check(outcome.code != 0, "an unknown rom exited 0")
  check(outcome.output.contains("rom must be one of"),
        &"no clean message for an unknown rom:\n{outcome.output}")
  check(not outcome.output.contains("Traceback"),
        "an unknown rom printed a traceback")
  report("an unknown rom: non-zero, names the three cartridges, no traceback")

proc testSeedIsPinnedAndRandomised() =
  ## A config that NAMES a seed is honoured; one that does not is randomised —
  ## with a public fixed seed every scatter flip, serve angle and marcher
  ## volley would be pre-computable by an opponent.
  let pinned = getTempDir() / "atari57-pinned.json"
  writeFile(pinned, """{"rom":"chomper","seed":424242,"num_agents":4,
                        "minPlayers":4,"lobbyJoinTimeoutTicks":24,
                        "maxTicks":120,"startWaitTicks":0}""")
  let first = runEntrypoint(@[("COGAME_HOST", "127.0.0.1"),
                              ("COGAME_PORT", "8801"),
                              ("COGAME_CONFIG_URI", "file://" & pinned)],
                            capSeconds = 8)
  check(first.output.contains("seed=424242"),
        &"a pinned seed was not honoured:\n{first.output}")
  check(not first.output.contains("seed not pinned"),
        "a pinned seed was randomised anyway")

  let free = getTempDir() / "atari57-free.json"
  writeFile(free, """{"rom":"chomper","num_agents":4,"minPlayers":4,
                      "lobbyJoinTimeoutTicks":24,"maxTicks":120,
                      "startWaitTicks":0}""")
  var seeds: seq[string]
  for port in ["8802", "8803"]:
    let outcome = runEntrypoint(@[("COGAME_HOST", "127.0.0.1"),
                                  ("COGAME_PORT", port),
                                  ("COGAME_CONFIG_URI", "file://" & free)],
                                capSeconds = 8)
    check(outcome.output.contains("seed not pinned; randomized"),
          &"an unpinned seed was not randomised:\n{outcome.output}")
    for line in outcome.output.splitLines():
      if line.contains(" seed="):
        let at = line.find(" seed=")
        seeds.add(line[at + 6 ..< line.find(' ', at + 6)])
        break
  check(seeds.len == 2, "the startup line did not report a seed")
  check(seeds[0] != seeds[1],
        &"two unpinned runs drew the SAME seed ({seeds[0]})")
  report("a named seed is honoured; an unnamed one is randomised per process")

proc testBothBinariesAreBuiltAndCopied() =
  let dockerfile = readRepoFile("Dockerfile")
  check(dockerfile.contains("--out:atari-57 \\\n  src/atari57.nim") or
        dockerfile.contains("--out:atari-57"),
        "the Dockerfile does not build the game binary")
  check(dockerfile.contains("--out:atari-57-player"),
        "the Dockerfile does not build the player binary")
  check(dockerfile.contains("/workspace/atari57/atari-57 /bin/atari-57"),
        "the runtime stage does not copy /bin/atari-57")
  check(dockerfile.contains(
          "/workspace/atari57/atari-57-player /bin/atari-57-player"),
        "the runtime stage does not copy /bin/atari-57-player")
  check(dockerfile.contains("CMD [\"/bin/atari-57\"]"),
        "the image's CMD is not the cabinet")
  check(dockerfile.contains("COPY --from=build /workspace/atari57/data ./data"),
        "the runtime stage does not carry the shipped art")
  check(dockerfile.contains("COPY --from=build /workspace/atari57/client ./client"),
        "the runtime stage does not carry the client art")
  let policies = parseJson(readRepoFile("tools/ci/policies.json"))
  check(policies.len == 4, &"{policies.len} policies, not 4")
  var prompts = 0
  var scripted = 0
  for policy in policies:
    check(policy{"run"}.getStr() == "/bin/atari-57-player",
          "a policy does not run the player entrypoint")
    check(policy{"name"}.getStr().startsWith("atari-57-"),
          "a policy is not named for this game")
    if policy{"env"}.hasKey("PLAYER_PROMPT"):
      inc prompts
      check(policy{"env"}{"PLAYER_PROMPT"}.getStr().len > 400,
            "a champion's prompt is trivial")
    if policy{"env"}.hasKey("PLAYER_SCRIPTED"):
      inc scripted
      check(policy{"env"}{"PLAYER_SCRIPTED"}.getStr() in ["arcader", "hoover"],
            "a filler names an unpublished baseline")
  check(prompts == 2, &"{prompts} PLAYER_PROMPT champions, not 2")
  check(scripted == 2, &"{scripted} PLAYER_SCRIPTED fillers, not 2")
  check(policies[1]{"player"}.getStr() ==
          "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
        "champion #2 does not carry the daveey-1 player id")
  report("both entrypoints are built and copied; four policies, two prompts")

when isMainModule:
  echo "test_startup"
  discard buildEntrypoint()
  testMissingConfigExitsCleanly()
  testUnparseableConfigExitsCleanly()
  testUnknownRomExitsCleanly()
  testSeedIsPinnedAndRandomised()
  testBothBinariesAreBuiltAndCopied()
  echo "test_startup OK"
