# Solution
## 问题

我们在建设一个开源的SuperPaymaster项目，一个遵守ERC4337协议的paymaster，包括符合erc4337的签名paymaster relay server，一个改进的paymaster合约；对于合约，我们建立了多账户系统，任何想运行自己paymaster，支持自己发行的ERC20 gas token的人，都可以在superpaymaster合约内stake，剩下的由服务来完成。同时我们改造了对应的bundler，可以配合SuperPaymaster合约，进行子账户的stake余额验证（因为签名server是去中心化节点，有作恶，恶意超额滥用额度的可能）。
一些资料：erc4337 paymaser，更多关于paymaster：https://web3auth.io/docs/guides/erc20-paymaster，https://erc4337.mirror.xyz/7DUTUn2eNrjvum3tWAnRih8576IrX13E6WnZeADvAHQ，https://github.com/pimlicolabs/erc20-paymaster，https://medium.com/oak-security/a-deep-dive-into-the-main-components-of-erc-4337-account-abstraction-using-alt-mempool-part-4-ab7dacbf64d4，https://www.alchemy.com/overviews/what-is-a-paymaster，想基于Entrypoint 0.8:https://github.com/eth-infinitism/account-abstraction/releases， 来完成一个SuperPaymaster版本。
我们的问题：
1. 如何设计SuperPaymaster合约，来完成对子账户的stake ETH和提取ETH余额的管理，以及必要的安全验证，提供必要的接口合约来管理和交互。
2. 如何改进开源的bundler，来完成子账户余额校验：https://github.com/AAStarCommunity/ultra-relay （此方案需要研究）
3. 如果有其他可能，例如在superPaymaster合约内，完成签名验证的同时余额验证（需要check是否符合ERC4337的gas sponsor流程，paymaster relay的签名验证，是在使用ecrecover默认，还是使用可自定义的签名验证，如果是ERC1271的可自定义的签名验证，那gas sponsor签名验证就在合约内验证，余额验证是顺便的事情了）
4. SuperPaymaster对ERC20 token的兑换比例和上限额度的配置和管理，就是说子账户stake多少，支持哪一个ERC20 gas token，在确定erc20合约地址和兑换比例后，支付的上限由stake额度决定；当达到上限80%时，要触发event：SuperPaymaster账户0xxxxxxxx需要stake更多，已经到达预警额度20%。
5. 继承自ERC4337的paymaster合约的所有基础能力，我们计划基于Pimlico的开源0.7版本，来完成0.7版本和0.8版本：https://github.com/pimlicolabs/singleton-paymaster/tree/349f1043989306f63c37c3419ba4cca191b205b2
6. 对于gas sponsor支付成功后，先触发event：tx hash sponsor successfuly；然后基于ERC7253，对paymaster的子账户的Reputation进行管理
7. 在此之上，请考虑不影响上述流程的EOA gas sponsor支持：EIP7702，也是0.8 Entrypoint的新特征之一。请给出0.7版本和0.8版本，两个SuperPaymaster合约
8. 低优先级：正常的失败管理和重试、补偿记录，可以基于链下异步来完成，但要有proof
我们已经遵守ERC4337，建立了paymaster relay server和bundler，也完成了基于SimpleAccount的简单合约账户的建立，请调研并给出可行性方案分析，技术方案分析和关键合约的模块设计（继承自Pimlico版本）和实现代码，以及相关的时序图流程文字描述和mermaid图。



## Gemini 2.5 Pro建议方案
好的，这是一个非常有趣且有价值的项目。构建一个多租户、支持多种 ERC20 代币的 SuperPaymaster 平台，可以极大地降低 DApp 和用户使用 ERC4337 账户抽象的门槛。

下面我们来分析和设计这个 SuperPaymaster 系统。

**可行性分析**

该项目是可行的。ERC-4337 协议本身就是模块化设计的，Paymaster 是其核心组件之一。Pimlico 等已有的开源 Paymaster 实现证明了基础功能的可行性。在此基础上扩展多账户管理、ERC20 配置、增强的 Bundler 校验等功能，虽然增加了复杂性，但在技术上是完全可以实现的。主要挑战在于合约设计的健壮性、安全性以及与 Bundler 的协调。

**技术方案分析与设计**

我们将按照您提出的问题点逐一进行分析和设计。

**1. SuperPaymaster 合约设计 (Stake 管理、安全验证、接口)**

目标：管理多个子账户（Sponsor）的 ETH 质押和提取，并提供交互接口。

**核心数据结构:**

```solidity
// Sponsor 配置信息
struct SponsorConfig {
    address owner;          // Sponsor 配置的所有者 (通常是 Sponsor 地址)
    address token;          // 支持的 ERC20 代币地址
    address priceOracle;    // 用于获取 ERC20/ETH 价格的预言机地址 (可选，也可以用固定汇率)
    uint256 exchangeRate;   // 如果不用预言机，则使用固定汇率 (例如，1 ETH = N ERC20)
    uint256 warningThreshold; // 余额预警阈值 (ETH wei)
    bool isEnabled;         // 是否启用该 Sponsor 配置
    address signer;         // 授权代表此 Sponsor 签名的中继服务器地址
}

// Sponsor 质押信息
struct SponsorStake {
    uint256 stakedAmount;   // 当前质押的 ETH 数量 (wei)
    // uint256 lockedAmount; // (可选) 如果 postOp 需要锁定部分资金，可以在此跟踪
}

// 主要存储
mapping(address => SponsorConfig) public sponsorConfigs; // sponsor 地址 => 配置
mapping(address => SponsorStake) public sponsorStakes;    // sponsor 地址 => 质押信息
mapping(address => bool) public isSponsor;              // 快速检查地址是否为 Sponsor
address public owner;                                   // SuperPaymaster 合约所有者
IEntryPoint public immutable entryPoint;                // EntryPoint 合约地址
```

