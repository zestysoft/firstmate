# Live validation evidence: stranded Codex doorbell fix (fm/codex-handoff-investigation)

All transcripts were produced by driving the REAL firstmate scripts and libraries
(bin/fm-task-inbox-lib.sh, bin/fm-watch.sh, bin/fm-send.sh, bin/backends/herdr.sh)
against real tmux 3.7c servers on private sockets and real, isolated herdr 0.9.0 lab
sessions (bin/fm-herdr-lab.sh). Real codex-cli 0.155.1 was used for the handoff
scenarios; a stand-in worker TUI (rig/swallow-tui.py) that swallows Enter and logs
every keystroke it receives was used where a real harness cannot be forced to swallow
an Enter. Codex ran with a temporary CODEX_HOME so the operator's ~/.codex was never
modified.

| File | Scenario |
|---|---|
| tmux-stranded-ring.transcript.txt | Swallowed Enter on tmux: ring reports 4, next ring 1, pane bytes unchanged, zero keys sent, no clear/cancel keys ever |
| tmux-stranded-ring-before-fix.transcript.txt | Same rig on the BASE commit's bin/ tree: the defect reproduces (rc 0 with a stranded line, then rc 1 forever) |
| tmux-watcher-escalation.transcript.txt | Real fm-watch.sh: budget spent on a stranded line escalates once as "input line holds unsubmitted text ... the worker is not the blocker", names bin/fm-send.sh, promises no further ring, then reads quiet |
| tmux-fm-send.transcript.txt | Real fm-send.sh: rc=4 stranded-line notice on the first steer, rc=1 skipped notice on the second, both exit 0 with durable records |
| tmux-codex-handoff.transcript.txt, tmux-codex-handoff.final-screen.txt | Real Codex in tmux steered through real fm-send.sh: doorbell lands (no notice), composer clears, Codex acts and moves the record to handled/ |
| tmux-codex-live-doorbell-e2e.transcript.txt | The repo's own live doorbell e2e for codex: blocked by Codex's folder-trust dialog in this untrusted worktree (environment limitation; superseded by tmux-codex-handoff) |
| herdr-codex-proof.transcript.txt, herdr-codex-proof.final-screen.txt | Real Codex on an isolated herdr pane: no-agent pane -> proof 1; settled idle pane -> proof 0; real ring rc 0; native status `working` right after the submit -> proof 1 (Enter landed, not stranded); Codex acts and acks; idle again -> proof 0 |
| herdr-status-timeline.transcript.txt | 60 samples over 42s of an idle Codex pane on herdr: native status idle and proof 0 at every sample (the adapter_status_raw column errored because that helper is lazily sourced; ignore that column) |
| herdr-stranded-ring.transcript.txt | Real herdr pane registered idle via `pane report-agent` with the Enter-swallowing worker: ring 4, next ring 1, no keys; re-registered `blocked` (Cursor-shaped): the same swallowed submit stays advisory (0) |
| unit-fm-task-inbox.test.log | tests/fm-task-inbox.test.sh on the target commit (all ok) |
| rig/ | The scripts that produced the transcripts |
