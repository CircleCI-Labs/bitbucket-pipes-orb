# Bitbucket Pipes Orb (Unofficial) [![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/bitbucket-pipes-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/bitbucket-pipes-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/bitbucket.svg)](https://circleci.com/developer/orbs/orb/cci-labs/bitbucket) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/bitbucket-pipes-orb/main/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

Run a single [Bitbucket Pipe](https://bitbucket.org/product/features/pipelines/integrations) --
any Docker image built to the Bitbucket Pipelines pipe contract -- as one step inside an
otherwise-native CircleCI job or workflow. If your team already has a pipe it likes (an
Atlassian one, or your own), this orb gets you running it on CircleCI with no rewrite: the pipe's
own `variables:` reach it under their real Bitbucket names, CircleCI's build context is mapped
onto the `BITBUCKET_*` variables the pipe actually reads, and anything the pipe writes back comes
out into native CircleCI steps.

---
**Disclaimer:**

CircleCI Labs, including this repo, is a collection of solutions developed by members of
CircleCI's field engineering teams through our engagement with various customer needs.

- ✅ Created by engineers @ CircleCI
- ✅ Used by real CircleCI customers
- ❌ **not** officially supported by CircleCI support

---

## Scope: one pipe, not a pipeline

This orb runs **one pipe per call** -- it is not a Bitbucket Pipelines emulator, and it does not
attempt to run a whole `bitbucket-pipelines.yml`. Everything around that one pipe (checkout,
build steps, deploys, notifications, other pipes) is meant to be **native CircleCI**, written the
normal CircleCI way. If a Bitbucket pipeline chains five pipes together, that becomes five calls
to this orb interleaved with whatever native steps you want between them -- not one orb call.

## Quick start

```yaml
version: 2.1
orbs:
  bitbucket: cci-labs/bitbucket@x.y.z
workflows:
  main:
    jobs:
      - bitbucket/pipe:
          image: bitbucketpipelines/demo-pipe-bash:0.1.0
          variables: |
            NAME=Mona Octocat
```

That's it -- no Bitbucket account, no Bitbucket Pipelines runner, and no rewrite of the pipe
itself. See [`src/examples/`](src/examples/) for the command form (inline among native steps),
private images, array variables, and pre/post-step interleaving.

## How it works

- **`bitbucket/pipe`** (job) and the **`pipe`** command do the same four things, in order:
  1. `create-output-file` -- creates the file a pipe can append output variables to.
  2. `map-env` -- exports CircleCI's build context onto the `BITBUCKET_*` variables pipes read.
  3. `run-pipe` -- `docker run`s the image, with your workspace bind-mounted where pipes expect it,
     your `variables:` passed through under their literal Bitbucket names, and the pipe's own
     exit code and stderr reaching you unmodified. No retries, no wrapping, no assertion layer.
  4. `collect-outputs` -- reads back anything the pipe wrote and exports it into `$BASH_ENV`, so
     the very next native step can use it like any other CircleCI-set environment variable.
- These four are separate, composable commands specifically so you can call them yourself with
  native steps in between, and so a future version could chain more than one pipe per job without
  a breaking change. `pipe` is just the common case, pre-assembled.
- Runs on a `machine` executor. **Not** `docker` + `setup_remote_docker` -- see
  ["What does not work"](#what-does-not-work) for why.

## Bitbucket variables are literal -- no prefix

Unlike this orb's sibling ecosystem-bridge orbs, a pipe's `variables:` become environment
variables **under their exact, literal Bitbucket names** -- no prefix, no case change. If a
pipe's docs say it reads `AWS_ACCESS_KEY_ID`, you write `AWS_ACCESS_KEY_ID=...` in this orb's
`variables:` parameter, and that pipe's own container sees literally `AWS_ACCESS_KEY_ID`.

Array variables can be written either way, and both produce the identical container-side result:

- Bitbucket's own flat convention, typed out by hand -- `SOME_VAR_COUNT=2`, `SOME_VAR_0=...`,
  `SOME_VAR_1=...`.
- A bracket list, matching the exact syntax a Bitbucket *pipeline author* already writes on real
  Bitbucket (`SOME_VAR=['first', 'second']`) -- `run-pipe` flattens this into the `_COUNT`/`_0`/
  `_1`/... form itself, so you never have to hand-count array items or keep a `_COUNT` in sync
  with hand-typed `_N` entries. (Limitation: a comma inside a quoted item is treated as an item
  separator -- this is a plain split, not a full YAML/JSON parser.)

Use `$MY_SECRET` inside `variables:` (or `extra-env-mapping:`) to pull from a real CircleCI
context/project env var at runtime, via [`circleci env
subst`](https://circleci.com/changelog/new-cli-command-env-subst) -- the secret's value never
enters your CircleCI config.

### The literal-naming tradeoff: two small denylists

Because `variables:`/`extra-env-mapping:`/a pipe's own output-variables file all accept
Bitbucket's literal, unprefixed names, and this orb's whole point is running third-party (and
potentially untrusted) vendor images, "any identifier is a valid Bitbucket variable name" would
otherwise let a value collide with something that isn't a Bitbucket variable at all:

- **Reserved shell-control names** (`PATH`, `IFS`, `BASH_ENV`, `ENV`, `LD_PRELOAD`,
  `LD_LIBRARY_PATH`, and similar) are rejected -- warn-and-skip, same as a malformed line -- by
  `extra-env-mapping` and by the pipe's own output-variables file. Both of those sinks write into
  `$BASH_ENV`, which every later native step in the job sources; a pipe container (or a copy-paste
  mistake) naming one of these would otherwise rewrite the shell environment for the rest of the
  job. This does **not** apply to the plain `variables:` parameter -- those values only ever reach
  the pipe's own container via `docker run -e`, never `$BASH_ENV`, so they carry no such risk and
  keep the fully literal, unrestricted contract.
- **The four paths this orb itself bind-mounts** (`BITBUCKET_CLONE_DIR`,
  `BITBUCKET_PIPELINES_VARIABLES_PATH`, `BITBUCKET_PIPE_STORAGE_DIR`,
  `BITBUCKET_PIPE_SHARED_STORAGE_DIR`) are rejected the same way if a `variables:` line names one
  -- and, as a structural backstop, `run-pipe`'s own authoritative `-e` for each of these four is
  always emitted last, so Docker's real last-`-e`-wins behavior can't be used to desync a
  pipe's belief about these paths from the actual bind-mount target even if the denylist check
  above were somehow bypassed.

Neither denylist restricts any real Bitbucket usage: no official or third-party pipe declares an
input or output variable literally named `PATH`, `BASH_ENV`, or one of the four bind-mount paths
above -- those are either shell internals or platform-set constants a pipe *reads*, never a
`variables:` key a pipeline author sets.

## CircleCI -> Bitbucket variable mapping

`map-env` sets the identity/context rows below before the pipe runs; the last row
(`BITBUCKET_PIPELINES_VARIABLES_PATH` / `BITBUCKET_PIPE_STORAGE_DIR` /
`BITBUCKET_PIPE_SHARED_STORAGE_DIR`) is actually set by `create-output-file`, not `map-env` --
both run automatically as part of the `pipe` command/job, so this only matters if you're composing
the four commands yourself and skip one of them. "Confirmed" means the mapping (or the variable's
real usage) was verified against Atlassian's docs and/or real pipe source; "synthesized" means
there is no CircleCI equivalent and a placeholder is generated purely so the pipe does not crash
on a missing variable.

| Bitbucket variable | Source | Status |
|---|---|---|
| `BITBUCKET_WORKSPACE`, `BITBUCKET_REPO_OWNER` (deprecated alias, still widely read) | `CIRCLE_PROJECT_USERNAME` | Confirmed |
| `BITBUCKET_REPO_SLUG` | `CIRCLE_PROJECT_REPONAME` | Confirmed |
| `BITBUCKET_REPO_FULL_NAME` | `$CIRCLE_PROJECT_USERNAME/$CIRCLE_PROJECT_REPONAME` | Synthesized (simple join) |
| `BITBUCKET_COMMIT` | `CIRCLE_SHA1` | Confirmed |
| `BITBUCKET_BUILD_NUMBER` | `CIRCLE_BUILD_NUM` | Confirmed |
| `BITBUCKET_BRANCH` | `CIRCLE_BRANCH` | Confirmed; only set on branch builds |
| `BITBUCKET_TAG` | `CIRCLE_TAG` | Confirmed; only set on tag builds |
| `BITBUCKET_PR_ID` | Trailing number parsed out of `CIRCLE_PULL_REQUEST` | **Format mismatch, best effort** -- Bitbucket wants a bare number, CircleCI's var is a full PR URL; left unset if unparsable |
| `BITBUCKET_CLONE_DIR` | Set to the `clone-dir` parameter (default `/opt/atlassian/pipelines/agent/build`), the bind-mount target | Confirmed |
| `BITBUCKET_GIT_HTTP_ORIGIN` / `BITBUCKET_GIT_SSH_ORIGIN` | Derived from `CIRCLE_REPOSITORY_URL` | Best effort -- keeps the repo's *real* host, which is more useful to a pipe than Atlassian's literal `bitbucket.org` example format, but is a deviation from it |
| `BITBUCKET_PIPELINE_UUID`, `BITBUCKET_STEP_UUID`, `BITBUCKET_WORKSPACE_UUID`, `BITBUCKET_REPO_UUID`, `BITBUCKET_PROJECT_UUID`, `BITBUCKET_STEP_TRIGGERER_UUID` | Generated per run | **Synthesized placeholders** -- not real Bitbucket identifiers, exist only so a pipe checking presence/uniqueness doesn't crash |
| `BITBUCKET_REPO_OWNER_UUID` (deprecated alias of `BITBUCKET_WORKSPACE_UUID`, still documented) | Same generated value as `BITBUCKET_WORKSPACE_UUID` | **Synthesized placeholder** |
| `BITBUCKET_PROJECT_KEY` | Derived from `CIRCLE_PROJECT_REPONAME` | **Synthesized placeholder** |
| `BITBUCKET_PIPELINES_VARIABLES_PATH`, `BITBUCKET_PIPE_STORAGE_DIR`, `BITBUCKET_PIPE_SHARED_STORAGE_DIR` | Orb-managed scratch paths | Confirmed mechanism, orb-synthesized paths |

Add to or override any of this with the `extra-env-mapping` parameter (multi-line
`BITBUCKET_VAR=value`, also run through `circleci env subst`), applied after the table above.

## What does not work

- **Bitbucket-hosted pipe references (`account/repo:tag`)**: this orb only runs `docker://`-style
  image references, passed to `docker run` verbatim, per this project's locked design decision to
  do zero image-resolution of its own. Point `image:` at the pipe's real Docker image (check its
  `pipe.yml` `image:` field, or run `docker run --rm --entrypoint cat <image> /pipe.yml` against
  any candidate image to read its baked-in metadata).
- **`BITBUCKET_STEP_OIDC_TOKEN`**: no CircleCI equivalent exists, and none is synthesized (unlike
  the identity UUIDs above, a fake token would be actively misleading, not just a placeholder). A
  pipe that authenticates to AWS/GCP via Bitbucket's OIDC federation cannot do so through this
  bridge -- give it long-lived credentials via `variables:`/CircleCI contexts instead, if the pipe
  supports that.
- **`BITBUCKET_DEPLOYMENT_ENVIRONMENT` / `BITBUCKET_DEPLOYMENT_ENVIRONMENT_UUID`**: no CircleCI
  concept maps onto Bitbucket's deployment environments, so these are left unset rather than
  guessed. Set them yourself via `extra-env-mapping` if a pipe needs a specific value.
- **A `docker` executor**: CircleCI's `docker` executor with `setup_remote_docker` runs its Docker
  daemon in a separate remote VM with no filesystem shared with the job -- bind mounts silently
  don't work there, and CircleCI's own docs point you at `docker cp` instead. Making that work
  for this orb would mean copying the whole checkout into the remote environment before the pipe
  runs and copying the workspace and outputs back out afterward -- a slower, materially riskier
  second code path we have not built or verified. Only `machine` is supported; use it.
- **Root-owned files from the pipe container**: pipe containers run as root by default (matching
  Bitbucket's own real-world behavior). On a real Linux `machine` executor this can leave
  root-owned files in your checkout that break later native steps -- set `fix-permissions: true`
  if you hit this. (This specific failure mode does not reproduce under Docker Desktop on macOS,
  whose bind-mount layer transparently remaps container UIDs; it was verified against well-known
  Docker semantics for genuine Linux, not hands-on-reproduced in this project's own testing.)
- **Bitbucket's own output-variables mechanism catches less than you'd expect**: real pipes
  almost never write to `$BITBUCKET_PIPELINES_VARIABLES_PATH` -- across a sample of Atlassian's
  own official pipes, none did. Pipes that do hand data forward mostly write their own file into
  the workspace (documented in that pipe's own README) instead. The good news: since that file is
  inside the bind-mounted workspace already, a later native step can just read it directly with
  zero extra plumbing -- you don't need this orb's output-variable mechanism for that at all. Real
  Bitbucket also caps this mechanism at 50 shared variables / 100KB combined (key+value) per
  pipeline; this orb enforces no equivalent limit of its own -- `collect-outputs` exports every
  line in the file unconditionally (minus the reserved-name denylist above).
- **One pipe per orb call**: by design (see "Scope" above). The underlying commands are layered
  so chaining could be added later without a breaking change, but that isn't built yet.

## Commands and job

| Name | Kind | What it does |
|---|---|---|
| `pipe` | command, job | The aggregate most users want: all four steps below, in order. |
| `create-output-file` | command | Creates the output-variables file + pipe storage scratch dirs. |
| `map-env` | command | Exports the CIRCLE_*->BITBUCKET_* mapping into `$BASH_ENV`. |
| `run-pipe` | command | The `docker run` invocation itself. Named `run-pipe`, not `run`, to avoid colliding with CircleCI's own built-in `run` step. |
| `collect-outputs` | command | Reads the output file back and exports it into `$BASH_ENV`. |

The `pipe` **job** (only when invoked from a workflow's `jobs:` list, not the `pipe` command
inside another job's own `steps:`) also accepts CircleCI's own built-in `pre-steps`/`post-steps`
arguments -- available on every 2.1+ job, not something this orb declares. Pass them at the call
site, e.g.:

```yaml
- bitbucket/pipe:
    image: bitbucketpipelines/demo-pipe-bash:0.1.0
    pre-steps:
      - run: echo "before checkout AND before the pipe"
    post-steps:
      - run: echo "after the pipe; its outputs are already in $BASH_ENV"
```

One real platform caveat worth calling out: `pre-steps` run before **every** step in the job,
including this job's own internal `checkout` -- not just before the pipe. If a pre-step needs the
repo checked out, do that checkout yourself inside the pre-step, or use the `pipe` command with
native steps around it instead (see [`src/examples/`](src/examples/)).

Full parameter reference: [CircleCI Orb Registry page](https://circleci.com/developer/orbs/orb/cci-labs/bitbucket).

## Resources

[CircleCI Orb Registry Page](https://circleci.com/developer/orbs/orb/cci-labs/bitbucket) - the
official registry page of this orb for all versions, executors, commands, and jobs described.

[CircleCI Orb Docs](https://circleci.com/docs/orb-intro/#section=configuration) - docs for using,
creating, and publishing CircleCI orbs.

[Bitbucket Pipes reference](https://support.atlassian.com/bitbucket-cloud/docs/) - Atlassian's
own pipe docs, including the "Default variables" and step `output-variables` reference pages this
orb's env mapping and output handling are built from.

## How to Contribute

We welcome [issues](https://github.com/CircleCI-Labs/bitbucket-pipes-orb/issues) and [pull
requests](https://github.com/CircleCI-Labs/bitbucket-pipes-orb/pulls) against this repository!

## How to Publish An Update

1. Merge pull requests with desired changes to the main branch.
   - For the best experience, squash-and-merge and use [Conventional Commit
     Messages](https://conventionalcommits.org/).
2. Find the current version of the orb.
   - You can run `circleci orb info cci-labs/bitbucket | grep "Latest"` to see the current
     version.
3. Create a [new Release](https://github.com/CircleCI-Labs/bitbucket-pipes-orb/releases/new) on
   GitHub.
   - Click "Choose a tag" and _create_ a new [semantically versioned](http://semver.org/) tag.
     (ex: v1.0.0)
4. Click _"+ Auto-generate release notes"_.
5. Ensure the version tag selected is semantically accurate based on the changes included.
6. Click _"Publish Release"_ -- this pushes the tag and triggers the publishing pipeline.
