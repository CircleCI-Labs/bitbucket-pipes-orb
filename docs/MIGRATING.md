# Migrating from Bitbucket Pipelines

How to translate a real Bitbucket Pipelines pipe step into this orb's config, concept by concept.

## A worked comparison

Here's a real Bitbucket Pipelines step running a pipe, next to this orb's equivalent:

```yaml
# bitbucket-pipelines.yml (Bitbucket Pipelines)
pipelines:
  default:
    - step:
        name: Deploy to S3
        script:
          - pipe: atlassian/aws-s3-deploy:1.7.0
            variables:
              AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID
              AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY
              AWS_DEFAULT_REGION: us-east-1
              S3_BUCKET: my-bucket
              LOCAL_PATH: dist
```

```yaml
# .circleci/config.yml (this orb)
version: 2.1
orbs:
  bitbucket: cci-labs/bitbucket@x.y.z
workflows:
  deploy:
    jobs:
      - bitbucket/pipe:
          image: bitbucketpipelines/aws-s3-deploy:1.7.0
          variables: |
            AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
            AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
            AWS_DEFAULT_REGION=us-east-1
            S3_BUCKET=my-bucket
            LOCAL_PATH=dist
```

What actually changed, concept by concept:

- **A Bitbucket "pipe" step becomes a `bitbucket/pipe` command** (inline, among native steps)
  **or job** (standalone). Bitbucket's `pipe:` attribute names a repository reference
  (`atlassian/aws-s3-deploy:1.7.0`) that Bitbucket's own backend resolves into a Docker image; this
  orb has no such resolver (a locked design decision; see [LIMITS.md](LIMITS.md)), so `image:`
  takes the pipe's real Docker image reference directly (typically the same organization's Docker
  Hub namespace, here `bitbucketpipelines/...` instead of `atlassian/...`; check the pipe's own
  `pipe.yml` or Docker Hub page if unsure).
- **`variables:` goes from real Bitbucket YAML (a map) to this orb's flat `KEY=VALUE` lines**, the
  same literal, unprefixed names either side (see "Bitbucket variables are literal" below), just a
  different YAML shape to hold them.
- **Where the vendor's env vars come from doesn't actually change much here**, which is unusual
  among this orb's sibling bridges: real Bitbucket Pipelines also expects secrets as plain
  repository/workspace variables referenced by name, so `$AWS_ACCESS_KEY_ID` means almost the same
  thing on both sides. The only difference is which platform's UI you defined it in (Bitbucket's
  Repository settings, Variables, versus a CircleCI context or project environment variable).
  This orb's `variables:`/`extra-env-mapping:` still run the value through `circleci env subst` at
  runtime, so the secret never has to be typed into committed config on either platform.
- **What Bitbucket's platform does for you that CircleCI does natively instead:** real Bitbucket
  auto-scans fixed test-report globs and calls that Pipelines' test-results feature. This orb's
  `store-test-results` default (see [LIMITS.md](LIMITS.md)) is the direct equivalent, already
  wired up with zero extra config. Bitbucket has no fixed artifacts directory either, so there's
  nothing to port on that axis; add your own `store_artifacts` step if you know the specific
  pipe's own output path.

## Bitbucket variables are literal, no prefix

Unlike this orb's sibling ecosystem-bridge orbs, a pipe's `variables:` become environment variables
under their exact, literal Bitbucket names: no prefix, no case change. If a pipe's docs say it
reads `AWS_ACCESS_KEY_ID`, you write `AWS_ACCESS_KEY_ID=...` in this orb's `variables:` parameter,
and that pipe's own container sees literally `AWS_ACCESS_KEY_ID`.

Array variables can be written either way, and both produce the identical container-side result:

- Bitbucket's own flat convention, typed out by hand: `SOME_VAR_COUNT=2`, `SOME_VAR_0=...`,
  `SOME_VAR_1=...`.
- A bracket list, matching the exact syntax a Bitbucket pipeline author already writes on real
  Bitbucket (`SOME_VAR=['first', 'second']`). `run-pipe` flattens this into the `_COUNT`/`_0`/`_1`/
  ... form itself, so you never have to hand-count array items or keep a `_COUNT` in sync with
  hand-typed `_N` entries. (Limitation: a comma inside a quoted item is treated as an item
  separator; this is a plain split, not a full YAML/JSON parser.)

