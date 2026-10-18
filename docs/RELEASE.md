# Releasing Mutalisk

The current candidate is version `0.1.0` in `mix.exs`. Building a package does
not publish it. Publication is a manual release step.

## Validate the release commit

Run `bash bin/verify`. It checks formatting, warning-free compilation, Credo,
unit and fixture tests, Dialyzer, golden fixtures, both execution engines,
end-to-end mutation testing, warning-free documentation, and the Hex package.
CI must also pass for the exact release commit on its Elixir 1.19 and 1.20 / OTP
28 matrix. Local checks on another Elixir version do not replace that matrix.

Inspect `mutalisk-0.1.0.tar`: it must contain runtime code, the public Mix task,
compiler integration, `mix.exs`, README, license, changelog, and mutator catalogue.
Development tasks, tests, caches, benchmark results, and maintainer docs are
excluded. Extract the package and test it as a dependency of a fresh project:
compile, run ordinary tests, and exercise both mutation engines. This catches
missing package files that repository tests cannot detect.

Confirm the version, changelog, Apache-2.0 metadata, and public GitHub source URL.
The supported API consists of the documented task, configuration, reports, and
`Mutalisk` runtime helpers; internal `Mut.*` modules are not a compatibility
commitment. Incremental execution remains opt-in.

## Publish

After the release commit is merged, pushed, and green in CI, create and push the
matching `v0.1.0` tag. HexDocs source links use that tag, so it must exist before
docs are published.

Authenticate with `mix hex.user auth`, then run `mix hex.publish` from the
verified release commit. Review the metadata and file list before confirming.
This publishes both the package and documentation. Use `mix hex.publish docs`
only when intentionally republishing documentation separately.

See the [Hex publishing guide](https://hex.pm/docs/publish) for account setup and
publication commands. Verify the released version and documentation on Hex
and HexDocs after publication.
