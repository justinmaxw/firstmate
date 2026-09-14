# Antigravity CLI

Antigravity's `agy` TUI, verified end to end on 2026-09-10 with agy 1.2.0 on Linux through the Herdr backend, and originally verified 2026-08-26 with agy 1.1.20 on macOS through tmux.
Built from the captain-approved Gemini (Antigravity) pool spec (`data/firstmate-gemini-pro-pool-spec-260825/report.md` in the primary home); the credential preflight and subscription-only billing refusal below are part of that spec's Task 1 scope.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no agy wake protocol.
`../../../../../docs/verification/agy.md` owns how every fact below was established and what is still unproven.
A raw launch command is refused outright for `harness=agy`: it carries none of the placeholders the model allowlist, model listing check, credential preflight, and subscription-only refusal below are gated on, so `--harness agy` (or the bare `agy` positional) is the only supported path.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `agy` from `PATH`, refused if absent; a Go-compiled single binary, so the live process name is exactly `agy` with `argv[0]=agy`. |
| Launch | `agy --prompt-interactive "<brief>" --model <id> --dangerously-skip-permissions`, with the resolved absolute binary; the brief auto-submits with no extra Enter. `AGY_CLI_DISABLE_AUTO_UPDATE=true` avoids lock contention on agy's own background self-updater's advisory lock when several crewmates launch close together. `GEMINI_API_KEY` is stripped at the launch boundary (`env -u GEMINI_API_KEY`) as part of the subscription-only enforcement below. The spawn pre-registers the worktree in agy's trust store first, then waits for a busy turn (answering the folder-trust dialog if it renders anyway) before reporting success. |
| Models | `--model <id>` with the bare catalog id from `agy models`. agy 1.2.x ids carry their effort as a suffix (`gemini-3.7-flash-low\|medium\|high`); the bare family name `gemini-3.7-flash` is no longer listed. The captain-approved AC-2 allowlist is Gemini 3.7 Flash only: `../../../../../bin/fm-spawn.sh` launches exactly `gemini-3.7-flash-low`, `gemini-3.7-flash-medium`, or `gemini-3.7-flash-high`, resolves an empty or `default` model to the variant an explicit `low\|medium\|high` effort names (`gemini-3.7-flash-medium` otherwise), and refuses every other id (every `gemini-3.8-*`, `gemini-3.6-*`, and `gemini-3.1-pro-*` included). An allowed id must also appear in the live catalog: fm-spawn refuses a requested id a reachable listing omits. The listing is a remote fetch, so the probe runs stdin-detached under the shared hard bound and an unreachable or hung listing launches unvalidated with a notice. |
| Busy state | No hook or plugin writer, so nothing is armed and no record is seeded; on Herdr the native `working` status classifies busy, and everywhere else the `agy-regex` rendered-tail fallback in `../../../../../bin/fm-busy-lib.sh` does. |
| Rendered tail | Busy status row carries `esc to cancel` on the left; the idle row shows `? for shortcuts` instead. The `Generating...` word beside the braille spinner is free-floating output and is not a signal. |
| Turn end | No turn-end hook or notification touch exists; completion arrives through the worker status protocol and, on Herdr, the native return to `idle`. |
| Exit | `/quit`, one Enter; the process exits. |
| Interrupt | Single `Escape`, which prints the Interrupted row and leaves an idle composer with no repollution, so no clear key follows. |
| Skill | No verified slash-skill form; use natural language. |
| Autonomy | `--dangerously-skip-permissions` auto-approves tool calls for the run; this carries the same disclosed recursive-subagent risk every other full-autonomy adapter flag already carries fleet-wide. |
| Marker | None; a live TUI carries no `AGY_*` or `ANTIGRAVITY_*` variable. An earlier verification against agy 1.1.20 believed `ANTIGRAVITY_AGENT=1` was agy's own marker, but re-verification against agy 1.2.0 found no such variable, and no `AGENT=1` seen on a live TUI is an inherited launcher value rather than an agy identity - see Detection below. |
| Resume | `--continue` and `--conversation` exist but carry no verified pane-resume contract; use deterministic relaunch. |
| Effort | Encoded in the model id's suffix, so no separate `--effort` flag is passed (verified live, agy 1.2.2: `--model gemini-3.7-flash-medium` alone is accepted). This replaces agy 1.1.20, whose bare `gemini-3.7-flash` required a separate `--effort` flag. `state/<id>.meta` records the suffix as the effort (`gemini-3.7-flash-medium` records `effort=medium`), and an explicit `--effort` that disagrees with the chosen model's suffix refuses the launch rather than silently picking one. `../../../../../bin/fm-control.sh relaunch` re-derives the effort from whichever model the replacement uses (an effort-only relaunch picks the matching Gemini 3.7 Flash variant), and refuses any other effort before the running agent is stopped. |
| Composer | Borderless bare `>` row, which the shared classifier reads as `unknown` under the dead-shell rule, never `empty`; steering confirms delivery through native agent-state and the delivery footer instead, the cursor precedent. |

## Trust, and where the decision persists