**关键函数:**

* **管理函数 (通常由 Sponsor Owner 或合约 Owner 调用):**
    * `registerSponsor(address _sponsor)`: (仅限 Owner) 注册一个新的 Sponsor 地址。
    * `setSponsorConfig(address _token, address _priceOracle, uint256 _exchangeRate, uint256 _warningThreshold, address _signer)`: (仅限 Sponsor Owner) 设置或更新 Sponsor 的配置。需要进行输入验证。
    * `enableSponsor(bool _enabled)`: (仅限 Sponsor Owner) 启用/禁用 Sponsor。
    * `depositStake()`: `payable` (Sponsor 调用) Sponsor 向自己的账户质押 ETH。更新 `sponsorStakes[_msgSender()].stakedAmount` 并增加 Paymaster 在 EntryPoint 的总质押 (`entryPoint.depositTo{value: msg.value}(address(this))`)。触发 `StakeDeposited` 事件。
    * `withdrawStake(uint256 _amount)`: (Sponsor 调用) Sponsor 提取部分未锁定的 ETH。需要检查 `_amount <= sponsorStakes[msg.sender].stakedAmount`。先从 EntryPoint 取回 (`entryPoint.withdrawTo(payable(msg.sender), _amount)`)，成功后再更新 `sponsorStakes[msg.sender].stakedAmount`。使用 Reentrancy Guard。触发 `StakeWithdrawn` 事件。
    * `withdrawAllStake()`: (Sponsor 调用) 提取所有质押。类似 `withdrawStake`。

* **ERC-4337 Paymaster 接口 (`validatePaymasterUserOp`, `postOp`):**
    * **`validatePaymasterUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)`:**
        1.  **解码 `paymasterAndData`:**
            * 预期 `paymasterAndData` 包含: `abi.encode(address sponsor, address token, uint256 maxErc20Cost, bytes memory signature)`。
            * 解析出 `sponsor` 地址、`token` 地址、用户愿意支付的最大 `maxErc20Cost` 以及 `signature`。
        2.  **基础验证:**
            * 检查 `sponsor` 是否已注册且已启用 (`isSponsor[sponsor] && sponsorConfigs[sponsor].isEnabled`).
            * 检查 `token` 是否与 `sponsorConfigs[sponsor].token` 匹配。
            * 检查 `paymaster` 地址是否是本合约。
        3.  **签名验证 (核心):**
            * 获取配置的 `sponsorConfigs[sponsor].signer` 地址。
            * 构建需要签名的消息哈希。这通常包含 `userOpHash`, `address(this)` (paymaster), `sponsor` 地址, `token` 地址, `maxErc20Cost` 以及可能的 nonce 或有效期 (`validUntil`, `validAfter` - 这些也需要包含在 `paymasterAndData` 中并在签名时使用)。
            * 使用 `ecrecover` 验证 `signature` 是否由 `sponsorConfigs[sponsor].signer` 签署。
        4.  **价格和余额检查:**
            * 获取 ERC20/ETH 汇率：如果使用 `priceOracle`，调用预言机；否则使用 `sponsorConfigs[sponsor].exchangeRate`。注意处理预言机调用失败或价格无效的情况。
            * 计算 `maxEthCost`：根据汇率将 `maxErc20Cost` 转换为对应的最大 ETH 成本。需要考虑精度问题。
            * **检查 Sponsor 余额:** `require(sponsorStakes[sponsor].stakedAmount >= maxEthCost, "SuperPaymaster: insufficient sponsor stake");` **注意：** 这个检查只能防止单个 UserOp 超额，无法防止并发攻击。Bundler 端的检查是必要的补充（见第 2 点）。
        5.  **设置 Context 和 Gas:**
            * 返回 `context`：`abi.encode(sponsor, token, maxEthCost)`。这个 context 会传递给 `postOp`。
            * 返回 `validUntil` 和 `validAfter` (如果使用)。
    * **`postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost)`:**
        1.  **解码 `context`:** 解析出 `sponsor`, `token`, `maxEthCost`。
        2.  **模式检查:** 通常只处理 `mode == PostOpMode.opSucceeded` 或 `mode == PostOpMode.postOpReverted`。
        3.  **扣款:**
            * `require(actualGasCost <= maxEthCost, "SuperPaymaster: actual cost exceeds max");` // 安全检查
            * `require(sponsorStakes[sponsor].stakedAmount >= actualGasCost, "SuperPaymaster: sponsor stake depleted post-validation");` // 最终检查
            * `sponsorStakes[sponsor].stakedAmount -= actualGasCost;` // 从 Sponsor 内部账本扣款
            * **注意:** Paymaster 在 EntryPoint 的总质押已经在 `_handlePostOp` 中被扣除，这里是更新内部子账户的账本。
        4.  **触发事件:**
            * `emit SponsorshipSuccess(userOpHash, sponsor, token, actualGasCost);` (需要 userOpHash，但这在 postOp 中不易获取，可能需要在 validate 中存入 mapping 或通过其他方式传递，或者事件中不包含 userOpHash，只包含 sponsor 和 cost)。
            * 检查预警: `if (sponsorStakes[sponsor].stakedAmount < sponsorConfigs[sponsor].warningThreshold) { emit StakeWarning(sponsor, sponsorStakes[sponsor].stakedAmount); }`
        5.  **处理 ERC20 (可选但常见):**
            * **方式一 (推荐，Relay Server 处理):** Paymaster 合约只负责 ETH 质押和支付。Relay Server 在确认 UserOp 成功后，在链下或通过独立交易从用户那里收取 ERC20。这需要用户预先 `approve` ERC20 给 Relay Server 或 Sponsor 的收款地址。
            * **方式二 (合约内处理，复杂):** 如果要在 `postOp` 内处理 ERC20 转账 (用户 -> Sponsor)，需要用户在 UserOp 的 `callData` 中包含一个 ERC20 `transfer` 或 `transferFrom` 的调用。这会增加 UserOp 的复杂性和 Gas 成本，且 `postOp` 的 Gas 有限，可能失败。**不推荐在 `postOp` 内直接操作 ERC20 转账。**

