### Code Intelligence

Prefer LSP over Grep/Read for code navigation — it's faster, precise, and avoids reading entire files:

- `workspaceSymbol` to find where something is defined
- `findReferences` to see all usages across the codebase
- `goToDefinition` / `goToImplementation` to jump to source
- `hover` for type info without reading the file

Use Grep only when LSP isn't available or for text/pattern searches (comments, strings, config).

After writing or editing code, check LSP diagnostics and fix errors befor proceeding.

When opting to use grep use ripgrep (rg) instead,

Use fd instead of find.

### Text formatting

Don't use em/en dashes like "—" on texts.

### Writing style

Use natural, plain English by default for chat answers and requested writing, including Slack messages, tickets, PR descriptions, and docs. Lead with the answer, then the detail. Prefer familiar words, explain unfamiliar terms when needed, and drop density and filler. This preference does not activate a writing-style skill.

### Writing skill selection

- Use `iso-24495` from danyuchn only when I explicitly request ISO, ISO format, ISO plain language, or that skill by name or slash command. A generic ISO request selects danyuchn's implementation. Do not activate it automatically for chat answers, explanations, drafts, messages, tickets, PRs, or docs.
- Use `developer-documentation` for creating, restructuring, or maintaining developer docs grounded in the actual system. Keep its research, structure, examples, and verification workflow. Use natural, plain English for prose unless I explicitly select a writing-style skill; do not automatically load ISO or SimpleEnglish. This workflow can accompany one explicitly selected writing style.
- Use GaZmagik's `iso-24495-1` through `iso-24495-5`, `iso-24495-code`, and `iso-24495-text-audit` only when I explicitly request that alternative or name one of those skills. When I select that alternative, load its relevant extensions as directed by the selected skill.
- Use `simple-english` only when I explicitly request SimpleEnglish, STE, ASD-STE100, or `/simple-english`. Requests for plain English, simpler wording, or an easier explanation do not activate this skill.
- Apply at most one writing-style skill per task, only when explicitly requested. Scope that selection to the requested task rather than subsequent unrelated chat answers or drafts. For an A/B comparison, apply each style separately to the same original text.
- Preserve facts, uncertainty, technical tokens, and my requested destination format. My formatting instructions take priority over a skill's house style.

### Copy-paste / Slack message format

When drafting a Slack message (or any text I will copy-paste elsewhere), output it inside a single fenced code block using Slack's own markup, not chat markdown:

- Use `*single asterisks*` for bold, not `**double**`.
- Use `` `inline code` `` and bullet char `•` as normal.
- Do not wrap the draft in `>` blockquote markers.

Reason: chat-markdown rendering (blockquote + `**bold**`) loses formatting when pasted into Slack. A fenced block with Slack markup pastes clean; Slack prompts to apply formatting on paste (or Cmd+Shift+F).

### Commits and PRs

- Never add `Co-Authored-By` or 🤖 / "Generated with Claude" footers to commits or PR bodies.
- Keep PR descriptions concise. Do not paste the whole Jira ticket into the body; link the ticket and summarize.

### Subagent models

- When I ask for a "sonnet subagent" (or Sonnet 5.5), use `subagent_type: sonnet-worker` and do not set the `model` parameter. The `sonnet` model shortcut resolves to the older Sonnet 5 on this machine; `sonnet-worker` runs Sonnet 5.5.
- When I ask for an "opus subagent", omit `model` (the session default is Opus 5.5) or set it to `opus`.
