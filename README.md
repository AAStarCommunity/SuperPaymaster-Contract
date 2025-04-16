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
- So, we will get a **decentralized gas sponsor network, a competitive gas sponsor market and a simple gas card**.

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

## Components we add (PoC)
1. Stake module: Contract balance account stake management
2. Verify and Pay: paymasterAndData Signature verification, payment, record and balance record change(follow ERC4337, nochange on original flow,just enhance verification to adapt permissionless nodes public key ).
3. Post Processing: Transaction success post processing: reputation increase, TODO, ERC7253
4. Compensation: Asynchronous transaction status compensation: failed and successful re-check, proof submission and reputation modification (off-chain, call on-chain method) TODO

### V0.7 Flow
```mermaid
sequenceDiagram
    participant User as User/Wallet
    participant SDK as Wallet SDK
    participant Bundler as Bundler (Ultra Relay)
    participant EP as EntryPoint Contract
    participant SP as SuperPaymaster Contract
    participant SponsorRelay as Sponsor Relay (Signer)
    participant SponsorERC20 as Sponsor's ERC20

    User->>SDK: Initiate action (e.g., transfer)
    SDK->>SDK: Construct UserOperation (calldata, etc.)
    SDK->>SponsorRelay: Request gas sponsorship (UserOp hash, max ERC20 cost, token)
    SponsorRelay->>SponsorRelay: Verify user eligibility (off-chain)
    SponsorRelay->>SponsorRelay: Prepare signature data (userOpHash, SP addr, sponsor, token, maxErc20Cost, timestamps, chainId)
    SponsorRelay->>SponsorRelay: Sign data with Sponsor's configured key
    SponsorRelay->>SDK: Return signature & Paymaster data (sponsor addr, token, maxErc20Cost, timestamps, signature)
    SDK->>SDK: Add paymasterAndData to UserOperation
    SDK->>Bundler: Submit UserOperation (eth_sendUserOperation)

    Bundler->>Bundler: Receive UserOp
    Bundler->>Bundler: Basic Validation (sig length, gas limits etc.)
    Bundler->>SP: **[Bundler Check 1]** Read sponsorStakes(sponsor)
    Bundler->>Bundler: **[Bundler Check 2]** Decode paymasterAndData, get sponsor, estimate maxEthCost
    Bundler->>Bundler: **[Bundler Check 3]** Check onChainStake >= pendingCost[sponsor] + maxEthCost
    alt Insufficient Stake in Bundler Check
        Bundler-->>SDK: Reject UserOp (stake limit)
    else Sufficient Stake
        Bundler->>Bundler: Add maxEthCost to pendingCost[sponsor]
        Bundler->>EP: Simulate Validation (eth_estimateUserOperationGas or simulateValidation)
        EP->>SP: call validatePaymasterUserOp(userOp, userOpHash, maxCost)
        SP->>SP: Decode paymasterAndData
        SP->>SP: Check config (enabled, token match)
        SP->>SP: Verify Signature (ecrecover)
        SP->>SP: Calculate maxEthCost from maxErc20Cost & rate
        SP->>SP: Check sponsorStakes[sponsor] >= maxEthCost (Contract Check)
        alt Validation Failed in Contract
            SP-->>EP: Revert (e.g., bad sig, insufficient stake)
            EP-->>Bundler: Simulation Failed
            Bundler-->>SDK: Reject UserOp (simulation failed)
            Bundler->>Bundler: Remove cost from pendingCost[sponsor]
        else Validation Succeeded in Contract
            SP-->>EP: Return context, validationData (timestamps)
            EP-->>Bundler: Simulation OK (return gas estimates)
        end
        Bundler->>Bundler: Add valid UserOp to Mempool / Bundle
    end

    opt Bundle Inclusion
        Bundler->>EP: Send Bundle (handleOps)
        EP->>EP: Iterate UserOps in Bundle
        EP->>SP: call validatePaymasterUserOp (again, pre-execution check)
        SP->>SP: (Performs checks again)
        SP-->>EP: Return context, validationData
        EP->>userOp.sender: Execute UserOperation (CALL userOp.callData)
        opt UserOp Execution Fails
             EP->>SP: call postOp(mode=opReverted, context, 0)
             SP->>SP: Handle revert (usually no stake change)
             SP-->>EP: Return
        else UserOp Execution Succeeds
            EP->>EP: Calculate actualGasCost
            EP->>SP: call postOp(mode=opSucceeded, context, actualGasCost)
            SP->>SP: Decode context (get sponsor, token, userOpHash etc.)
            SP->>SP: Check actualGasCost <= maxEthCost
            SP->>SP: Check sponsorStakes[sponsor] >= actualGasCost
            SP->>SP: **Deduct actualGasCost from sponsorStakes[sponsor]**
            SP->>SP: Emit SponsorshipSuccess(...)
            SP->>SP: Check & Emit StakeWarning(...) if needed
            SP-->>EP: Return (signals successful payment)
        end
        EP->>Bundler: Pay Bundler Fee (from EP stake)
        Bundler->>Bundler: **Remove processed UserOp costs from pendingCost[sponsor]**
    end
```