**安全性:**

* **访问控制:** 使用 OpenZeppelin 的 `Ownable` 或类似模式管理合约所有者权限。Sponsor 配置和提款应限制为 Sponsor Owner。
* **Reentrancy Guard:** 在 `withdrawStake` 等涉及外部调用（`entryPoint.withdrawTo`）和状态更改的函数上使用。
* **签名防重放:** 签名消息中应包含 `userOpHash` 和 `chainId`，以及可选的 `nonce` 或 `validUntil`/`validAfter` 时间戳，防止签名被重用于其他 UserOp 或链。
* **价格预言机风险:** 如果使用预言机，需要考虑其可靠性、延迟和潜在的操纵风险。使用成熟的预言机（如 Chainlink）并添加安全边际。
* **并发超额风险:** 必须依赖 Bundler 端的检查来缓解此风险。

**2. Bundler 改进 (子账户余额校验)**

目标：修改 Bundler (基于 `ultra-relay`)，在将 UserOp 加入内存池或打包之前，验证 SuperPaymaster 中对应 Sponsor 的余额是否足够。

**修改思路 (`ultra-relay`):**

需要深入 `ultra-relay` 的代码库，找到处理 `UserOperation` 验证的逻辑，特别是在 `validateUserOp` 或类似阶段，针对使用了 SuperPaymaster 的 UserOp 增加以下校验：

1.  **识别 SuperPaymaster UserOp:** 检查 `userOp.paymaster` 是否等于部署的 SuperPaymaster 合约地址。
2.  **解码 `paymasterAndData`:** 解析出 `sponsor` 地址和 `maxErc20Cost` (或者已经计算出的 `maxEthCost`，如果它包含在内的话)。如果 `maxEthCost` 不在 `paymasterAndData` 中，Bundler 需要模拟 `validatePaymasterUserOp` 的价格计算部分来估算 `maxEthCost`。
3.  **查询 Sponsor 余额:** 调用 SuperPaymaster 合约的 `sponsorStakes(sponsor)` view 函数，获取该 Sponsor 当前的 `stakedAmount`。**注意:** 查询的是链上状态，可能不是最新的，但这是 Bundler 能做的最好检查。
4.  **本地账本 (关键):** Bundler 需要维护一个 *本地内存状态*，记录当前正在处理或已包含在待打包块中的、属于同一个 Sponsor 的 UserOp 的 *预期* Gas 成本总和 (`pendingCost[sponsor]`)。
5.  **校验逻辑:**
    * 获取 Sponsor 的链上余额 `onChainStake = sponsorStakes[sponsor].stakedAmount`。
    * 获取当前 UserOp 的预估最大 ETH 成本 `currentOpMaxEthCost` (来自 `paymasterAndData` 或模拟计算)。
    * 获取该 Sponsor 在此 Bundler 中已累积的待处理成本 `pendingCost[sponsor]`。
    * **核心检查:** `require(onChainStake >= pendingCost[sponsor] + currentOpMaxEthCost, "Bundler check: insufficient sponsor stake for pending ops");`
6.  **更新本地账本:** 如果校验通过，将 `currentOpMaxEthCost` 加到 `pendingCost[sponsor]` 上。
7.  **清理本地账本:** 当一个 Bundle 被成功打包上链后，或者某些 UserOp 超时/失败后，需要相应地减少或清除 `pendingCost` 中对应的金额。这需要仔细处理，以避免状态不一致。

**挑战:**

* **实现复杂性:** 需要修改 Bundler 核心验证逻辑，处理并发和状态更新。
* **性能:** 额外的合约调用 (`sponsorStakes`) 和本地状态管理会增加 Bundler 处理每个 UserOp 的开销。
* **状态同步:** Bundler 的本地 `pendingCost` 状态可能与链上状态有延迟或不一致，尤其是在有多个 Bundler 运行时。这无法完全避免，但上述检查能显著降低超额风险。

**3. 合约内完成签名和余额验证的可能性**