Every task worktree is a path agy has never seen, so an unregistered launch stops on `Do you trust the contents of this project?` with the safe choice `Yes, I trust this folder` preselected, and an unanswered dialog sends the turn into agy's scratch directory instead of the worktree.
There is no launch flag that suppresses the dialog, but agy honours a `trustedWorkspaces` entry in the captain's own `~/.gemini/antigravity-cli/settings.json` written ahead of launch (verified live), so `../../../../../bin/fm-spawn.sh` pre-registers the worktree through `../../../../../bin/fm-agy-trust.sh` before launch, the claude shape: the helper refuses anything but a linked worktree of the spawning project, records both the logical pane path and its resolved form because agy compares the logical cwd, and preserves every other key in the store.
The post-launch readiness gate is the backstop: it answers a dialog that renders anyway with a single Enter, then requires a busy verdict (Herdr's native `working` status or the pinned `esc to cancel` row) before the spawn reports success, and on a path that was not pre-registered it never counts a busy verdict as ready until the dialog has been answered, because Herdr's native verdict can precede the dialog.
A pane whose brief cannot be confirmed to run in the worktree fails the spawn, records the failure in the task status, and closes the endpoint.
Never steer into a pane still showing the dialog; a spawn that reported success has already cleared it.

## Credential preflight and subscription-only enforcement

Modeled on the Muse precedent ("credentials are a spawn preflight, not a screen check"): `../../../../../bin/fm-spawn.sh` refuses an `agy` launch unless `~/.gemini/antigravity-cli/jetski_state.pbtxt` exists and is non-empty, because an unauthenticated interactive pane does not exit - it sits on a Google sign-in browser flow indefinitely, which supervision would misread as a wedged worker rather than a missing credential. The file's contents are never read, only its presence. Verified live: every subsequent local `agy` process, including a separately spawned OS process, silently reuses the captain's one interactive login with no re-prompt.

Two further captain-approved refusals sit alongside the credential check, both fail-closed on any `jq` error (a settings file that cannot be parsed is refused, never silently permitted): a set `GEMINI_API_KEY`, or a `settings.json` `modelProvider` key, both switch `agy` onto pay-as-you-go API billing instead of the Google AI Pro/Ultra subscription this pool exists to use, and refuse the launch; a `settings.json` `useG1Credits: true` would silently spend the captain's own paid personal-credit top-ups once subscription quota is exhausted, and also refuses.

The `GEMINI_API_KEY` refusal reads fm-spawn's OWN process environment, which is not the pane's: crewmate panes are created by a long-lived tmux/Herdr daemon whose shell can export the key from an rc file firstmate never read, the same caller-vs-worker environment split Muse's `META_API_KEY` handling already documents. That refusal is therefore an early diagnostic, not the guarantee; the guarantee rides the launch itself - the generated launch carries `env -u GEMINI_API_KEY`, so the actual `agy` child cannot see the key on any backend even when the caller-side check saw nothing.

Open follow-up, deliberately not implemented: the wider Gemini CLI tooling family also honors a `GOOGLE_GENAI_USE_VERTEXAI`/`GOOGLE_CLOUD_PROJECT` Vertex vector. Whether `agy` itself reads those is UNVERIFIED, and this guard refuses only vectors verified first-hand against agy 1.1.20, so refusing on them today would block launches on no evidence; verify against the vendor CLI first, then extend `agy_settings_permits_subscription_only` in `../../../../../bin/fm-spawn.sh`.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process name `agy`, never `*agy*`.
No environment marker is promoted: `AGENT=1` observed on a live TUI is an inherited launcher value, not an agy identity, and agy does not clear an inherited `CLAUDECODE` - but a structural agy ancestor now outranks that retained marker, which `../../../../../bin/fm-harness.sh` decides without depending on the spawn's own launch-boundary marker clearing.
agy is deliberately absent from the session-lock name vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, where muse, gemini, and rovo are also absent: a crewmate-only adapter must never own a home session lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` arms no busy generation for agy and writes no sidecar, exactly because no writer could ever clear a seeded record.
`fm_busy_agy_tail_busy` matches the pinned `esc to cancel` status row alone, hardcoded with no environment override, and `fm_busy_classify` reports `unknown agy-regex` rather than idle when it is absent, because a long turn can scroll the marker out of the captured tail.
Teardown removes nothing agy-specific because the spawn leaves nothing behind.

## Known limitation: composer emptiness is not provable yet

`../../../../../bin/fm-tmux-lib.sh`'s shared structural composer classifier (`fm_tmux_composer_state`) reads a genuinely idle `agy` pane as `unknown`, never `empty`, live-verified. This is SAFE - it never misreports a real idle composer as `pending`, and never falsely proves one `empty` either - but any convenience gated on a PROVEN-empty composer (for example away-mode auto-injection) is unavailable for `agy` today.

Root cause: `agy`'s composer box uses a bare `─` rule both above and below its prompt with no corner glyphs, the same shape `../../../../../bin/fm-composer-lib.sh`'s pi-pair detector exists to recognize for Pi's own composer. Resolving a detected pi-pair candidate requires proving Pi process identity, which `agy` correctly fails, so the verdict falls through to the safe `unknown` rather than a wrong guess. Cursor's post-hoc structural-identity reclassification does not transfer directly, because agy's ambiguity is a property of the screen content itself, not of cursor placement. A real fix needs either a non-Pi identity path in the shared scanner or a different structural disambiguator, both out of proportion for this adapter's scope; `../../../../../tests/fm-agy-signals-live-e2e.test.sh` pins the current, honest `unknown` verdict rather than asserting the more precise `empty` a future fix could earn.

## Maturity caveats

Antigravity CLI is closed-source and self-updating; see `AGY_CLI_DISABLE_AUTO_UPDATE=true` in Operating facts above. There is no published numeric subscription quota in Antigravity's own public documentation; a real numeric quota IS available from the authenticated product itself (`agy -p "/usage"`, verified live), but `quota-axi`'s own `agy` probe is a loopback check expecting an already-running `agy` process and finds nothing against a one-shot call - wiring that surface is separate, later work. A live agy process sets `ANTIGRAVITY_LS_ADDRESS=localhost:<port>` for its own child/tool processes, naming a local loopback address plausibly usable by that same probe, worth investigating first rather than assuming a new mechanism is needed.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no agy protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
