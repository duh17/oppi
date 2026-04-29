# Session tree and fork semantics

Oppi intentionally keeps two tree concepts separate.

## Pi entry tree

Pi's `/tree` UI and `AgentSession.navigateTree()` move the current leaf inside a single Pi session file. Navigating the entry tree does not create a new Oppi session or a new Pi session file. When the selected entry is a user message, Pi moves the leaf to that entry's parent and returns the selected user text as `editorText` so the client can prefill the composer.

Oppi exposes this through `get_session_tree` and `navigate_tree`. After `navigate_tree`, the server refreshes Pi state and the Apple client reloads timeline history for the same Oppi session.

## Timeline fork

Pi `fork()` creates a new Pi session file containing the selected branch/path. Pi records file-level ancestry in the new JSONL header as `parentSession`, pointing to the previous Pi session file.

Oppi maps timeline forks to independent root sessions. The REST fork route creates a new Oppi `Session`, points it at the source Pi trace, starts it, and then runs Pi `fork`. It must not copy the source session's `parentSessionId` and must not set `parentSessionId` on the forked session.

## Oppi parent/child session tree

`Session.parentSessionId` is reserved for spawned subagent sessions created by `spawn_agent` without `detached: true`. Those sessions appear under the parent session in the Apple UI and receive parent-stream lifecycle broadcasts.

Detached sessions and timeline forks are independent root sessions in the workspace list.
