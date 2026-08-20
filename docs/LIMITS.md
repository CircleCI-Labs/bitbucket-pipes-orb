# Limits, gotchas, and trust notes

The full list of what doesn't work through this orb, the security tradeoffs worth understanding
before you turn a knob, and the gotchas found while building and testing it.

## The literal-naming tradeoff: two small denylists

Because `variables:`/`extra-env-mapping:`/a pipe's own output-variables file all accept
Bitbucket's literal, unprefixed names, and this orb's whole point is running third-party (and
potentially untrusted) vendor images, "any identifier is a valid Bitbucket variable name" would
otherwise let a value collide with something that isn't a Bitbucket variable at all:

- **Reserved shell-control names** (`PATH`, `IFS`, `BASH_ENV`, `ENV`, `LD_PRELOAD`,
  `LD_LIBRARY_PATH`, and similar) are rejected, warn-and-skip, same as a malformed line, by
  `extra-env-mapping` and by the pipe's own output-variables file. Both of those sinks write into
  `$BASH_ENV`, which every later native step in the job sources; a pipe container (or a copy-paste
  mistake) naming one of these would otherwise rewrite the shell environment for the rest of the
  job. This does not apply to the plain `variables:` parameter: those values only ever reach the
  pipe's own container via `docker run -e`, never `$BASH_ENV`, so they carry no such risk and keep
  the fully literal, unrestricted contract.
- **The four paths this orb itself bind-mounts** (`BITBUCKET_CLONE_DIR`,
  `BITBUCKET_PIPELINES_VARIABLES_PATH`, `BITBUCKET_PIPE_STORAGE_DIR`,
  `BITBUCKET_PIPE_SHARED_STORAGE_DIR`) are rejected the same way if a `variables:` line names one.
  As a structural backstop, `run-pipe`'s own authoritative `-e` for each of these four is always
  emitted last, so Docker's real last-`-e`-wins behavior can't be used to desync a pipe's belief
  about these paths from the actual bind-mount target even if the denylist check above were
  somehow bypassed.

Neither denylist restricts any real Bitbucket usage: no official or third-party pipe declares an
input or output variable literally named `PATH`, `BASH_ENV`, or one of the four bind-mount paths
above. Those are either shell internals or platform-set constants a pipe reads, never a
`variables:` key a pipeline author sets.

**No output value is ever masked in logs.** Unlike CircleCI's own context/project secrets (which
CircleCI's log masking redacts by exact match), a pipe's output-variables file, `variables:`
values, and anything `extra-env-mapping` sets are printed and passed through in plain text. Treat
every value that reaches this orb, in either direction, as public log content.

## What genuinely doesn't work

- **Bitbucket-hosted pipe references (`account/repo:tag`)**: this orb only runs `docker://`-style
  image references, passed to `docker run` verbatim, per this project's locked design decision to
  do zero image-resolution of its own. Point `image:` at the pipe's real Docker image (check its
  `pipe.yml` `image:` field, or run `docker run --rm --entrypoint cat <image> /pipe.yml` against
  any candidate image to read its baked-in metadata). See [ROADMAP.md](ROADMAP.md) item 4.
- **`BITBUCKET_STEP_OIDC_TOKEN`**: no CircleCI equivalent exists, and none is synthesized (unlike
  the identity UUIDs in [MIGRATING.md](MIGRATING.md), a fake token would be actively misleading,
  not just a placeholder). A pipe that authenticates to AWS/GCP via Bitbucket's OIDC federation
  cannot do so through this bridge; give it long-lived credentials via `variables:`/CircleCI
  contexts instead, if the pipe supports that. See [ROADMAP.md](ROADMAP.md) item 3.
- **`BITBUCKET_DEPLOYMENT_ENVIRONMENT` / `BITBUCKET_DEPLOYMENT_ENVIRONMENT_UUID`**: no CircleCI
  concept maps onto Bitbucket's deployment environments, so these are left unset rather than
  guessed. Set them yourself via `extra-env-mapping` if a pipe needs a specific value. See
  [ROADMAP.md](ROADMAP.md) item 3.
- **A `docker` executor**: CircleCI's `docker` executor with `setup_remote_docker` runs its Docker
  daemon in a separate remote VM with no filesystem shared with the job. Bind mounts silently
  don't work there, and CircleCI's own docs point you at `docker cp` instead. Only `machine` is
  supported; use it. See [ROADMAP.md](ROADMAP.md) item 2 for the full reasoning.
