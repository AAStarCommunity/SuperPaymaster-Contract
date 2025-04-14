# SuperPaymaster v0.2
We finished the basic version v 0.1 in [ETHTaiPei2024](https://taikai.network/ethtaipei/hackathons/hackathon-2024/projects/cltjx090k04c7wc01w1ib9lbi/idea)
Now we launched new version v0.2 with decentralization、seamlessly and community-owned.

We create this based on Account-Abstraction (EIP-4337) singleton EntryPoint release [Entrypoint contract](https://github.com/eth-infinitism/account-abstraction/releases) and Pimlico's [Singleton Paymaster](https://github.com/pimlicolabs/singleton-paymaster)(ZeroDev is also used this version).

For PoC, we use flat version(all in one) to show the structure.
![](https://raw.githubusercontent.com/jhfnetboy/MarkDownImg/main/img/202504141148732.png)

## Why we create SuperPaymaster?
We need a **Decentralized\Seamlessly\Low Cost** paymaster.
Current blockchain gas payments impede widespread adoption due to high costs, complexity, and poor user experience (UX) rooted in HCI challenges. While Account Abstraction (ERC-4337) offers potential, centralized implementations often introduce critical risks like censorship and price manipulation, undermining decentralization.
This paper introduces SuperPaymaster, a novel gas payment system using ERC-4337 and a Standardized Decentralized Service System (SDSS) to create a truly decentralized, competitive, and user-friendly ecosystem. It directly tackles high costs, usability friction, and centralization vulnerabilities. SuperPaymaster provides an open-source framework enabling permissionless Paymaster nodes via a unified contract, fostering competition, supporting diverse ERC-20 gas tokens, and integrating with secure accounts like AirAccount via SDSS for streamlined, secure interactions.
By optimizing gas payments through decentralization and enhanced UX, SuperPaymaster aims to significantly lower entry barriers, improve blockchain interaction efficiency and usability, and ultimately accelerate Web3 adoption. A Proof-of-Concept (PoC) demonstrates the system's feasibility and potential advantages.

## What is the unique feature of the SuperPaymaster?
We provide:
- a Permissionless & Open-Source Paymaster framework permitting anyone to run a paymaster serverice.
- a DePIN solution to run all nodes based on SDSS() with a Rain Computing mode(according to the Cloud Computing).
- a OpenCard&OpenPNTs protocol with any community PNTs as gas token to pay gas with your task getting PNTs.
So, we will get a **decentralized gas sponsor network, a competitive gas sponsor market and a simple gas card**.

## How do we provide these feats?
We use Technology Acceptance Model (TAM) and Human-Computer Interaction (HCI) to guide us on enhancing current solution.
We combine so many technology concepts and operation steps into one daily thing: gas card.
We create a two side market and a community-driven task PNTs system to help normal get negative cost on gas payment.
We build this on Ethereum community open source repositories as mentioned above.

[a collection show on HCI](https://docs.google.com/spreadsheets/d/1g1PlP0TPAyWSWnJJapfoh10z0ury78Y4ls5OL3O2_pc/edit?usp=sharing)
![](https://raw.githubusercontent.com/jhfnetboy/MarkDownImg/main/img/202504141239529.png)


## What is AAStar?
AAStar is a team incubated by Plancker^ community, we focus on Account Abstraction and related topics.
We are trying to sweeping the tech barrier of mass adoption on the Human digital future.
We are Ethereum builder who attracted by the idea: "Human Digital Future".



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