* **ERC-4337 流程:** 如您所述，`validatePaymasterUserOp` 用于验证签名和进行初步检查（包括余额），`postOp` 用于实际支付。
* **签名验证方式:**
    * **`ecrecover` (默认):** Relay Server (或 Sponsor 授权的服务器) 使用其 EOA 密钥对消息进行签名。验证发生在合约内，使用 `ecrecover`。这是最常见的方式。
    * **ERC-1271 (合约签名):** 如果签名者是一个合约账户（例如，Sponsor 自己运行一个智能合约钱包来授权），则可以在 `validatePaymasterUserOp` 中调用该签名者合约的 `isValidSignature` 方法进行验证。
* **结合余额验证:** 无论使用 `ecrecover` 还是 ERC-1271，签名验证 *都* 发生在 `validatePaymasterUserOp` 内部。余额检查 (`sponsorStakes[sponsor].stakedAmount >= maxEthCost`) *也* 在 `validatePaymasterUserOp` 中进行。
* **能否解决并发问题?** **不能。** 即使签名和余额检查都在 `validatePaymasterUserOp` 中完成，这个函数可能被并发地为同一个 Sponsor 的多个 UserOp 调用并通过验证（在模拟阶段或被不同 Bundler 处理）。只有在 `postOp` 执行时，余额才会被实际扣除。因此，合约内的检查是必要的，但不足以完全防止并发超额，仍然需要 Bundler 级别的检查。

**结论:** 使用 `ecrecover` 是标准且推荐的方式。结合 ERC-1271 是可能的，如果 Sponsor 的签名授权逻辑很复杂或基于合约。但无论哪种方式，**Bundler 级别的余额校验仍然是缓解并发超额风险的关键补充措施。**

**4. ERC20 兑换比例、上限额度和预警管理**

* **配置:** 通过 `SponsorConfig` 结构体和 `setSponsorConfig` 函数管理。
    * `token`: ERC20 合约地址。
    * `priceOracle` / `exchangeRate`: 用于确定价格。如果使用 `exchangeRate`，单位需要明确（例如，多少 ERC20 wei 等于 1 ETH wei）。
    * `warningThreshold`: Sponsor 设置的 ETH 余额预警线 (绝对值，单位 wei)。
* **上限额度:** 上限由 `sponsorStakes[sponsor].stakedAmount` 动态决定。`validatePaymasterUserOp` 和 Bundler 的检查确保单次或并发操作的总成本不超过此余额。
* **预警触发:** 在 `postOp` 成功扣款后，检查 `sponsorStakes[sponsor].stakedAmount < sponsorConfigs[sponsor].warningThreshold`，如果满足条件，则 `emit StakeWarning(sponsor, sponsorStakes[sponsor].stakedAmount);`。监听这个事件的链下服务可以通知 Sponsor 需要充值。

**5. 继承 Pimlico 的 Paymaster (v0.7 & v0.8)**

* **基础:** 选择 Pimlico 的 `VerifyingPaymaster` 或 `SingletonPaymaster` (如果 EntryPoint v0.7 支持 Singleton) 作为基类。它们提供了 ERC-4337 接口的基本实现、签名验证框架 (`_verifySignature`) 以及与 EntryPoint 交互的函数（存款、提款）。
* **v0.7 实现:**
    * 继承 Pimlico v0.7 版本的 `VerifyingPaymaster`。
    * 覆盖 `_validatePaymasterUserOp` (或类似内部函数) 和 `postOp` 来实现上述的多 Sponsor 逻辑 (解码 `paymasterAndData`，查找 Sponsor 配置和余额，使用 Sponsor 配置的签名者进行验证，从 Sponsor 余额扣款)。
    * 添加 Sponsor 注册、配置、存款、提款的函数和事件。
    * 修改构造函数以接受 EntryPoint v0.7 的地址。
    * 确保 `paymasterAndData` 的编码/解码与 Relay Server/SDK 协同一致。
* **v0.8 实现:**
    * 基础与 v0.7 类似，但继承 Pimlico 针对 EntryPoint v0.8 的 Paymaster 版本（如果 Pimlico 已更新）。
    * 根据 EntryPoint v0.8 的接口调整 `validatePaymasterUserOp` 和 `postOp` 的函数签名和参数（例如，`validatePaymasterUserOp` 返回结构体）。
    * 如果需要支持 EIP-7702，请参见第 7 点。
    * 构造函数接受 EntryPoint v0.8 的地址。

**6. Event 和 ERC-7253 Reputation**

* **成功事件:** 在 `postOp` 成功扣款后，触发 `emit SponsorshipSuccess(userOpHash, sponsor, token, actualGasCost);` (注意 `userOpHash` 的获取可能需要调整)。
* **ERC-7253 (链下处理):**
    1.  一个独立的链下服务监听 `SponsorshipSuccess` 事件。
    2.  当事件触发时，该服务根据事件数据（`sponsor` 地址等）构建一个 ERC-7253 Attestation。
    3.  Attestation 的内容可以包括：证明该 `sponsor` 在特定时间成功赞助了一笔交易，可能包含 `actualGasCost` 等信息。
    4.  该服务使用自己的密钥（Attester）签名此 Attestation，并将其存储（例如，在 IPFS 或专门的 Attestation 数据库中）或直接在链上通过 ERC-7253 注册表发布（如果 Gas 成本可接受）。
    5.  DApps 或其他系统可以查询这些 Attestation 来评估 Sponsor 的声誉（活跃度、可靠性）。

**7. EIP-7702 支持 (EntryPoint v0.8)**

