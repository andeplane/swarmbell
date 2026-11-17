---
name: Swarmbell Website
description: A warm editorial home for a quiet local agent monitor.
colors:
  paper: "#f6f5ee"
  ink: "#232c25"
  muted: "#62685e"
  accent: "#80601f"
  bell-honey: "#f4cb62"
  bell-forest: "#24362f"
  line: "#d8dacd"
  soft: "#eaecdf"
  white: "#fffefa"
  dark: "#253129"
typography:
  display:
    fontFamily: "DM Sans, sans-serif"
    fontSize: "clamp(58px, 7.4vw, 96px)"
    fontWeight: 600
    lineHeight: 1.05
    letterSpacing: "-0.04em"
  emphasis:
    fontFamily: "Fraunces, Georgia, serif"
    fontWeight: 500
    letterSpacing: "-0.04em"
  headline:
    fontFamily: "DM Sans, sans-serif"
    fontSize: "60px"
    fontWeight: 500
    lineHeight: 1.06
    letterSpacing: "-0.035em"
  section:
    fontFamily: "DM Sans, sans-serif"
    fontSize: "46px"
    fontWeight: 500
    lineHeight: 1.1
    letterSpacing: "-0.035em"
  title:
    fontFamily: "DM Sans, sans-serif"
    fontSize: "24px"
    fontWeight: 500
    lineHeight: 1.25
    letterSpacing: "-0.025em"
  body:
    fontFamily: "DM Sans, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.75
  hero-body:
    fontFamily: "DM Sans, sans-serif"
    fontSize: "20px"
    fontWeight: 400
    lineHeight: 1.6
  label:
    fontFamily: "DM Sans, sans-serif"
    fontSize: "12px"
    fontWeight: 400
  action:
    fontFamily: "DM Sans, sans-serif"
    fontSize: "15px"
    fontWeight: 600
rounded:
  compact: "6px"
  button: "8px"
  surface: "14px"
spacing:
  compact: "8px"
  control-gap: "12px"
  control: "16px"
  content: "24px"
  section-gap: "40px"
components:
  button-primary:
    backgroundColor: "{colors.dark}"
    textColor: "{colors.white}"
    typography: "{typography.action}"
    rounded: "{rounded.button}"
    padding: "16px 23px"
  button-text:
    textColor: "{colors.ink}"
    typography: "{typography.body}"
  button-review:
    backgroundColor: "#e8d39d"
    textColor: "#493813"
    rounded: "{rounded.compact}"
    padding: "10px 14px"
  tab-selected:
    backgroundColor: "#d8dfc9"
    textColor: "#2d402c"
    rounded: "{rounded.compact}"
    padding: "10px 13px"
  attention-badge:
    backgroundColor: "#efe1bb"
    textColor: "#775519"
    padding: "2px 5px"
  agent-row:
    textColor: "{colors.ink}"
    padding: "12px 0"
  input-search:
    backgroundColor: "#f8f9f2"
    textColor: "{colors.ink}"
    rounded: "{rounded.compact}"
    padding: "10px 13px"
    height: "48px"
  navigation:
    textColor: "{colors.ink}"
  demo-surface:
    backgroundColor: "{colors.soft}"
    rounded: "{rounded.surface}"
  quick-switcher:
    backgroundColor: "{colors.white}"
    textColor: "{colors.ink}"
    rounded: "{rounded.surface}"
    padding: "22px"
---

# Design System: Swarmbell Website

## Overview

**Creative North Star: "A little less checking"**

Swarmbell’s website makes a quiet local utility feel warm and approachable. Warm paper, forest text, a honey-colored bell, generous whitespace, and italic serif emphasis carry the public reference direction the user chose and approved. This is the website’s visual system; the native app’s separate design record does not govern these surfaces.

The typography does most of the expressive work. Large centered statements introduce the product, while the interactive preview becomes deliberately denser and more operational. Muted olive layers keep that change in density connected to the surrounding editorial page.

**Key Characteristics:**
- Warm paper and forest text with restrained honey emphasis.
- DM Sans structure paired with expressive italic Fraunces.
- Generous editorial space around a compact, working product preview.
- Quiet borders, soft corners, and diffuse depth at the demo and dialog.

## Colors

The palette combines warm ivory with forest and olive neutrals; the bell’s honey color and darker ochre give emphasis a small, useful presence. The frontmatter is the canonical value record and retains the stylesheet’s token names.

### Primary
- **Ochre emphasis (`accent`)** colors serif phrases, the wordmark dot, feature icons, and selected attention cues.
- **Honey bell (`bell-honey`)** is the authored mark’s warmer identity accent.

### Neutral
- **Warm paper (`paper`)** is the page canvas.
- **Forest ink (`ink`)** carries ordinary text and strong separators.
- **Quiet olive (`muted`)** carries supporting explanations and release metadata.
- **Olive line (`line`)** separates FAQs, installation notes, and data groups.
- **Soft olive (`soft`)** grounds the demo shell.
- **Warm white (`white`)** makes the operational workspace and modal readable.
- **Deep forest (`dark`)** gives the primary download action its weight.
- **Bell forest (`bell-forest`)** is the authored identity mark’s stroke and dot color; preserve the SVG’s own palette.

**The The Quiet Accent Rule Rule.** Use honey and ochre for emphasis and attention; keep ordinary text in forest and supporting text in muted neutrals.

## Typography

**Display and Body Font:** self-hosted DM Sans, with sans-serif fallback. The source provides regular, medium, semibold, and bold weights.
**Expressive Font:** self-hosted Fraunces italic, with Georgia and serif fallbacks, at medium weight.

**Character:** the sans-serif is direct and friendly; italic Fraunces lends an editorial, conversational inflection. Emphasis inherits its surrounding size rather than introducing another unrelated scale.

