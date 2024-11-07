# Arbiters
Repository for developing and testing arbiters for [The Compact](https://github.com/Uniswap/the-compact).

Ensure that [Foundry](https://book.getfoundry.sh/getting-started/installation) and [Supersim](https://supersim.pages.dev/getting-started/installation) are both installed.

To start Supersim and deploy The Compact (Version 0) to each chain, run:
```sh
$ ./bootstrap.sh
```

Arbiter implementations should be placed into `src/[project]/arbiter/[name].sol` for the main arbiter interfacing with The Compact on the origin chain, `src/[project]/*/*.sol` for any ancillary contracts on the destination chain as well as project-specific bridge contracts, gateways, or other facilities. Then, associated deployments + tests should be structured as scripts so they can be incorporated into the Supersim test framework.