EIP-7702 允许 EOA 通过设置特定的 `authorization` 字段并由授权者（可以是 Paymaster）签名，来委托交易的执行和 Gas 支付，而无需部署智能合约钱包。

**整合 SuperPaymaster (v0.8):**

这需要一种不同于 ERC-4337 UserOp 的处理流程，但可以复用 Sponsor 的质押池。

1.  **新的入口函数:** 在 SuperPaymaster 合约中添加一个新的 `payable` 函数，例如 `sponsorEoaTransaction(bytes calldata _signedTx)`。这个函数会被 Bundler 或专门的 EIP-7702 Relay 调用。
2.  **交易解析与验证:**
    * `sponsorEoaTransaction` 需要解析 `_signedTx`，这是一个符合 EIP-7702 格式的已签名交易。
    * 它需要提取出 EOA 的原始交易参数（`to`, `value`, `data`）、`chainId`、`nonce` 以及 `authorization` 列表。
    * 找到与 SuperPaymaster 相关的 `authorization`。这个 `authorization` 应该包含由 Sponsor 的授权签名者（`sponsorConfigs[sponsor].signer`）签名的授权信息。授权信息需要明确指出允许 SuperPaymaster 代表哪个 `sponsor` 支付 Gas，以及可能的最大 ERC20 成本或直接的最大 ETH 成本，以及对应的 `token` 地址。
    * 验证此授权签名。
3.  **Sponsor 查找与余额检查:**
    * 根据授权信息找到对应的 `sponsor` 地址。
    * 检查 Sponsor 配置 (`sponsorConfigs[sponsor]`) 是否有效、启用，`token` 是否匹配。
    * 计算最大 ETH 成本 (基于授权信息中的 ERC20 成本和汇率，或直接使用授权的 ETH 成本)。
    * 检查 `sponsorStakes[sponsor].stakedAmount` 是否足够覆盖这个成本 *加上* 执行交易本身所需支付的 Gas (这需要估算)。
4.  **执行与 Gas 支付:**
    * 如果验证通过，SuperPaymaster 需要一种机制来支付 Gas。EIP-7702 的核心是由 *Bundler* (或区块提议者) 识别授权并从授权者（Paymaster）那里收取 Gas。Paymaster 合约本身可能 *不需要* 直接执行 `CALL`，而是需要确保自己在 EntryPoint (或其他机制) 中有足够的 ETH 供 Bundler 收取。
    * **关键问题:** EIP-7702 的 Gas 支付机制与 ERC-4337 的 `postOp` 不同。它更像是 EIP-1559 的 Gas 支付，但费用从授权者（Paymaster）账户扣除。SuperPaymaster 需要确保其在 EntryPoint 的存款足以覆盖这些 EIP-7702 交易的 Gas 费用。
    * 在交易成功后（由链下服务或 Bundler 确认），需要更新 Sponsor 的内部账本 `sponsorStakes[sponsor].stakedAmount`，扣除实际 Gas 成本。这可能需要在 `sponsorEoaTransaction` 函数中进行某种形式的预扣或锁定，然后在链下确认后最终结算，或者依赖 Bundler/Relay 提供可靠的回调或证明。这部分机制比 ERC-4337 的 `postOp` 更复杂。
5.  **事件与预警:** 同样，在扣款后触发成功事件和预警检查。

**v0.7 vs v0.8 合约:**

* **SuperPaymasterV0_7.sol:** 继承 Pimlico v0.7 Paymaster，实现 ERC-4337 v0.7 接口，包含多 Sponsor 质押、配置、验证、`postOp` 逻辑。
* **SuperPaymasterV0_8.sol:** 继承 Pimlico v0.8 Paymaster (或适配)，实现 ERC-4337 v0.8 接口。**如果需要支持 EIP-7702，** 添加 `sponsorEoaTransaction` 函数和相关逻辑，处理 EIP-7702 授权验证和 Gas 预留/扣款（这部分比较复杂，需要仔细设计与 Bundler/Relay 的交互）。

**8. 失败管理、重试、补偿 (低优先级)**

* **链上失败:**
    * `validatePaymasterUserOp` 失败：UserOp 不会被处理，无影响。
    * `postOp` 失败：整个交易（包括 UserOp）回滚。Sponsor 质押不扣款。用户操作未执行。
* **链下失败:**
    * Relay Server 签名失败：UserOp 无法提交。
    * Bundler 验证失败（如余额不足）：UserOp 被拒绝。
    * 网络问题导致 UserOp 未上链。
* **处理:**
    * **监控:** 链下服务监控 UserOp 状态和 Paymaster 事件。
    * **日志:** Relay Server 和 Bundler 应记录详细日志。
    * **重试:** 对于可恢复的错误（如临时网络问题、nonce 过低），Relay Server 或用户可以重试提交 UserOp。
    * **补偿:** 如果因为 Paymaster 或 Relay Server 的问题导致用户损失（例如，支付了 ERC20 但交易未成功），需要根据服务协议进行链下补偿。这通常涉及复杂的争议解决和证明机制。
    * **Proof:** 交易哈希、事件日志、签名数据、Bundler/Relay 日志都可以作为证据。

**关键合约模块设计 (基于 Pimlico VerifyingPaymaster)**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19; // 或更高版本，根据 EntryPoint 和依赖调整

