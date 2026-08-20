# Roadmap / deferred design decisions

This file records the things a recent audit of the `cci-labs` ecosystem-bridge orb family
(2026-08) found worth doing to `bitbucket-pipes-orb`, but that this orb deliberately does **not**
do, and why. The decision is visible in the repo instead of living only in a chat transcript or a
PR description that ages out. It also carries forward the reasoning behind a handful of
scope/design calls that already shipped, so a future contributor doesn't have to re-derive "why is
it built this way" from scratch.

None of the items below are secretly half-built. If you pick one up, treat this as the starting
brief, not a patch to apply.

## Deferred / not implemented

### 1. Chaining more than one pipe per orb call

**What it would do:** let a single `bitbucket/pipe` call (or a new aggregate) run more than one
pipe in sequence, the way a real Bitbucket pipeline's `script:` list can name several `- pipe:`
entries under one step.

**Why it's deferred:** this orb's scope is deliberately "one pipe, not a pipeline" (see
[ARCHITECTURE.md](ARCHITECTURE.md)'s "Scope" section). Every real need so far has been satisfiable
by calling this orb's commands more than once in the same job, interleaved with whatever native
steps you want between them (see
[`src/examples/chain_two_pipes.yml`](../src/examples/chain_two_pipes.yml)).

**What shipped instead:** the four commands (`create-output-file`, `map-env`, `run-pipe`,
`collect-outputs`) are already layered specifically so this could be added later without a
breaking change; see "Command-split decisions" below. `skip-map-env` on later calls avoids
redundant work when chaining today.

**If someone picks this up:** the underlying commands don't need to change shape. What's missing
is a convenience aggregate (or a `pipes:` list-shaped parameter) that drives the same four-stage
loop once per pipe instead of requiring the caller to write it out by hand each time.

### 2. A `docker` executor (instead of `machine`-only)

**What it would do:** let `bitbucket/pipe` run on CircleCI's `docker` executor with
`setup_remote_docker`, which many users would reach for first since it's cheaper and starts faster
than `machine`.

**Why it's deferred:** `setup_remote_docker` runs its Docker daemon in a separate remote VM with no
filesystem shared with the job. Bind mounts silently don't work there, and CircleCI's own docs
point at `docker cp` instead. Making this orb work there would mean copying the whole checkout into
the remote environment before the pipe runs and copying the workspace and outputs back out
afterward: a slower, materially riskier second code path this project has not built or verified.

**What shipped instead:** [LIMITS.md](LIMITS.md) states this plainly and points at `machine` as
the only supported executor, rather than silently producing broken bind-mount behavior on
`docker`.

**If someone picks this up:** the `docker cp`-based copy-in/copy-out path is the real design work
here. It isn't a small tweak; it's a second execution mode with its own correctness questions
(what if the pipe writes large output? what about the pipe-storage scratch dirs?) that would need
the same level of real-CI verification this orb's `machine` path already has.

### 3. `BITBUCKET_STEP_OIDC_TOKEN` and deployment-environment variables

**What it would do:** synthesize `BITBUCKET_STEP_OIDC_TOKEN` (for a pipe that federates to
AWS/GCP via Bitbucket's own OIDC issuer) and `BITBUCKET_DEPLOYMENT_ENVIRONMENT`/
`BITBUCKET_DEPLOYMENT_ENVIRONMENT_UUID` (for a pipe that branches on Bitbucket's deployment
environments).

**Why it's deferred:** unlike the synthesized identity UUIDs elsewhere in the variable-mapping
table (placeholders that let a pipe's presence/uniqueness check pass without lying about their
value), a fake OIDC token would be actively misleading rather than just a placeholder, and no
CircleCI concept maps onto Bitbucket's deployment environments at all.

**What shipped instead:** both are documented as left unset in [LIMITS.md](LIMITS.md), with the
real workaround for OIDC-federated pipes named explicitly (long-lived credentials via
`variables:`/CircleCI contexts instead) rather than a synthesized value that would silently fail
differently.

**If someone picks this up:** CircleCI's own native OIDC tokens
(`circleci.com/docs/openid-connect-tokens`) are the right building block for a pipe that's
rewritten to trust CircleCI's issuer instead of Bitbucket's, the same rework path the sibling
`buildkite` orb documents for its own `oidc` shim gap.

### 4. Resolving a Bitbucket-hosted pipe reference (`account/repo:tag`) to a Docker image

**What it would do:** accept the same `account/repo:tag` reference real Bitbucket Pipelines YAML
uses under `pipe:`, and resolve it to the pipe's actual Docker image yourself.

**Why it's deferred:** a locked design decision, not an oversight. This orb does zero
image-resolution of its own anywhere (see [LIMITS.md](LIMITS.md)'s "Immutable pinning": `image`
always passes through to `docker run` verbatim). Building a resolver for this one reference format
would be the only resolution logic in the whole orb, inconsistent with every other input this orb
accepts literally.

**What shipped instead:** [MIGRATING.md](MIGRATING.md) tells you how to find the real image
yourself: check the pipe's own `pipe.yml` `image:` field, or run `docker run --rm --entrypoint cat
<image> /pipe.yml` against any candidate image to read its baked-in metadata.

## Limitations reassessment (2026-08)

Four cross-cutting questions came up while auditing this orb against its `cci-labs` siblings. Each
was already answered somewhere in this orb's design; this section is where that reasoning lives
now, instead of being spread across README prose a user has to hunt for.

### Image caching economics

The `default` executor's `docker_layer_caching` parameter defaults to **off**. The vast majority of
real `bitbucketpipelines/*` images are well under 70MB (`demo-pipe-bash` is 4MB, `git-secrets-scan`
51MB, `slack-notify` 54MB, `aws-cloudformation-deploy` 69MB, checked directly against Docker Hub
while researching this orb) and pull in low single-digit seconds; DLC's own fixed overhead
plausibly exceeds that, so it isn't worth turning on for these. Larger images (several hundred MB
to multi-GB: browser/ML/Android-class pipes) are where DLC's per-layer reuse starts to pay off over
a full `docker pull` every run. There's no separate `docker save`/`load` caching mechanism in this
orb on top of DLC. It would be redundant with, and strictly worse than (all-or-nothing per exact
tag, versus DLC's per-layer reuse), a feature that already ships. This is also a plan-gated, billed
CircleCI feature; check plan eligibility before relying on it. See [LIMITS.md](LIMITS.md)'s
"Caching the pipe image" section for the current user-facing guidance.

### Command-split decisions

`pipe` decomposes into four separate, composable commands (`create-output-file`, `map-env`,
`run-pipe`, `collect-outputs`) specifically so you can call them yourself with native steps in
between, and so a future version could chain more than one pipe per job (see item 1 above) without
a breaking change. `pipe` is just the common case, pre-assembled. `create-output-file` truncates
its output-variables file on every call, which is exactly why chaining today means giving each
pipe its own `output-file` rather than reusing one path. See [ARCHITECTURE.md](ARCHITECTURE.md)'s
"How it works" and [COMMANDS.md](COMMANDS.md)'s "Commands and job reference" sections for the
current mechanism and worked example.

### Workspace / parallelism fit

This orb's output-export mechanism (the pipe's output-variables file, read into `$BASH_ENV`) is
job-scoped, exactly like any other `$BASH_ENV` export on CircleCI. It doesn't cross a job boundary
on its own, and no orb change was built to make it do so. Passing a pipe's output value to a
downstream job is already fully solved with zero orb changes: write it to a file,
`persist_to_workspace` it, `attach_workspace` downstream. Branching which jobs run, based on an
upstream job's runtime output, was considered and explicitly not solved here. CircleCI has no
native construct for a genuine workflow-level conditional at all, orb or no orb; the closest real
mechanism is a setup workflow plus the `circleci/continuation` orb, and there is no lighter-weight
substitute available today. See [MIGRATING.md](MIGRATING.md)'s "Passing pipe output across jobs"
section for the current worked examples of both mechanisms.

### Vendor-image layering

Checked directly against Docker Hub while researching this orb's vendor-image options: every
Bitbucket Pipe is already its own purpose-built image, the same structural story as the sibling
`harness` orb. `run-pipe` just `docker run`s it, and there is no generic Bitbucket base image to
layer in underneath that. Atlassian's own `atlassian/default-image` is the outer Bitbucket Cloud
build-step container (what plain `script:` commands run in on real Bitbucket), not something a
Pipe runs inside, so it doesn't fix anything here; this orb never executes user code in that outer
layer at all. The one place a real difference shows up is documented as a migration aid, not a
layering decision: [MIGRATING.md](MIGRATING.md)'s "Matching Bitbucket Cloud's own default
build-step tools" shows how to reach for `atlassian/default-image` yourself in a
`pre-steps`/`post-steps` step if you're porting a plain shell command that used to run in Bitbucket
Cloud's default container, not a Pipe.
