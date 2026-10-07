# Agent guide for agents

Read README.md before changing skill organization, discovery links, or provenance.
This is a standalone knowledge/skills repository; it must also work outside knowl.

- Keep authored and imported skills in skills/<name>. Use vendor submodules
  only for upstream repositories deliberately retained as dependencies. Keep one canonical copy per skill.
- Declare agent destinations and selected skill paths in manifest.json; sync.py
  distributes individual home symlinks. Do not recreate per-agent selection dirs.
- Select skills only for compatible agents. Use distinct canonical skill names
  when tool-specific instructions are incompatible; selection links are not overlays.
- Preserve upstream license/support files and record copied/adapted GitHub skills
  in sources.json imports with their full upstream commit and source path.
- Keep unmodified upstream repositories under vendor as pinned submodules; review
  changes before updating a gitlink. Record matching URLs and full revisions in
  sources.json repositories. Do not automatically pull/update vendors.
- Do not overwrite existing discovery entries or migrate plugin/system skills.
  Home linking and skill execution require an explicit request.
- Keep credentials, sessions, caches, and generated runtime state outside Git.
- Check this repository and any affected parent/vendor Git status before editing;
  preserve existing work. Do not commit or push without authorization.
- Before publishing a knowl gitlink, publish this repository's referenced commit.
- Validate relevant skill behavior using mock inputs. Do not execute imported
  scripts or access live credentials just to check a documentation change.
- Read tests before running make test. They use an isolated temporary HOME and
  local Git fixtures, never network or live discovery directories. make plan is
  read-only; make sync changes home and is not a routine validation command.
