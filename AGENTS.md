# Agent Guidelines for rules_dnfo

Notes and operating protocols for LLM coding agents working on this repository (`CLAUDE.md` and `GEMINI.md` are symlinks to this file).

---

## 1. Bazel Invocation Protocol

Whenever invoking `bazel` (`build`, `test`, `run`, `cquery`, `query`, etc.):
1. Generate an invocation ID with `uuidgen`:
   ```bash
   INVOCATION_ID=$(uuidgen)
   ```
2. Print it before calling `bazel`:
   ```bash
   echo "Invocation ID: ${INVOCATION_ID}"
   ```
3. All `bazel` invocations must take `--invocation_id=${INVOCATION_ID}` immediately after the command:
   ```bash
   bazel <command> --invocation_id=${INVOCATION_ID} <args>
   ```
   Or as a one-liner:
   ```bash
   INVOCATION_ID=$(uuidgen) && echo "Invocation ID: ${INVOCATION_ID}" && bazel <command> --invocation_id=${INVOCATION_ID} <args>
   ```

> [!NOTE]
> The `INVOCATION_ID` protocol is solely for agent session tracking and logs. It must **never** be included in user-facing documentation, README files, or release notes.

---

## 2. Git & Branch Management Protocol

- **Never push directly to `main`**: Even if admin/owner permissions allow it, never push directly to `main`.
- **Always use Pull Requests**:
  1. Create a descriptive feature/fix/chore branch (e.g. `feat/...`, `fix/...`, `chore/...`).
  2. Commit changes with clear commit messages.
  3. Push the branch to `origin`.
  4. Open a Pull Request against `main`.

---

## 3. Path Handling Protocol

- **Relative Paths Only**: Paths must never be absolute when hardcoding; they must always be relative to the repository root.
- **Bazel Run Integration**: For tools executed through `bazel run`, use `BUILD_WORKSPACE_DIRECTORY` to reference files relative to the workspace root.

---

## 4. Timezone & Date Localization Protocol

- **Amsterdam Timezone (Europe/Amsterdam - CET/CEST)**:
  - Always display all dates, times, and timestamps localized to the Amsterdam timezone (`Europe/Amsterdam`, CET/CEST) in all user-facing responses, summaries, and reports.
  - When citing timestamps from logs, databases, or UTC sources, convert and present them in Amsterdam local time.

---

## 5. Development & Codebase Standards

- **No `genrule`**: Never use `genrule`. Use proper binary rules, Starlark rules, and helpers from `bazel_lib` or `tar.bzl`.
- **Tooling**: Built in Go using `rules_go` and `gazelle`.
- **Starlark Management**: Starlark (`.bzl` and `BUILD.bazel`) files are managed using `aspect_gazelle_prebuilt`. Always verify with:
  ```bash
  bazel run //:gazelle
  bazel run //:gazelle.check
  ```
- **Remote Cache & Credentials**:
  - Do not delete, commit, or overwrite `.bazelrc.user`. It is git-ignored and contains remote execution credentials.
- **Submodule Isolation**:
  - Keep nested test workspaces or git worktrees under `.worktrees` or `e2e/`, ignored by `REPO.bazel` and `.bazelignore`.
