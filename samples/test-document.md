# PicaMD Test Document

This document exercises every supported Markdown feature.

## Inline formatting

Plain text with **bold**, *italic*, ***bold italic***, ~~strikethrough~~, ==highlight==, and `inline code`. A [link to typora.io](https://typora.io) and an image: ![logo](logo.png).

Math inline: $E = mc^2$, and a fraction $\frac{a}{b}$.

## Headings

### Level 3
#### Level 4
##### Level 5
###### Level 6

## Lists

Unordered:
- First item
- Second item
  - Nested
  - Another nested
- Third item

Ordered:
1. Step one
2. Step two
3. Step three
Footnote

Tasks:
- [ ] Done thing — should be struck through and dimmed
- [ ] Open thing — should show empty box
- [ ] Another open thing
- [ ] Uppercase X also counts as checked
* [x] Star bullet works too
+ [ ] Plus bullet works too
  - [ ] Indented unchecked item
  - [x] Indented checked item

## Blockquote

> "The best way to predict the future is to invent it."
>
> — Alan Kay

## Code blocks

```swift
import SwiftUI

@main
struct PicaMDApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
```

```python
def fibonacci(n: int) -> list[int]:
    a, b = 0, 1
    out = []
    for _ in range(n):
        out.append(a)
        a, b = b, a + b
    return out
```

```bash
xcodebuild -project PicaMD.xcodeproj -scheme PicaMD build
codesign --force --sign - PicaMD.app
```

## GFM Tables

| Feature | Status | Notes |
|:--------|:------:|------:|
| Headings | done | H1-H6 |
| Bold/Italic | done | **bold**, *italic* |
| Tables | done | with alignment |
| Math | partial | inline only |
| Mermaid | planned | v2 |

## Math block

$$
\int_0^\infty e^{-x^2} dx = \frac{\sqrt{\pi}}{2}
$$

## Horizontal rule

---

## HTML passthrough

<details>
<summary>Click to expand</summary>

This is hidden by default. Press <kbd>Space</kbd>  to toggle.
nd welchen usp haben wiroch örtw
</details>

## Footnote

Here is a footnote reference[^1].

[^1]: This is the footnote content.