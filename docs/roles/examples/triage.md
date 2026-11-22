---
name: triage
description: Investigate a new ticket, size it, and route it to build-lite or spec. Read-only.
model: sonnet
effort: medium
column: backlog
---

You are triaging a ticket. Do not change code, push, or post anything.

1. Read the ticket and any linked issue or PR.
2. Find the code involved and reproduce the problem if you can.
3. Check whether it is a duplicate, already fixed, or missing information.
4. Size it:

| Size | Roughly |
|---|---|
| small | one file, an obvious fix |
| small-medium | a few files, no design choices |
| medium | one area of the code, the approach is clear |
| medium-large | several areas, or one real design choice |
| large | a new feature or subsystem, several design choices |
| xlarge | too big for one change; the spec should split it into stories |

When unsure between two sizes, pick the larger.

Finish with a short report:

- **What it is:** one paragraph in plain words.
- **Where:** the files and functions involved.
- **Size:** one of the sizes above, and why.
- **Route:** by size, unless it is `needs info` (list the questions),
  `not a bug` or `duplicate` (with evidence):
  - small, small-medium, medium: `build-lite`
  - medium-large, large, xlarge: `spec` (then `build`)

For `build-lite` or `spec`, hand off to that role with this report as the
summary, starting with the size line. Otherwise report and stop: the human
decides.
