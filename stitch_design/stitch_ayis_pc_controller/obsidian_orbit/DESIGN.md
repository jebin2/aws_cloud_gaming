---
name: Obsidian Orbit
colors:
  surface: '#10141a'
  surface-dim: '#10141a'
  surface-bright: '#353940'
  surface-container-lowest: '#0a0e14'
  surface-container-low: '#181c22'
  surface-container: '#1c2026'
  surface-container-high: '#262a31'
  surface-container-highest: '#31353c'
  on-surface: '#dfe2eb'
  on-surface-variant: '#bbcabf'
  inverse-surface: '#dfe2eb'
  inverse-on-surface: '#2d3137'
  outline: '#86948a'
  outline-variant: '#3c4a42'
  surface-tint: '#4edea3'
  primary: '#4edea3'
  on-primary: '#003824'
  primary-container: '#10b981'
  on-primary-container: '#00422b'
  inverse-primary: '#006c49'
  secondary: '#7bd0ff'
  on-secondary: '#00354a'
  secondary-container: '#00a6e0'
  on-secondary-container: '#00374d'
  tertiary: '#ffb95f'
  on-tertiary: '#472a00'
  tertiary-container: '#e29100'
  on-tertiary-container: '#523200'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#6ffbbe'
  primary-fixed-dim: '#4edea3'
  on-primary-fixed: '#002113'
  on-primary-fixed-variant: '#005236'
  secondary-fixed: '#c4e7ff'
  secondary-fixed-dim: '#7bd0ff'
  on-secondary-fixed: '#001e2c'
  on-secondary-fixed-variant: '#004c69'
  tertiary-fixed: '#ffddb8'
  tertiary-fixed-dim: '#ffb95f'
  on-tertiary-fixed: '#2a1700'
  on-tertiary-fixed-variant: '#653e00'
  background: '#10141a'
  on-background: '#dfe2eb'
  surface-variant: '#31353c'
typography:
  headline-xl:
    fontFamily: Geist
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Geist
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
    letterSpacing: -0.015em
  headline-md:
    fontFamily: Geist
    fontSize: 18px
    fontWeight: '500'
    lineHeight: 26px
    letterSpacing: -0.01em
  body-lg:
    fontFamily: Geist
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-md:
    fontFamily: Geist
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  body-sm:
    fontFamily: Geist
    fontSize: 12px
    fontWeight: '400'
    lineHeight: 18px
  code-lg:
    fontFamily: JetBrains Mono
    fontSize: 15px
    fontWeight: '500'
    lineHeight: 22px
    letterSpacing: -0.01em
  code-md:
    fontFamily: JetBrains Mono
    fontSize: 13px
    fontWeight: '400'
    lineHeight: 18px
  code-sm:
    fontFamily: JetBrains Mono
    fontSize: 11px
    fontWeight: '400'
    lineHeight: 16px
  label-caps:
    fontFamily: JetBrains Mono
    fontSize: 11px
    fontWeight: '600'
    lineHeight: 14px
    letterSpacing: 0.06em
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  gutter: 1rem
  gutter-desktop: 1.5rem
  margin: 1.5rem
  margin-desktop: 2rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 1rem
  space-lg: 1.5rem
  space-xl: 2rem
---

## Brand & Style

This design system targets power users, systems engineers, and technical gamers who provision high-performance virtual workstations and cloud gaming rigs on AWS. The aesthetic is grounded in low-latency utility, surgical precision, and uncompromised clarity. It eliminates marketing fluff, ambient visual noise, and decorative illustrations in favor of an authoritative developer-grade console.

The visual style is **Precision Technical Minimalism**:
- **Utilitarian Discipline:** High density of actionable telemetry paired with strict negative space boundaries.
- **Instrumental Focus:** Flat, subtle dark surfaces overlaid with hair-thin 1px structural boundaries.
- **High Signal-to-Noise Ratio:** Neutral values handle 90% of the canvas; vivid chroma is reserved strictly for instance lifecycle states, cost meters, and execution triggers.
- **Physical Machine Analogy:** Interfaces mimic high-end hardware diagnostic monitors—calm, predictable, and mission-critical.

