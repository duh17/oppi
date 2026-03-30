# Oppi Inline Rendering Showcase

Everything below renders natively — no WebViews, no JavaScript, pure CoreGraphics.

---

## Text & Formatting

**Bold**, *italic*, ~~strikethrough~~, `inline code`, and [links](https://example.com).

- Bullet list item
- Another item
  - Nested item

1. Numbered list
2. Second item

> Blockquote: the best code is no code at all.

---

## Code Block (syntax highlighted)

```swift
struct ContentView: View {
    @State private var count = 0
    
    var body: some View {
        Button("Tapped \(count) times") {
            count += 1
        }
    }
}
```

```typescript
async function streamTokens(model: string): Promise<void> {
    const response = await fetch("/api/chat", {
        method: "POST",
        body: JSON.stringify({ model, stream: true }),
    });
    for await (const chunk of response.body!) {
        process.stdout.write(new TextDecoder().decode(chunk));
    }
}
```

---

## Table

| Feature | Status | Notes |
|---------|--------|-------|
| Mermaid flowchart | Done | All directions: TD, LR, BT, RL |
| Mermaid sequence | Done | Participants, async arrows, notes |
| Mermaid gantt | Done | Sections, task states, dependencies |
| Mermaid mindmap | Done | Nested nodes, auto-layout |
| LaTeX math | Done | Block rendering via CoreGraphics |
| Inline images | Done | Remote URLs + workspace relative paths |
| Tables | Done | Headers, alignment, inline formatting |

---

## Mermaid Flowchart

```mermaid
graph TD
    A[User Input] --> B{Parse Markdown}
    B --> C[Text Segment]
    B --> D[Code Block]
    B --> E[Mermaid Diagram]
    B --> F[LaTeX Block]
    B --> G[Image]
    E --> H[CoreGraphics Render]
    F --> H
    H --> I[UIImage]
    I --> J[Display Inline]
```

## Mermaid Sequence Diagram

```mermaid
sequenceDiagram
    participant U as User
    participant A as App
    participant S as Server
    participant L as LLM
    U->>A: Send message
    A->>S: WebSocket
    S->>L: Stream request
    L-->>S: Token chunks
    S-->>A: SSE events
    A-->>U: Render inline
```

## Mermaid Gantt Chart

```mermaid
gantt
    title Sprint Plan
    dateFormat YYYY-MM-DD
    section Backend
    API endpoints    :done, a1, 2026-03-25, 3d
    Database schema  :done, a2, after a1, 2d
    section Frontend
    UI components    :active, b1, 2026-03-28, 4d
    Integration      :b2, after b1, 3d
    section QA
    Testing          :c1, after b2, 2d
    Release          :milestone, after c1, 0d
```

## Mermaid Mindmap

```mermaid
mindmap
    root((Rendering))
        Mermaid
            Flowchart
            Sequence
            Gantt
            Mindmap
        LaTeX
            Block formulas
            Symbols
        Images
            Remote URL
            Workspace relative
        Text
            Bold / Italic
            Code spans
            Links
```

---

## LaTeX Math

```latex
\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}
```

```math
x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}
```

```tex
\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}
```

---

## Remote Image (HTTPS)

![Oppi architecture](https://raw.githubusercontent.com/nicklockwood/SwiftFormat/main/EditorExtension/Assets.xcassets/AppIcon.appiconset/icon_128x128.png)

## Workspace Relative Image

![Social export example](images/share-export/social-simple.png)

![Mermaid export](images/share-export/social-mermaid.png)

---

## Horizontal Rule

Above and below this line.

---

*End of showcase. All rendered natively via CoreGraphics — 5-15ms per diagram on a background thread.*
