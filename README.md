# Bitbucket Pipes Orb (Unofficial)

[![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/bitbucket-pipes-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/bitbucket-pipes-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/bitbucket.svg)](https://circleci.com/developer/orbs/orb/cci-labs/bitbucket) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/bitbucket-pipes-orb/main/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

Run a single [Bitbucket Pipe](https://bitbucket.org/product/features/pipelines/integrations),
any Docker image built to the Bitbucket Pipelines pipe contract, as one step inside an
otherwise-native CircleCI job or workflow. It exists so a team with a pipe it already likes (an
Atlassian one, or its own) can bring that work to CircleCI with no rewrite: the pipe's own
`variables:` reach it under their real Bitbucket names, CircleCI's build context is mapped onto
the `BITBUCKET_*` variables the pipe actually reads, and anything the pipe writes back comes out
into native CircleCI steps.

---
**Disclaimer:**

CircleCI Labs, including this repo, is a collection of solutions developed by members of
CircleCI's field engineering teams through our engagement with various customer needs.

-   ✅ Created by engineers @ CircleCI
-   ⚠️ **Not yet used by production CircleCI customers.** This orb is newly published, with no production track record yet. What *is* verified: a real, credential-free pipe (`bitbucketpipelines/git-secrets-scan`, a genuine gitleaks scan) runs green in this repo's own CI, including a real CircleCI-checkout incompatibility this orb's own test discovered and worked around (`GITLEAKS_COMMAND=dir`, see `.circleci/test-deploy.yml`).
-   ❌ **not** officially supported by CircleCI support

---

## Table of contents

- [Quick start](#quick-start)
- [Capabilities](#capabilities)
- [Limits](#limits)
- [Resources](#resources)
- [How to contribute](#how-to-contribute)
- [How to publish an update](#how-to-publish-an-update)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how it works, the command pipeline, the native primary-container execution model
- [docs/GETTING-STARTED.md](docs/GETTING-STARTED.md): a fuller walkthrough with more examples and executor choices
- [docs/COMMANDS.md](docs/COMMANDS.md): the complete command and job reference, every parameter
- [docs/MIGRATING.md](docs/MIGRATING.md): mapping a real Bitbucket Pipelines pipe step onto this orb
- [docs/LIMITS.md](docs/LIMITS.md): the full limits, gotchas, and trust notes
- [docs/ROADMAP.md](docs/ROADMAP.md): items deliberately scoped out, with the reasoning kept

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

That's it: no Bitbucket account, no Bitbucket Pipelines runner, and no rewrite of the pipe itself.
See [docs/GETTING-STARTED.md](docs/GETTING-STARTED.md) for the command form, private images,
array variables, and interleaving native steps around the pipe.

## Capabilities

| Command / job | What it does | Full reference |
|---|---|---|
| `pipe` (command, job) | Run one pipe via a real `docker run`: `variables:` pass through under literal Bitbucket names, output lands in `$BASH_ENV`, `store_test_results` runs by default. | [docs/COMMANDS.md](docs/COMMANDS.md) |
| `create-output-file`, `map-env`, `run-pipe`, `collect-outputs` | The four commands `pipe` composes, callable individually for chaining or interleaving native steps. | [docs/COMMANDS.md](docs/COMMANDS.md) |
| `pipe-native` (command, job) | Runs a pipe image as the job's own primary container instead of via `docker run`. No `machine` VM boot, but no `--user` control and no chaining multiple pipe images. | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#the-native-primary-container-path) |

See [docs/COMMANDS.md](docs/COMMANDS.md) for every parameter, and
[docs/MIGRATING.md](docs/MIGRATING.md) for how a real Bitbucket Pipelines step maps onto this orb.

## Limits

- **One pipe per orb call.** By design; see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#scope-one-pipe-not-a-pipeline).
- **No Bitbucket-hosted pipe references (`account/repo:tag`).** Point `image:` at the pipe's real
  Docker image reference; see [docs/LIMITS.md](docs/LIMITS.md).
- **No `BITBUCKET_STEP_OIDC_TOKEN` or deployment-environment variables.** No CircleCI equivalent
  exists, and none is synthesized. See [docs/LIMITS.md](docs/LIMITS.md).
- **The native primary-container path can't run `--user`-forced pipes or chain two different pipe
  images in one job.** Use `pipe`/`bitbucket/pipe` for those cases.

Full detail, the exact preflight refusal messages, and the two variable-name denylists this orb
enforces are in [docs/LIMITS.md](docs/LIMITS.md).

## Resources

[CircleCI Orb Registry Page](https://circleci.com/developer/orbs/orb/cci-labs/bitbucket): the
official registry page of this orb for all versions, executors, commands, and jobs described.

[CircleCI Orb Docs](https://circleci.com/docs/orb-intro/#section=configuration): docs for using,
creating, and publishing CircleCI orbs.

[Bitbucket Pipes reference](https://support.atlassian.com/bitbucket-cloud/docs/): Atlassian's own
pipe docs, including the "Default variables" and step `output-variables` reference pages this
orb's env mapping and output handling are built from.

## How to Contribute

We welcome [issues](https://github.com/CircleCI-Labs/bitbucket-pipes-orb/issues) and [pull
requests](https://github.com/CircleCI-Labs/bitbucket-pipes-orb/pulls) against this repository! See
[docs/ROADMAP.md](docs/ROADMAP.md) for items deliberately scoped out of past passes, with the
reasoning recorded rather than lost.

**CircleCI CLI version floor: `>= 1.0.48254`.** Older CLI builds silently pack this orb's
`<<include(...)>>` directives as literal text instead of expanding them, producing a broken orb
that can still pass `circleci orb validate`: a false green with no other symptom. Run
`scripts/check-circleci-cli-version.sh` (also wired into `.circleci/config.yml`'s `lint-pack`
workflow) before packing locally if you're not sure which build you have.

**`pre-steps`/`post-steps` are reserved job-parameter names.** `circleci orb validate` rejects a
job parameter literally named `pre-steps` or `post-steps` outright. This only surfaces under `orb
validate`, which needs a token, so a plain `circleci config validate`/pack will not catch it. If
you're adding a new job parameter, don't pick either name.

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
6. Click _"Publish Release"_. This pushes the tag and triggers the publishing pipeline.
