# SuperPaymaster v0.2
We finished the basic version v 0.1 in [ETHTaiPei2024](https://taikai.network/ethtaipei/hackathons/hackathon-2024/projects/cltjx090k04c7wc01w1ib9lbi/idea)
Now we launched new version v0.2 with decentralization、seamlessly and community-owned.

We create this based on Account-Abstraction (EIP-4337) singleton EntryPoint release [Entrypoint contract](https://github.com/eth-infinitism/account-abstraction/releases) and Pimlico's [Singleton Paymaster](https://github.com/pimlicolabs/singleton-paymaster)(ZeroDev is also used this version).

For PoC, we use flat version(all in one) to show the structure.
![](https://raw.githubusercontent.com/jhfnetboy/MarkDownImg/main/img/202504141148732.png)

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
