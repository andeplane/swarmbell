# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

Native macOS menu-bar app and native iOS read-only companion.

## Stack

Swift 6 core and command-line tools; an AppKit menu bar shell, SwiftUI views and Swift Charts dashboard. System SQLite stores refresh measurements locally.

## Users

The user runs coding agents across Claude Code, Codex, and Cursor and needs to see their combined activity without checking each app individually.

## Product Purpose

Show active-agent and needs-you counts in the macOS menu bar. A click lists sessions with harness icons; selecting one opens its original conversation. A global shortcut opens a searchable Spotlight-like panel with needs-you sessions first.

## Operating Context

Local macOS app. Approximately five-second refresh requested. The user chose a new repository under `~/projects/personal`; this project is `~/projects/personal/agent-beacon`. The attached screenshot illustrates the existing crowded macOS menu bar; it contains no implementation instructions.

## Capabilities and Constraints

Monitor sessions already running in the three harnesses. Keep monitoring inside the app; no hosted backend. Native-thread activation is required. The user subsequently requested building and running the actual menu bar app immediately, plus persistent measurements on every refresh and a dashboard with time series, weekday/hour histograms, weekly/monthly ranges and actionable statistics. Parallel subagents were explicitly requested.

Chosen name: Agent Beacon. Open decisions: how much child-agent detail belongs in the headline counts; whether a completed result should become an unread attention item; remote-host coverage; terminal preference; final global shortcut. Proposed defaults are documented as proposals, not confirmed preferences.

## Evidence on Hand

ImageGen concept board with menu bar and quick-switcher surfaces. Native app and live Claude/Codex polling verified. Codex desktop observation uses a versioned private interface and remains partial. Cursor lifecycle contracts and safe setup are implemented; native attention and original-chat activation are not yet established across all three harnesses. Statistics uses real collected measurements, with source gaps and observation uncertainty retained.

## Product Principles

- Counts must say when source coverage is incomplete.
- Distinguish a question or approval from ordinary idle state.
- Keep the original harness responsible for interaction and execution.
- Keep routine monitoring local and small.
