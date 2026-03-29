# Inline Rendering Test

Validates inline mermaid diagrams and images in the chat timeline.

## Mermaid Diagrams

### Flowchart

```mermaid
graph TD
    A[Start] --> B{Decision}
    B -->|Yes| C[Do thing]
    B -->|No| D[Skip]
    C --> E[End]
    D --> E
```

### Sequence Diagram

```mermaid
sequenceDiagram
    participant Client
    participant Server
    Client->>Server: Request
    Server-->>Client: Response
```

### Gantt Chart

```mermaid
gantt
    title Project Timeline
    dateFormat YYYY-MM-DD
    section Phase 1
    Design    :2024-01-01, 30d
    Implement :2024-02-01, 45d
    section Phase 2
    Test      :2024-03-15, 20d
    Deploy    :2024-04-05, 5d
```

### Mindmap

```mermaid
mindmap
  root((Project))
    Frontend
      React
      TypeScript
    Backend
      Go
      PostgreSQL
    Infra
      Docker
      K8s
```

### mmd alias

```mmd
graph LR
    A --> B --> C
```

## Online Images

### GitHub avatar (https, PNG, always up)

![GitHub user 1](https://avatars.githubusercontent.com/u/1?v=4)

### Wikipedia image (https, JPEG)

![Wikipedia globe](https://upload.wikimedia.org/wikipedia/commons/thumb/8/80/Wikipedia-logo-v2.svg/200px-Wikipedia-logo-v2.svg.png)

### Picsum photo (https, redirect)

![Random photo](https://picsum.photos/id/237/300/200)

## Edge Cases

### Mixed paragraph (should NOT render as standalone image)

Check this out: ![tiny](https://avatars.githubusercontent.com/u/2?v=4&s=32) inline with text.

### Regular code blocks (not mermaid)

```python
def hello():
    print("This is python, not mermaid")
```

### Empty mermaid block

```mermaid
```

### Unsupported diagram type

```mermaid
journey
    title My working day
    section Go to work
      Make tea: 5: Me
```