import {UserOperation} from "@erc4337/contracts/interfaces/UserOperation.sol";
import {IEntryPoint} from "@erc4337/contracts/interfaces/IEntryPoint.sol";
import {IPaymaster} from "@erc4337/contracts/interfaces/IPaymaster.sol";
import {VerifyingPaymaster} from "path/to/pimlico/VerifyingPaymaster.sol"; // 替换为实际 Pimlico 路径
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {IPriceOracle} from "./interfaces/IPriceOracle.sol"; // 如果使用预言机

// 注意：以下代码是 V0.7 的概念设计，V0.8 接口可能略有不同
contract SuperPaymasterV0_7 is VerifyingPaymaster, Ownable, ReentrancyGuard {

    struct SponsorConfig {
        address owner;
        address token;
        // address priceOracle; // 启用预言机则取消注释
        uint256 exchangeRate; // e.g., 1 ETH wei = N Token wei
        uint256 warningThreshold; // ETH wei
        bool isEnabled;
        address signer; // Authorized relay/sponsor signer
    }

    struct SponsorStake {
        uint256 stakedAmount; // wei
    }

    mapping(address => SponsorConfig) public sponsorConfigs;
    mapping(address => SponsorStake) public sponsorStakes;
    mapping(address => bool) public isSponsor;

    event SponsorRegistered(address indexed sponsor);
    event SponsorConfigSet(address indexed sponsor, address indexed token, uint256 exchangeRate, uint256 warningThreshold, address signer);
    event SponsorEnabled(address indexed sponsor, bool enabled);
    event StakeDeposited(address indexed sponsor, uint256 amount);
    event StakeWithdrawn(address indexed sponsor, uint256 amount);
    event SponsorshipSuccess(bytes32 indexed userOpHash, address indexed sponsor, address indexed token, uint256 actualGasCost);
    event StakeWarning(address indexed sponsor, uint256 currentStake);

    // --- Constructor and Basic Setup ---

    // constructor(IEntryPoint _entryPoint, address _owner, address _verifyingSigner) VerifyingPaymaster(_entryPoint, _verifyingSigner) {
    // Pimlico 的 VerifyingPaymaster 可能需要一个全局 signer，但在我们的模型中，签名者是 Sponsor 特定的。
    // 需要调整基类或覆盖签名验证逻辑。
    // 这里假设基类构造函数可以被调整或我们直接覆盖验证。
    constructor(IEntryPoint _entryPoint, address _initialOwner) VerifyingPaymaster(_entryPoint, address(0)) Ownable(_initialOwner) {
       // 基类的 signer 设为 0，因为我们用 sponsor 特定的 signer
    }

    // --- Sponsor Management ---

    function registerSponsor(address _sponsor) external onlyOwner {
        require(!isSponsor[_sponsor], "Sponsor already registered");
        isSponsor[_sponsor] = true;
        // Initialize default config (owner = sponsor itself)
        sponsorConfigs[_sponsor] = SponsorConfig({
            owner: _sponsor,
            token: address(0),
            // priceOracle: address(0),
            exchangeRate: 0,
            warningThreshold: 0,
            isEnabled: false,
            signer: address(0)
        });
        emit SponsorRegistered(_sponsor);
    }

    function setSponsorConfig(address _token, uint256 _exchangeRate, uint256 _warningThreshold, address _signer) external {
        address _sponsor = msg.sender; // Or check config owner: require(msg.sender == sponsorConfigs[_sponsor].owner)
        require(isSponsor[_sponsor], "Not a sponsor");
        require(_token != address(0), "Invalid token address");
        require(_signer != address(0), "Invalid signer address");
        // Add more validation for rate and threshold if needed

        SponsorConfig storage config = sponsorConfigs[_sponsor];
        config.token = _token;
        config.exchangeRate = _exchangeRate;
        config.warningThreshold = _warningThreshold;
        config.signer = _signer;

        emit SponsorConfigSet(_sponsor, _token, _exchangeRate, _warningThreshold, _signer);
    }

    function enableSponsor(bool _enabled) external {
         address _sponsor = msg.sender; // Or check config owner
         require(isSponsor[_sponsor], "Not a sponsor");
         sponsorConfigs[_sponsor].isEnabled = _enabled;
         emit SponsorEnabled(_sponsor, _enabled);
    }

    // --- Stake Management ---

    function depositStake() external payable nonReentrant {
        address _sponsor = msg.sender;
        require(isSponsor[_sponsor], "Not a sponsor");
        require(msg.value > 0, "Deposit value must be positive");

        sponsorStakes[_sponsor].stakedAmount += msg.value;
        // Deposit funds to EntryPoint for this paymaster
        entryPoint.depositTo{value: msg.value}(address(this));

        emit StakeDeposited(_sponsor, msg.value);
    }

    function withdrawStake(uint256 _amount) external nonReentrant {
        address _sponsor = msg.sender;
        require(isSponsor[_sponsor], "Not a sponsor");
        SponsorStake storage stake = sponsorStakes[_sponsor];
        require(_amount > 0 && _amount <= stake.stakedAmount, "Invalid withdraw amount");

        stake.stakedAmount -= _amount; // Update internal ledger first

        // Withdraw from EntryPoint
        entryPoint.withdrawTo(payable(_sponsor), _amount);

        emit StakeWithdrawn(_sponsor, _amount);
    }

     // --- Overridden Paymaster Functions ---

    function _validatePaymasterUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal view override returns (bytes memory context, uint256 validationData)
    {
        // 1. Decode paymasterAndData
        (address sponsor, address token, uint256 maxErc20Cost, uint48 validUntil, uint48 validAfter, bytes memory signature) = abi.decode(
            userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:], // Adjust offset based on基类
            (address, address, uint256, uint48, uint48, bytes)
        );

        // 2. Basic Validations
        require(isSponsor[sponsor] && sponsorConfigs[sponsor].isEnabled, "SP: Sponsor invalid or disabled");
        require(token == sponsorConfigs[sponsor].token, "SP: Token mismatch");
        require(block.timestamp <= validUntil && block.timestamp >= validAfter, "SP: Timestamp invalid");

        // 3. Signature Verification
        address signer = sponsorConfigs[sponsor].signer;
        bytes32 sigHash = _getHash(userOpHash, sponsor, token, maxErc20Cost, validUntil, validAfter); // Use the基类 method or implement your own hashing
        require(signer == ECDSA.recover(sigHash, signature), "SP: Invalid signature"); // Replace ECDSA.recover with Pimlico's internal or OZ lib

        // 4. Price & Balance Check
        uint256 exchangeRate = sponsorConfigs[sponsor].exchangeRate;
        require(exchangeRate > 0, "SP: Invalid exchange rate");
        // Calculate max ETH cost based on rate. Be careful with division and precision.
        // Example: If rate is "N token wei per 1 ETH wei", maxEthCost = (maxErc20Cost * 1 ether) / exchangeRate
        // Example: If rate is "N ETH wei per 1 Token wei", maxEthCost = maxErc20Cost * exchangeRate / (10**tokenDecimals) // Requires token decimals
        // Let's assume rate is "Token Wei per 1 ETH Wei" for simplicity here:
        uint256 maxEthCost = (maxErc20Cost * 1 ether) / exchangeRate;
        require(maxEthCost <= maxCost, "SP: Calculated ETH cost exceeds maxCost"); // Check against EP provided maxCost

        require(sponsorStakes[sponsor].stakedAmount >= maxEthCost, "SP: Insufficient sponsor stake");

        // 5. Return Context & Validation Data (validUntil, validAfter)
        context = abi.encode(sponsor, token, maxEthCost, userOpHash); // Include userOpHash for event later
        validationData = _packValidationData(true, validUntil, validAfter); // true for sig validation, pack timestamps

        return (context, validationData);
    }


    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost) internal override {
        (address sponsor, address token, uint256 maxEthCost, bytes32 userOpHash) = abi.decode(context, (address, address, uint256, bytes32));

        // Refund unused stake if op reverted or didn't consume gas (handled by base contract usually)
        super._postOp(mode, context, actualGasCost); // Call base postOp first for standard handling

        if (mode == PostOpMode.opSucceeded || mode == PostOpMode.postOpReverted) {
             // Check if base contract already handled the charge, if not:
             // require(actualGasCost <= maxEthCost, "SP: Actual cost exceeds calculated max"); // Sanity check
             require(sponsorStakes[sponsor].stakedAmount >= actualGasCost, "SP: Insufficient stake post-validation");

             sponsorStakes[sponsor].stakedAmount -= actualGasCost;

             // Emit success event (only if opSucceeded?)
             if (mode == PostOpMode.opSucceeded) {
                 emit SponsorshipSuccess(userOpHash, sponsor, token, actualGasCost);
             }

             // Check warning threshold
             if (sponsorStakes[sponsor].stakedAmount < sponsorConfigs[sponsor].warningThreshold) {
                 emit StakeWarning(sponsor, sponsorStakes[sponsor].stakedAmount);
             }
        }
        // No ERC20 handling here, assumed off-chain or via UserOp execution data
    }

    // --- Helper Functions ---

    function _getHash(bytes32 userOpHash, address sponsor, address token, uint256 maxErc20Cost, uint48 validUntil, uint48 validAfter)
        internal view returns (bytes32)
    {
        // Mimic the hashing logic expected by the signer (Relay Server)
        return keccak256(abi.encode(
            userOpHash,
            address(this), // Paymaster address
            sponsor,
            token,
            maxErc20Cost,
            validUntil,
            validAfter,
            block.chainid
        ));
    }

     // Override _verifySig if necessary, or rely on _validatePaymasterUserOp logic above
     // function _verifySig(bytes32 userOpHash, bytes calldata paymasterAndData) internal view override returns (uint256 validationData, address signer, bytes memory context) { ... }

     // Helper to pack validation data (timestamps, sig validation flag)
     function _packValidationData(bool sigValidated, uint48 validUntil, uint48 validAfter) internal pure returns (uint256) {
         // Refer to EntryPoint specification for packing format
         // Typically involves bit shifting `validUntil` and `validAfter`
         // And potentially a flag for signature success
         uint256 timestamps = (uint256(validUntil) << 48) | uint256(validAfter);
         // Example: If EP expects 0 for success, 1 for failure:
         return sigValidated ? timestamps : timestamps | 1;
     }

     // Offset within paymasterAndData where sponsor-specific data starts
     // This might depend on how Pimlico's base contract structures it.
     // If base contract uses first 20 bytes for signer, offset is 20. Adjust accordingly.
     uint256 internal constant PAYMASTER_DATA_OFFSET = 20; // EXAMPLE - VERIFY THIS

    // Add receive() function to accept ETH from EntryPoint during reconciliation if needed
    receive() external payable {}
}
```

**时序图 (Mermaid)**

**ERC-4337 流程 (带 SuperPaymaster 和 Bundler 检查)**

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

**文字描述:**

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

这个流程结合了合约内的验证和 Bundler 端的并发控制，为 SuperPaymaster 提供了一个相对健壮的多账户 Gas 赞助方案。请务必仔细测试合约和 Bundler 的交互，特别是边缘情况和并发场景。

## Dev plan

### Project Overview

The SuperPaymaster is a decentralized gas payment solution based on ERC-4337 that allows multiple sponsors to fund transactions using ERC20 tokens. The system consists of:

1. **SuperPaymaster Contract**: A multi-tenant contract where sponsors can deposit ETH, set ERC20 token rates, and authorize relays
2. **Paymaster Relay Server**: Signs paymaster data on behalf of sponsors
3. **Modified Bundler**: Verifies sponsor balances at the bundler level to prevent concurrent overdraws

### Development Phases

#### Phase 1: Environment Setup and Baseline (1 week)

1. **Foundry Project Setup**
   - Initialize the project with Foundry
   - Configure dependencies and imports for Pimlico's SingletonPaymaster
   - Set up testing environment

2. **Contract Architecture Design**
   - Define data structures for Sponsor configuration and stake management
   - Create interface definitions
   - Document contract interaction flows

#### Phase 2: Core Contract Development (2 weeks)

1. **Sponsor Management Module**
   - Implement sponsor registration and configuration
   - Develop stake deposit and withdrawal functionality
   - Add stake warning threshold mechanisms

2. **Signature Verification**
   - Implement signature creation and verification for paymasterAndData
   - Develop mechanisms to validate sponsor-specific signers
   - Create utilities for hash calculation and validation data packing

3. **ERC20 Price Management**
   - Implement exchange rate configuration
   - Add optional price oracle integration
   - Develop ETH cost calculation from ERC20 cost

4. **Core ERC-4337 Integration**
   - Implement validatePaymasterUserOp with sponsor-specific logic
   - Develop postOp functionality for handling payments
   - Add event emission for monitoring and off-chain processing

#### Phase 3: Testing and Validation (2 weeks)

1. **Unit Testing**
   - Test sponsor registration, configuration and stake management
   - Validate signature verification mechanism
   - Test ERC20 to ETH conversion logic
   - Verify validatePaymasterUserOp and postOp functionality

2. **Integration Testing**
   - Test full UserOperation flow including EntryPoint interactions
   - Validate event emissions
   - Test edge cases and failure scenarios

3. **Gas Optimization**
   - Analyze gas costs and optimize expensive operations
   - Implement gas-efficient storage patterns
   - Benchmark different implementations

#### Phase 4: Documentation and Deployment (1 week)

1. **Documentation**
   - Create comprehensive technical documentation
   - Document contract interfaces and events
   - Create integration guides for Relay Servers and Bundlers

2. **Deployment Scripts**
   - Prepare deployment scripts for different networks
   - Configure test deployments
   - Set up verification processes

### Foundry Setup Steps

1. **Initialize Project**

```bash
# Install Foundry if not already installed
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Create a new Foundry project
forge init SuperPaymaster-Contract

