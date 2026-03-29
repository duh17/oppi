# Inline Rendering Test

This file validates inline mermaid diagrams and images in the chat timeline.

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

### Using mmd alias

```mmd
graph LR
    A --> B --> C
```

## Images

### Online URL (https)

![Placeholder image](https://picsum.photos/300/200)

### Online URL (http)

![HTTP test](http://via.placeholder.com/200x100.png)

### Relative path (workspace file)

![Screenshot](screenshots/example.png)

### Mixed content (image in paragraph - should NOT render as image)

Check out this diagram: ![inline](https://picsum.photos/50/50) pretty cool right?

## Regular Code Blocks (should NOT render as diagrams)

```python
def hello():
    print("This is python, not mermaid")
```

```swift
let x = 42
print("Swift code block")
```

## Edge Cases

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