#### Description

1.  **用户发起操作:** 用户通过钱包发起一个需要 Gas 的操作。
2.  **SDK 构建 UserOp:** 钱包 SDK 构建基础的 `UserOperation`。
3.  **请求赞助:** SDK 向配置好的 Sponsor Relay Server 发送请求，包含 `UserOperation` 哈希、用户愿意支付的最大 ERC20 代币数量及其地址。
4.  **Relay 签名:** Relay Server 验证用户资格（可选，链下逻辑），然后使用 Sponsor 在 SuperPaymaster 合约中配置的授权签名密钥，对包含 `userOpHash`、Paymaster 地址、Sponsor 地址、Token 地址、最大 ERC20 成本、时间戳和链 ID 等信息的数据进行签名。
5.  **SDK 组装:** SDK 收到签名和相关数据（Sponsor 地址、Token、最大成本、时间戳），将其编码后放入 `UserOperation` 的 `paymasterAndData` 字段。
6.  **提交 Bundler:** SDK 将完整的 `UserOperation` 提交给 Bundler。
7.  **Bundler 验证:**
    * Bundler 收到 UserOp 并进行基本检查。
    * **关键:** Bundler 识别出这是一个 SuperPaymaster 的 UserOp，解析出 Sponsor 地址，并**调用 SuperPaymaster 合约查询该 Sponsor 当前的链上质押余额**。
    * Bundler **检查其内部维护的该 Sponsor 的待处理成本 (`pendingCost`)**，确保 `链上余额 >= pendingCost + 当前 UserOp 的预估最大 ETH 成本`。
    * 如果 Bundler 检查失败，拒绝 UserOp。
    * 如果成功，Bundler 将当前 UserOp 的成本加入 `pendingCost[sponsor]`，然后**模拟验证流程** (`eth_estimateUserOperationGas` 或 `simulateValidation`)。
8.  **合约验证 (模拟):**
    * EntryPoint 调用 SuperPaymaster 的 `validatePaymasterUserOp`。
    * SuperPaymaster 解码数据，检查 Sponsor 配置，验证 Relay Server 的签名，计算最大 ETH 成本，并**再次检查 Sponsor 的链上余额**。
    * 如果验证失败，模拟失败，Bundler 拒绝 UserOp 并更新 `pendingCost`。
    * 如果成功，模拟成功，Bundler 获得 Gas 估算并将 UserOp 加入内存池或待打包的 Bundle。
9.  **打包上链:**
    * Bundler 将 Bundle 提交给 EntryPoint 的 `handleOps`。
    * EntryPoint 再次调用 `validatePaymasterUserOp` 进行最终验证。
    * EntryPoint 执行用户的 `callData`。
    * **执行后:** EntryPoint 调用 SuperPaymaster 的 `postOp`。
10. **支付与结算 (`postOp`):**
    * SuperPaymaster 根据 `context` 找到 Sponsor。
    * 验证并从该 Sponsor 的内部 `sponsorStakes` 映射中**扣除实际发生的 `actualGasCost`**。
    * 触发 `SponsorshipSuccess` 事件。
    * 检查余额是否低于阈值，如果低于则触发 `StakeWarning` 事件。
    * `postOp` 成功返回。EntryPoint 从 SuperPaymaster 在 EntryPoint 的总存款中扣除 Gas 费用，并支付给 Bundler。
11. **Bundler 清理:** Bundler 在确认 Bundle 上链后，清理其内部 `pendingCost` 中与已处理 UserOp 相关的金额。





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
