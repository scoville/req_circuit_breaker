# Contributing

Thanks for helping out. Issues and pull requests are both welcome.

## Security

Please do not open a public issue for a vulnerability. [SECURITY.md](SECURITY.md)
explains how to report one privately.

## Getting started

```bash
mix deps.get
mix test
```

The suite needs no network access. Every request goes through a `Req.Test`
stub.

## Running the checks

Run what CI runs before you push:

```bash
mix precommit
```

## Pull requests

For a new feature, or a change to how an existing one behaves, please open an
issue first so we can agree on the shape before you write it. For bug fixes,
documentation and typo fixes, you can open a PR directly.

If an issue exists, reference it in the pull request, for example
`resolves #123`. Add a test that covers the change, and for a bug fix one that
fails without it. Add a changelog entry if the change is user-facing.

Commit messages follow no particular convention. Keep the first line under 72
characters, write it in the present tense, and say what the commit does: "add
option to read the circuit without the server" rather than "added option" or
"fixes". The existing history is a reasonable guide.

## Tests that share a breaker

A circuit breaker is state outside the test process. Tests that install a
breaker under the same name cannot run concurrently. Name the breaker after the
test and remove it in `on_exit`.