## Colors

The palette is engineered around dark slate and deep charcoal layers with high functional contrast. Color communicates state, urgency, and resource expenditure rather than brand decoration.

### Surface System
- **Base Canvas (`#0d1117`):** The foundational viewport substrate. Never overlaid directly with bright saturation.
- **Elevated Canvas (`#161b22`):** Primary card, sidebar, and container background.
- **Surface Active / Muted (`#21262d`):** Hover states, input backgrounds, active segmented pill tracks.
- **Borders & Dividers (`#30363d`):** Strict 1px delineations for panels, structural grids, and separator rules.
- **Border Focus (`#8b949e`):** Explicit keyboard and focus boundary states.

### Core Accents & Semantics
- **Primary Accent (`#10b981` - Tech Emerald):** The heartbeat of the system. Used strictly for "Instance Online", "Connect Parsec/Moonlight", active billing runs, and primary action buttons.
- **Secondary Accent (`#38bdf8` - Electric Cyan):** Networking metrics, throughput rates, active GPU telemetry (e.g., NVIDIA NVENC status), and informational badges.
- **Warning (`#f59e0b` - Telemetry Amber):** Auto-shutdown countdown timers, storage idle warnings, EBS snapshot pendings, and threshold alerts.
- **Destructive (`#ef4444` - Crimson):** Strictly quarantined for teardown, stack termination, disk destruction, and volume detachment. Never used as an ambient decorative red.

### Typography Contrast Tiers
- **Text Primary (`#f0f6fc`):** Crisp, high-contrast headings, metrics, and active values.
- **Text Secondary (`#8b949e`):** Structural labels, instance specifications, inactive telemetry.
- **Text Tertiary / Disabled (`#484f58`):** Code placeholders, disabled buttons, subtle grid coordinates.

## Typography

The typographic hierarchy implements an asymmetric dual-font structure:
1. **Geist** delivers crisp geometric neutral shapes for layout context, operational menus, and primary control labels.
2. **JetBrains Mono** powers all machine metadata, financial figures, EC2 types (`g4dn.xlarge`, `g5.2xlarge`), IPv4 addresses, ping counters, session duration clocks, and log readouts.

### Usage Standards
- Monospace figures must always use tabular alignment (`font-variant-numeric: tabular-nums`) to prevent jitter when timers and telemetry refresh.
- Section tags, sub-panel headings, and status labels use `label-caps` rendered in uppercase for industrial dashboard ergonomics.
- Monospace font weights do not exceed `500` (Medium) to preserve legibility on low-light displays.

## Layout & Spacing

The canvas is tailored for a high-density primary desktop viewport of 1440x900, scalable across wide external displays. The layout structure uses a fixed-pane utility model rather than an editorial fluid stack.

### Structural Framework
- **Shell Layout:** Fixed-width 240px command sidebar navigation + dynamic main stage pane (min 960px) + collapsible 320px telemetry & logs drawer.
- **Rhythm Base:** 8-point base grid system (`0.5rem` / `8px` quantum), supplemented with `4px` (`space-xs`) for micro-gap alignments between paired data keys and values.
- **Desktop Grid:** A 12-column modular content grid with `gutter-desktop` (24px) padding, anchored with a static canvas margin of `margin-desktop` (32px).
- **Responsive Handling:** When viewport drops below 1280px, the telemetry drawer shifts into an overlay layer. Below 1024px, the navigation collapses into an icon rail (64px width).

## Elevation & Depth

This system avoids blurred floating drop shadows, gradient scrims, and skeuomorphic bevels. Visual separation is accomplished purely through **tonal layering and hair-thin border enclosures**.