Use `$MY_SECRET` inside `variables:` (or `extra-env-mapping:`) to pull from a real CircleCI
context/project env var at runtime, via [`circleci env
subst`](https://circleci.com/changelog/new-cli-command-env-subst). The secret's value never enters
your CircleCI config.

See [LIMITS.md](LIMITS.md) for the two small denylists that this literal-naming contract requires.

## CircleCI to Bitbucket variable mapping

`map-env` sets the identity/context rows below before the pipe runs; the last row
(`BITBUCKET_PIPELINES_VARIABLES_PATH` / `BITBUCKET_PIPE_STORAGE_DIR` /
`BITBUCKET_PIPE_SHARED_STORAGE_DIR`) is actually set by `create-output-file`, not `map-env`. Both
run automatically as part of the `pipe` command/job, so this only matters if you're composing the
four commands yourself and skip one of them. "Confirmed" means the mapping (or the variable's real
usage) was verified against Atlassian's docs and/or real pipe source; "synthesized" means there is
no CircleCI equivalent and a placeholder is generated purely so the pipe does not crash on a
missing variable.

| Bitbucket variable | Source | Status |
|---|---|---|
| `BITBUCKET_WORKSPACE`, `BITBUCKET_REPO_OWNER` (deprecated alias, still widely read) | `CIRCLE_PROJECT_USERNAME` | Confirmed |
| `BITBUCKET_REPO_SLUG` | `CIRCLE_PROJECT_REPONAME` | Confirmed |
| `BITBUCKET_REPO_FULL_NAME` | `$CIRCLE_PROJECT_USERNAME/$CIRCLE_PROJECT_REPONAME` | Synthesized (simple join) |
| `BITBUCKET_COMMIT` | `CIRCLE_SHA1` | Confirmed |
| `BITBUCKET_BUILD_NUMBER` | `CIRCLE_BUILD_NUM` | Confirmed |
| `BITBUCKET_BRANCH` | `CIRCLE_BRANCH` | Confirmed; only set on branch builds |
| `BITBUCKET_TAG` | `CIRCLE_TAG` | Confirmed; only set on tag builds |
| `BITBUCKET_PR_ID` | Trailing number parsed out of `CIRCLE_PULL_REQUEST` | Format mismatch, best effort: Bitbucket wants a bare number, CircleCI's var is a full PR URL; left unset if unparsable |
| `BITBUCKET_CLONE_DIR` | Set to the `clone-dir` parameter (default `/opt/atlassian/pipelines/agent/build`), the bind-mount target | Confirmed |
| `BITBUCKET_GIT_HTTP_ORIGIN` / `BITBUCKET_GIT_SSH_ORIGIN` | Derived from `CIRCLE_REPOSITORY_URL` | Best effort: keeps the repo's real host, which is more useful to a pipe than Atlassian's literal `bitbucket.org` example format, but is a deviation from it |
| `BITBUCKET_PIPELINE_UUID`, `BITBUCKET_STEP_UUID`, `BITBUCKET_WORKSPACE_UUID`, `BITBUCKET_REPO_UUID`, `BITBUCKET_PROJECT_UUID`, `BITBUCKET_STEP_TRIGGERER_UUID` | Generated per run | Synthesized placeholders: not real Bitbucket identifiers, exist only so a pipe checking presence/uniqueness doesn't crash |
| `BITBUCKET_REPO_OWNER_UUID` (deprecated alias of `BITBUCKET_WORKSPACE_UUID`, still documented) | Same generated value as `BITBUCKET_WORKSPACE_UUID` | Synthesized placeholder |
| `BITBUCKET_PROJECT_KEY` | Derived from `CIRCLE_PROJECT_REPONAME` | Synthesized placeholder |
| `BITBUCKET_PIPELINES_VARIABLES_PATH`, `BITBUCKET_PIPE_STORAGE_DIR`, `BITBUCKET_PIPE_SHARED_STORAGE_DIR` | Orb-managed scratch paths | Confirmed mechanism, orb-synthesized paths |

Add to or override any of this with the `extra-env-mapping` parameter (multi-line
`BITBUCKET_VAR=value`, also run through `circleci env subst`), applied after the table above.

## Matching Bitbucket Cloud's own default build-step tools

If your old Bitbucket pipeline ran ordinary shell commands in Bitbucket Cloud's default container
around a Pipe (not the Pipe itself, which already carries its own tools) and you want that same
tool footprint (`docker-compose`, `ant`, a specific `node`/`python`) in a native CircleCI
`pre-steps`/`post-steps` step, use Atlassian's own `atlassian/default-image` there:

```yaml
- bitbucket/pipe:
    image: some/pipe
    pre-steps:
      - run:
          name: A plain shell command that used to run in Bitbucket Cloud's own default container
          # Never pin ":latest" here. Atlassian's own Docker Hub page documents that
          # ":latest" resolves to v1 (Ubuntu 14.04, 2014-era) for backward compatibility, not
          # the current image. Pin an explicit major version instead.
          command: docker run --rm -v "$(pwd):/work" -w /work atlassian/default-image:5 docker-compose version
```

This is a documentation/parity aid, not something this orb wires up itself: `atlassian/default-image`
is Bitbucket Cloud's outer build-step container, and this orb's `run-pipe` never executes your code
in that layer; the Pipe's own image already carries whatever it needs. Checked directly against
Docker Hub while researching this orb's vendor-image options: unlike the sibling `bitrise` orb
(whose Steps genuinely run bare with nothing else providing a toolchain), there's no gap here for a
default executor to fill.

## Passing pipe output across jobs

The output-variables mechanism described above (and `$BASH_ENV` generally) is job-scoped: a pipe's
output can reach a later native step in the same CircleCI job, but not a later job in the same
workflow. Two real, native CircleCI mechanisms cover this without any orb change:

- **Passing a value to a downstream job**: after `bitbucket/pipe` runs, write the value you need
  to a file and `persist_to_workspace` it, then `attach_workspace` in the downstream job and read
  the file with a plain `run` step.
- **Branching which jobs run based on an upstream job's output** (a genuine workflow-level
  conditional): CircleCI has no native construct for this. The closest real mechanism is a setup
  workflow plus the
  [`circleci/continuation`](https://circleci.com/developer/orbs/orb/circleci/continuation) orb,
  where an early job computes a value and calls `continuation/continue` with a config whose
  `workflows:` block is shaped by that value. See [ROADMAP.md](ROADMAP.md)'s "Workspace /
  parallelism fit" for why this wasn't built as an orb feature.
