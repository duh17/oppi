# Session tree and fork semantics

Oppi uses Pi's in-file tree navigation. It treats timeline forks as separate sessions.

## Pi entry tree

Pi's `/tree` UI and `AgentSession.navigateTree()` move the current leaf within one Pi session file. Entry-tree navigation creates neither an Oppi session nor a Pi session file. When the selected entry is a user message, Pi moves the leaf to that entry's parent and returns the selected user text as `editorText`, which lets the client prefill the composer.

Oppi exposes this through `get_session_tree` and `navigate_tree`. After `navigate_tree`, the server refreshes Pi state, and the Apple client reloads timeline history for the same Oppi session.

## Timeline fork

Pi `fork()` creates a Pi session file for the selected branch or path. In the new JSONL header, Pi records file-level ancestry as `parentSession`, which points to the previous Pi session file.

Oppi maps timeline forks to independent sessions. The REST fork route creates a new Oppi `Session`, points it at the source Pi trace, starts it, then runs Pi `fork`.