- **Root-owned files from the pipe container**: pipe containers run as root by default (matching
  Bitbucket's own real-world behavior). On a real Linux `machine` executor this can leave
  root-owned files in your checkout that break later native steps; set `fix-permissions: true` if
  you hit this. (This specific failure mode does not reproduce under Docker Desktop on macOS,
  whose bind-mount layer transparently remaps container UIDs; it was verified against well-known
  Docker semantics for genuine Linux, not hands-on-reproduced in this project's own testing.)
- **Bitbucket's own output-variables mechanism catches less than you'd expect**: real pipes almost
  never write to `$BITBUCKET_PIPELINES_VARIABLES_PATH`. Across a sample of Atlassian's own
  official pipes, none did. Pipes that do hand data forward mostly write their own file into the
  workspace (documented in that pipe's own README) instead. The good news: since that file is
  inside the bind-mounted workspace already, a later native step can just read it directly with
  zero extra plumbing; you don't need this orb's output-variable mechanism for that at all. Real
  Bitbucket also caps this mechanism at 50 shared variables / 100KB combined (key plus value) per
  pipeline; this orb enforces no equivalent limit of its own. `collect-outputs` exports every line
  in the file unconditionally, minus the reserved-name denylist above.
- **One pipe per orb call**: by design; see [ARCHITECTURE.md](ARCHITECTURE.md)'s "Scope" section.
  The underlying commands are layered so chaining could be added later without a breaking change,
  but that isn't built yet. See [ROADMAP.md](ROADMAP.md) item 1.
- **Pipes that call the Bitbucket Cloud REST API against the running pipeline itself, not just a
  generic cloud provider**: this orb runs a pipe's Docker image, but it never talks to Bitbucket's
  own control plane, so a pipe that expects to reach back into Bitbucket's own pipeline/runner
  APIs has no equivalent here. Two concrete, named examples, checked directly against the real
  `bitbucketpipelines` Docker Hub catalog while researching this orb: `bitbucket-clear-cache`/
  `clear-cache` (calls the Pipelines Caches API, scoped to a real running Bitbucket pipeline's
  cache; there is no equivalent to point it at here, the same shape as the sibling `bitrise` orb's
  Save/Restore Cache Steps limitation) and `runners-autoscaler` (manages Bitbucket's own
  self-hosted-runner fleet via the Cloud API, categorically not something running inside a
  CircleCI step can substitute for). `BITBUCKET_STEP_OIDC_TOKEN` above is the same underlying gap
  in miniature.

## Test results and artifacts

`store_test_results` runs automatically, by default. After the pipe runs, `pipe` (command and job)
calls `store_test_results` against the checkout root (`.`), gated by the `store-test-results`
parameter (default `true`). Real Bitbucket Pipelines auto-scans five fixed glob patterns rooted at
its own clone directory for JUnit XML (`surefire-reports/`, `failsafe-reports/`, `test-results/`,
`test-reports/`, `TestResults/`, each up to 3 levels deep). The checkout root is a safe superset of
all five, since CircleCI's own recursive XML scan doesn't need the exact subfolder names. A pipe
that writes no JUnit XML anywhere makes this a silent no-op, not a failure. Disable it with
`store-test-results: false` if you'd rather call `store_test_results` yourself (for a narrower
path, for example), or if you're calling the `pipe` command more than once in the same job and only
want it after the last call.

There is no equivalent `store-artifacts` default, and that's deliberate. Real Bitbucket has no
fixed artifact directory at all: every pipe declares its own `artifacts:` paths, and those
artifacts are transient (14-day expiry, step-to-step handoff), not a persistent store this orb
could point at. The only directory this orb does own is the bind-mounted checkout root itself (the
same one `store-test-results` scans above), and defaulting `store_artifacts` there would upload the
entire repository on every run: a materially worse default than no default at all. If you know the
specific pipe you're running deposits real output files at a predictable path inside the checkout,
add your own `store_artifacts` step (or `post-steps:` on the `pipe` job) pointed at that path.

## Defaults that deviate from a bare `docker run`

**No deviations found.** Every default this orb sets was checked against what a plain `docker run`
(this orb's own execution mechanism; there's no separate Bitbucket Pipelines CLI to compare
against) or Bitbucket Pipelines' own documented default behavior would already do, and each one
matches rather than deviates: `user` is left empty (pipe containers run as root, matching
Bitbucket's own real-world behavior); `store-test-results` defaults to `true` because real
Bitbucket Pipelines also auto-scans fixed JUnit-XML glob patterns by default, so this orb's default
keeps the two platforms' out-of-the-box behavior aligned rather than introducing a difference;
`clone-dir` defaults to the same path (`/opt/atlassian/pipelines/agent/build`) real Bitbucket
Pipelines itself uses; and there is deliberately no `store-artifacts` default, matching Bitbucket's
own lack of a fixed artifact directory (see "Test results and artifacts" above). Nothing here was
invented to fill out this section; if a genuine deviation is added later, it belongs here.

## Immutable pinning

`image` is passed through verbatim, with no version resolution of any kind. Any reference other
than a full digest pin can silently point at different image content later with no diff in this
repo to review: an omitted tag means `:latest` (the most mutable case), but even an explicit
version tag (`bitbucketpipelines/aws-ecs-deploy:1.15.0`) can be force-moved by the image's own
maintainer. `run-pipe` prints a one-line `WARNING` to the step's stderr whenever `image` doesn't
contain `@sha256:...`, mirroring the identical unpinned-`#ref` warning the sibling `buildkite` orb
already prints for a plugin reference with no ref pinned. To pin by digest, pull the image once
and read its digest back:

```shell
docker pull bitbucketpipelines/aws-ecs-deploy:1.15.0
docker inspect --format '{{.RepoDigests}}' bitbucketpipelines/aws-ecs-deploy:1.15.0
# => [bitbucketpipelines/aws-ecs-deploy@sha256:1a2b3c...]
```

then use that full `image@sha256:...` string as `image`. This is a warning, not an enforced gate.
Pinning is recommended, not required.

## Caching the pipe image

The `default` executor's `docker_layer_caching` parameter (off by default) enables CircleCI's
Docker Layer Caching for the `machine` executor's Docker daemon. This is an opt-in, billed
feature, gated by your CircleCI plan; see [CircleCI's Docker Layer Caching
docs](https://circleci.com/docs/docker-layer-caching/) for current plan eligibility and pricing.
See [ROADMAP.md](ROADMAP.md)'s "Image caching economics" for the rule of thumb on when it's
actually worth turning on.

## Preflight verification drift (native path)

Verified directly (`docker run --entrypoint sh <image>` against each real image, not taken on
faith) against the five images sampled while designing the native path, the results have drifted
from that design pass for the two Bitbucket-flavored ones, confirmed while wiring up this repo's
own CI:

| Image | Preflight verdict (checkout: false) | Why |
|---|---|---|
| `bitbucketpipelines/git-secrets-scan:3.2.0` | Passes | Has everything the custom-image guide requires; entrypoint `python3 /pipe.py`. The only one of the five this repo's own CI runs the full working path against. |
| `plugins/docker` | Refused: `docker-daemon-required` | Ships `dockerd`/`dockerd-entrypoint.sh`, needs `$DOCKER_HOST`. Matches the design pass. |
| `plugins/s3` | Refused: `missing-tool: tar` (also has no `git`/`gzip`) | Fails the very first tool check. Matches the design pass. |
| `bitbucketpipelines/demo-pipe-bash:0.1.0` | Passes with `checkout: false`; refused (`missing-tool: git`) only with `checkout: true` | Drifted from the design pass's "zero CA certificates" call: as of this writing it ships a real roughly 230KB `/etc/ssl/cert.pem`. It does still lack `git`, so this repo's own CI uses it (a real image, not a fixture) for the `checkout: true` missing-`git` branch instead. |
| `plugins/slack` | Passes with `checkout: false` | Also drifted (its "CA bundle is a stub" call no longer holds either). Covered by the sibling `harness-orb`'s own test suite (using its own `checkout: true` git-missing branch), not this repo's. |

That drift is exactly the risk "Immutable pinning" above warns about: neither Bitbucket-flavored
sampled image was pinned by digest, so both floated to different real content between the design
pass and this writing. Net effect: neither of this repo's two Bitbucket-flavored sampled images
currently demonstrates the `missing-ca-certificates` refusal. That branch is still real code with
a still-real test, just not one backed by a still-eligible sampled image; this repo's own CI covers
it with a small synthetic fixture (Alpine with both known CA bundle file paths truncated to empty)
built on the fly instead, documented as a real, current gap rather than silently passed off as
sampled-image coverage.

## What the native path gives up, and what you don't get for free

- **No `--user`/root-forcing control.** The pipe runs as whatever user its own image's Dockerfile
  sets, for the entire job. There is no per-invocation `--user` override the way `run-pipe` has,
  because there is no `docker run` invocation here to attach one to.
- **No chaining two different pipe images in one job.** The primary container is fixed for the
  whole job's lifetime. That's the platform mechanism
  [`chain_two_pipes.yml`](../src/examples/chain_two_pipes.yml) relies on `machine` plus repeated
  `docker run` to get around, and this path structurally cannot.
- **Not cheaper than `setup_remote_docker`.** Since June 2023, CircleCI bills remote Docker at the
  same rate as `machine`. The real saving here is against a `machine`-executor VM's 30-60s boot
  time and its per-second-of-VM billing, at the plain `docker`-executor rate, not against
  `setup_remote_docker` specifically. This only pays off for a pipe that genuinely needs no Docker
  daemon of its own at all.
- **What it does buy:** no `machine` VM boot, the plain `docker`-executor billing rate, and no
  post-run `fix-permissions` chown, because nothing ever wrote into a bind-mounted,
  differently-UID'd container in the first place.
