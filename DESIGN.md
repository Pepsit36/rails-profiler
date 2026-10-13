# Thermal - Design System

The design system of the Rails Profiler's dashboard and toolbar. "Thermal" is the name its own
stylesheets give it: amber accents, inspired by heat-map instruments, on a deep obsidian (dark)
or warm stone (light) surface. A profiler should feel like a precision diagnostic tool.

Everything below is defined in `app/assets/stylesheets/profiler/`, mostly in `_variables.scss`,
and compiled into `app/assets/builds/profiler.css` (see [ARCHITECTURE.md](ARCHITECTURE.md#6-frontend-assets)).
The screenshots in [docs/screenshots/](docs/screenshots/) show the light theme.

## Design Philosophy

1. **Precision**: dense, compact type and spacing; a devtool shows a lot at once
2. **Visual hierarchy**: one accent color (amber) for what is interactive or current, semantic
   colors for status only
3. **Thermal metaphor**: warmer means hotter; slow queries, errors and warnings stand out by color
   before they are read
4. **Two themes, one identity**: the dark and light themes share every token name and differ only
   in values

## Visual Identity

### Typography

- **UI**: Outfit (`--profiler-font-sans`), falling back to the system UI fonts
- **Code and data**: JetBrains Mono (`--profiler-font-mono`), falling back to SF Mono, Fira Code,
  Cascadia Code

Both are loaded from Google Fonts by `_variables.scss`; without network access the fallbacks
apply. The scale is compact on purpose: `--profiler-text-xs` (10px) to `--profiler-text-3xl`
(28px), with 13px as the base size.

### Themes

The dark theme is the default (`:root` and `[data-theme="dark"]`); the light theme applies with
`[data-theme="light"]`, or when the system prefers light and no theme was chosen
(`@media (prefers-color-scheme: light)` on `:root:not([data-theme])`). The theme toggle of the
dashboard (`theme.ts`) and the toolbar keep the choice in `localStorage` (`profiler-theme`:
`light`, `dark` or `auto`).

| Token | Dark | Light | Used for |
|---|---|---|---|
| `--profiler-bg` | `#080b10` | `#f5f3ef` | Page background |
| `--profiler-bg-light` | `#0d1117` | `#edeae3` | Panels |
| `--profiler-bg-lighter` | `#131920` | `#e3ded5` | Cards, inputs |
| `--profiler-bg-elevated` | `#1a2030` | `#ffffff` | Raised surfaces |
| `--profiler-text` | `#eef2f7` | `#1c1410` | Body text |
| `--profiler-text-muted` | `#5e7080` | `#8a7a6e` | Labels, secondary data |
| `--profiler-accent` | `#f59e0b` | `#b45309` | Links, active tab, focus, primary buttons |
| `--profiler-success` | `#22c55e` | `#15803d` | 2xx, fast, passed, cache hit |
| `--profiler-warning` | `#fb923c` | `#c2410c` | 3xx, slower, warnings |
| `--profiler-error` | `#f87171` | `#dc2626` | 4xx and 5xx, slow, errors, N+1 |
| `--profiler-info` | `#60a5fa` | `#1d4ed8` | Informative badges |

Each semantic color has a `-bg` variant (about 10% opacity in dark, 8% in light) for badge and
banner backgrounds, and a `-glow` variant for hover glows. Borders (`--profiler-border`,
`--profiler-border-strong`, `--profiler-border-accent`), shadows (`--profiler-shadow-sm` to
`-xl`) and the terminal colors of the test runner output (`--profiler-terminal-*`, `--ansi-*`)
follow the same pattern.

### Shared tokens

- **Spacing**: a 4px grid, `--profiler-space-1` (4px) to `--profiler-space-12` (48px)
- **Radius**: `--profiler-radius-sm` (4px), `-md` (6px), `-lg` (10px), `-full`
- **Transitions**: `--profiler-transition-fast` (120ms), `-base` (220ms), `-slow` (350ms), all
  `cubic-bezier(0.4, 0, 0.2, 1)`, and `-elastic` (500ms, `cubic-bezier(0.34, 1.56, 0.64, 1)`)
- **Glass**: `--profiler-glass-bg`, `--profiler-glass-border` and `--profiler-blur`
  (`backdrop-filter`) for the toolbar and its panels
- **Stacking**: `--profiler-z-toolbar`, `--profiler-z-panel`, `--profiler-z-modal`, high enough to
  sit above the host page

Older SCSS variables (`$accent-cyan`, `$accent-mint`, `$accent-orange`, `$accent-purple`) are kept
as aliases of the tokens above so that every partial still compiles; new code uses the CSS
custom properties.

## Components

### Toolbar

`_toolbar.scss`, rendered by `components/toolbar/`:
- A fixed bar at the bottom of the host page, sliding in on load, collapsible to a small tab at
  the right (Alt+P or the arrow), the state kept in `localStorage`
- One compact item per collector, colored by status, each with a panel on hover
- The toolbar injector inlines its styles, scoped under `#profiler-toolbar`, so that they neither
  depend on nor leak into the host page's CSS

### Dashboard pages

`_base.scss`, `_components.scss`, `_profiles.scss`, `_dashboard.scss`:
- A header with the page title in the accent color, then one panel holding the tabs
- Tabs: plain text, the active one underlined in the accent color
- Tables with a tinted header row and sortable columns (⇅)
- Cards for queries, requests, mails and jobs (`.profiler-query-card`, `.profiler-ajax-card`),
  with a colored left border for their status
- Badges for methods, statuses and durations (`.badge-success`, `.badge-warning`, `.badge-error`,
  `.badge-info`, `.badge-default`)
- Buttons: `.btn` with `.btn-primary`, `.btn-secondary`, `.btn-danger`, `.btn-sm`, and the
  smaller `.profiler-btn`

### Timeline and flame graph

`_flamegraph.scss` (canvas flame graphs of the Timeline tab) and `_timeline.scss` (the older SVG
timeline). Event categories have fixed colors, shown in the legend of the Timeline tab:
controller, view, partial, SQL, cache, HTTP, custom events and Ruby methods.

### AJAX

`_ajax.scss`: the cards of the AJAX tab and of the toolbar's XHR panel.

## Utility classes

- `.animate-fade-in`, `.animate-fade-in-up`: entry animations
- `.loading-spinner`: animated loading spinner
- `.card`: a standard card
- `.profiler-flex`, `.profiler-grid`, `.profiler-mb-*`, `.profiler-mt-*`, `.profiler-text--*`:
  layout and text helpers used by the components

### Responsive breakpoint

One breakpoint, at 768px (`_base.scss`): below it, layouts stack and tables scroll.

## Accessibility

- Visible focus rings (`:focus-visible`) in the accent color
- Status is never shown by color alone: badges and items carry a number, a label or an icon
- Both themes are designed for contrast on their own background

Not done yet: reduced motion (`prefers-reduced-motion` is not honored by the animations), and a
systematic contrast check of every token pair.

## Best Practices

1. **Use the tokens**, never raw colors, so that both themes stay right
2. **Animate sparingly**: entry and hover only, with the transition tokens
3. **Keep the 4px rhythm** of the spacing tokens
4. **Check both themes**: the light theme is what the documentation screenshots show, the dark
   theme is the default
5. **CSS before JavaScript** for transitions and states

## File Structure

```
app/assets/stylesheets/profiler/
├── main.scss          # Entry point: @use of every partial below, in this order
├── _variables.scss    # Tokens of both themes, shared tokens, SCSS aliases, theme toggle
├── _base.scss         # Global styles, buttons, badges, utilities, animations
├── _components.scss   # Layout helpers, panels, stat and query cards, alerts, badges, modals
├── _toolbar.scss      # Bottom toolbar and its panels
├── _profiles.scss     # Profile list and detail pages
├── _timeline.scss     # SVG timeline
├── _flamegraph.scss   # Flame graphs of the Timeline tab
├── _syntax.scss       # Code syntax highlighting
├── _dashboard.scss    # Dashboard tabs
└── _ajax.scss         # AJAX request cards
```

## The browser extension (separate repository)

The Chrome DevTools extension of the profiler uses the same Thermal design system, with its own
copy of the tokens. Its code is **not in this repository**: it lives in the
`rails-profiler-extension` repository (`reference/rails-profiler-extension` on the swarm hub), in
`src/devtools/` (`panel.html`, `panel.css`, `panel.ts`). The panel is a split view, the list of
the inspected page's requests on one side and the profile of the selected one on the other, shown
in an iframe of the dashboard's embedded layout (`/_profiler/profiles/:token?embed=true`, see
`app/views/layouts/profiler/embedded.html.erb` here). Its own documentation is in that
repository's README.

## Future Enhancements

Potential additions to consider:

- [ ] Sparkline graphs for metrics trends
- [ ] Honor `prefers-reduced-motion`
- [ ] Keyboard shortcuts overlay (Alt+P, which toggles the toolbar, is the only shortcut today
      besides Ctrl+F in the flame graph)
- [ ] Waterfall view of a page and its AJAX requests

Shipped since this list was first written: the dark and light themes with their toggle, flame
graphs, and the waterfall of outbound HTTP calls.
