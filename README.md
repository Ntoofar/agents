# agents

Personal knowledge and reusable skills for Codex, Claude Code, and other agents.
This is a separate Git repository with origin
`git@github.com:Ntoofar/agents.git`, pinned by knowl as the `agents` submodule.

## Layout

```text
agents/
├── skills/<name>/       Authored or imported skills: one canonical copy
│   ├── SKILL.md
│   └── scripts/         Optional scripts, references/, and assets/
├── vendor/<repo>/       Third-party skill repositories, pinned submodules
├── manifest.json        Each agent's destination and selected skills
├── sources.json         Vendor URLs/commit locks and copied-skill provenance
├── Makefile             plan / sync / test
├── sync.py              Local link distribution, Python standard library only
└── tests/               Isolated filesystem and Git fixtures
```

Skills live once in `skills/` or `vendor/`. The manifest replaces the old
`codex/skills/`, `claude-code/skills/`, and `pi/skills/` selection directories.
Synchronization creates individual home symlinks directly to canonical skill
folders. Agent-specific variants use distinct names in `skills/`; do not duplicate
portable skills just to distribute them to another tool.

Use common `name` and `description` frontmatter for portable skills. Keep agent
configuration, hooks, and permissions separate from the skill body. Codex's
optional `agents/openai.yaml` provides UI metadata; Claude-specific fields such
as `allowed-tools` do not configure Codex permissions. Verify a skill in each
selected agent before calling it portable. Keep directory and frontmatter names
aligned, and avoid duplicate skill names within an agent's selection.

## Select skills with manifest.json

The checked-in manifest selects the imported `skills/glab` for Codex and Claude Code.
Example configuration for additional skills after creating/importing them:

```json
{
  "version": 1,
  "agents": {
    "codex": {
      "destination": "~/.agents/skills",
      "skills": ["skills/review", "vendor/example/skills/debug"]
    },
    "claude-code": {
      "destination": "~/.claude/skills",
      "skills": ["skills/review"]
    },
    "pi": {
      "destination": null,
      "skills": []
    }
  }
}
```

Each selected path must identify a directory containing `SKILL.md` within this
repository. Custom paths use `skills/<name>`; vendor paths identify a skill within
a locked vendor repository. The final directory name becomes the home link name.
Claude Code reserves `synced` and `anthropic-skills` outside plugins.

