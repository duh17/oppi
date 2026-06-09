# Session tree and fork semantics

Oppi uses Pi's in-file tree navigation and treats timeline forks as separate sessions.

## Pi entry tree

Pi's `/tree` UI and `AgentSession.navigateTree()` move the current leaf inside a single Pi session file. Navigating the entry tree does not create a new Oppi session or a new Pi session file. When the selected entry is a user message, Pi moves the leaf to that entry's parent and returns the selected user text as `editorText` so the client can prefill the composer.

Oppi exposes this through `get_session_tree` and `navigate_tree`. After `navigate_tree`, the server refreshes Pi state and the Apple client reloads timeline history for the same Oppi session.

## Timeline fork

Pi `fork()` creates a new Pi session file containing the selected branch/path. Pi records file-level ancestry in the new JSONL header as `parentSession`, pointing to the previous Pi session file.

Oppi maps timeline forks to independent sessions. The REST fork route creates a new Oppi `Session`, points it at the source Pi trace, starts it, and then runs Pi `fork`.
