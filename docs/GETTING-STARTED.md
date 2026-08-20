# Getting started

A fuller walkthrough of `bitbucket-pipes-orb` beyond the README's quick start: more runnable
examples, how to interleave native CircleCI steps around a pipe, and how to choose between the two
execution paths.

## Minimal example

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
See [`src/examples/`](../src/examples/) for the command form (inline among native steps), private
images, array variables, and pre/post-step interleaving.

## Interleaving native CircleCI steps around the pipe

The `pipe` job (only when invoked from a workflow's `jobs:` list, not the `pipe` command inside
another job's own `steps:`) also accepts CircleCI's own built-in `pre-steps`/`post-steps`
arguments, available on every 2.1+ job and not something this orb declares. Pass them at the call
site:

```yaml
- bitbucket/pipe:
    image: bitbucketpipelines/demo-pipe-bash:0.1.0
    pre-steps:
      - run: echo "before checkout AND before the pipe"
    post-steps:
      - run: echo "after the pipe; its outputs are already in $BASH_ENV"
```

**One real platform caveat:** `pre-steps` run before every step in the job, including this job's
own internal `checkout`, not just before the pipe. If a pre-step needs the repo checked out, do
that checkout yourself inside the pre-step, or use the `pipe` command with native steps around it
instead (see [`src/examples/`](../src/examples/)).

## Choosing an executor: docker-run vs. native primary container

`bitbucket/pipe` runs on `machine` and does a real `docker run` of the pipe image: use it when you
need `--user` control over the container's runtime user, when you're chaining more than one pipe
image in the same job, or when you just want the well-tested default path.

`bitbucket/pipe-native` skips the `machine` VM boot and the `docker run` entirely by giving the
pipe's own image straight to a `docker` executor as the job's primary container: use it when the
pipe needs no Docker daemon of its own, doesn't need root-forcing, and you only need one pipe image
for the whole job. See [ARCHITECTURE.md](ARCHITECTURE.md) for how that path works and
[LIMITS.md](LIMITS.md) for exactly what it gives up in exchange.