Codex's documented personal discovery path is `~/.agents/skills`, rather than
assuming the existing `~/.codex/skills` installer directory is interchangeable.
Keep system/plugin-managed skills and caches where their installer owns them.
Sources: [Codex skill discovery](https://learn.chatgpt.com/docs/build-skills) and
[Claude Code skill discovery](https://code.claude.com/docs/en/skills).

Pi is deliberately unconfigured: verify its discovery path and compatibility,
then set its destination and skills. Adding another agent needs only another
manifest entry. Destinations must be `~/` paths inside the current user's home.

## Preview and distribute

Run from this repository root with Python 3.9+ and Make installed. Git is required
when distributing vendor skills. No dependencies are installed by these commands.

```sh
make plan                    # Read-only checks and proposed links
make sync                    # Explicitly create selected home symlinks
python3 sync.py --agent codex # Preview one agent
python3 sync.py --apply --agent codex
make test                    # Temporary HOME and local Git fixtures only
```

The script defaults to preview; Make's default target is `plan`. An empty manifest
makes no home changes, even with `make sync`. `--agent` can be repeated.
Synchronization is separate from dotfiles apply and does not download skills,
install tools, access credentials, or run skill scripts.

Before creating anything, it validates all selected sources and destinations.
It refuses existing files/directories, conflicting or broken symlinks, symlinked
discovery parents, duplicate destinations, missing skills, and unlocked vendor
sources. Existing links resolving to the same canonical skill are kept.
Independently installed skills are untouched. Discovery roots remain directories,
so Claude's managed `synced/` folder can coexist with selected skills.

Links are absolute. Moving the checkout requires deliberate inspection and repair;
the script refuses stale conflicting links instead of replacing them. Removing a
skill from the manifest does not remove an already installed link. Inspect and
remove only that link explicitly when retirement is wanted. There is no automatic
pruning, overwriting, or rollback; an I/O failure after preflight may leave some
links created. Fix the failure and rerun. Start a new session and verify skill
discovery and invocation in the selected agents.

These are local personal links. Cloud sessions need skills available within their
checkout, not links to this machine's home.

## Lock vendor sources

Keep unchanged upstream repositories as nested submodules under `vendor/`.
`sources.json` also records each repository URL and exact reviewed commit:

```json
{
  "version": 1,
  "repositories": [
    {
      "path": "vendor/example",
      "repository": "https://github.com/OWNER/REPO.git",
      "revision": "FULL_REVIEWED_COMMIT_SHA"
    }
  ],
  "imports": []
}
```

The JSON above is an example; replace example values before use. Add a nested
submodule deliberately, check out its reviewed full commit, record the same URL
and commit here, and select its skill paths in `manifest.json`. Git's `.gitmodules`
records transport configuration and the gitlink records the clone revision;
`sources.json` makes the expected source/version explicit for distribution.

For selected vendor skills, sync verifies an initialized separate repository,
exact HEAD, matching `origin` URL, and a clean worktree (including untracked files).
It refuses mismatches without printing Git diagnostics. It never fetches, clones,
checks out commits, or runs `git submodule update --remote` automatically. After
reviewing an upstream update, update both its gitlink and the source record.
Retain upstream license and attribution files.

## Included third-party skill: glab

Both configured agents select `skills/glab`, imported from
[gitlabhq/gitlabhq](https://github.com/gitlabhq/gitlabhq/tree/e3cb8a9fd23c4664b120b14468f77fd44dfdb45e/.claude/skills/glab)
at commit `e3cb8a9fd23c4664b120b14468f77fd44dfdb45e`. Only the selected skill and
upstream LICENSE are retained in this repository. `SKILL.md` is unchanged,
version 3.0.0. `sources.json` records its original path, commit, and license.
No GitLab repository/submodule is required to clone or distribute this skill.

This is a thin wrapper that loads the skill bundled with the installed `glab`
binary. Claude Code can evaluate its shell expansion; other agents follow its
explicit fallback to run `glab skills get glab`. That command requires glab
1.119.0 or newer. The wrapper also documents an older-version fallback. Dotfiles
currently pins glab 1.120.0, but the binary still needs to be available on PATH.
Sync does not install or upgrade glab or log into GitLab. The source lock pins
the wrapper, while full runtime instructions depend on the installed CLI.
Skill discovery and actual GitLab workflows must be verified separately.

For future imports, download only the selected complete skill directory and
required license/support files at a reviewed commit, record the import, and
select its local path in the manifest. A downloader may use a temporary Git
checkout internally; that checkout need not remain in `vendor/`. Reserve vendor
submodules for collections whose upstream repositories you want to retain.

For copied/adapted upstream skills in `skills/`, use an `imports` entry:

```json
{
  "path": "skills/example-skill",
  "repository": "https://github.com/OWNER/REPO",
  "revision": "FULL_UPSTREAM_COMMIT_SHA",
  "upstream_path": "skills/example-skill",
  "license": "SPDX_IDENTIFIER_OR_LICENSE_DESCRIPTION",
  "license_file": "skills/example-skill/LICENSE",
  "imported_on": "YYYY-MM-DD",
  "local_changes": "Describe adaptations, or use 'none'."
}
```

Imports are provenance notes, not download instructions or automatic revision
checks on adapted content. For locally authored skills, Git history is the source
of truth; no upstream entry is needed. Keep URLs free of credentials, and keep
sessions, caches, logs, and rendered secret configurations outside this repository.

## Clone and publish

From the knowl root, initialize this submodule:

```sh
git submodule update --init --recursive agents
```

Publish changed upstream forks first, then this repository (including nested
vendor gitlinks and source records), then knowl's `agents` gitlink. All referenced
commits must be reachable from their remotes. Commit/push only when requested.
Dotfiles owns tool installation and home settings; this repository owns skills,
source tracking, selection, and explicit skill distribution.