# Navigate to the project directory
cd SuperPaymaster-Contract
```

2. **Configure Dependencies**

```bash
# Add dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install eth-infinitism/account-abstraction

# Add Pimlico's SingletonPaymaster as a submodule
git submodule add https://github.com/pimlicolabs/singleton-paymaster.git lib/singleton-paymaster
```

3. **Configure foundry.toml**

Create or modify `foundry.toml` to include:

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.19"
optimizer = true
optimizer_runs = 200
remappings = [
    "@openzeppelin/=lib/openzeppelin-contracts/",
    "@account-abstraction/=lib/account-abstraction/",
    "@singleton-paymaster/=lib/singleton-paymaster/",
]
```

4. **Create Contract Structure**

```bash
mkdir -p src/v0_7
mkdir -p src/v0_8
mkdir -p src/interfaces
mkdir -p test/v0_7
mkdir -p test/v0_8
```

5. **Initial Contract Implementation**

Create the base contract files:

```bash
touch src/interfaces/ISuperPaymaster.sol
touch src/v0_7/SuperPaymasterV0_7.sol
touch src/v0_8/SuperPaymasterV0_8.sol
```

6. **Test Setup**

Create test files:

```bash
touch test/v0_7/SuperPaymasterV0_7.t.sol
touch test/v0_8/SuperPaymasterV0_8.t.sol
```

7. **Build and Test**

```bash
# Compile contracts
forge build

# Run tests
forge test

# Generate gas report
forge test --gas-report
```

### Implementation Strategy

For the SuperPaymaster implementation, we will:

1. **Extend the Singleton Paymaster**: Use inheritance to build on top of Pimlico's implementation
2. **Add Multi-Sponsor Support**: Implement our own data structures and logic for multi-tenant operations
3. **Integrate with ERC-4337 Flow**: Conform to the EntryPoint interfaces for v0.7 and v0.8
4. **Implement Flexible Signature Verification**: Support sponsor-specific signers with ecrecover

Our approach prioritizes:
- Minimal modifications to the core ERC-4337 flow
- Gas efficiency for common operations
- Security against signature forgery and balance manipulation
- Clear interfaces for integration with other components