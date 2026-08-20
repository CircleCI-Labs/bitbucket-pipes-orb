# Commands and job reference

The complete command and job reference for `bitbucket-pipes-orb`, including every parameter. See
[ARCHITECTURE.md](ARCHITECTURE.md) for how these compose, and
[GETTING-STARTED.md](GETTING-STARTED.md) for runnable examples.

## Docker-run path

| Name | Kind | What it does |
|---|---|---|
| `pipe` | command, job | The aggregate most users want: create-output-file, then map-env, then run-pipe, then collect-outputs, then store_test_results, in order. |
| `create-output-file` | command | Creates the output-variables file and the two pipe-storage scratch dirs. Truncates the variables file on every call, so when chaining, give each pipe its own `output-file` rather than reusing one path. |
| `map-env` | command | Exports the `CIRCLE_*` to `BITBUCKET_*` mapping into `$BASH_ENV`. |
| `run-pipe` | command | The `docker run` invocation itself. Named `run-pipe`, not `run`, to avoid colliding with CircleCI's own built-in `run` step. |
| `collect-outputs` | command | Reads the output file back and exports it into `$BASH_ENV`. |

**Reach for the granular commands instead of the `pipe` aggregate when:** you're chaining more
than one pipe in one job (see
[`src/examples/chain_two_pipes.yml`](../src/examples/chain_two_pipes.yml); `skip-map-env` on later
calls avoids redundant work), or you need native steps interleaved between individual stages, for
example inspecting the mapped `BITBUCKET_*` vars before `run-pipe`.

### `pipe` (command and job) parameters

| Parameter | Type | Default | What it does |
|---|---|---|---|
| `executor` *(job only)* | executor | `default` | Must be a `machine` executor. See [LIMITS.md](LIMITS.md). |
| `checkout` | boolean | `true` | Check out the project first. |
| `image` | string | *(required)* | The pipe's Docker image reference, passed to `docker run` verbatim. |
| `variables` | string | `""` | The pipe's `variables:` as multi-line `KEY=VALUE`, literal Bitbucket names. `$SECRET` resolved via `circleci env subst`. |
| `skip-map-env` | boolean | `false` | Skip the `CIRCLE_*` to `BITBUCKET_*` mapping. Most pipes need at least `BITBUCKET_REPO_OWNER`; only skip if you supply everything yourself. |
| `extra-env-mapping` | string | `""` | Multi-line `BITBUCKET_VAR=value` pairs added on top of (and overriding) the built-in mapping. |
| `clone-dir` | string | `/opt/atlassian/pipelines/agent/build` | Container-side path the checkout is bind-mounted at (`$BITBUCKET_CLONE_DIR`). |
| `output-file` | string | `/tmp/bitbucket-pipe-scratch/pipe-output.env` | Host-side path for the pipe's output-variables file. |
| `pipe-storage-dir` | string | `/tmp/bitbucket-pipe-scratch/storage` | Host-side scratch dir mapped to `BITBUCKET_PIPE_STORAGE_DIR`. |
| `pipe-shared-storage-dir` | string | `/tmp/bitbucket-pipe-scratch/shared-storage` | Host-side scratch dir mapped to `BITBUCKET_PIPE_SHARED_STORAGE_DIR`. |
| `user` | string | `""` | Optional `--user` for `docker run` (for example `1000:1000`). Empty means the pipe's container runs as root, matching real Bitbucket. |
| `fix-permissions` | boolean | `false` | `chown` the checkout back to the CircleCI user after the pipe exits. |
| `extra-docker-args` | string | `""` | Extra flags appended to `docker run`, before the image reference. Understand the cost before reaching for one: `--network host` removes the pipe container's network isolation, putting it on the job's own network namespace where it can reach anything bound in the job, including cloud-instance metadata endpoints. It is only necessary when the pipe must reach a server running inside the job container, which a sibling container on the default bridge genuinely cannot do, not as a general fix for connectivity problems. |
| `registry-username` | env_var_name | `BITBUCKET_PIPE_REGISTRY_USERNAME` | Name of the env var holding a private image's registry username. |
| `registry-password` | env_var_name | `BITBUCKET_PIPE_REGISTRY_PASSWORD` | Name of the env var holding a private image's registry password/token. |
| `registry-server` | string | `""` | Registry host to log in to. Empty means Docker Hub. |
| `step-name` | string | `Run Bitbucket pipe` | Name of the `docker run` step. Override when chaining pipes so job-log steps are distinguishable. |
| `store-test-results` | boolean | `true` | Auto-run `store_test_results` against the checkout root after the pipe. |

Individual commands (`create-output-file`, `map-env`, `run-pipe`, `collect-outputs`) expose the
matching subset of these parameters under the same names. See each command's own description on
the [Orb Registry page](https://circleci.com/developer/orbs/orb/cci-labs/bitbucket) for the
exhaustive, always-current list.

### Worked example: composing the granular commands by hand

```yaml
version: 2.1
orbs:
  bitbucket: cci-labs/bitbucket@x.y.z
jobs:
  deploy:
    machine:
      image: ubuntu-2404:current
    steps:
      - checkout
      - bitbucket/create-output-file
      - bitbucket/map-env
      - bitbucket/run-pipe:
          image: bitbucketpipelines/aws-s3-deploy:1.7.0
          variables: |
            AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
            AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
            AWS_DEFAULT_REGION=us-east-1
            S3_BUCKET=my-bucket
            LOCAL_PATH=dist
      - bitbucket/collect-outputs
      - store_test_results:
          path: .
workflows:
  main:
    jobs:
      - deploy
```

## Native primary-container path

See [ARCHITECTURE.md](ARCHITECTURE.md#the-native-primary-container-path) for how this path works
and why it needs a preflight check, and [LIMITS.md](LIMITS.md) for what it gives up.

| Name | Kind | What it does |
|---|---|---|
| `pipe-native` | command, job | The aggregate: preflight-native, then checkout/attach_workspace, then create-output-file, then map-env (reused unmodified), then run-pipe-native, then collect-outputs, then store_test_results. |
| `preflight-native` | command | Refuses an ineligible image with a specific reason. Runs first, always. |
| `run-pipe-native` | command | Execs `entrypoint` as an ordinary `run:` step, with `variables:` exported directly into that step's own process. |
| `native` | executor | `docker` executor whose primary container is the pipe's own `image`. |

`pipe-native`'s `entrypoint` parameter has no default (see ARCHITECTURE.md for why). Every other
parameter mirrors `pipe`'s equivalent under the same name, with `checkout` defaulting to `false`
here (mirrored, not the same value) instead of `true`, and `clone-dir` renamed to
`workspace-root` to make clear it's now a real, unmounted path rather than a bind-mount target.

This is a separate job/command from `pipe`/`bitbucket/pipe`, deliberately, never a parameter flip
on the existing one, so nobody lands in this narrower contract (no `--user`, one image per job,
`preflight-native` gating) by accident.