### Layer Hierarchy
1. **Base Layer (Level 0):** `#0d1117` — The outer frame and application viewport background.
2. **Container Layer (Level 1):** `#161b22` — Cards, instance tiles, terminal shells, and tables. Defined by a continuous `1px solid #30363d` stroke.
3. **Elevated Elements (Level 2):** `#21262d` — Tooltips, context menus, and select drop-down menus. Bounded by `1px solid #484f58` to ensure sharp visibility against Level 1.
4. **Overlay Shields (Level 3):** Modal dialogues sit over `#0d1117` at 80% opacity with backdrop filter `blur(4px)`. Modals use a `1px solid #30363d` border and a single directional ambient shadow: `0 16px 32px rgba(1, 4, 9, 0.85)`.

No glow filters or bloom effects are applied to active elements; status lights use a crisp dual-dot structure (solid indicator inside a low-opacity border halo).

## Shapes

The design uses tight, deliberate corner radiuses (`roundedness: 1`), imparting an engineered, calibrated feel.
- **Base Components (Inputs, Buttons, Badges):** `4px` (`0.25rem`). Ensures crisp pixel-grid snapping without jagged subpixel rendering.
- **Containers (Panels, Terminal Windows, Cards):** `6px` (`0.375rem`) outer border radius, nesting inner elements seamlessly with `4px` radiuses.
- **Terminal Display & Telemetry Chips:** `4px` maximum. Never use pill or circular forms for structural UI, except for 6px circular static indicator dots.

## Components

### Buttons
- **Primary Action (Start Machine / Connect):** Background `#10b981`, foreground `#0d1117`, font weight `500`. Hover state `#059669`. No shadow, no outline.
- **Secondary (Inspect, Settings):** Background `#21262d`, foreground `#f0f6fc`, border `1px solid #30363d`. Hover state `#30363d`.
- **Destructive (Teardown / Terminate):** Background `transparent`, foreground `#ef4444`, border `1px solid #ef4444`. Hover state: background `#ef4444` with foreground `#ffffff`.
- **Sizing:** Fixed heights (32px standard, 28px compact) with 12px horizontal padding. Monospaced indicators or icons placed inline are sized strictly to 14px.

### Badges & Telemetry Chips
- **Layout:** Monospaced label, `4px` border radius, padding `2px 8px`, border width `1px`.
- **Status Running:** Background `rgba(16, 185, 129, 0.1)`, text `#10b981`, border `rgba(16, 185, 129, 0.3)`. Features a 6px static dot indicator.
- **Status Stopped:** Background `rgba(139, 148, 158, 0.1)`, text `#8b949e`, border `rgba(139, 148, 158, 0.3)`.
- **Status Warning / Expiring:** Background `rgba(245, 158, 11, 0.1)`, text `#f59e0b`, border `rgba(245, 158, 11, 0.3)`.

### Form Inputs & Selectors
- **Fields:** Surface `#0d1117`, border `1px solid #30363d`, height 32px, text `body-md` in `#f0f6fc`.
- **Focus:** Border color changes to `#38bdf8`, with an instant 0-transition outline (no diffuse box-shadow).
- **Code Inputs (SSH Key, AMI ID):** JetBrains Mono `code-md`, uppercase where applicable, muted placeholder `#484f58`.

### Instance Cards
- **Architecture:** Surface `#161b22`, border `1px solid #30363d`. Header contains the instance friendly name, region flag (`us-east-1`), and active state badge.
- **Data Matrix:** Key-value layout rendered in two-column format. Keys in `label-caps` (`#8b949e`), values in `code-md` (`#f0f6fc`).
- **Footer Control Strip:** Separated by a `1px solid #30363d` divider, hosting the burn rate (e.g., `$0.72/hr`) alongside immediate action buttons.

### Live Telemetry Stream / Console Box
- **Container:** Dark well (`#0d1117`), inset border `1px solid #21262d`.
- **Text:** JetBrains Mono `code-sm`, line height 1.6, auto-scroll with subtle 4px scrollbars (`#30363d` thumb).
- **Log Categorization:** Timestamp in `#484f58`, level tags `[INFO]` in `#38bdf8`, `[WARN]` in `#f59e0b`, `[ERR]` in `#ef4444`.