### Hierarchy
- **Display:** the fluid hero role in frontmatter; the italic line has extra leading (1.18). At the phone breakpoint it uses a smaller fluid range (`clamp(45px, 8.9vw, 65px)`), then a fixed narrow-phone size (43px).
- **Headline:** large explanatory and local statements; tablet size (52px), phone size (46px). The closing statement uses slightly looser leading (1.1) and falls to 43px, then 39px.
- **Section:** demo introduction, reducing to 41px on tablets and 39px on phones, then 36px on narrow phones.
- **Title:** compact preview heading, reducing to 22px and 21px, then 18px on narrow phones.
- **Body:** feature explanations use the frontmatter body role; hero support uses the larger hero-body role. FAQ answers use readable leading (1.8) and a maximum measure (65ch).
- **Label / action:** supporting metadata uses the label role; primary actions use the action role. Phone preview metadata is raised to 12px by the final responsive corrections. Numeric statistics use tabular figures.

**The The Two Voices Rule Rule.** Use DM Sans for navigation, controls, and reading; reserve italic Fraunces for expressive headline phrases and the preview’s quiet aside.

## Layout

The desktop container is centered with a maximum width (1160px) and total side allowance (96px). The header is a horizontal wordmark/navigation row; the hero and final action are centered. Explanatory and local sections use two columns with a generous gap (90px); the FAQ uses an asymmetric split (1fr / 1.4fr). These are observed page compositions, not compulsory layouts for every future surface.

The desktop preview has a sidebar (200px) and flexible main area, with a minimum workspace height (560px). At the tablet breakpoint (1000px) the outer allowance becomes 56px and the sidebar narrows to 165px. At the phone breakpoint (760px), content stacks, the outer allowance becomes 36px, and preview navigation becomes a wrapping horizontal strip. Main preview padding reduces from 34px 35px 22px to 26px 21px 22px. At 380px the allowance becomes 28px and primary/secondary hero actions stack. Above 1500px the hero gains breathing room.

Use the recorded small spacing steps for related controls; larger section intervals come from composition. Keep actionable targets at least 44px high, including the bell counter, tabs, selectors, review action, wordmark, and modal close action. Search is 48px high. Row layouts retain a flexible, wrapping copy column and a distinct state column.

## Elevation & Depth

Depth is a hybrid of olive tonal layering and two diffuse shadows. Borders organize operational lists and explanatory content; they do not turn every section into a card. Exact shadow tokens are recorded in the sidecar because the frontmatter component schema does not support them.

### Shadow Vocabulary
- **Preview ambient:** a broad, low shadow under the desktop demonstration.
- **Dialog lifted:** stronger diffuse depth beneath the quick switcher, with a translucent forest backdrop and light blur (3px).

**The The Lift Has a Purpose Rule Rule.** Use diffuse shadows for the product preview and quick switcher; ordinary content stays on the page with separators rather than raised cards.

## Shapes

Forms are gently curved rather than pill-shaped. Compact controls and selection backgrounds use the compact radius; primary actions use the button radius; the demo shell and dialog share the surface radius. Agent rows remain flat with a thin bottom separator, while small attention badges use tighter corners (5px). Stroke icons use rounded caps and joins. The authored bell SVG is the identity mark; interface icon paths remain simple and small.

## Components

### Buttons

Primary download actions are dark forest with warm-white text, a medium corner radius, and generous horizontal padding. Hover changes the fill and raises the button slightly (2px). Secondary text actions stay unfilled and underline on hover. Review actions use a pale honey fill with dark brown text. Keep the global ochre focus outline (3px, offset 4px); disabled buttons dim to half opacity. The standard transition is gentle and brief; reduced motion removes the hover movement.

### Chips

The attention count is a small pale-honey badge with dark ochre text. It is informational, not an independent control. Selected preview navigation uses a muted olive fill and stronger text. State labels remain readable as words, with color as a supporting cue.

### Cards / Containers

The product preview is the main raised container: soft olive shell, clipped rounded corners, a menu strip, side navigation, and warm-white main area. Ordinary feature sections use horizontal separators rather than cards. Agent rows have no raised border or shadow; hover and selected states use subtle warm surface changes.

### Inputs / Fields

Search uses a pale green-white field, a thin olive border, a compact radius, and the global focus ring. Native selectors use a warm-white fill and line token border. Preserve accessible labels even when visually hidden. The quick switcher displays selected results with a soft green fill and supports arrow keys, Return, and Escape.

### Navigation

The header uses restrained sans-serif links with a lightly underlined download destination. Desktop preview tabs stack vertically; phone tabs move to a compact wrapping strip. The active status filter is marked by text weight and a dark underline. All interactive navigation retains the global visible focus treatment.

### Quick Switcher

The native dialog is a warm-white rounded surface with a strong diffuse shadow. It is bounded to the viewport (600px maximum width, 32px horizontal allowance, 48px vertical allowance), scrolls internally when needed, and uses a translucent forest backdrop. The close action remains a complete touch target. Search results are rows, not separate raised cards. The demonstration explicitly identifies its example data.

## Do's and Don'ts

### Do:
- **Do** preserve warm paper, forest text, and restrained ochre emphasis.
- **Do** pair expressive serif phrases with a clear sans-serif reading hierarchy.
- **Do** preserve visible keyboard focus, at least 44px action targets, and reduced-motion behavior.
- **Do** let the operational preview become compact without losing labels or state names.
- **Do** show fictional-demo and source-coverage context near the interface it qualifies.

### Don't:
- **Don't** apply the native app’s design system to this independently styled website.
- **Don't** turn informational feature sections into a field of raised cards.
- **Don't** use the serif for control labels or dense operational data.
- **Don't** promote compact desktop metadata below 12px into a reusable type rule.
