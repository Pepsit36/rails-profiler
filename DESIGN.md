# Performance Dashboard Luxe - Design System

A distinctive, production-grade design system for the Rails Profiler, inspired by high-performance monitoring dashboards and premium developer tools.

## Design Philosophy

### Core Principles

1. **Luxe Technical Precision** - Every element conveys expertise and attention to detail
2. **Visual Hierarchy** - Clear information architecture with intentional use of color and space
3. **Performance Aesthetics** - Design that reinforces the tool's purpose
4. **Memorable Distinctiveness** - Avoiding generic "AI slop" aesthetics

## Visual Identity

### Typography

- **Display & UI**: DM Sans - Modern, geometric, highly readable
- **Code & Data**: JetBrains Mono - Distinctive monospace with excellent legibility

### Color Palette

The palette departs from typical developer tool colors (no generic blues or purple gradients):

#### Primary Accents
- **Cyan Electric** (#00d9ff) - Primary accent, navigation, interactive elements
- **Mint Green** (#00ff9f) - Success states, positive metrics
- **Amber Orange** (#ff6b35) - Warnings, highlights
- **Purple Luxe** (#bd93f9) - Alternative accent

#### Backgrounds
- **Deep Noir** (#0a0e14) - Base background
- **Slate Dark** (#15191f) - Elevated surfaces
- **Charcoal** (#1f2329) - Panels and cards

#### Status Colors
- **Success**: #00ff9f with 10% opacity background
- **Warning**: #ffb86c with 10% opacity background
- **Error**: #ff6b6b with 10% opacity background
- **Info**: #00d9ff with 10% opacity background

### Visual Effects

#### Glass-morphism
All panels and cards use:
- `backdrop-filter: blur(12px) saturate(180%)`
- Semi-transparent backgrounds
- Subtle borders with glow effects

#### Glow Effects
Interactive elements feature sophisticated glow on hover:
- Cyan glow: `0 0 20px rgba(0, 217, 255, 0.4)`
- Mint glow: `0 0 20px rgba(0, 255, 159, 0.4)`
- Orange glow: `0 0 20px rgba(255, 107, 53, 0.4)`

#### Animations
All animations use custom cubic-bezier curves:
- **Fast**: 150ms cubic-bezier(0.4, 0, 0.2, 1)
- **Base**: 250ms cubic-bezier(0.4, 0, 0.2, 1)
- **Slow**: 350ms cubic-bezier(0.4, 0, 0.2, 1)
- **Elastic**: 500ms cubic-bezier(0.68, -0.55, 0.265, 1.55)

## Components

### Toolbar

The profiling toolbar features:
- Slide-in animation on load
- Floating glass-morphism cards for each metric
- Hover-triggered panels with detailed information
- Responsive overflow handling with custom scrollbar

**Key Features**:
- Backdrop blur for depth
- Gradient borders on hover
- Staggered entry animations
- Glow effects on status indicators

### Profile Pages

#### Tabs Navigation
- Pill-style tabs with glass background
- Active state with gradient background and glow
- Smooth underline indicator
- Horizontal scroll on mobile

#### Content Cards
- Asymmetric layouts to avoid monotony
- Hover effects with translateY and shadow depth
- Inline code with cyan accent background
- Tables with zebra striping and hover states

### Timeline Visualization

Advanced SVG-based timeline with:
- Color-coded event bars
- Animated entry (bars slide in sequentially)
- Hover effects with glow and scale
- Interactive legend
- Metric cards grid

**Event Colors**:
- Controller actions: Cyan Electric
- Views: Mint Green
- Partials: Amber Orange
- Database: Warning Yellow
- Default: Purple Luxe

### Chrome Extension Panel

Split-pane interface with:
- Animated requests list with staggered loading
- Gradient selection state
- Method badges with appropriate colors
- Empty states with floating icon animations
- Ambient background glow animation

## Customization

### CSS Variables

All colors and effects are customizable via CSS variables in `_variables.scss`:

```scss
:root {
  --profiler-accent-cyan: #00d9ff;
  --profiler-accent-mint: #00ff9f;
  --profiler-accent-orange: #ff6b35;
  // ... more variables
}
```

### Component Classes

Utility classes available:

- `.animate-fade-in` - Fade in animation
- `.animate-fade-in-up` - Fade in with upward movement
- `.animate-slide-in` - Slide in from left
- `.animate-pulse` - Pulsing opacity
- `.loading-spinner` - Animated loading spinner
- `.card` - Standard card with glass-morphism
- `.btn` - Button with variants (primary, secondary, success, error)

### Responsive Breakpoints

- Desktop: > 1200px
- Tablet: 769px - 1200px
- Mobile: < 768px

## Accessibility

- Focus states with visible outlines
- Sufficient color contrast (WCAG AA)
- Keyboard navigation support
- Reduced motion respected via `prefers-reduced-motion`
- Semantic HTML throughout

## Best Practices

1. **Always use semantic HTML** - Proper heading hierarchy, nav elements, etc.
2. **Leverage animations sparingly** - High-impact moments only
3. **Maintain visual rhythm** - Consistent spacing using 4px/8px grid
4. **Test in dark mode** - Primary design target
5. **Performance first** - Use CSS transitions over JavaScript animations

## File Structure

```
profiler-gem/app/assets/stylesheets/profiler/
├── _variables.scss      # Color palette, typography, transitions
├── _base.scss          # Global styles, reset, utilities
├── _toolbar.scss       # Bottom toolbar styles
├── _profiles.scss      # Profile list and detail pages
├── _timeline.scss      # Timeline visualization
├── _syntax.scss        # Code syntax highlighting
├── _dashboard.scss     # Dashboard page
├── _ajax.scss          # AJAX request styles
└── main.scss           # Main entry point (imports all)
```

```
chrome-extension/src/devtools/
├── panel.html          # Extension panel HTML
├── panel.css           # Extension panel styles
└── panel.ts            # Extension panel logic
```

## Future Enhancements

Potential additions to consider:

- [ ] Sparkline graphs for metrics trends
- [ ] Dark/light theme toggle
- [ ] Custom cursor on interactive elements
- [ ] Noise texture overlays for depth
- [ ] Advanced data visualization (flame graphs, waterfall charts)
- [ ] Real-time performance monitoring
- [ ] Keyboard shortcuts overlay
- [ ] Export/share functionality with branded design

---

**Design by**: Performance Dashboard Luxe System
**Version**: 1.0.0
**Last Updated**: 2026-01-28
