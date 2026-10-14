# IMPORTANT!

To keep the `grate` project healthy and sustainable, we have made the decision to move from `erikbra/grate` to `grate-devs/grate`.

Please update your remote URLs to point to the new location:

| Platform   | Old location  | New location     |
| ---------- | ------------- | ---------------- |
| Github org | erikbra/grate | grate-devs/grate |
| NuGet      | erikbra.grate | grate-devs.grate |
| DockerHub  | erikbra/grate | no change        |


# grate

SQL scripts migration runner 

[![CI](https://github.com/grate-devs/grate/actions/workflows/ci.yml/badge.svg)](https://github.com/grate-devs/grate/actions/workflows/ci.yml)
[![Build](https://github.com/grate-devs/grate/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/grate-devs/grate/actions/workflows/build.yml)
[![Integration tests](https://github.com/grate-devs/grate/actions/workflows/integration-tests.yml/badge.svg)](https://github.com/grate-devs/grate/actions/workflows/integration-tests.yml)

## Example workflow runs

Below are examples on how to integrate grate in your workflow in different CI systems.

| Build pipeline | Last run                                                                                                                                                                                    | Build definition                                                                                                                    |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Github actions | [![Example grate workflow](https://github.com/grate-devs/grate/actions/workflows/grate-workflow.yml/badge.svg)](https://github.com/grate-devs/grate/actions/workflows/grate-workflow.yml)   | [/examples/github-actions/grate-workflow.yml](https://github.com/grate-devs/grate/blob/main/.github/workflows/grate-workflow.yml)   |
| Azure DevOps   | [![Build Status](https://dev.azure.com/my-grate/grate/_apis/build/status/erikbra.grate?branchName=main)](https://dev.azure.com/my-grate/grate/_build/latest?definitionId=1&branchName=main) | [/examples/AzureDevops/azure-pipelines.yml](https://github.com/grate-devs/grate/blob/main/examples/AzureDevops/azure-pipelines.yml) |

## Goal

The goal of grate is to be largely backwards compatible with RoundhousE, which is an amazing tool. It is initiated by the main
maintainer of RoundhousE for the last three years, please see this issue in the RoundhousE repo for details: https://github.com/chucknorris/roundhouse/issues/438.

While early versions of grate may not support every last RoundhousE feature, those features that are implemented should work identically, or with only very small changes.  For detailed information see the [migration](docs/MigratingFromRoundhousE.md) docco.

## Docs

Full documentation is available [on the grate site](https://grate-devs.github.io/grate/).

For coding agents working in projects that use grate, see the [use-grate skill](skills/use-grate/SKILL.md) and its [usage and verification guide](docs/AgentSkill.md).

## Why the name grate?

grate is short for migrate. And it's also pronounced the same way as _great_, so, there you go. 

## Status

grate is catching up on RoundhousE features, there are a couple of features missing, they are documented in unit tests. But I've successfully replaced 
RoundhousE with grate in a 5-year-in-development folder of SQL scripts, without any issues. 

## Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md)
