# Feats
我们有两个版本：v0.7和v0.8，分别对应了Entrypointv0.7和v0.8：https://github.com/eth-infinitism/account-abstraction/releases。

## 继承所有Singleton Paymaster feats
1. 基于submodule pimlico repo，不修改，继承
2. 罗列原有的核心接口和功能在此
3. 完成功能测试，记录v0.6.01，后续按此追加0.01每次


## v0.7:多租户的账户管理
1. 无需可的stake ETH和管理功能：查看余额，查看资助的交易（合约不存储，web ui提供etherscan过滤参数和查看）
2. withdraw的锁定期，等结算周期完毕后，一般1小时之后，在进行的交易完成后
3. 保障不被滥用的余额检查（合约部分）
4. 更多feat参考 @solution.md

## v0.8继承所有0.7feats
不再罗列，原则上继承0.7功能，但针对Entrypoint0.8做出了优化和新增。
罗列0.8的变更和新增feat在此。

## v0.8 EOA gas sponsor
1. 基于EIP7702，支持EOA能够简单的授权delegation gas sponsor合约，然后代付gas
2. 基于此demo： https://docs.pimlico.io/permissionless/how-to/eip-7702-demo， 修改demo到二次验证， https://docs.pimlico.io/conceptual/eip7702 ，完成一个最简单，最安全的代付合约，EOA授权后基于ERC20 gas token来代付。
3. 代付gas的ERC20扣除支持专门账户扣除，进一步提供安全性，无需对EOA账户进行ERC20扣除，而是其他专用地址账户，此账户创建时就授权了ERC20 gas token和superpayermaster合约的扣除权限。
4. 个人专用账户批量扣除。为了节省gas和效率，个人可以有一个gas token存储和扣除的专用账户，superpaymaster在支付gas时不扣除，只锁定对应余额？或者计数一次，配合一定的ERC20信用额度，可以适度透支，就可以异步的把例如20次gas sponsor的ERC20一次性转账。
5. 专用账户的批量扣除。借鉴个人专用账户，为了节省gas和效率，某个社区可以指定一个专用账户，服务于大家的EOA免gas交易。此功能容易引起滥用，低优先级，先设计，不开发。

## 疑问和确认
### 关于admin角色和多租户功能
在SuperPaymaster合约中，虽然设计为多租户系统，但仍需要一定的治理和控制机制。admin/manager的作用主要有：
控制谁可以成为sponsor：registerSponsor函数由admin/manager控制，这是为了防止恶意用户注册sponsor并可能滥用系统
管理bundler白名单：控制哪些bundler可以提交UserOperation
系统治理：处理紧急情况和升级
修改注释从"Only callable by contract owner"到"Only callable by contract admin or manager"实际上是更加准确的，因为实现中使用的是onlyAdminOrManager修饰符而非onlyOwner。这不会影响多租户功能，因为：
一旦用户被注册为sponsor后，他们就能自由地管理自己的stake、配置和资金
sponsor的所有日常操作（配置、存入、提取资金等）仍然是完全自治的
admin只负责初始注册环节，不干预sponsor的日常操作
